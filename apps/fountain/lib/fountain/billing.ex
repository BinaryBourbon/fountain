defmodule Fountain.Billing do
  @moduledoc """
  Billing context: Stripe integration, subscription gating, and usage aggregation.

  ## Hard gate pattern

      # Raises SubscriptionRequiredError for past_due / canceled:
      Fountain.Billing.assert_active!(current_user)

  Call sites:
  - `ConversationServer.init/1` — blocks new conversations at the GenServer level
  - `POST /api/conversations` controller — returns HTTP 402 on failure
  - `on_mount :require_active_subscription` LiveView hook — redirects to billing page

  ## Webhook sync

      Fountain.Billing.sync_subscription(stripe_event)

  Called from `FountainWeb.StripeWebhookController` after signature verification.
  """

  import Ecto.Query

  alias Fountain.Accounts.User
  alias Fountain.Billing.UsageEvent
  alias Fountain.Repo

  # ─── Error ─────────────────────────────────────────────────────────────────

  defmodule SubscriptionRequiredError do
    @moduledoc """
    Raised by `Fountain.Billing.assert_active!/1` when the user's subscription
    status does not permit new conversation creation.

    `plug_status: 402` lets Phoenix's FallbackController render the correct HTTP
    status automatically if the error propagates as far as the fallback.
    """
    defexception message: "An active subscription is required to perform this action.",
                 plug_status: 402
  end

  # ─── Gate ──────────────────────────────────────────────────────────────────

  @active_statuses ~w(trialing active)

  @doc """
  Returns `:ok` when the user's subscription allows new conversation creation.
  Raises `SubscriptionRequiredError` for `past_due` and `canceled` statuses.
  """
  @spec assert_active!(User.t()) :: :ok
  def assert_active!(%User{subscription_status: status}) when status in @active_statuses,
    do: :ok

  def assert_active!(%User{}), do: raise(SubscriptionRequiredError)

  # ─── Stripe customer ────────────────────────────────────────────────────────

  @doc """
  Creates a Stripe Customer for the given user, stores `stripe_customer_id`,
  and sets `trial_ends_at` to 14 days from now.

  Intended to be called via `Task.async` after email verification so it does
  not block the HTTP response. The user is already `trialing` by default;
  this call attaches the customer record to Stripe before the trial ends.
  """
  @spec create_stripe_customer(User.t()) :: {:ok, User.t()} | {:error, term()}
  def create_stripe_customer(%User{} = user) do
    with {:ok, %Stripe.Customer{id: customer_id}} <-
           Stripe.Customer.create(%{email: user.email, metadata: %{"user_id" => user.id}}) do
      trial_ends_at =
        DateTime.utc_now()
        |> DateTime.add(14 * 24 * 60 * 60, :second)
        |> DateTime.truncate(:second)

      user
      |> User.billing_changeset(%{
        stripe_customer_id: customer_id,
        trial_ends_at: trial_ends_at
      })
      |> Repo.update()
    end
  end

  # ─── Webhook sync ───────────────────────────────────────────────────────────

  @doc """
  Syncs `users.subscription_status` (and `trial_ends_at`) from a verified
  Stripe webhook event.

  Handles `customer.subscription.created`, `.updated`, `.deleted`.
  All other event types return `{:ok, :ignored}` without touching the DB.
  """
  @spec sync_subscription(Stripe.Event.t()) :: {:ok, User.t() | :ignored} | {:error, term()}
  def sync_subscription(%Stripe.Event{type: type, data: %{object: sub}})
      when type in [
             "customer.subscription.created",
             "customer.subscription.updated",
             "customer.subscription.deleted"
           ] do
    customer_id = extract_customer_id(sub.customer)
    status = coerce_status(sub.status, type)

    trial_ends_at =
      case Map.get(sub, :trial_end) do
        nil -> nil
        ts when is_integer(ts) -> DateTime.from_unix!(ts) |> DateTime.truncate(:second)
      end

    case get_user_by_stripe_customer_id(customer_id) do
      nil ->
        {:error, :user_not_found}

      user ->
        user
        |> User.billing_changeset(%{
          subscription_status: status,
          trial_ends_at: trial_ends_at
        })
        |> Repo.update()
    end
  end

  def sync_subscription(_event), do: {:ok, :ignored}

  # ─── Usage summary ──────────────────────────────────────────────────────────

  @doc """
  Returns a usage summary for `user_id` over the given period.

  Fields:
  - `:conversations` — count of `sandbox_provisioned` events
  - `:turns` — count of `turn_started` events
  - `:sandbox_minutes` — total wall-clock sandbox time in minutes, derived
    from `duration_ms` metadata on `sandbox_terminated` events
  """
  @spec usage_summary(binary(), DateTime.t(), DateTime.t()) ::
          %{conversations: non_neg_integer(), turns: non_neg_integer(), sandbox_minutes: float()}
  def usage_summary(user_id, %DateTime{} = period_start, %DateTime{} = period_end) do
    events =
      from(e in UsageEvent,
        where:
          e.user_id == ^user_id and
            e.inserted_at >= ^period_start and
            e.inserted_at < ^period_end
      )
      |> Repo.all()

    conversations = Enum.count(events, &(&1.event_type == "sandbox_provisioned"))
    turns = Enum.count(events, &(&1.event_type == "turn_started"))

    sandbox_minutes =
      events
      |> Enum.filter(&(&1.event_type == "sandbox_terminated"))
      |> Enum.reduce(0.0, fn ev, acc ->
        ms =
          get_in(ev.metadata, ["duration_ms"]) ||
            get_in(ev.metadata, [:duration_ms]) || 0

        acc + ms / 60_000.0
      end)

    %{conversations: conversations, turns: turns, sandbox_minutes: sandbox_minutes}
  end

  # ─── Usage emission ─────────────────────────────────────────────────────────

  @doc """
  Writes a usage event synchronously to `usage_events`.

  Called from `ConversationServer` at sandbox provisioning, turn start,
  and sandbox termination points.
  """
  @spec emit(binary(), String.t(), binary() | nil, String.t() | nil, map()) ::
          {:ok, UsageEvent.t()} | {:error, Ecto.Changeset.t()}
  def emit(user_id, event_type, resource_id, resource_type, metadata \\ %{}) do
    %UsageEvent{}
    |> UsageEvent.changeset(%{
      user_id: user_id,
      event_type: event_type,
      resource_id: resource_id,
      resource_type: resource_type,
      metadata: metadata,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert()
  end

  # ─── Private helpers ────────────────────────────────────────────────────────

  defp get_user_by_stripe_customer_id(nil), do: nil

  defp get_user_by_stripe_customer_id(customer_id) when is_binary(customer_id) do
    Repo.get_by(User, stripe_customer_id: customer_id)
  end

  # Stripe can return the customer as a plain string ID or as an expanded object.
  defp extract_customer_id(customer) when is_binary(customer), do: customer
  defp extract_customer_id(%{id: id}) when is_binary(id), do: id
  defp extract_customer_id(_), do: nil

  # Deleted events always map to "canceled" regardless of the Stripe status field.
  defp coerce_status(_stripe_status, "customer.subscription.deleted"), do: "canceled"
  defp coerce_status("trialing", _), do: "trialing"
  defp coerce_status("active", _), do: "active"
  defp coerce_status("past_due", _), do: "past_due"
  defp coerce_status("canceled", _), do: "canceled"
  defp coerce_status("unpaid", _), do: "past_due"
  defp coerce_status("incomplete", _), do: "past_due"
  defp coerce_status("incomplete_expired", _), do: "canceled"
  defp coerce_status("paused", _), do: "past_due"
  defp coerce_status(_, _), do: "past_due"
end
