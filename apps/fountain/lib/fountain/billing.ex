defmodule Fountain.Billing do
  @moduledoc """
  Billing context: Stripe integration, subscription gating, and usage aggregation.

  ## Hard gate pattern

      # Raises SubscriptionRequiredError for past_due / canceled:
      Fountain.Billing.assert_active!(current_user)

  Call sites:
  - `Conversations.start_conversation/1` and the wake path — the backstop. Every
    route to a sprite passes through one of these, so a new surface cannot
    silently skip the gate the way `POST /api/conversations/:id/prompts` did.
  - `POST /api/conversations` controller — fast 402 before doing any work
  - `on_mount :require_active_subscription` LiveView hook — redirects to billing.
    Mount-time only, so it does not cover a session that is cancelled mid-flight;
    the context-level check does.

  ## Webhook sync

      Fountain.Billing.sync_subscription(stripe_event)

  Called from `FountainWeb.StripeWebhookController` after signature verification.
  """

  import Ecto.Query

  require Logger

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

  @doc """
  Non-raising gate, for `with` pipelines in contexts.

  Accepts a user or a user id. An unknown id fails closed: a caller that cannot
  identify the user must not be able to provision on someone's behalf.
  """
  @spec check_active(User.t() | binary()) :: :ok | {:error, :subscription_required}
  def check_active(%User{subscription_status: status}) when status in @active_statuses, do: :ok
  def check_active(%User{}), do: {:error, :subscription_required}

  def check_active(user_id) when is_binary(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :subscription_required}
      user -> check_active(user)
    end
  end

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

  @doc """
  Returns the user with a `stripe_customer_id`, creating the Stripe Customer if
  it is missing.

  Checkout must never be opened without one. Passing `customer_email` instead
  makes Stripe mint its own Customer whose id we never learn, so the resulting
  `customer.subscription.created` webhook matches no user and the payment is
  taken without ever activating the account.
  """
  @spec ensure_stripe_customer(User.t()) :: {:ok, User.t()} | {:error, term()}
  def ensure_stripe_customer(%User{stripe_customer_id: id} = user)
      when is_binary(id) and id != "",
      do: {:ok, user}

  def ensure_stripe_customer(%User{} = user), do: create_stripe_customer(user)

  @doc """
  Attach a Stripe customer id to a user that has none.

  Used to repair the accounts created before Checkout guaranteed a customer:
  `checkout.session.completed` carries both the customer id and our
  `client_reference_id`, which is the only way back to the user for a Customer
  Stripe minted on its own.
  """
  @spec attach_stripe_customer(User.t(), binary()) :: {:ok, User.t()} | {:error, term()}
  def attach_stripe_customer(%User{} = user, customer_id) when is_binary(customer_id) do
    user
    |> User.billing_changeset(%{stripe_customer_id: customer_id})
    |> Repo.update()
  end

  # ─── Webhook sync ───────────────────────────────────────────────────────────

  @doc """
  Syncs `users.subscription_status` (and `trial_ends_at`) from a verified
  Stripe webhook event.

  Handles `customer.subscription.created`, `.updated`, `.deleted`.
  All other event types return `{:ok, :ignored}` without touching the DB.
  """
  @spec sync_subscription(Stripe.Event.t()) :: {:ok, User.t() | :ignored} | {:error, term()}
  def sync_subscription(%Stripe.Event{
        type: "checkout.session.completed",
        data: %{object: session}
      }) do
    customer_id = extract_customer_id(Map.get(session, :customer))
    user_id = Map.get(session, :client_reference_id)

    cond do
      is_nil(customer_id) ->
        {:ok, :ignored}

      # Already linked — the subscription events will carry the same customer.
      not is_nil(get_user_by_stripe_customer_id(customer_id)) ->
        {:ok, :ignored}

      is_binary(user_id) ->
        case Repo.get(User, user_id) do
          nil -> {:error, :user_not_found}
          user -> attach_stripe_customer(user, customer_id)
        end

      true ->
        {:error, :user_not_found}
    end
  end

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
  Best-effort `emit/5`.

  Metering is bookkeeping: it must never be able to fail a conversation. A bad
  changeset, a dropped connection or an unexpected raise is logged and swallowed,
  the same contract `Fountain.Audit.record/1` uses. The cost is that a silent
  metering outage looks like zero usage — worth an alert once there is anything
  to bill.
  """
  @spec record_usage(binary(), String.t(), binary() | nil, String.t() | nil, map()) ::
          {:ok, UsageEvent.t()} | {:error, term()}
  def record_usage(user_id, event_type, resource_id, resource_type, metadata \\ %{}) do
    case emit(user_id, event_type, resource_id, resource_type, metadata) do
      {:ok, _} = ok ->
        ok

      {:error, %Ecto.Changeset{} = cs} ->
        Logger.warning("usage: #{event_type} rejected: #{inspect(cs.errors)}")
        {:error, :invalid}
    end
  rescue
    e ->
      Logger.warning("usage: #{event_type} failed: #{Exception.message(e)}")
      {:error, :exception}
  end

  @doc """
  Writes a usage event synchronously to `usage_events`.

  Raises nothing itself but returns `{:error, changeset}` on rejection. Callers
  on a conversation's critical path should use `record_usage/5`, which cannot
  fail the operation it is measuring.

  Emitted from `Conversations.update_sandbox/2` and `Conversations.create_turn/1`
  rather than from `ConversationServer`, so every path that provisions, runs or
  tears down a sandbox is counted — including the wake path and the
  terminate-when-the-server-is-already-dead path.
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
