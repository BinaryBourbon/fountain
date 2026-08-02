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
  def assert_active!(%User{} = user) do
    case check_active(user) do
      :ok -> :ok
      {:error, :subscription_required} -> raise(SubscriptionRequiredError)
    end
  end

  @doc """
  Whether the subscription gate is enforced at all.

  ADR 0006 made it a product invariant. On a self-hosted instance it is a lock
  on the front door with no key, so `BILLING_ENABLED=false` disables it — config
  rather than the source patch the ADR assumed.
  """
  def enabled?, do: Application.get_env(:fountain, :billing_enabled, true)

  @doc """
  Non-raising gate, for `with` pipelines in contexts.

  Accepts a user or a user id. An unknown id fails closed: a caller that cannot
  identify the user must not be able to provision on someone's behalf.
  """
  @spec check_active(User.t() | binary()) :: :ok | {:error, :subscription_required}
  def check_active(subject) do
    if enabled?() do
      do_check_active(subject)
    else
      :ok
    end
  end

  # `trialing` is only active while the trial actually has time left. The
  # subscription created at signup means Stripe drives this and sends a webhook
  # when the trial ends — but the whole reason trials never expired is that the
  # expiry depended on something arriving. Checking the clock too means an
  # undelivered webhook, a Stripe outage or a misconfigured endpoint delays
  # revenue rather than forfeiting it.
  #
  # A nil `trial_ends_at` is treated as no expiry. 159 production accounts are
  # in that state, from before a trial end was recorded at all; deciding their
  # cutoff is a business call, not something a boolean should do silently. See
  # Fountain.Release.expire_legacy_trials/1.
  defp do_check_active(%User{subscription_status: "trialing", trial_ends_at: nil}), do: :ok

  defp do_check_active(%User{subscription_status: "trialing", trial_ends_at: ends_at}) do
    if DateTime.compare(DateTime.utc_now(), ends_at) == :lt do
      :ok
    else
      {:error, :subscription_required}
    end
  end

  defp do_check_active(%User{subscription_status: status}) when status in @active_statuses,
    do: :ok

  defp do_check_active(%User{}), do: {:error, :subscription_required}

  defp do_check_active(user_id) when is_binary(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :subscription_required}
      user -> do_check_active(user)
    end
  end

  defp do_check_active(_), do: {:error, :subscription_required}

  # ─── Stripe customer ────────────────────────────────────────────────────────

  @trial_days 14

  @doc "Length of the free trial, in days."
  def trial_days, do: @trial_days

  @doc """
  Creates a Stripe Customer for the given user.

  Customer only. Starting the trial is `start_trial_subscription/1`, kept
  separate because this function is also on the Checkout path — where the user
  is about to buy, and opening a trialing subscription moments before a paid one
  would be wrong.
  """
  @spec create_stripe_customer(User.t()) :: {:ok, User.t()} | {:error, term()}
  def create_stripe_customer(%User{} = user) do
    with {:ok, %Stripe.Customer{id: customer_id}} <-
           Stripe.Customer.create(%{email: user.email, metadata: %{"user_id" => user.id}}) do
      user
      |> User.billing_changeset(%{stripe_customer_id: customer_id})
      |> Repo.update()
    end
  end

  @doc """
  Opens a trialing Stripe Subscription and records what Stripe says about it.

  This is the missing piece behind "trials never expire". Signup created a
  Customer and nothing else, so Stripe had no subscription object to run a trial
  against, would never emit a lifecycle webhook for one, and nothing anywhere
  moved the account off `trialing` when the date passed.

  `missing_payment_method: "cancel"` decides what happens at the end for someone
  who never entered a card, which is the common case. The alternative,
  `create_invoice`, raises an unpaid invoice and puts the subscription in
  `past_due`, which starts Stripe's dunning emails — chasing payment on an
  invoice from someone who never agreed to pay. Cancelling is quieter, says
  nothing untrue, and `canceled` closes the gate just as effectively.

  Called from `Workers.StripeCustomerSync`, so a Stripe failure retries with
  backoff.

  `trial_ends_at` comes from the subscription's `trial_end` rather than being
  computed locally, so the database agrees with the thing that will actually do
  the charging.

  A missing `STRIPE_PRICE_ID` is not an error: a self-hosted instance has no
  price and no Stripe. It falls back to recording a local trial end so the
  account still behaves like a trial, and logs loudly enough to be found if the
  price is missing somewhere that does bill.
  """
  @spec start_trial_subscription(User.t()) :: {:ok, User.t()} | {:error, term()}
  def start_trial_subscription(%User{stripe_customer_id: nil} = user), do: {:ok, user}

  def start_trial_subscription(%User{} = user) do
    case Application.get_env(:fountain, :stripe_price_id) do
      price when is_binary(price) and price != "" ->
        create_trial_subscription(user, price)

      _ ->
        require Logger

        Logger.warning(
          "no STRIPE_PRICE_ID — user #{user.id} gets a local trial with no subscription"
        )

        record_local_trial(user)
    end
  end

  defp create_trial_subscription(user, price_id) do
    params = %{
      customer: user.stripe_customer_id,
      items: [%{price: price_id}],
      trial_period_days: @trial_days,
      trial_settings: %{end_behavior: %{missing_payment_method: "cancel"}},
      metadata: %{"user_id" => user.id}
    }

    case Stripe.Subscription.create(params) do
      {:ok, sub} ->
        user
        |> User.billing_changeset(%{
          subscription_status: to_string(sub.status),
          trial_ends_at: unix_to_datetime(Map.get(sub, :trial_end)),
          subscription_synced_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record_local_trial(user) do
    user
    |> User.billing_changeset(%{trial_ends_at: trial_end_from_now()})
    |> Repo.update()
  end

  @doc false
  def trial_end_from_now do
    DateTime.utc_now()
    |> DateTime.add(@trial_days * 24 * 60 * 60, :second)
    |> DateTime.truncate(:second)
  end

  defp unix_to_datetime(ts) when is_integer(ts),
    do: DateTime.from_unix!(ts) |> DateTime.truncate(:second)

  defp unix_to_datetime(_), do: trial_end_from_now()

  @doc """
  Cancels every subscription attached to the user's Stripe customer.

  Used when an account is deleted. Returns the number cancelled, or an error if
  Stripe could not be reached or refused — the caller must treat that as fatal,
  because deleting an account that keeps being charged leaves the person with no
  account to log into and cancel from.

  Cancels rather than deleting the Stripe Customer: invoices are financial
  records a business is required to retain, and Stripe is the system of record
  for them. Ending the billing relationship does not require destroying the
  accounting trail.

  Lists with `status: "all"` and cancels everything not already in a terminal
  state. Filtering the API call to `"active"` would be the obvious thing and
  would be wrong: a `trialing` subscription has not charged yet but will, and
  `past_due` and `unpaid` are still live billing relationships. Only `canceled`
  and `incomplete_expired` can no longer produce a charge.

  Skipping the already-terminal ones also makes a retry after a partial failure
  safe.
  """
  @cancellable ~w(active trialing past_due unpaid incomplete paused)

  @spec cancel_subscriptions(User.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def cancel_subscriptions(%User{stripe_customer_id: nil}), do: {:ok, 0}
  def cancel_subscriptions(%User{stripe_customer_id: ""}), do: {:ok, 0}

  def cancel_subscriptions(%User{stripe_customer_id: customer_id}) do
    case Stripe.Subscription.list(%{customer: customer_id, status: "all", limit: 100}) do
      {:ok, %{data: subs} = list} ->
        # A customer with more than 100 subscriptions is not a thing we create,
        # but silently cancelling the first page and reporting success would
        # leave the rest charging a deleted account.
        if Map.get(list, :has_more, false) do
          {:error, :too_many_subscriptions}
        else
          subs |> Enum.filter(&(to_string(&1.status) in @cancellable)) |> cancel_each()
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cancel_each(subs) do
    Enum.reduce_while(subs, {:ok, 0}, fn sub, {:ok, count} ->
      case Stripe.Subscription.cancel(sub.id) do
        {:ok, _} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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
  Entry point for a verified Stripe webhook event.

  Claims the event id first, so a redelivery is a no-op rather than a second
  application. Stripe retries a failed delivery for up to three days and makes
  no ordering promise, so without this a replayed
  `customer.subscription.updated{active}` arriving after `.deleted` silently
  reactivates a cancelled account.

  Returns `{:ok, :duplicate}` for an event already seen.
  """
  @spec handle_event(Stripe.Event.t()) ::
          {:ok, User.t() | :ignored | :duplicate | :stale} | {:error, term()}
  def handle_event(%Stripe.Event{id: id, type: type} = event) when is_binary(id) do
    if claim_event(id, type) == :claimed do
      sync_subscription(event)
    else
      {:ok, :duplicate}
    end
  end

  # No id (hand-built events in tests) — nothing to dedupe against.
  def handle_event(%Stripe.Event{} = event), do: sync_subscription(event)

  # Atomic claim: the unique primary key is what makes concurrent deliveries of
  # the same event resolve to exactly one winner.
  defp claim_event(id, type) do
    {count, _} =
      Repo.insert_all(
        "stripe_events",
        [
          %{
            id: id,
            type: type,
            inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
          }
        ],
        on_conflict: :nothing
      )

    if count == 1, do: :claimed, else: :duplicate
  end

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

  @doc false
  # Stripe fires this three days before a trial ends. It used to fall through to
  # the catch-all and be dropped, so the one notification Stripe goes out of its
  # way to send us was received, parsed and discarded — while trials that (since
  # #153) actually end now cut people off with no warning.
  #
  # Only enqueues; the send is a job. A mail failure must not make this return
  # an error and have Stripe retry the whole event.
  def sync_subscription(%Stripe.Event{
        type: "customer.subscription.trial_will_end",
        data: %{object: sub}
      }) do
    customer_id = extract_customer_id(Map.get(sub, :customer))

    case customer_id && get_user_by_stripe_customer_id(customer_id) do
      %User{} = user ->
        trial_end =
          case Map.get(sub, :trial_end) do
            ts when is_integer(ts) -> DateTime.from_unix!(ts) |> DateTime.truncate(:second)
            _ -> nil
          end

        Fountain.Workers.TrialEndingEmail.enqueue(user.id, trial_end)
        {:ok, user}

      _ ->
        {:ok, :ignored}
    end
  end

  def sync_subscription(%Stripe.Event{type: type, data: %{object: sub}} = event)
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

    event_created = event_created_at(event)

    case get_user_by_stripe_customer_id(customer_id) do
      nil ->
        {:error, :user_not_found}

      user ->
        if stale?(user.subscription_synced_at, event_created) do
          # An older event arriving after a newer one. Applying it would move the
          # account backwards — reactivating a cancellation, or re-locking an
          # account that has already recovered.
          {:ok, :stale}
        else
          user
          |> User.billing_changeset(%{
            subscription_status: status,
            trial_ends_at: trial_ends_at,
            subscription_synced_at: event_created || user.subscription_synced_at
          })
          |> Repo.update()
        end
    end
  end

  def sync_subscription(_event), do: {:ok, :ignored}

  defp event_created_at(%Stripe.Event{created: ts}) when is_integer(ts),
    do: DateTime.from_unix!(ts) |> DateTime.truncate(:second)

  defp event_created_at(_), do: nil

  # Unknown timestamps are treated as fresh: refusing to apply an event we
  # cannot order would be worse than applying it.
  defp stale?(nil, _incoming), do: false
  defp stale?(_synced, nil), do: false
  defp stale?(synced, incoming), do: DateTime.compare(incoming, synced) == :lt

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
