defmodule Fountain.Billing do
  @moduledoc """
  Billing context: Stripe integration, subscription gating, and usage aggregation.

  ## Hard gate pattern

      # Raises SubscriptionRequiredError for past_due / canceled:
      Fountain.Billing.assert_active!(current_user)

  Call sites:
  - `ConversationServer.turn_gate/1` — the backstop. Every turn passes through
    it, whichever door it entered by (controller, LiveView, or the queued
    initial prompt a wake delivers), so a live session cannot outrun a
    subscription that expires mid-flight and no new prompt surface can
    silently skip the gate.
  - `Conversations.start_conversation/1` and both arms of the wake path —
    refuse before provisioning (or reattaching to) a sprite, so the caller
    hears the refusal synchronously.
  - `POST /api/conversations` controller — fast 402 before doing any work
  - `on_mount :require_active_subscription` LiveView hook — redirects to
    billing at mount time.

  ## Webhook sync

      Fountain.Billing.sync_subscription(stripe_event)

  Called from `FountainWeb.StripeWebhookController` after signature verification.
  """

  import Ecto.Query

  require Logger

  alias Fountain.Accounts.User
  alias Fountain.Audit
  alias Fountain.Billing.Finance
  alias Fountain.Billing.SandboxUsage
  alias Fountain.Billing.UsageEvent
  alias Fountain.Plans
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

  @active_statuses ~w(trialing active comped)

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
  # A nil `trial_ends_at` is "no expiry" only for accounts that predate the
  # 2026-08-02 backfill (Fountain.Release.expire_legacy_trials/1 exists for any
  # of those that reappear). Registration has stamped a trial end on every
  # account since #244, so a newer account at nil means a stalled sync or data
  # drift — and an open-ended branch here turned every such account into a free
  # one (#314). Those fail closed; support can extend_trial to reopen them.
  # A *deliberate* free account is "comped", not this.
  @legacy_trial_cutoff ~U[2026-08-02 00:00:00Z]

  defp do_check_active(%User{subscription_status: "trialing", trial_ends_at: nil} = user) do
    if DateTime.compare(user.inserted_at, @legacy_trial_cutoff) == :lt do
      :ok
    else
      {:error, :subscription_required}
    end
  end

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
  the charging. In the other direction, the subscription is *anchored* to the
  trial end registration already stamped — creating it at verification time
  must not restart the clock — and is not created at all when that date has
  already passed.

  A missing `STRIPE_PRICE_ID` is not an error: a self-hosted instance has no
  price and no Stripe. It falls back to recording a local trial end so the
  account still behaves like a trial, and logs loudly enough to be found if the
  price is missing somewhere that does bill.
  """
  @spec start_trial_subscription(User.t()) :: {:ok, User.t()} | {:error, term()}
  def start_trial_subscription(%User{stripe_customer_id: nil} = user), do: {:ok, user}

  def start_trial_subscription(%User{} = user) do
    case signup_plan() do
      {slug, price_id} ->
        create_trial_subscription(user, slug, price_id)

      :none ->
        require Logger

        Logger.warning(
          "no plan price configured — user #{user.id} gets a local trial with no subscription"
        )

        record_local_trial(user)
    end
  end

  # The plan a trial opens on: this deployment's default (`DEFAULT_PLAN`,
  # normally the entry tier), falling back to the closed flat price so that a
  # deployment which has the old `STRIPE_PRICE_ID` set but not yet the per-plan
  # ones keeps signing people up rather than silently minting free accounts.
  # That fallback is the whole window between deploying this and finishing the
  # Stripe setup, and it is the one an unattended overnight signup lands in.
  defp signup_plan do
    default = Plans.default()

    cond do
      is_binary(Plans.price_id(default)) -> {default.slug, Plans.price_id(default)}
      is_binary(Plans.price_id("legacy")) -> {"legacy", Plans.price_id("legacy")}
      true -> :none
    end
  end

  defp create_trial_subscription(user, plan_slug, price_id) do
    case trial_end_param(user.trial_ends_at) do
      :expired ->
        # The locally-stamped clock has already ended this trial; opening a
        # live Stripe trial now would re-grant time the account no longer has,
        # and Stripe rejects a past trial_end anyway. The clock side of the
        # gate covers these accounts.
        {:ok, user}

      trial_param ->
        do_create_trial_subscription(user, plan_slug, price_id, trial_param)
    end
  end

  # Anchor the subscription to the trial end registration already stamped, so
  # a subscription created at verification time (or backfilled later) does not
  # restart the clock. Only an account with no local date gets a fresh window.
  defp trial_end_param(nil), do: %{trial_period_days: @trial_days}

  defp trial_end_param(%DateTime{} = ends_at) do
    if DateTime.compare(ends_at, DateTime.add(DateTime.utc_now(), 300, :second)) == :gt do
      %{trial_end: DateTime.to_unix(ends_at)}
    else
      :expired
    end
  end

  defp do_create_trial_subscription(user, plan_slug, price_id, trial_param) do
    params =
      Map.merge(
        %{
          customer: user.stripe_customer_id,
          items: [%{price: price_id}],
          trial_settings: %{end_behavior: %{missing_payment_method: :cancel}},
          metadata: %{"user_id" => user.id}
        },
        trial_param
      )

    # Idempotent across Oban retries (#400): when the create succeeded but
    # the local write below failed, the retry re-entered here (the worker's
    # guard checks stripe_subscription_id, which the failed write never set)
    # and minted another trialing subscription — up to five per user, all of
    # them converting and charging if a card was added before trial end. A
    # stable per-user key makes Stripe return the original subscription for
    # every retry inside the 24h idempotency window instead.
    request_opts = [headers: %{"Idempotency-Key" => "trial-subscription-#{user.id}"}]

    case Stripe.Subscription.create(params, request_opts) do
      {:ok, sub} ->
        user
        |> User.billing_changeset(%{
          stripe_subscription_id: sub.id,
          # The same coercion the webhook path applies (#400): Stripe can
          # answer with incomplete/unpaid/paused, none of which the
          # changeset's inclusion list accepts — and that rejected write was
          # the realistic trigger for the duplicating retries above.
          subscription_status: coerce_status(to_string(sub.status), nil),
          trial_ends_at: unix_to_datetime(Map.get(sub, :trial_end)),
          subscription_synced_at: DateTime.utc_now() |> DateTime.truncate(:second),
          plan: plan_slug
        })
        |> Repo.update()
        |> audit_billing(user, "billing.trial.started", "stripe")

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A date that is already set stands: the worker re-runs on every OAuth login,
  # and re-stamping +14d from "now" would quietly extend a self-host trial on
  # each one.
  defp record_local_trial(%User{trial_ends_at: %DateTime{}} = user), do: {:ok, user}

  defp record_local_trial(user) do
    user
    |> User.billing_changeset(%{trial_ends_at: trial_end_from_now()})
    |> Repo.update()
    |> audit_billing(user, "billing.trial.started", "local")
  end

  # ── audit ─────────────────────────────────────────────────────────────────
  #
  # Subscription state changed under the tenant with nothing to explain it:
  # this module had zero `Audit.record` calls, so an account could go from
  # `active` to `canceled` and the person it happened to saw only the result
  # (#550). Admin-initiated billing changes landed in `admin_audit_events`,
  # which the tenant-facing `/audit` never reads.
  #
  # `source` is the point. "Your subscription was cancelled" means something
  # different depending on whether Stripe said so, an operator did it, or a
  # sweeper decided a trial had run out, and the status column cannot tell
  # those apart.
  #
  # Only real transitions are recorded — a sync that reasserts the status the
  # account already had is not news, and the webhook path re-syncs constantly.

  defp audit_billing(result, before, action, source, extra \\ %{})

  defp audit_billing({:ok, %User{} = updated} = ok, %User{} = before, action, source, extra) do
    record_billing_transition(before, updated, action, source, extra)
    ok
  end

  defp audit_billing(%User{} = updated, %User{} = before, action, source, extra) do
    record_billing_transition(before, updated, action, source, extra)
    updated
  end

  defp audit_billing(other, _before, _action, _source, _extra), do: other

  defp record_billing_transition(%User{} = before, %User{} = updated, action, source, extra) do
    changed? =
      before.subscription_status != updated.subscription_status or
        before.trial_ends_at != updated.trial_ends_at or
        before.stripe_customer_id != updated.stripe_customer_id or
        before.cancel_at_period_end != updated.cancel_at_period_end

    if changed? do
      Audit.record(%{
        user_id: updated.id,
        action: action,
        resource_type: "subscription",
        resource_id: updated.stripe_subscription_id,
        actor: actor_for(source),
        metadata:
          Map.merge(
            %{
              "source" => source,
              "from_status" => before.subscription_status,
              "to_status" => updated.subscription_status,
              "cancel_at_period_end" => updated.cancel_at_period_end
            },
            extra
          )
      })
    end
  end

  # `source` says what drove the transition; the actor says who. Every source
  # here is unattended except one — an operator extending a trial, comping an
  # account or forcing a resync is a person, and `system:admin` claimed the
  # opposite. Core records those as `admin` and so does this (ADR 0013). The
  # source survives in metadata either way.
  defp actor_for("admin"), do: "admin"
  defp actor_for(source), do: "system:#{source}"

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
  Extends a user's trial by `days`, counted from whichever is later — now or
  the current trial end — so an extension can never shorten a trial.

  Stripe owns `trial_ends_at` for an account with a subscription still in its
  trial (`sync_subscription/1` overwrites the local value on every subscription
  event), so for those the extension goes through `Stripe.Subscription.update/2`
  first and the local write is the optimistic copy the webhook will confirm.
  An account with no live trial subscription — no Stripe customer at all, or a
  subscription already ended — gets a plain local update, which also moves a
  `canceled` or `past_due` account back to `trialing`: the support lever for
  "give this person another look".

  The extension also advances `subscription_synced_at`, because an operator
  decision outranks anything already in flight: without the stamp, a straggler
  event from the old cancelled subscription (or a re-checkout race) with a
  newer `created` than the last synced event would silently revert the
  extension and gate the user again. Events younger than the extension still
  apply — Stripe remains the authority for everything that happens *after* the
  operator acted.

  Refused for `active` (they are paying; there is no trial) and `comped`
  (already free; extending would demote them to a trial that ends).
  """
  @spec extend_trial(User.t(), pos_integer()) :: {:ok, User.t()} | {:error, term()}
  def extend_trial(%User{subscription_status: "active"}, _days),
    do: {:error, :active_subscription}

  def extend_trial(%User{subscription_status: "comped"}, _days), do: {:error, :comped}

  def extend_trial(%User{} = user, days) when is_integer(days) and days > 0 do
    now = DateTime.utc_now()

    base =
      case user.trial_ends_at do
        %DateTime{} = ends_at -> if DateTime.compare(ends_at, now) == :gt, do: ends_at, else: now
        nil -> now
      end

    new_end = base |> DateTime.add(days * 24 * 60 * 60, :second) |> DateTime.truncate(:second)

    with :ok <- push_stripe_trial_end(user, new_end) do
      user
      |> User.billing_changeset(%{
        subscription_status: "trialing",
        trial_ends_at: new_end,
        subscription_synced_at: DateTime.truncate(now, :second)
      })
      |> Repo.update()
      |> audit_billing(user, "billing.trial.extended", "admin", %{"days" => days})
    end
  end

  # Stripe first, so a Stripe refusal leaves nothing half-applied. Only a
  # subscription still trialing can have its trial moved; any other state means
  # there is no live trial subscription and the local write stands alone.
  defp push_stripe_trial_end(%User{stripe_customer_id: id}, _new_end) when id in [nil, ""],
    do: :ok

  defp push_stripe_trial_end(%User{stripe_customer_id: customer_id}, new_end) do
    case Stripe.Subscription.list(%{customer: customer_id, status: :trialing, limit: 1}) do
      {:ok, %{data: [sub | _]}} ->
        case Stripe.Subscription.update(sub.id, %{
               trial_end: DateTime.to_unix(new_end),
               proration_behavior: :none
             }) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Expires `trialing` accounts whose trial end passed more than `:grace_hours`
  ago and whose status never moved (#504).

  Stripe normally ends trials itself — the signup subscription carries
  `missing_payment_method: "cancel"` and the cancellation webhook flips the
  status. This sweep is the backstop for when that signal never lands: a
  missed webhook, or a local-only trial that has no subscription at all (no
  `STRIPE_PRICE_ID`). Access is already denied at read time the moment the
  clock passes (`check_active/1`); what a stale row corrupts is recorded
  status — admin counts, status-based queries — and the trial-expired email,
  which only fires on a status transition.

  For an account with a Stripe subscription the truth is in Stripe, so the
  sweep retrieves the live subscription and applies its status through the
  same changeset-and-lifecycle-email path webhooks use — a trial extended in
  Stripe's dashboard updates the local clock rather than being cancelled. The
  retrieve happens before the row lock is taken (third-party HTTP must not
  run inside the transaction — see `BillingWebhookSyncRaceTest`), and the row
  is re-checked under lock so a concurrent conversion is never overwritten.
  Accounts with no subscription are flipped to `canceled` directly.

  The grace window (default 48h) gives Stripe's webhook and its retries the
  first shot; rows with a nil `trial_ends_at` are left alone — legacy
  accounts are deliberately grandfathered and newer nil rows already fail
  closed at read time.

  Returns counts: `:expired` (local trials cancelled), `:synced` (status
  adopted from Stripe), `:extended` (Stripe still trialing; clock repaired),
  `:skipped` (Stripe error or concurrent change — retried next run).
  """
  @spec expire_stale_trials(keyword()) :: %{
          expired: non_neg_integer(),
          synced: non_neg_integer(),
          extended: non_neg_integer(),
          skipped: non_neg_integer()
        }
  def expire_stale_trials(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    grace_hours = Keyword.get(opts, :grace_hours, 48)
    batch = Keyword.get(opts, :batch, 100)
    cutoff = DateTime.add(now, -grace_hours * 3600, :second)

    stale =
      Repo.all(
        from(u in User,
          where: u.subscription_status == "trialing",
          where: u.trial_ends_at < ^cutoff,
          order_by: [asc: u.trial_ends_at],
          limit: ^batch
        )
      )

    Enum.reduce(stale, %{expired: 0, synced: 0, extended: 0, skipped: 0}, fn user, acc ->
      Map.update!(acc, sweep_stale_trial(user, now), &(&1 + 1))
    end)
  end

  defp sweep_stale_trial(%User{stripe_subscription_id: sub_id} = user, now)
       when is_binary(sub_id) and sub_id != "" do
    case Stripe.Subscription.retrieve(sub_id) do
      {:ok, %Stripe.Subscription{status: "trialing"} = sub} ->
        # Stripe still says trialing — the local clock is behind (a trial
        # extended in the dashboard). Adopt Stripe's end; don't cancel.
        apply_trial_sweep(
          user,
          %{trial_ends_at: unix_field(Map.get(sub, :trial_end))},
          now,
          :extended
        )

      {:ok, %Stripe.Subscription{} = sub} ->
        apply_trial_sweep(
          user,
          %{
            subscription_status: coerce_status(sub.status, "trial_sweep"),
            trial_ends_at: unix_field(Map.get(sub, :trial_end)),
            current_period_start: unix_field(period_start_unix(sub)),
            current_period_end: unix_field(period_end_unix(sub))
          },
          now,
          :synced
        )

      {:error, reason} ->
        Logger.warning(
          "trial sweep: Stripe retrieve failed for #{user.id} (#{sub_id}): #{inspect(reason)}"
        )

        :skipped
    end
  end

  defp sweep_stale_trial(%User{} = user, now) do
    # No subscription (local trial): nothing else will ever flip this row.
    apply_trial_sweep(user, %{subscription_status: "canceled"}, now, :expired)
  end

  # The attrs were decided outside the transaction (the Stripe read must not
  # hold a row lock); the recheck under lock makes them safe to apply — a row
  # that converted, was comped, or was deleted in the meantime is left alone.
  defp apply_trial_sweep(%User{id: user_id}, attrs, now, tally) do
    result =
      Repo.transaction(fn ->
        case get_user_for_update(user_id) do
          %User{subscription_status: "trialing"} = user ->
            user
            |> User.billing_changeset(
              Map.put(attrs, :subscription_synced_at, DateTime.truncate(now, :second))
            )
            |> Repo.update!()
            |> tap(&enqueue_lifecycle_email(user.subscription_status, &1))
            |> audit_billing(user, "billing.trial.expired", "trial_sweeper")

          _ ->
            Repo.rollback(:not_trialing)
        end
      end)

    case result do
      {:ok, _user} -> tally
      {:error, :not_trialing} -> :skipped
    end
  end

  defp unix_field(ts) when is_integer(ts),
    do: DateTime.from_unix!(ts) |> DateTime.truncate(:second)

  defp unix_field(_), do: nil

  @doc """
  Admin repair for webhook drift (#502): re-reads the subscription of record
  from Stripe and applies what Stripe says, writing the same fields the
  webhook path writes.

  `subscription_synced_at` is stamped with the read time, so a delayed older
  webhook event arriving after the resync is dropped by `sync_subscription/1`'s
  ordering guard instead of undoing the repair.

  Comped accounts are refused — a comp is an operator decision Stripe does not
  override, same guard as webhook sync. A user with no subscription of record
  has nothing to re-read; `Workers.StripeCustomerSync` is enqueued instead,
  which creates whichever of customer/trial subscription is missing.
  """
  @spec resync_from_stripe(User.t()) ::
          {:ok, User.t() | :sync_enqueued} | {:error, term()}
  def resync_from_stripe(%User{subscription_status: "comped"}), do: {:error, :comped}

  def resync_from_stripe(%User{stripe_subscription_id: sub_id} = user)
      when is_binary(sub_id) and sub_id != "" do
    case Stripe.Subscription.retrieve(sub_id) do
      {:ok, %Stripe.Subscription{} = sub} -> apply_resync(user, sub)
      {:error, reason} -> {:error, reason}
    end
  end

  def resync_from_stripe(%User{} = user) do
    case Fountain.Workers.StripeCustomerSync.enqueue(user) do
      {:ok, _} -> {:ok, :sync_enqueued}
      {:error, reason} -> {:error, reason}
    end
  end

  # The Stripe read happens outside the transaction (it must not hold a row
  # lock); the recheck under lock keeps the comp guard honest against an
  # operator comping the account between read and write.
  defp apply_resync(%User{id: user_id}, %Stripe.Subscription{} = sub) do
    attrs = %{
      subscription_status: coerce_status(sub.status, "admin_resync"),
      trial_ends_at: unix_field(Map.get(sub, :trial_end)),
      current_period_start: unix_field(period_start_unix(sub)),
      current_period_end: unix_field(period_end_unix(sub)),
      cancel_at_period_end: Map.get(sub, :cancel_at_period_end) == true,
      subscription_synced_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    Repo.transaction(fn ->
      case get_user_for_update(user_id) do
        nil ->
          Repo.rollback(:user_not_found)

        %User{subscription_status: "comped"} ->
          Repo.rollback(:comped)

        %User{} = user ->
          user
          |> User.billing_changeset(attrs)
          |> Repo.update!()
          |> tap(&enqueue_lifecycle_email(user.subscription_status, &1))
          |> audit_billing(user, "billing.subscription.resynced", "admin")
      end
    end)
  end

  @doc """
  Read-only invoice history for the admin user detail page (#502), fetched
  live from Stripe — nothing is stored locally, so this can never drift from
  the billing system of record the way webhook-derived state can.

  Refused before Stripe when billing is disabled (#399), and a user with no
  Stripe customer has no invoices to fetch — `{:ok, []}` without a call.
  """
  @spec list_invoices(User.t()) :: {:ok, [Stripe.Invoice.t()]} | {:error, term()}
  def list_invoices(%User{} = user) do
    cond do
      not enabled?() ->
        {:error, :billing_disabled}

      user.stripe_customer_id in [nil, ""] ->
        {:ok, []}

      true ->
        case Stripe.Invoice.list(%{customer: user.stripe_customer_id, limit: 20}) do
          {:ok, %Stripe.List{data: invoices}} -> {:ok, invoices}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Marks an account comped: free access granted by an operator, indefinitely.

  Any live Stripe subscription is cancelled first — a comped account must not
  keep charging, and a surviving subscription's webhooks would fight the comp.
  The cancellation webhook that follows is ignored by `sync_subscription/1`
  (comped accounts are excluded from webhook sync), so the comp sticks until
  `revoke_comp/1`.
  """
  @spec comp_account(User.t()) :: {:ok, User.t()} | {:error, term()}
  def comp_account(%User{subscription_status: "comped"} = user), do: {:ok, user}

  def comp_account(%User{} = user) do
    with {:ok, _cancelled} <- cancel_subscriptions(user) do
      user
      |> User.billing_changeset(%{subscription_status: "comped"})
      |> Repo.update()
      |> audit_billing(user, "billing.comped", "admin")
    end
  end

  @doc """
  Ends a comp. The account becomes `canceled` — gated, with self-serve checkout
  as the way back in — rather than guessing at whatever state preceded the comp.
  """
  @spec revoke_comp(User.t()) :: {:ok, User.t()} | {:error, :not_comped}
  def revoke_comp(%User{subscription_status: "comped"} = user) do
    user
    |> User.billing_changeset(%{subscription_status: "canceled"})
    |> Repo.update()
    |> audit_billing(user, "billing.comp_revoked", "admin")
  end

  def revoke_comp(%User{}), do: {:error, :not_comped}

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
    case Stripe.Subscription.list(%{customer: customer_id, status: :all, limit: 100}) do
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
  Whether the user's Stripe customer has any subscription that can still
  produce a charge. `{:ok, true}` / `{:ok, false}`, or `{:error, reason}` when
  Stripe cannot be asked — the caller must not guess.

  This is the guard in front of Checkout. Our local `subscription_status` can
  read `canceled` while a live subscription still exists in Stripe (a lost or
  misordered webhook, or a `.deleted` from an old trial subscription landing
  after the paid one's events) — and a subscription cancelled at period end is
  still `active` in Stripe until the period ends. Opening Checkout in either
  state creates a second, duplicate subscription; such a user belongs in the
  Billing Portal, where the existing subscription can be renewed instead.

  "Live" is the same set `cancel_subscriptions/1` cancels: everything except
  the terminal `canceled` and `incomplete_expired`.
  """
  @spec has_live_subscription?(User.t()) :: {:ok, boolean()} | {:error, term()}
  def has_live_subscription?(%User{stripe_customer_id: id}) when id in [nil, ""], do: {:ok, false}

  def has_live_subscription?(%User{stripe_customer_id: customer_id}) do
    case Stripe.Subscription.list(%{customer: customer_id, status: :all, limit: 100}) do
      {:ok, %{data: subs}} ->
        {:ok, Enum.any?(subs, &(to_string(&1.status) in @cancellable))}

      {:error, reason} ->
        {:error, reason}
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
  Mint a Stripe Billing Portal session URL for `user`, returning `{:ok, url}`.

  Refuses a comped account: there is nothing to manage and nothing to pay.
  Refuses an account with no Stripe customer — the portal is per-customer, and
  a user who has never been one has no portal to visit.
  """
  @spec portal_url(User.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def portal_url(%User{subscription_status: "comped"}, _return_url), do: {:error, :comped}

  def portal_url(%User{stripe_customer_id: id}, _return_url) when id in [nil, ""],
    do: {:error, :no_customer}

  def portal_url(%User{stripe_customer_id: customer_id}, return_url) do
    case Stripe.BillingPortal.Session.create(%{customer: customer_id, return_url: return_url}) do
      {:ok, session} -> {:ok, session.url}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Mint a Stripe Checkout session URL for `user`, returning `{:ok, url}`.

  Creates the Stripe Customer first when the user has none: passing
  `customer_email` instead makes Stripe mint its own Customer whose id we never
  learn, so the resulting webhook matches no user and the card is charged
  without the account ever activating.

  Refuses a comped account. Callers must check `has_live_subscription?/1`
  first — Checkout opened on top of a live subscription creates a second,
  duplicate one.

  `plan` names the tier to buy and defaults to this deployment's default. An
  unknown or unpriced plan falls back to that default rather than to an empty
  price string, which is what the single-price version did and what turned a
  misconfigured `STRIPE_PRICE_ID` into an opaque Stripe error at the last
  step of signup.
  """
  @spec checkout_url(User.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def checkout_url(user, return_url, plan \\ nil)

  def checkout_url(%User{subscription_status: "comped"}, _return_url, _plan),
    do: {:error, :comped}

  def checkout_url(%User{} = user, return_url, plan) do
    with {:ok, user} <- ensure_stripe_customer(user) do
      params = %{
        mode: :subscription,
        line_items: [%{price: checkout_price_id(plan), quantity: 1}],
        success_url: return_url <> "?checkout=success",
        cancel_url: return_url,
        customer: user.stripe_customer_id,
        # Second route back to the user if the customer link is ever lost —
        # checkout.session.completed carries this through.
        client_reference_id: user.id,
        # Show the "Add promotion code" link; without the flag it is hidden.
        allow_promotion_codes: true
      }

      case Stripe.Checkout.Session.create(params) do
        {:ok, session} -> {:ok, session.url}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp checkout_price_id(plan) do
    Plans.price_id(plan) || Plans.price_id(Plans.default()) ||
      Application.get_env(:fountain, :stripe_price_id, "")
  end

  @doc """
  The Stripe URL a "manage my subscription" action should send `user` to:
  the Portal when they already have something live to manage, Checkout when
  they do not.

  An existing customer may hold a live subscription even when the local status
  says otherwise — a cancel-at-period-end stays `active` in Stripe until the
  period ends, and a lost webhook leaves the same mismatch — so the lookup is
  what keeps Checkout from opening a duplicate subscription on top.
  """
  @spec manage_url(User.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def manage_url(%User{subscription_status: "comped"}, _return_url), do: {:error, :comped}

  def manage_url(%User{} = user, return_url) do
    cond do
      user.subscription_status in ~w(active past_due) and user.stripe_customer_id ->
        portal_url(user, return_url)

      user.stripe_customer_id in [nil, ""] ->
        checkout_url(user, return_url)

      true ->
        case has_live_subscription?(user) do
          {:ok, true} -> portal_url(user, return_url)
          {:ok, false} -> checkout_url(user, return_url)
          {:error, _} = error -> error
        end
    end
  end

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

  # ─── Plans ──────────────────────────────────────────────────────────────────

  @doc """
  The user's plan (`Fountain.Plans`). Never nil — see `Plans.resolve/1`.
  """
  @spec plan(User.t()) :: Plans.t()
  def plan(%User{} = user), do: Plans.resolve(user.plan)

  @doc """
  The plans this deployment can actually sell: the public catalog, minus any
  whose Stripe price id is unset.

  A tier with no price is not a cheaper tier, it is a broken button — Checkout
  refuses the session and the customer sees a Stripe error. Filtering here is
  what lets the price ids be rolled out one at a time.
  """
  @spec available_plans() :: [Plans.t()]
  def available_plans do
    if enabled?() do
      Enum.filter(Plans.public(), &is_binary(Plans.price_id(&1)))
    else
      []
    end
  end

  @doc """
  Move `user` to `slug` by swapping the price on their existing subscription.

  This is the upgrade path for anyone who already has a subscription, which
  after registration is everybody: Checkout would open a *second* one. The
  base plan item is repriced in place and the add-on item, if the tenant has
  teammate contacts, is left alone.

  Proration is Stripe's default `create_prorations`, so an upgrade mid-period
  bills the difference immediately and a trial stays a trial — the price
  change simply lands on whatever the trial converts to.

  The local `plan` column is **not** written here. The
  `customer.subscription.updated` event this call produces is what writes it
  (`maybe_adopt_plan/3`), so the entitlement always follows what Stripe
  actually charges rather than what we asked it to. A returned `{:ok, user}`
  therefore still carries the old slug; reload after the webhook lands.

  Returns `{:error, :comped}` for a comped account (an operator's decision is
  not a customer's to change), `{:error, :unknown_plan}`, `{:error,
  :plan_unavailable}` when the target has no price id on this deployment,
  `{:error, :no_subscription}` when there is nothing to reprice — the caller
  should send those to Checkout — and `{:error, :plan_item_not_found}` when
  the subscription carries no item this deployment recognises.
  """
  @spec change_plan(User.t(), String.t(), keyword()) :: {:ok, User.t()} | {:error, term()}
  def change_plan(user, slug, opts \\ [])

  def change_plan(%User{subscription_status: "comped"}, _slug, _opts), do: {:error, :comped}

  def change_plan(%User{stripe_subscription_id: id}, _slug, _opts) when id in [nil, ""],
    do: {:error, :no_subscription}

  def change_plan(%User{} = user, slug, opts) when is_binary(slug) do
    with {:known, true} <- {:known, Plans.known?(slug)},
         {:priced, price_id} when is_binary(price_id) <- {:priced, Plans.price_id(slug)},
         {:ok, sub} <- Stripe.Subscription.retrieve(user.stripe_subscription_id),
         {:item, item_id} when is_binary(item_id) <- {:item, plan_item_id(sub)},
         # Repricing the item directly rather than through
         # `Stripe.Subscription.update/2`: same call at the API, but the
         # subscription-level `items` type in stripity_stripe has no `id`
         # field, so the in-place edit cannot be expressed there.
         {:ok, _updated} <-
           Stripe.SubscriptionItem.update(item_id, %{
             price: price_id,
             proration_behavior: :create_prorations
           }) do
      Audit.record(%{
        user_id: user.id,
        action: "billing.plan.change_requested",
        resource_type: "user",
        resource_id: user.id,
        actor: Keyword.get(opts, :actor, "self"),
        request_ip: Keyword.get(opts, :request_ip),
        metadata: %{"from" => Plans.resolve(user.plan).slug, "to" => slug}
      })

      {:ok, user}
    else
      {:known, false} -> {:error, :unknown_plan}
      {:priced, _} -> {:error, :plan_unavailable}
      {:item, _} -> {:error, :plan_item_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # The subscription item holding a plan price — the one `change_plan/3`
  # reprices. Deliberately not "the first item": a tenant with teammate
  # contacts has two, and repricing the add-on item would swap their numbers
  # for a subscription tier.
  defp plan_item_id(sub) do
    sub
    |> subscription_items()
    |> Enum.find_value(fn item ->
      if item |> item_price_id() |> Plans.slug_for_price_id(), do: item_id(item)
    end)
  end

  # ─── Teammate contact add-on ────────────────────────────────────────────────

  @doc """
  Bring the teammate-contact add-on item in line with how many contacts
  `user_id` actually holds.

  An AgentMail inbox and an AgentPhone number cost Fountain money every month
  per teammate, so they are billed per unit rather than folded into a tier: a
  second subscription item whose quantity is the tenant's contact count
  (`Fountain.Team.Comms`).

  **Set, never increment.** The quantity is computed from the contact rows,
  so a dropped call, a retry, a crash between provisioning and syncing, or an
  admin deleting rows directly all converge on the right number the next time
  this runs. An increment would not: it would drift, and a tenant would be
  billed for numbers they no longer have.

  ## Comped contacts

  Two levers, deliberately separate. A `comped` subscription makes everything
  free and short-circuits here entirely. `users.comped_contacts` is the
  narrower one: the first N contacts are not charged, so a tenant can pay for
  their tier and still hold a number Fountain eats the cost of. The billed
  quantity is `max(0, count - comped_contacts)`, which is why an allowance
  larger than the contact count is harmless rather than a negative quantity
  Stripe would reject.

  Returns `{:ok, quantity}`, or `{:ok, :not_billed}` when there is nothing to
  bill against — billing off, no subscription, or no contact price configured.
  That last one is how a deployment offers teammate comms for free.
  """
  @spec sync_contact_addon(binary()) :: {:ok, non_neg_integer() | :not_billed} | {:error, term()}
  def sync_contact_addon(user_id) when is_binary(user_id) do
    price_id = Plans.contact_price_id()
    user = Repo.get(User, user_id)

    cond do
      not enabled?() -> {:ok, :not_billed}
      is_nil(price_id) -> {:ok, :not_billed}
      is_nil(user) -> {:ok, :not_billed}
      user.subscription_status == "comped" -> {:ok, :not_billed}
      user.stripe_subscription_id in [nil, ""] -> {:ok, :not_billed}
      true -> do_sync_contact_addon(user, price_id)
    end
  end

  defp do_sync_contact_addon(%User{} = user, price_id) when is_binary(price_id) do
    quantity = billable_contacts(user)

    with {:ok, sub} <- Stripe.Subscription.retrieve(user.stripe_subscription_id),
         {:ok, _} <- apply_contact_quantity(sub, price_id, quantity) do
      {:ok, quantity}
    end
  end

  @doc """
  How many of a user's teammate contacts Stripe is billed for: the count they
  hold, less their comped allowance, floored at zero.

  Public because the admin surfaces show it beside the raw count — "3 contacts,
  1 billed" is the sentence an operator needs, and recomputing the subtraction
  at each call site is how the two drift.
  """
  @spec billable_contacts(User.t()) :: non_neg_integer()
  def billable_contacts(%User{} = user) do
    max(0, Fountain.Team.Comms.contact_count(user.id) - (user.comped_contacts || 0))
  end

  defp apply_contact_quantity(sub, price_id, quantity) when is_binary(price_id) do
    existing =
      sub
      |> subscription_items()
      |> Enum.find(fn item -> item_price_id(item) == price_id end)

    cond do
      # Nothing to bill and no item to bill it on: the common case for every
      # tenant that has never used teammate comms. Adding a zero-quantity item
      # would put a $0 line on every invoice for no reason.
      is_nil(existing) and quantity == 0 ->
        {:ok, :noop}

      is_nil(existing) ->
        Stripe.SubscriptionItem.create(%{
          subscription: subscription_id(sub),
          price: price_id,
          quantity: quantity,
          proration_behavior: :create_prorations
        })

      item_quantity(existing) == quantity ->
        {:ok, :noop}

      # Down to zero: delete the item rather than set quantity 0. Stripe
      # rejects a zero quantity on a licensed price, and a lingering item is
      # what puts "1 × contact" on the invoice of a tenant who released their
      # last number.
      quantity == 0 ->
        Stripe.SubscriptionItem.delete(item_id(existing), %{
          proration_behavior: :create_prorations
        })

      true ->
        Stripe.SubscriptionItem.update(item_id(existing), %{
          quantity: quantity,
          proration_behavior: :create_prorations
        })
    end
  end

  defp subscription_id(%{id: id}) when is_binary(id), do: id

  # ─── Webhook sync ───────────────────────────────────────────────────────────

  @doc """
  Entry point for a verified Stripe webhook event.

  Claims the event id first, so a redelivery is a no-op rather than a second
  application. Stripe retries a failed delivery for up to three days and makes
  no ordering promise, so without this a replayed
  `customer.subscription.updated{active}` arriving after `.deleted` silently
  reactivates a cancelled account.

  Claim and apply run in one transaction: a failed apply rolls the claim back.
  Otherwise the two halves defeat each other — the controller answers 500 so
  Stripe redelivers, but the redelivery hits the already-claimed id and dedupes
  into a no-op, and the event is lost for good. If that event was the
  `customer.subscription.deleted` that ends a trial, no later event ever
  corrects it.

  Returns `{:ok, :duplicate}` for an event already seen.
  """
  @spec handle_event(Stripe.Event.t()) ::
          {:ok, User.t() | :ignored | :duplicate | :stale | :comped_ignored | :other_subscription}
          | {:error, term()}
  def handle_event(%Stripe.Event{id: id, type: type} = event) when is_binary(id) do
    # Stripe side effects run BEFORE the claim transaction opens (#393):
    # holding a DB transaction — and, since #393, a row lock on the user —
    # across a third-party HTTP call is what made the sync race window wide
    # enough to hit, and it pins a pool connection for the duration.
    # Cancellation is idempotent (already-cancelled subscriptions are
    # filtered out on the retry), so a failure here leaves the event
    # unclaimed for Stripe redelivery, exactly as the rollback used to.
    with :ok <- prepare_event(event) do
      Repo.transaction(fn ->
        if claim_event(id, type) == :claimed do
          case sync_subscription(event) do
            {:ok, result} -> result
            {:error, reason} -> Repo.rollback(reason)
          end
        else
          :duplicate
        end
      end)
    end
  end

  # No id (hand-built events in tests) — nothing to dedupe against.
  def handle_event(%Stripe.Event{} = event) do
    with :ok <- prepare_event(event), do: sync_subscription(event)
  end

  # checkout.session.completed is the one event whose apply has a Stripe side
  # effect: cancelling every other live subscription on the customer. The
  # short-circuits mirror adopt_subscription/3's — no user (sync will report
  # :user_not_found), comped, or the subscription already adopted (a
  # redelivery) mean no cancellations either.
  defp prepare_event(%Stripe.Event{type: "checkout.session.completed", data: %{object: session}}) do
    customer_id = extract_stripe_id(Map.get(session, :customer))
    subscription_id = extract_stripe_id(Map.get(session, :subscription))
    user_id = Map.get(session, :client_reference_id)

    user =
      get_user_by_stripe_customer_id(customer_id) ||
        (is_binary(user_id) && Repo.get(User, user_id)) || nil

    cond do
      is_nil(customer_id) or is_nil(subscription_id) ->
        :ok

      is_nil(user) ->
        :ok

      user.subscription_status == "comped" ->
        :ok

      user.stripe_subscription_id == subscription_id ->
        :ok

      true ->
        with {:ok, _cancelled} <- cancel_other_subscriptions(customer_id, subscription_id),
             do: :ok
    end
  end

  defp prepare_event(_event), do: :ok

  @doc """
  Best-effort record of a webhook processing failure (#501).

  A failed apply rolls the `stripe_events` claim back by design, so without
  this a failing event leaves zero DB trace — the failure exists only in
  Stripe's dashboard and our logs, and subscription state silently lags
  reality. One row per event id: a retried delivery bumps `failure_count`
  and `last_failed_at` (and un-resolves a previously resolved row) rather
  than accumulating a row per attempt across Stripe's three days of retries.

  Best-effort on the same contract as `record_usage/5`: recording the
  failure must never change the webhook response.
  """
  @spec record_webhook_failure(Stripe.Event.t(), term()) :: :ok | :error
  def record_webhook_failure(%Stripe.Event{id: id, type: type}, reason) when is_binary(id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    error = reason |> inspect() |> String.slice(0, 500)

    Repo.insert_all(
      "stripe_webhook_failures",
      [
        %{
          event_id: id,
          event_type: type,
          error: error,
          failure_count: 1,
          first_failed_at: now,
          last_failed_at: now
        }
      ],
      on_conflict: [
        set: [error: error, last_failed_at: now, resolved_at: nil],
        inc: [failure_count: 1]
      ],
      conflict_target: :event_id
    )

    :ok
  rescue
    e ->
      Logger.error(
        "webhook failure record failed for #{inspect(reason)}: #{Exception.message(e)}"
      )

      :error
  end

  def record_webhook_failure(_event, _reason), do: :ok

  @doc """
  Marks a previously recorded webhook failure resolved — called when a later
  delivery of the same event processes successfully (or dedupes/goes stale,
  which means the event no longer needs applying). Best-effort, like
  `record_webhook_failure/2`.
  """
  @spec resolve_webhook_failure(String.t() | nil) :: :ok
  def resolve_webhook_failure(event_id) when is_binary(event_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update_all(
      from(f in "stripe_webhook_failures",
        where: f.event_id == ^event_id and is_nil(f.resolved_at)
      ),
      set: [resolved_at: now]
    )

    :ok
  rescue
    e ->
      Logger.error("webhook failure resolve failed for #{event_id}: #{Exception.message(e)}")
      :ok
  end

  def resolve_webhook_failure(_), do: :ok

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

  Handles `customer.subscription.created`, `.updated`, `.deleted` — keyed by
  **subscription**, not customer: the customer only locates the user, and an
  event naming any subscription other than `users.stripe_subscription_id`
  returns `{:ok, :other_subscription}` without touching the account. The
  subscription of record is set at trial creation
  (`start_trial_subscription/1`) and replaced when a Checkout completes
  (`checkout.session.completed` adopts the new subscription; `handle_event/1`
  cancels every other live one on the customer before the claim transaction
  opens, so no Stripe call runs inside it).

  Reads the user row `FOR UPDATE` so the ownership and ordering guards are
  evaluated against the same snapshot the write commits against (#393).

  All other event types return `{:ok, :ignored}` without touching the DB.
  """
  @spec sync_subscription(Stripe.Event.t()) ::
          {:ok, User.t() | :ignored | :stale | :comped_ignored | :other_subscription}
          | {:error, term()}
  def sync_subscription(
        %Stripe.Event{
          type: "checkout.session.completed",
          data: %{object: session}
        } = event
      ) do
    customer_id = extract_stripe_id(Map.get(session, :customer))
    subscription_id = extract_stripe_id(Map.get(session, :subscription))
    user_id = Map.get(session, :client_reference_id)

    user =
      get_user_by_stripe_customer_id(customer_id, :for_update) ||
        get_user_for_update(user_id)

    cond do
      is_nil(customer_id) -> {:ok, :ignored}
      is_nil(user) -> {:error, :user_not_found}
      true -> complete_checkout(user, customer_id, subscription_id, event_created_at(event))
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
    customer_id = extract_stripe_id(Map.get(sub, :customer))

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
    customer_id = extract_stripe_id(sub.customer)
    subscription_id = Map.get(sub, :id)
    status = coerce_status(sub.status, type)

    trial_ends_at =
      case Map.get(sub, :trial_end) do
        nil -> nil
        ts when is_integer(ts) -> DateTime.from_unix!(ts) |> DateTime.truncate(:second)
      end

    # A portal cancellation flips this flag while the status stays "active":
    # the user keeps access until the period ends and `.deleted` arrives. Synced
    # so the billing page can say "access until <date>" instead of hard-locking
    # (or saying nothing) at the webhook. `.deleted` clears it — the pending
    # cancellation has happened, and a stale flag would haunt a resubscription.
    cancel_at_period_end =
      type != "customer.subscription.deleted" and Map.get(sub, :cancel_at_period_end) == true

    # Both ends of the invoiced period, not just the one the cancellation
    # notice needed. `current_period_start` is what `billing_period/2`
    # measures an allowance over; without it every usage number was reported
    # against a calendar month that drifts out of step with the invoice at
    # every renewal.
    current_period_start =
      case period_start_unix(sub) do
        ts when is_integer(ts) -> DateTime.from_unix!(ts) |> DateTime.truncate(:second)
        _ -> nil
      end

    current_period_end =
      case period_end_unix(sub) do
        ts when is_integer(ts) -> DateTime.from_unix!(ts) |> DateTime.truncate(:second)
        _ -> nil
      end

    event_created = event_created_at(event)

    case get_user_by_stripe_customer_id(customer_id, :for_update) do
      nil ->
        {:error, :user_not_found}

      # A comp is an operator decision; Stripe events do not override it. In
      # particular, comp_account/1 cancels the user's subscriptions, and the
      # cancellation webhook that follows must not flip the account it just
      # comped to "canceled". revoke_comp/1 is the only way out of comped.
      %User{subscription_status: "comped"} ->
        {:ok, :comped_ignored}

      user ->
        cond do
          # The customer is how we find the user; the subscription is what the
          # event is *about*, and only the subscription of record may write the
          # account's status. A customer briefly carries two subscriptions
          # during a mid-trial upgrade, and before this filter the doomed
          # trial's deletion event locked out the paying account (#309).
          other_subscription?(user, subscription_id) ->
            {:ok, :other_subscription}

          stale?(user.subscription_synced_at, event_created) ->
            # An older event arriving after a newer one. Applying it would move
            # the account backwards — reactivating a cancellation, or
            # re-locking an account that has already recovered.
            {:ok, :stale}

          true ->
            user
            |> User.billing_changeset(
              %{
                subscription_status: status,
                trial_ends_at: trial_ends_at,
                subscription_synced_at: event_created || user.subscription_synced_at,
                cancel_at_period_end: cancel_at_period_end,
                current_period_start: current_period_start,
                current_period_end: current_period_end
              }
              |> maybe_adopt_subscription_id(user, subscription_id, type)
              |> maybe_adopt_plan(sub, type)
            )
            |> Repo.update()
            |> tap(fn
              {:ok, updated} -> enqueue_lifecycle_email(user.subscription_status, updated)
              _ -> :ok
            end)
            |> audit_billing(user, "billing.subscription.synced", "webhook", %{
              "event_type" => type
            })
        end
    end
  end

  @doc false
  # invoice.payment_failed / invoice.payment_action_required (#447): the
  # first-class dunning signals. Status is NOT written here — that stays with
  # `customer.subscription.updated`, which carries the authoritative status —
  # these events only drive the notification. Both usually arrive in the same
  # delivery burst as the subscription update, and `Workers.LifecycleEmail`'s
  # 24 h uniqueness collapses the invoice-driven and transition-driven
  # enqueues into one email.
  #
  # Unknown customers return {:ok, :ignored}, not {:error, :user_not_found}:
  # a deleted account's trailing invoice events are expected traffic, and
  # there is no state to repair by redelivering.
  def sync_subscription(%Stripe.Event{type: type, data: %{object: invoice}})
      when type in ["invoice.payment_failed", "invoice.payment_action_required"] do
    customer_id = extract_stripe_id(Map.get(invoice, :customer))
    subscription_id = extract_stripe_id(Map.get(invoice, :subscription))

    case customer_id && get_user_by_stripe_customer_id(customer_id) do
      %User{subscription_status: "comped"} ->
        {:ok, :comped_ignored}

      %User{} = user ->
        if other_subscription?(user, subscription_id) do
          {:ok, :other_subscription}
        else
          email =
            case type do
              "invoice.payment_failed" -> "payment_failed"
              "invoice.payment_action_required" -> "payment_action_required"
            end

          enqueue_email(user, email)
          {:ok, user}
        end

      _ ->
        {:ok, :ignored}
    end
  end

  @doc false
  # invoice.paid (#447) drives exactly one thing: dunning recovery. It must
  # never write status except off `past_due` — Stripe pays a $0 invoice at
  # trial-subscription creation and one per normal renewal, and applying
  # those would flip a fresh trialing account straight to active. The
  # past_due → active write below routes through the same watermark and
  # subscription-of-record guards as the subscription events, and the
  # transition enqueues the payment_recovered email via lifecycle_email/2.
  def sync_subscription(%Stripe.Event{type: "invoice.paid", data: %{object: invoice}} = event) do
    customer_id = extract_stripe_id(Map.get(invoice, :customer))
    subscription_id = extract_stripe_id(Map.get(invoice, :subscription))
    event_created = event_created_at(event)

    case customer_id && get_user_by_stripe_customer_id(customer_id, :for_update) do
      %User{subscription_status: "comped"} ->
        {:ok, :comped_ignored}

      %User{subscription_status: "past_due"} = user ->
        cond do
          other_subscription?(user, subscription_id) ->
            {:ok, :other_subscription}

          stale?(user.subscription_synced_at, event_created) ->
            {:ok, :stale}

          true ->
            user
            |> User.billing_changeset(%{
              subscription_status: "active",
              subscription_synced_at: event_created || user.subscription_synced_at
            })
            |> Repo.update()
            |> tap(fn
              {:ok, updated} -> enqueue_lifecycle_email("past_due", updated)
              _ -> :ok
            end)
            |> audit_billing(user, "billing.payment.recovered", "webhook")
        end

      %User{} ->
        {:ok, :ignored}

      _ ->
        {:ok, :ignored}
    end
  end

  def sync_subscription(_event), do: {:ok, :ignored}

  # ─── Lifecycle emails (#283) ────────────────────────────────────────────────

  # Which lifecycle email a status *transition* triggers, if any. Keyed on the
  # transition and not the new status because Stripe fires several
  # `customer.subscription.updated` events per dunning cycle, all carrying
  # `past_due` — only the first one is news. A replayed event with the same
  # status is likewise a no-op here (on top of the event-id claim upstream).
  #
  # `canceled` splits on where the account came from: a trial that ran out
  # (`missing_payment_method: :cancel` deletes the subscription at trial end)
  # gets the "trial expired, here's checkout" email; a paying account —
  # cancelled by the user or by dunning exhaustion — gets the cancellation
  # confirmation. A pre-subscription nil status counts as trialing.
  defp lifecycle_email(same, same), do: nil
  defp lifecycle_email(old, "canceled") when old in ["trialing", nil], do: "trial_expired"
  defp lifecycle_email(_old, "canceled"), do: "subscription_canceled"
  defp lifecycle_email(_old, "past_due"), do: "payment_failed"
  # Dunning recovery (#447): the counterpart to payment_failed. Fires whether
  # the recovery arrives via customer.subscription.updated or invoice.paid.
  defp lifecycle_email("past_due", "active"), do: "payment_recovered"
  defp lifecycle_email(_old, _new), do: nil

  # Only enqueues; the send is a job (`Workers.LifecycleEmail`). A mail — or
  # even enqueue — failure must not make the webhook return an error and have
  # Stripe retry the whole event, so this always returns :ok.
  defp enqueue_lifecycle_email(old_status, %User{} = user) do
    case lifecycle_email(old_status, user.subscription_status) do
      nil -> :ok
      email -> enqueue_email(user, email)
    end
  end

  defp enqueue_email(%User{} = user, email) do
    case Fountain.Workers.LifecycleEmail.enqueue(user.id, email) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "lifecycle_email: enqueue #{email} for #{user.id} failed: #{inspect(reason)}"
        )

        :ok
    end
  end

  # A session with no subscription (payment mode, or an old-style session) only
  # backfills the customer link, exactly as before.
  defp complete_checkout(%User{} = user, customer_id, nil, _event_created) do
    if user.stripe_customer_id == customer_id do
      {:ok, :ignored}
    else
      attach_stripe_customer(user, customer_id)
    end
  end

  defp complete_checkout(%User{} = user, customer_id, subscription_id, event_created) do
    linked =
      if user.stripe_customer_id == customer_id do
        {:ok, user}
      else
        attach_stripe_customer(user, customer_id)
      end

    with {:ok, user} <- linked,
         {:ok, user} <- adopt_subscription(user, subscription_id, event_created) do
      # The teammate-contact add-on lives on the subscription, so a *new*
      # subscription starts without it. Nothing else would notice: the
      # quantity is only pushed on provision and release, so a tenant who
      # cancelled (or was comped and then un-comped) and came back through
      # Checkout would keep their numbers and stop being billed for them
      # until they happened to add or remove one.
      #
      # Best-effort, and last: this event's job is to record the
      # subscription, and a Stripe hiccup here must not make the webhook fail
      # and Stripe redeliver an adoption that already succeeded.
      resync_contact_addon(user)
      {:ok, user}
    end
  end

  defp resync_contact_addon(%User{} = user) do
    if Fountain.Team.Comms.contact_count(user.id) > 0 do
      case sync_contact_addon(user.id) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.error(
            "[billing] could not re-attach the contact add-on for user #{user.id} " <>
              "on subscription #{user.stripe_subscription_id}: #{inspect(reason)} — " <>
              "they hold numbers that are not being billed"
          )

          :error
      end
    end
  rescue
    error ->
      Logger.error("[billing] contact add-on resync raised: #{Exception.message(error)}")
      :error
  end

  # Checkout in subscription mode always creates a *new* subscription, so a
  # mid-trial upgrade leaves the old trialing subscription alive alongside it.
  # Left alone, that subscription either dies at trial end — and its deletion
  # webhook locks out a now-paying customer — or converts and double-bills
  # them. Adopt the checkout's subscription as the account's subscription of
  # record; the other live subscriptions were cancelled by prepare_event/1
  # before the claim transaction opened (a failed cancellation never reaches
  # this point — the webhook answers 500 and Stripe redelivers an unclaimed
  # event).
  #
  # The status write is the optimistic copy the new subscription's own webhook
  # will confirm — necessary because that webhook may have already arrived and
  # been ignored for carrying an unrecorded subscription id.
  #
  # The billing period is deliberately *not* written here. A Checkout session
  # carries the subscription's id, not its object, and this runs inside the
  # event-claim transaction, where a Stripe read must not happen. The
  # `customer.subscription.created` event for the very subscription being
  # adopted carries both period ends and lands within seconds; until it does,
  # `billing_period/2` reports a calendar month and says so.
  #
  # The watermark stamp (#393) makes the adoption participate in the stale?/2
  # ordering guard: without it, any older event for the adopted subscription
  # that straggled in afterwards was treated as fresh and could move the
  # account backwards. Never moves the watermark backwards itself.
  # A webhook must never silently un-comp an account, so status is left
  # alone. But if a checkout DID complete for a comped account (#399 — the
  # billing page used to offer it), the customer is now being charged for a
  # subscription the app held no reference to: invisible to the MRR tile,
  # and revoke_comp/1 would lock out someone actively paying. Record the id
  # as a backstop and log loudly so an operator refunds or revokes the comp
  # deliberately.
  defp adopt_subscription(
         %User{subscription_status: "comped"} = user,
         subscription_id,
         event_created
       ) do
    if is_binary(subscription_id) and subscription_id != user.stripe_subscription_id do
      Logger.error(
        "[billing] comped user #{user.id} completed checkout for subscription " <>
          "#{subscription_id}; recording the id without changing status — " <>
          "they are being charged, investigate (refund or revoke the comp)"
      )

      user
      |> User.billing_changeset(%{
        stripe_subscription_id: subscription_id,
        subscription_synced_at: latest(event_created, user.subscription_synced_at)
      })
      |> Repo.update()
    else
      {:ok, user}
    end
  end

  defp adopt_subscription(%User{stripe_subscription_id: sub_id} = user, sub_id, _event_created),
    do: {:ok, user}

  defp adopt_subscription(%User{} = user, subscription_id, event_created) do
    user
    |> User.billing_changeset(%{
      stripe_subscription_id: subscription_id,
      subscription_status: "active",
      subscription_synced_at: latest(event_created, user.subscription_synced_at)
    })
    |> Repo.update()
  end

  defp latest(nil, b), do: b
  defp latest(a, nil), do: a
  defp latest(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  defp cancel_other_subscriptions(customer_id, keep_sub_id) when is_binary(customer_id) do
    case Stripe.Subscription.list(%{customer: customer_id, status: :all, limit: 100}) do
      {:ok, %{data: subs} = list} ->
        if Map.get(list, :has_more, false) do
          {:error, :too_many_subscriptions}
        else
          subs
          |> Enum.filter(&(&1.id != keep_sub_id and to_string(&1.status) in @cancellable))
          |> cancel_each()
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # An event that names a different subscription than the account's recorded
  # one is about a subscription this account no longer answers to. An event
  # with no subscription id (hand-built in tests) and an account with none
  # recorded (created before the id was persisted) both fall back to the old
  # customer-keyed behavior.
  defp other_subscription?(%User{stripe_subscription_id: recorded}, incoming)
       when is_binary(recorded) and is_binary(incoming),
       do: recorded != incoming

  defp other_subscription?(_user, _incoming), do: false

  # A legacy account (nil recorded id) adopts the subscription from the first
  # live event that names one — but never from a deletion: during a pre-fix
  # double-subscription window the dying trial must not become the subscription
  # of record while a paying one is alive; the paying one's next event adopts
  # and corrects instead.
  defp maybe_adopt_subscription_id(
         attrs,
         %User{stripe_subscription_id: nil},
         subscription_id,
         type
       )
       when is_binary(subscription_id) and type != "customer.subscription.deleted",
       do: Map.put(attrs, :stripe_subscription_id, subscription_id)

  defp maybe_adopt_subscription_id(attrs, _user, _subscription_id, _type), do: attrs

  # The plan follows the price on the subscription, which is what makes an
  # upgrade take effect: Stripe is told to swap the item's price, and the
  # entitlement changes when the resulting event lands. Three cases where the
  # key is deliberately left out, so the stored plan stands:
  #
  #   * a deletion — the account is losing access, not changing tier, and the
  #     plan it held is what a resubscription should default back to;
  #   * a subscription whose items carry no price this deployment knows —
  #     realistically an env var not yet set on the replica handling the
  #     webhook, and nulling a paying tenant's entitlement over that is worse
  #     than leaving it stale;
  #   * an event whose object carries no items at all (a hand-built test
  #     event, or a Stripe payload shape that changes under us).
  defp maybe_adopt_plan(attrs, _sub, "customer.subscription.deleted"), do: attrs

  defp maybe_adopt_plan(attrs, sub, _type) do
    case plan_slug_from_subscription(sub) do
      slug when is_binary(slug) -> Map.put(attrs, :plan, slug)
      nil -> attrs
    end
  end

  @doc false
  # The plan slug named by a subscription's items, or nil.
  #
  # A subscription carries the base plan item and, when the tenant has
  # teammate contacts, the add-on item as well. Only the base item maps to a
  # plan — `Plans.slug_for_price_id/1` answers nil for the add-on price, which
  # is exactly what makes "the first item that names a plan" correct rather
  # than order-dependent.
  def plan_slug_from_subscription(sub) do
    sub
    |> subscription_items()
    |> Enum.find_value(fn item -> item |> item_price_id() |> Plans.slug_for_price_id() end)
  end

  # Stripe hands items back as a %Stripe.List{} of structs on the API path and
  # as plain maps on some webhook paths; tests build both. Reading either
  # shape here keeps that difference out of every call site.
  defp subscription_items(%{items: %{data: data}}) when is_list(data), do: data
  defp subscription_items(%{items: data}) when is_list(data), do: data
  defp subscription_items(%{"items" => %{"data" => data}}) when is_list(data), do: data
  defp subscription_items(_), do: []

  @doc false
  # When the current billing period ends, as a unix timestamp, or nil.
  #
  # Stripe moved `current_period_start`/`current_period_end` off the
  # subscription and onto its items. On the API version this account is pinned
  # to, the subscription-level field reads `nil` and the real value sits on
  # `items.data[]` — so the obvious `Map.get(sub, :current_period_end)` had
  # never once populated `users.current_period_end` (#1018), and the
  # "access until <date>" a cancelling customer is shown was blank.
  #
  # Reads the item, falling back to the subscription-level field so an older
  # API version — and every existing test fixture, which is built in the old
  # shape and is exactly why this went unseen — still works.
  #
  # Any item will do: a plan item and a teammate-contact add-on ride the same
  # subscription and therefore share its period.
  def period_end_unix(sub), do: period_unix(sub, :current_period_end)

  @doc false
  # The other end of the same period (#1016), read the same way and for the
  # same reason. It moved onto the item in the same API change, so a
  # subscription-level read here would have repeated #1018 exactly: a column
  # that is never once populated, behind a green suite whose fixtures all
  # carry the old shape.
  def period_start_unix(sub), do: period_unix(sub, :current_period_start)

  defp period_unix(sub, key) do
    case field(sub, key) do
      ts when is_integer(ts) ->
        ts

      _ ->
        sub
        |> subscription_items()
        |> Enum.find_value(fn item ->
          case field(item, key) do
            ts when is_integer(ts) -> ts
            _ -> nil
          end
        end)
    end
  end

  # Stripe hands these back atom-keyed on the API path and string-keyed on
  # some webhook paths; tests build both.
  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp item_price_id(%{price: %{id: id}}), do: id
  defp item_price_id(%{price: id}) when is_binary(id), do: id
  defp item_price_id(%{"price" => %{"id" => id}}), do: id
  defp item_price_id(%{"price" => id}) when is_binary(id), do: id
  defp item_price_id(_), do: nil

  defp item_id(%{id: id}) when is_binary(id), do: id
  defp item_id(%{"id" => id}) when is_binary(id), do: id
  defp item_id(_), do: nil

  defp item_quantity(%{quantity: n}) when is_integer(n), do: n
  defp item_quantity(%{"quantity" => n}) when is_integer(n), do: n
  defp item_quantity(_), do: 0

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
  The calendar month `usage_summary/3` is normally asked about: the 1st at
  00:00:00 UTC to the last day at 23:59:59.

  Here rather than in each caller because the billing page, the billing API
  and the console's dashboard all report "this month" and must mean the same
  month — three copies of this arithmetic is three chances to disagree.
  """
  @spec current_month_range() :: {DateTime.t(), DateTime.t()}
  def current_month_range do
    now = DateTime.utc_now()
    period_start = %DateTime{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 0}}
    last_day = :calendar.last_day_of_the_month(now.year, now.month)

    period_end = %DateTime{
      now
      | day: last_day,
        hour: 23,
        minute: 59,
        second: 59,
        microsecond: {0, 0}
    }

    {period_start, period_end}
  end

  @doc """
  The window a tenant's usage should be measured over: the period Stripe is
  actually invoicing them for, or the calendar month when there is no such
  period — and which of the two it is.

  Returns `%{start:, end:, source:}` rather than a bare `{start, end}` on
  purpose. A number measured over the wrong window has to be able to say so:
  enforcing an allowance, or even displaying one, against a calendar month
  when the customer's invoice runs the 20th to the 20th is a support ticket
  per customer per month. Every surface that shows the number carries the
  `:source` with it.

  `:subscription` requires both ends synced from Stripe *and* that the stored
  period contains `now`. Everything else falls back to `:calendar_month`:

    * a self-hosted deployment with no Stripe at all;
    * a comped account, which has no invoiced period;
    * a trialing account Stripe has not reported a period for;
    * an account whose stored period has already ended — a cancelled
      subscription's final period, or the seconds between a renewal and the
      webhook that reports the new one.

  The last case is a real (brief) wobble at every renewal: the numbers move
  to a calendar month until `customer.subscription.updated` lands. Rolling the
  stored period forward instead would mean inventing a boundary Stripe has not
  confirmed, and the flag makes the substitution visible either way.
  """
  @spec billing_period(User.t(), DateTime.t() | nil) :: %{
          start: DateTime.t(),
          end: DateTime.t(),
          source: :subscription | :calendar_month
        }
  def billing_period(user, now \\ nil)

  def billing_period(
        %User{
          current_period_start: %DateTime{} = period_start,
          current_period_end: %DateTime{} = period_end
        },
        now
      ) do
    now = now || DateTime.utc_now()

    if DateTime.compare(period_start, now) != :gt and DateTime.compare(now, period_end) == :lt do
      %{start: period_start, end: period_end, source: :subscription}
    else
      calendar_month_period()
    end
  end

  def billing_period(%User{}, _now), do: calendar_month_period()

  defp calendar_month_period do
    {period_start, period_end} = current_month_range()
    %{start: period_start, end: period_end, source: :calendar_month}
  end

  @doc """
  Turn hours a tenant has spent in a period, on the providers Fountain pays
  for.

  A *turn* hour is an hour with a prompt in flight, not an hour of sandbox
  wall-clock: an agent left running overnight with nobody talking to it costs
  Fountain money (and is reported by `usage_summary/3` as sandbox minutes) but
  spends none of the tenant's allowance. Time on a tenant's own runner
  (ADR 0022) is excluded too — Fountain pays nothing for it, so charging an
  allowance against it would be indefensible.

  Pass a period as `{start, end}`; defaults to the tenant's `billing_period/2`.
  """
  @spec turn_hours_used(User.t(), keyword()) :: float()
  def turn_hours_used(%User{} = user, opts \\ []) do
    {period_start, period_end} =
      case Keyword.get(opts, :period) do
        {%DateTime{} = s, %DateTime{} = e} -> {s, e}
        nil -> billing_period(user) |> then(&{&1.start, &1.end})
      end

    user.id
    |> SandboxUsage.busy_for_user(period_start, period_end)
    |> Enum.filter(fn {provider, _seconds} -> SandboxUsage.platform_cost?(provider) end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.sum()
    |> SandboxUsage.hours()
  end

  @doc """
  The turn-hour meter, in one shape, for every surface that shows it: the
  billing page, `GET /api/account/billing`, and the admin per-tenant view.

  One function so the three cannot disagree about the window, the unit, or
  which providers count.

    * `:used` / `:included` — turn hours spent, and what the plan carries
    * `:remaining` — clamped at zero; a tenant over their allowance is not
      owed negative hours
    * `:period` — the `billing_period/2` map, `:source` included, so a
      surface can label a calendar-month fallback as one
    * `:over?` — whether `:used` has passed `:included`

  **Nothing acts on this.** No gate, no ceiling, no invoice line. Whether
  going over means post-paid overage or exhausted prepaid credits is still
  open (#1016 step 4) and is meant to be decided against a cycle of these
  numbers rather than ahead of one.
  """
  @spec turn_hour_allowance(User.t(), keyword()) :: %{
          used: float(),
          included: non_neg_integer(),
          remaining: float(),
          period: %{start: DateTime.t(), end: DateTime.t(), source: atom()},
          over?: boolean()
        }
  def turn_hour_allowance(%User{} = user, opts \\ []) do
    period = Keyword.get(opts, :period) || billing_period(user)
    used = turn_hours_used(user, period: {period.start, period.end})
    # The user, not `user.plan`: a slug carries no subscription status, so
    # passing one would quietly hand a trialing account the paid tier's
    # allowance (`Plans.effective/1`).
    included = Plans.included_turn_hours(user)

    %{
      used: used,
      included: included,
      remaining: Float.round(max(included - used, 0.0), 2),
      period: period,
      over?: used > included
    }
  end

  @doc """
  Returns a usage summary for `user_id` over the given period.

  Fields:
  - `:conversations` — count of `sandbox_provisioned` plus
    `sandbox_provision_failed` events. Failed attempts count because they
    still accrue sandbox minutes; excluding them makes the two numbers
    diverge for exactly the accounts where provisioning is failing.
  - `:turns` — count of `turn_started` events
  - `:sandbox_minutes` — active sandbox time in minutes inside the period,
    parked time excluded. Computed by `Fountain.Billing.SandboxUsage` from the
    sandbox rows themselves, clipped to the period: a sandbox that spans a
    month boundary contributes to each month what it ran in that month, and
    one still running contributes everything up to now.
  - `:sandbox_minutes_by_provider` — the same minutes split per sandbox
    provider, `%{provider => minutes}`. Providers the tenant did not use are
    absent. Minutes on different providers are bought at different prices, so
    this split is what makes the total attributable to a cost.
  - `:turn_hours` — the part of that time with a prompt actually in flight, on
    the providers Fountain pays for. The same number
    `turn_hours_used/2` computes, carried here so a surface showing usage does
    not need a second pass over the same rows to show the unit a plan is
    denominated in (`Fountain.Plans.included_turn_hours/1`).
  """
  @spec usage_summary(binary(), DateTime.t(), DateTime.t()) ::
          %{
            conversations: non_neg_integer(),
            turns: non_neg_integer(),
            sandbox_minutes: float(),
            sandbox_minutes_by_provider: %{optional(String.t()) => float()},
            turn_hours: float()
          }
  def usage_summary(user_id, %DateTime{} = period_start, %DateTime{} = period_end) do
    events =
      from(e in UsageEvent,
        where:
          e.user_id == ^user_id and
            e.inserted_at >= ^period_start and
            e.inserted_at < ^period_end and
            e.event_type in ["sandbox_provisioned", "sandbox_provision_failed", "turn_started"],
        select: e.event_type
      )
      |> Repo.all()

    conversations =
      Enum.count(events, &(&1 in ["sandbox_provisioned", "sandbox_provision_failed"]))

    turns = Enum.count(events, &(&1 == "turn_started"))

    # One attribution pass, read two ways. `for_user/3` and `busy_for_user/3`
    # would each run it again; this is the same two queries once.
    rows = SandboxUsage.attribution(period_start, period_end, user_id: user_id)

    %{
      conversations: conversations,
      turns: turns,
      # Rounded once, from the total — summing rounded per-provider minutes
      # would let the parts disagree with the whole.
      sandbox_minutes:
        rows |> Enum.map(& &1.active_seconds) |> Enum.sum() |> SandboxUsage.minutes(),
      sandbox_minutes_by_provider:
        rows
        |> Enum.reject(&(&1.active_seconds == 0))
        |> Map.new(&{&1.provider, SandboxUsage.minutes(&1.active_seconds)}),
      turn_hours:
        rows
        |> Enum.filter(&SandboxUsage.platform_cost?(&1.provider))
        |> Enum.map(& &1.busy_seconds)
        |> Enum.sum()
        |> SandboxUsage.hours()
    }
  end

  @doc """
  `usage_summary/3` for every user at once, in one query — for the admin view,
  which refreshes on a timer and must not run a query per user.

  Returns `%{user_id => %{conversations: n, turns: n, sandbox_minutes: f,
  sandbox_minutes_by_provider: %{provider => f}, turn_hours: f}}`; users with
  neither events nor sandbox time in the period are absent.

  Carries two units on purpose, because they answer different questions and
  the admin table shows both. `sandbox_minutes` is wall-clock sandbox time —
  what a provider bills Fountain, so minutes, per provider, because the
  providers charge differently. `turn_hours` is time with a prompt in flight —
  what a *plan* includes (`Fountain.Plans.included_turn_hours/1`), so hours,
  and summed only over the providers Fountain pays for, exactly as
  `turn_hours_used/2` computes it for one tenant.
  """
  @spec usage_summaries(DateTime.t(), DateTime.t()) :: %{optional(binary()) => map()}
  def usage_summaries(%DateTime{} = period_start, %DateTime{} = period_end) do
    empty = %{
      conversations: 0,
      turns: 0,
      sandbox_minutes: 0.0,
      sandbox_minutes_by_provider: %{},
      turn_hours: 0.0
    }

    counted =
      from(e in UsageEvent,
        where:
          e.inserted_at >= ^period_start and e.inserted_at < ^period_end and
            e.event_type in ["sandbox_provisioned", "sandbox_provision_failed", "turn_started"],
        group_by: [e.user_id, e.event_type],
        select: {e.user_id, e.event_type, count(e.id)}
      )
      |> Repo.all()
      |> Enum.reduce(%{}, fn {user_id, type, count}, acc ->
        summary = Map.get(acc, user_id, empty)

        summary =
          case type do
            "sandbox_provisioned" ->
              %{summary | conversations: summary.conversations + count}

            "sandbox_provision_failed" ->
              %{summary | conversations: summary.conversations + count}

            "turn_started" ->
              %{summary | turns: count}
          end

        Map.put(acc, user_id, summary)
      end)

    # Both sandbox figures come from the sandbox rows, not from these events —
    # the period-clipped, per-provider computation in `SandboxUsage`, which is
    # two more queries for every user at once rather than one per user.
    # `Finance.usage_by_user/1` rather than `SandboxUsage.by_user/1` because
    # the latter collapses to active seconds and drops the busy/idle split
    # turn hours are read off. Sandboxes whose owner has been deleted keep
    # their seconds under a `nil` owner in the provider report; it drops them,
    # since here there is no user row to hang them on.
    period_start
    |> SandboxUsage.attribution(period_end)
    |> Finance.usage_by_user()
    |> Enum.reduce(counted, fn {user_id, usage}, acc ->
      summary = Map.get(acc, user_id, empty)

      Map.put(acc, user_id, %{
        summary
        | sandbox_minutes: SandboxUsage.minutes(usage.active_seconds),
          sandbox_minutes_by_provider:
            Map.new(usage.by_provider, fn row ->
              {row.provider, SandboxUsage.minutes(row.active)}
            end),
          turn_hours:
            usage.by_provider
            |> Enum.filter(&SandboxUsage.platform_cost?(&1.provider))
            |> Enum.map(& &1.busy)
            |> Enum.sum()
            |> SandboxUsage.hours()
      })
    end)
  end

  # ─── Provider spend attribution ─────────────────────────────────────────────

  @doc """
  Sandbox time per provider for a period, and who it belongs to — the number to
  hold a Sprites, E2B or Daytona invoice next to.

  Options:
    * `:period` — `{period_start, period_end}`, default the current month
    * `:top` — how many tenants `:top_tenants` names (default 10)
    * `:now` — pins the clock (tests)

  Returns:
    * `:period_start` / `:period_end` — the window these numbers cover
    * `:by_provider` — `%{provider => %{active_seconds, busy_seconds,
      idle_seconds, sandboxes, users}}`, parked time already excluded
    * `:platform_seconds` — seconds on providers Fountain pays for. Self-hosted
      runners (decisions/0022) run on the tenant's own machine, so they appear
      in `:by_provider` but deliberately not in this total
    * `:platform_idle_seconds` — the part of `:platform_seconds` with no turn
      in flight. This is the number a shorter idle timeout removes, so it is
      the one to read before changing anything about the bill
    * `:top_tenants` — the accounts behind that total, biggest first, each with
      its `email` (`nil` once the account is deleted — the seconds were still
      paid for, they are simply no longer attributable)
    * `:attribution` — every per-tenant row the totals were built from

  Deliberately no money: prices are per-provider, per-machine-size and
  negotiated, and none of them are in this codebase. A made-up rate would make
  this look authoritative when it is not — multiply outside, against the rate
  card you actually pay.
  """
  @spec provider_spend(keyword()) :: %{
          period_start: DateTime.t(),
          period_end: DateTime.t(),
          by_provider: map(),
          platform_seconds: non_neg_integer(),
          platform_idle_seconds: non_neg_integer(),
          top_tenants: [map()],
          attribution: [SandboxUsage.row()]
        }
  def provider_spend(opts \\ []) do
    {period_start, period_end} = Keyword.get(opts, :period) || current_month_range()

    attribution_opts =
      case Keyword.fetch(opts, :now) do
        {:ok, now} -> [now: now]
        :error -> []
      end

    rows = SandboxUsage.attribution(period_start, period_end, attribution_opts)
    paid = Enum.filter(rows, &SandboxUsage.platform_cost?(&1.provider))

    %{
      period_start: period_start,
      period_end: period_end,
      by_provider: SandboxUsage.by_provider(rows),
      platform_seconds: paid |> Enum.map(& &1.active_seconds) |> Enum.sum(),
      platform_idle_seconds: paid |> Enum.map(& &1.idle_seconds) |> Enum.sum(),
      top_tenants: top_tenants(paid, Keyword.get(opts, :top, 10)),
      attribution: rows
    }
  end

  # One email lookup for the whole list rather than one per row — this renders
  # on the admin panel's ten-second refresh.
  defp top_tenants(rows, limit) do
    top = rows |> Enum.sort_by(& &1.active_seconds, :desc) |> Enum.take(limit)

    emails =
      top
      |> Enum.map(& &1.user_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> case do
        [] -> %{}
        ids -> Repo.all(from u in User, where: u.id in ^ids, select: {u.id, u.email}) |> Map.new()
      end

    Enum.map(top, &Map.put(&1, :email, Map.get(emails, &1.user_id)))
  end

  # ─── Admin billing overview (#286) ──────────────────────────────────────────

  @doc """
  The numbers an operator checks daily, in one read-only pass — for the admin
  panel (no tenant scoping; the caller is behind `require_admin`).

  - `status_counts` — users per `subscription_status`
  - `trials_ending_7d` — trialing users whose `trial_ends_at` is within the
    next 7 days
  - `conversions_this_month` — `checkout.session.completed` webhook events
    since the start of the current UTC month. Every verified webhook is
    claimed into `stripe_events` before handling, so the claim table is a
    complete record of checkouts — including a canceled user coming back.
  - `mrr_cents` / `mrr_by_plan` — recurring revenue, priced per plan from
    `Fountain.Billing.Finance.mrr/0`: each active subscription at its own
    tier's price, plus the teammate-contact add-on. Deliberately `active`
    only: `past_due` is at-risk revenue, comped is not revenue.

    It used to be `active × :stripe_price_monthly_cents`, one configured
    amount for everybody. The day there was a second price was supposed to be
    loud and was not — #991 shipped four tiers and this tile went on charging
    every account the legacy $29, under-reporting a deployment selling Scale
    by a factor of seven. The catalog has held every plan's price since, so
    there is nothing left to configure and nothing left to get out of step.
    `STRIPE_PRICE_MONTHLY_CENTS` is no longer read here.
  - `recent_events` — the last processed webhook events, newest first.
  - `failed_events` — unresolved webhook processing failures, most recently
    failed first (#501). Failed deliveries are never claimed (the claim rolls
    back with the failed apply), so these come from `stripe_webhook_failures`,
    written by the controller outside the rolled-back transaction.

  Options: `:now` pins the clock, `:event_limit` caps
  `recent_events`/`failed_events` (default 10).
  """
  @spec overview_admin(keyword()) :: map()
  def overview_admin(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    event_limit = Keyword.get(opts, :event_limit, 10)
    mrr = Finance.mrr()

    status_counts =
      from(u in User,
        group_by: u.subscription_status,
        select: {u.subscription_status, count(u.id)}
      )
      |> Repo.all()
      |> Map.new()

    in_7d = DateTime.add(now, 7, :day)

    trials_ending_7d =
      Repo.one(
        from u in User,
          where:
            u.subscription_status == "trialing" and not is_nil(u.trial_ends_at) and
              u.trial_ends_at >= ^now and u.trial_ends_at <= ^in_7d,
          select: count(u.id)
      ) || 0

    month_start = %{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 6}}

    conversions_this_month =
      Repo.one(
        from e in "stripe_events",
          where: e.type == "checkout.session.completed" and e.inserted_at >= ^month_start,
          select: count(e.id)
      ) || 0

    recent_events =
      Repo.all(
        from e in "stripe_events",
          order_by: [desc: e.inserted_at],
          limit: ^event_limit,
          select: %{id: e.id, type: e.type, inserted_at: e.inserted_at}
      )

    failed_events =
      Repo.all(
        from f in "stripe_webhook_failures",
          where: is_nil(f.resolved_at),
          order_by: [desc: f.last_failed_at],
          limit: ^event_limit,
          select: %{
            event_id: f.event_id,
            event_type: f.event_type,
            error: f.error,
            failure_count: f.failure_count,
            last_failed_at: f.last_failed_at
          }
      )

    %{
      status_counts: status_counts,
      trials_ending_7d: trials_ending_7d,
      conversions_this_month: conversions_this_month,
      mrr_cents: mrr.mrr_cents,
      mrr_by_plan: mrr.by_plan,
      recent_events: recent_events,
      failed_events: failed_events
    }
  end

  # ─── Usage emission ─────────────────────────────────────────────────────────

  @doc """
  Best-effort `emit/5`.

  Metering is bookkeeping: it must never be able to fail a conversation. A bad
  changeset, a dropped connection or an unexpected raise is logged and swallowed,
  the same contract `Fountain.Audit.record/1` uses. Because the swallow makes a
  metering outage look like zero usage, every drop also emits
  `[:fountain, :usage, :dropped]` — any non-zero count on that counter means
  billing data is being lost (#503).
  """
  @spec record_usage(binary(), String.t(), binary() | nil, String.t() | nil, map()) ::
          {:ok, UsageEvent.t()} | {:error, term()}
  def record_usage(user_id, event_type, resource_id, resource_type, metadata \\ %{}) do
    case emit(user_id, event_type, resource_id, resource_type, metadata) do
      {:ok, _} = ok ->
        mirror_usage_to_analytics(user_id, event_type, resource_type, metadata)
        ok

      {:error, %Ecto.Changeset{} = cs} ->
        usage_dropped(event_type, "rejected", cs.errors)
        {:error, :invalid}
    end
  rescue
    e ->
      usage_dropped(event_type, "exception", Exception.message(e))
      {:error, :exception}
  end

  # The six metering event types are also the six moments that say whether
  # anyone is actually *using* the product, so they go to PostHog from the
  # same choke point that writes the billing row — never from the callers,
  # which is the whole point of `record_usage/5` being the choke point.
  #
  # `usage.` prefixed so a product event and its billing counterpart are
  # obviously the same fact seen twice, and so they cannot collide with an
  # audit action name in the same PostHog project.
  defp mirror_usage_to_analytics(user_id, event_type, resource_type, metadata) do
    if Fountain.Analytics.enabled?(),
      do: do_mirror_usage(user_id, event_type, resource_type, metadata)

    :ok
  end

  defp do_mirror_usage(user_id, event_type, resource_type, metadata) do
    Fountain.Analytics.capture(
      "usage.#{event_type}",
      user_id,
      metadata
      |> Fountain.Analytics.sanitize()
      |> Map.merge(%{"resource_type" => resource_type, "source" => "metering"})
    )
  end

  defp usage_dropped(event_type, kind, reason) do
    Logger.warning("usage: #{event_type} #{kind}, event dropped: #{inspect(reason)}")

    :telemetry.execute(
      [:fountain, :usage, :dropped],
      %{count: 1},
      %{event_type: event_type, kind: kind}
    )
  end

  @doc """
  Writes a usage event synchronously to `usage_events`.

  Raises nothing itself but returns `{:error, changeset}` on rejection. Callers
  on a conversation's critical path should use `record_usage/5`, which cannot
  fail the operation it is measuring.

  Emitted from `Conversations.update_sandbox/2` and `Conversations._unsafe_create_turn/1`
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

  # FOR UPDATE (#393): the webhook sync paths evaluate their ownership
  # (other_subscription?/2) and ordering (stale?/2) guards on this read and
  # write afterwards. Unlocked, a concurrent sync for the same user — e.g.
  # the customer.subscription.deleted that a mid-upgrade cancellation
  # triggers — could pass the guards against a snapshot another transaction
  # was about to make stale, and the #309 lockout came back as a race. The
  # lock makes a concurrent sync wait here and re-evaluate against the
  # committed row. Outside a transaction (bare sync_subscription/1 calls in
  # tests) the lock is released at statement end and changes nothing.
  defp get_user_by_stripe_customer_id(nil, _lock_mode), do: nil

  defp get_user_by_stripe_customer_id(customer_id, :for_update) when is_binary(customer_id) do
    Repo.one(from(u in User, where: u.stripe_customer_id == ^customer_id, lock: "FOR UPDATE"))
  end

  defp get_user_for_update(user_id) when is_binary(user_id) do
    Repo.one(from(u in User, where: u.id == ^user_id, lock: "FOR UPDATE"))
  end

  defp get_user_for_update(_), do: nil

  # Stripe returns related objects (customer, subscription) as either a plain
  # string id or an expanded object, depending on the event and API version.
  defp extract_stripe_id(value) when is_binary(value), do: value
  defp extract_stripe_id(%{id: id}) when is_binary(id), do: id
  defp extract_stripe_id(_), do: nil

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
