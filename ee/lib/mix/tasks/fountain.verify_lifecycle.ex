defmodule Mix.Tasks.Fountain.VerifyLifecycle do
  @shortdoc "Walk the billing lifecycle against Stripe test mode with a Test Clock"

  @moduledoc """
  End-to-end billing lifecycle verification (#289): a command, not a memory.

      STRIPE_SECRET_KEY=sk_test_... mix fountain.verify_lifecycle

  Creates a scratch user and a Stripe Test Clock, then walks:
  signup → trialing subscription → clock to T-3d → trial-ending email
  enqueued → clock past trial end → canceled, gate refuses, trial-expired
  email (#283) → subscribe with a test card (the checkout-completes
  equivalent) → active, gate opens → cancel at period end → access retained,
  `cancel_at_period_end`/`current_period_end` synced (#284) → clock past
  period end → canceled, gate refuses, cancellation email, flag cleared →
  re-subscribe → active again (the return path) → swap to an always-failing
  card and advance past renewal → real dunning: `past_due`, gate refuses,
  payment-failed email.

  At each step it asserts the **Fountain-side** state — `subscription_status`,
  `trial_ends_at`, `Billing.check_active/1`, enqueued email jobs. Stripe's own
  behavior (that clocks advance, that trials cancel) is theirs to test; real
  test-mode objects are still used so our sync sees real shapes. Webhook
  *delivery* needs a public endpoint and is out of scope: each fetched
  subscription state is fed through `Billing.sync_subscription/1`, exactly
  what the webhook controller does after signature verification.

  Deliberately **not CI**: external, slow (~1–2 min of clock advances), needs
  a key. It is the documented release-verification step for billing-touching
  changes — see `docs/integrations/stripe.md`.

  Requirements: a **test-mode** key (`sk_test_`/`rk_test_` — live keys are
  refused), and a reachable dev database. The key expires every 90 days; an
  expired key fails the preflight with instructions, not a misleading error.
  Cleanup deletes the Test Clock (which removes its Stripe objects) and the
  scratch user, and runs even when a step fails.
  """

  use Mix.Task

  alias Fountain.{Accounts, Billing, Repo}
  alias Fountain.Accounts.User

  @clock_poll_ms 2_000
  @clock_poll_attempts 45

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    key = System.get_env("STRIPE_SECRET_KEY") || Application.get_env(:stripity_stripe, :api_key)
    preflight!(key)
    Application.put_env(:stripity_stripe, :api_key, key)

    # Half the checks assert what the gate refuses, and dev defaults
    # BILLING_ENABLED=false — without this the run dies at "gate refuses
    # after expiry" for a reason that has nothing to do with the lifecycle.
    Application.put_env(:fountain, :billing_enabled, true)

    state = %{user: nil, clock: nil}

    try do
      state = step_scratch_user(state)
      state = step_clock_and_customer(state)
      state = step_trial(state)
      state = step_trial_ending_warning(state)
      state = step_trial_expiry(state)
      state = step_subscribe(state)
      state = step_cancel_at_period_end(state)
      state = step_period_end(state)
      state = step_resubscribe(state)
      state = step_dunning(state)
      _state = step_dunning_recovery(state)

      info("\n✅  Lifecycle verified end to end.")
    after
      cleanup(state_now())
    end
  end

  # ── Steps ──────────────────────────────────────────────────────────────────

  defp preflight!(nil) do
    Mix.raise("""
    No Stripe key. Set STRIPE_SECRET_KEY to a *test-mode* key (sk_test_...).
    The CLI's key lives in ~/.config/stripe/config.toml (test_mode_api_key).
    """)
  end

  defp preflight!(key) do
    unless String.starts_with?(key, ["sk_test_", "rk_test_"]) do
      Mix.raise("Refusing to run: the key is not a test-mode key (sk_test_/rk_test_).")
    end

    case Stripe.Customer.list(%{limit: 1}, api_key: key) do
      {:ok, _} ->
        info("✓ preflight: test-mode key accepted")

      {:error, %Stripe.Error{extra: %{http_status: 401}}} ->
        Mix.raise("""
        Stripe rejected the key (401). Test-mode keys expire every 90 days —
        this one is likely expired, not wrong. Refresh with `stripe login`
        and re-run.
        """)

      {:error, err} ->
        Mix.raise("Stripe preflight failed: #{inspect(err)}")
    end
  end

  defp step_scratch_user(state) do
    suffix = System.system_time(:second)
    email = "lifecycle-verify-#{suffix}@example.com"

    {:ok, user} =
      Accounts.register_user(
        %{"email" => email, "password" => "scratch-#{suffix}!"},
        actor: "system:verify_lifecycle"
      )

    {:ok, user} = Accounts.verify_email(user)
    remember(%{state | user: user})

    check!("scratch user starts trialing", user.subscription_status == "trialing")
    check!("gate open while trialing", Billing.check_active(user.id) == :ok)
    %{state | user: user}
  end

  defp step_clock_and_customer(%{user: user} = state) do
    now = System.system_time(:second)
    {:ok, clock} = Stripe.TestHelpers.TestClock.create(%{frozen_time: now})
    state = remember(%{state | clock: clock})

    {:ok, customer} =
      Stripe.Customer.create(%{
        email: user.email,
        test_clock: clock.id,
        metadata: %{"user_id" => user.id, "purpose" => "lifecycle-verify"}
      })

    {:ok, user} =
      user |> User.billing_changeset(%{stripe_customer_id: customer.id}) |> Repo.update()

    info("✓ test clock #{clock.id} + customer #{customer.id}")
    %{state | user: user}
  end

  defp step_trial(%{user: user} = state) do
    price = ensure_price!()
    previous = Application.get_env(:fountain, :stripe_price_id)
    Application.put_env(:fountain, :stripe_price_id, price)

    try do
      {:ok, user} = Billing.start_trial_subscription(user)

      check!("trialing after subscription create", user.subscription_status == "trialing")
      check!("trial_ends_at recorded from Stripe", match?(%DateTime{}, user.trial_ends_at))

      days = DateTime.diff(user.trial_ends_at, DateTime.utc_now(), :day)
      check!("trial is ~#{Billing.trial_days()} days (got #{days})", days in 13..14)
      check!("gate open on real trial", Billing.check_active(user.id) == :ok)

      %{state | user: Repo.reload!(user)}
    after
      Application.put_env(:fountain, :stripe_price_id, previous)
    end
  end

  defp step_trial_ending_warning(%{user: user, clock: clock} = state) do
    target = DateTime.to_unix(user.trial_ends_at) - 3 * 86_400 + 3600
    clock = advance!(clock, target)

    sub = fetch_subscription!(user)
    {:ok, _} = Billing.sync_subscription(event("customer.subscription.trial_will_end", sub))

    check!(
      "T-3d: trial-ending email enqueued",
      email_enqueued?("Fountain.Workers.TrialEndingEmail", user.id)
    )

    %{state | clock: clock}
  end

  defp step_trial_expiry(%{user: user, clock: clock} = state) do
    clock = advance!(clock, DateTime.to_unix(user.trial_ends_at) + 3600)

    # missing_payment_method: cancel — Stripe cancels the sub at trial end
    sub = poll_subscription_status!(user, "canceled")

    {:ok, user} = Billing.sync_subscription(event("customer.subscription.deleted", sub))

    check!("canceled after trial expiry", user.subscription_status == "canceled")

    check!(
      "gate refuses after expiry",
      Billing.check_active(user.id) == {:error, :subscription_required}
    )

    check!(
      "trial-expired email enqueued (#283)",
      lifecycle_email_enqueued?(user.id, "trial_expired")
    )

    %{state | user: user, clock: clock}
  end

  defp step_subscribe(%{user: user} = state) do
    user = complete_checkout_equivalent!(user)

    check!("active after checkout-equivalent subscribe", user.subscription_status == "active")
    check!("gate reopens when paid", Billing.check_active(user.id) == :ok)
    %{state | user: user}
  end

  defp step_cancel_at_period_end(%{user: user} = state) do
    sub = fetch_subscription!(user, :active)
    {:ok, sub} = Stripe.Subscription.update(sub.id, %{cancel_at_period_end: true})

    {:ok, user} = Billing.sync_subscription(event("customer.subscription.updated", sub))

    check!(
      "cancel-at-period-end: access retained (still active)",
      user.subscription_status == "active"
    )

    check!("gate still open until period end", Billing.check_active(user.id) == :ok)

    # #284: the flag and period end are synced so the UI can say "access
    # until <date>" instead of leaving a cancellation invisible.
    check!("cancel_at_period_end flag synced (#284)", user.cancel_at_period_end == true)

    check!(
      "current_period_end synced and matches Stripe (#284)",
      user.current_period_end != nil and
        DateTime.to_unix(user.current_period_end) == sub.current_period_end
    )

    %{state | user: user}
  end

  defp step_period_end(%{user: user, clock: clock} = state) do
    sub = fetch_subscription!(user, :active)
    clock = advance!(clock, sub.current_period_end + 3600)
    sub = poll_subscription_status!(user, "canceled")

    {:ok, user} = Billing.sync_subscription(event("customer.subscription.deleted", sub))

    check!("canceled at period end", user.subscription_status == "canceled")

    check!(
      "gate refuses after period end",
      Billing.check_active(user.id) == {:error, :subscription_required}
    )

    check!(
      "canceled-confirmation email enqueued (#283)",
      lifecycle_email_enqueued?(user.id, "subscription_canceled")
    )

    check!(
      "cancel_at_period_end cleared on .deleted (#284)",
      user.cancel_at_period_end == false
    )

    %{state | user: user, clock: clock}
  end

  defp step_resubscribe(%{user: user} = state) do
    user = complete_checkout_equivalent!(user)

    check!("return path: re-subscribe reactivates", user.subscription_status == "active")
    check!("gate open again", Billing.check_active(user.id) == :ok)
    %{state | user: user}
  end

  # Sync is keyed by subscription id (#284): a Checkout completion adopts the
  # new subscription of record, then the subscription event applies its
  # status — fed here in the same order Stripe sends them.
  defp complete_checkout_equivalent!(user) do
    sub = create_paid_subscription!(user)

    {:ok, _} =
      Billing.sync_subscription(
        event("checkout.session.completed", %{
          customer: user.stripe_customer_id,
          subscription: sub.id,
          client_reference_id: user.id
        })
      )

    {:ok, %Fountain.Accounts.User{} = user} =
      Billing.sync_subscription(event("customer.subscription.created", sub))

    user
  end

  # Real dunning: swap the default card for one that always fails, advance the
  # clock past renewal, and let Stripe's own retry machinery mark the
  # subscription past_due. Nothing here is simulated except event transport.
  defp step_dunning(%{user: user, clock: clock} = state) do
    {:ok, pm} =
      Stripe.PaymentMethod.attach("pm_card_chargeCustomerFail", %{
        customer: user.stripe_customer_id
      })

    {:ok, _} =
      Stripe.Customer.update(user.stripe_customer_id, %{
        invoice_settings: %{default_payment_method: pm.id}
      })

    sub = fetch_subscription!(user, :active)
    clock = advance!(clock, sub.current_period_end + 3600)
    sub = poll_subscription_status!(user, "past_due")

    {:ok, user} = Billing.sync_subscription(event("customer.subscription.updated", sub))

    check!("past_due after failed renewal", user.subscription_status == "past_due")

    check!(
      "gate refuses while past_due",
      Billing.check_active(user.id) == {:error, :subscription_required}
    )

    check!(
      "payment-failed dunning email enqueued (#283)",
      lifecycle_email_enqueued?(user.id, "payment_failed")
    )

    # The invoice-driven dunning signal (#447): feed the real failed invoice
    # through sync. LifecycleEmail's 24 h uniqueness collapses this with the
    # transition-driven enqueue above — one dunning cycle, one email.
    {:ok, %{data: [invoice | _]}} =
      Stripe.Invoice.list(%{subscription: sub.id, status: :open, limit: 1})

    {:ok, %Fountain.Accounts.User{}} =
      Billing.sync_subscription(event("invoice.payment_failed", invoice))

    check!(
      "invoice.payment_failed handled for the subscription of record (#447)",
      lifecycle_email_enqueued?(user.id, "payment_failed")
    )

    %{state | user: user, clock: clock}
  end

  # Real dunning recovery (#447): put a working card back, pay the open
  # invoice through Stripe, and feed the real paid invoice through sync —
  # past_due → active plus the payment_recovered email, all off invoice.paid
  # rather than the subscription event.
  defp step_dunning_recovery(%{user: user} = state) do
    {:ok, pm} = Stripe.PaymentMethod.attach("pm_card_visa", %{customer: user.stripe_customer_id})

    {:ok, _} =
      Stripe.Customer.update(user.stripe_customer_id, %{
        invoice_settings: %{default_payment_method: pm.id}
      })

    sub = fetch_subscription!(user, :past_due)

    {:ok, %{data: [invoice | _]}} =
      Stripe.Invoice.list(%{subscription: sub.id, status: :open, limit: 1})

    {:ok, paid} = Stripe.Invoice.pay(invoice.id, %{})

    {:ok, %Fountain.Accounts.User{} = user} =
      Billing.sync_subscription(event("invoice.paid", paid))

    check!(
      "invoice.paid recovers past_due → active (#447)",
      user.subscription_status == "active"
    )

    check!("gate open after recovery", Billing.check_active(user.id) == :ok)

    check!(
      "payment-recovered email enqueued (#447)",
      lifecycle_email_enqueued?(user.id, "payment_recovered")
    )

    %{state | user: user}
  end

  # ── Assertions ─────────────────────────────────────────────────────────────

  defp email_enqueued?(worker, user_id, extra \\ %{}) do
    import Ecto.Query

    args = Map.merge(%{"user_id" => user_id}, extra)

    Repo.exists?(
      from j in Oban.Job,
        where: j.worker == ^worker and fragment("? @> ?", j.args, ^args)
    )
  end

  defp lifecycle_email_enqueued?(user_id, kind) do
    email_enqueued?("Fountain.Workers.LifecycleEmail", user_id, %{"email" => kind})
  end

  # ── Stripe helpers ─────────────────────────────────────────────────────────

  # A synthetic event around a real fetched object — what the webhook
  # controller would hand to sync after signature verification. Fed to
  # `sync_subscription/1` directly (not `handle_event/1`), so the synthetic id
  # is never claimed into `stripe_events` and cannot pollute admin counts.
  defp event(type, object) do
    %Stripe.Event{
      id: "evt_lifecycle_verify_#{System.unique_integer([:positive])}",
      account: "",
      api_version: nil,
      created: System.system_time(:second),
      data: %{object: object},
      livemode: false,
      object: "event",
      pending_webhooks: 0,
      request: nil,
      type: type
    }
  end

  defp ensure_price! do
    case System.get_env("STRIPE_PRICE_ID") do
      id when is_binary(id) and id != "" ->
        id

      _ ->
        {:ok, product} = Stripe.Product.create(%{name: "lifecycle-verify (scratch)"})

        {:ok, price} =
          Stripe.Price.create(%{
            product: product.id,
            unit_amount: 2900,
            currency: "usd",
            recurring: %{interval: :month}
          })

        price.id
    end
  end

  defp create_paid_subscription!(user) do
    {:ok, pm} = Stripe.PaymentMethod.attach("pm_card_visa", %{customer: user.stripe_customer_id})

    {:ok, _} =
      Stripe.Customer.update(user.stripe_customer_id, %{
        invoice_settings: %{default_payment_method: pm.id}
      })

    {:ok, sub} =
      Stripe.Subscription.create(%{
        customer: user.stripe_customer_id,
        items: [%{price: ensure_price!()}]
      })

    sub
  end

  defp advance!(clock, unix_time) do
    {:ok, clock} = Stripe.TestHelpers.TestClock.advance(clock.id, %{frozen_time: unix_time})
    wait_ready!(clock, @clock_poll_attempts)
  end

  defp wait_ready!(%{status: "ready"} = clock, _attempts), do: clock

  defp wait_ready!(clock, 0), do: Mix.raise("test clock #{clock.id} never became ready")

  defp wait_ready!(clock, attempts) do
    Process.sleep(@clock_poll_ms)
    {:ok, clock} = Stripe.TestHelpers.TestClock.retrieve(clock.id)
    wait_ready!(clock, attempts - 1)
  end

  defp fetch_subscription!(user, status \\ :all) do
    {:ok, %{data: subs}} =
      Stripe.Subscription.list(%{customer: user.stripe_customer_id, status: status, limit: 10})

    case subs do
      [sub | _] -> sub
      [] -> Mix.raise("no subscription with status #{status} for #{user.stripe_customer_id}")
    end
  end

  defp poll_subscription_status!(user, want, attempts \\ 30)

  defp poll_subscription_status!(_user, want, 0),
    do: Mix.raise("subscription never reached status #{want}")

  defp poll_subscription_status!(user, want, attempts) do
    sub = fetch_subscription!(user)

    if sub.status == want do
      sub
    else
      Process.sleep(@clock_poll_ms)
      poll_subscription_status!(user, want, attempts - 1)
    end
  end

  # ── Bookkeeping ────────────────────────────────────────────────────────────

  # `try/after` cannot see rebound step state, so keep the latest for cleanup.
  defp remember(state) do
    Process.put(:lifecycle_verify_state, state)
    state
  end

  defp state_now, do: Process.get(:lifecycle_verify_state, %{user: nil, clock: nil})

  defp cleanup(%{user: user, clock: clock}) do
    if clock do
      case Stripe.TestHelpers.TestClock.delete(clock.id) do
        {:ok, _} -> info("✓ cleanup: test clock deleted (removes its Stripe objects)")
        {:error, err} -> info("! cleanup: could not delete clock #{clock.id}: #{inspect(err)}")
      end
    end

    if user do
      # The clock deletion tears down the Stripe side; detach the customer so
      # local deletion does not try to cancel an already-torn-down subscription.
      user = Repo.reload!(user)
      {:ok, user} = user |> Ecto.Changeset.change(stripe_customer_id: nil) |> Repo.update()

      case Fountain.Accounts.Deletion.delete_user(user, actor: "system:lifecycle-verify") do
        {:ok, _} -> info("✓ cleanup: scratch user deleted")
        {:error, err} -> info("! cleanup: scratch user #{user.id} not deleted: #{inspect(err)}")
      end
    end
  end

  defp check!(description, true), do: info("✓ #{description}")
  defp check!(description, other), do: Mix.raise("✗ #{description} — got: #{inspect(other)}")

  defp info(msg), do: Mix.shell().info(msg)
end
