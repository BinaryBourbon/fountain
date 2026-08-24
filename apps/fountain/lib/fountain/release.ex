defmodule Fountain.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :fountain

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  The boot-time half of `migrate/0`: migrates unless `MIGRATE_ON_BOOT=false`.

  This is what the image's `CMD` runs, and the only migration path the switch
  gates. `migrate/0` itself — and `bin/migrate`, which is what a migrations
  Job runs — always migrates, because an explicit request to migrate should
  never be silently skipped by an environment variable meant for pods that
  only serve.

  Skipping is not a no-op boot: the release still starts, and if migrations
  have not in fact been run the app will fail on the first query against a
  missing column. That is the trade a deployment makes when it moves
  migrations into a Job — the Job is what must be ordered before the rollout.
  """
  def migrate_on_boot do
    load_app()

    if migrate_on_boot?() do
      migrate()
    else
      IO.puts("MIGRATE_ON_BOOT=false — skipping migrations at boot.")
      :skipped
    end
  end

  @doc """
  Whether this node should migrate as it boots.

  Read from application env (set by `config/runtime.exs` from
  `MIGRATE_ON_BOOT`) rather than from `System.get_env/1` directly, so the two
  boot paths that migrate — this task and the `Ecto.Migrator` child in
  `Fountain.Application` — decide from one value.
  """
  def migrate_on_boot? do
    Application.get_env(@app, :migrate_on_boot, true)
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Mark an account's email verified, without sending anything.

  The escape hatch for an instance whose mail provider is misconfigured or
  broken. While `email_verified_at` is nil the password still authenticates —
  login is *not* refused, which is the part worth knowing when someone reports
  "I can sign in but nothing works". The session is simply parked on
  `/auth/verify-pending` and reaches nothing else, and the API refuses both to
  mint a key and to accept one, with 403 `email_unverified` (#533). Under
  `EMAIL_DELIVERY=none` this is no longer part of first login: registration
  auto-verifies accounts there (ADR 0011). It remains for accounts created
  before mail broke, or before that mode was set.

  Verification runs the first-admin bootstrap like any other route: with
  `FIRST_USER_ADMIN=true` and no admin yet, the account comes back promoted.

      bin/fountain_server eval 'Fountain.Release.verify_email("you@example.com")'
  """
  def verify_email(email) when is_binary(email) do
    with_repo(fn -> do_verify_email(email) end)
  end

  defp do_verify_email(email) do
    case Fountain.Accounts.get_user_by_email(email) do
      nil ->
        IO.puts(:stderr, "No account found for #{email}")
        {:error, :not_found}

      user ->
        case Fountain.Accounts.verify_email(user, actor: "system:release_task") do
          {:ok, verified} ->
            IO.puts("Verified #{verified.email}. You can now sign in.")
            {:ok, verified}

          {:error, _} = err ->
            IO.puts(:stderr, "Could not verify #{email}")
            err
        end
    end
  end

  @doc """
  Grant an account the admin role, audit-recorded.

  The manual first-admin bootstrap. Both deploy guides used to end with raw
  SQL (`UPDATE users SET role = 'admin' ...`) — the only step in the
  self-deploy path that required editing the production database by hand.
  Since ADR 0011 the recommended path is `FIRST_USER_ADMIN=true`, which
  promotes the first verified account in-app; this task remains for instances
  that keep that switch off, and for lock-out recovery.

  Recorded as `admin.role.granted` with a nil actor (system-originated), so a
  promotion through this task is as visible in the admin audit trail as one
  through the admin panel. Revoking has no release task — that is done from
  the panel, by an admin, on purpose.

      bin/fountain_server eval 'Fountain.Release.promote_admin("you@example.com")'
  """
  def promote_admin(email) when is_binary(email) do
    with_repo(fn -> do_promote_admin(email) end)
  end

  defp do_promote_admin(email) do
    case Fountain.Accounts.get_user_by_email(email) do
      nil ->
        IO.puts(:stderr, "No account found for #{email}")
        {:error, :not_found}

      %{role: "admin"} = user ->
        IO.puts("#{user.email} is already an admin.")
        {:ok, user}

      user ->
        case Fountain.Accounts.update_user_role(user, "admin", actor: "system:release_task") do
          {:ok, promoted} ->
            Fountain.Audit.record_admin(%{
              actor_user_id: nil,
              target_user_id: promoted.id,
              event_type: "admin.role.granted",
              metadata: %{
                "email" => promoted.email,
                "from" => user.role,
                "to" => "admin",
                "via" => "release_task"
              }
            })

            IO.puts("Granted admin to #{promoted.email}.")
            {:ok, promoted}

          {:error, _} = err ->
            IO.puts(:stderr, "Could not grant admin to #{email}")
            err
        end
    end
  end

  @doc """
  Materialise `turns.reply_text` for every ended turn that has none (#826):
  the assistant's text of each, through the same parse the transcript uses,
  so `GET /api/search` covers replies from before the column existed. Turns
  ending after the migration are written as they end. Idempotent; prints a
  count. Runs beside the live server:

      PHX_SERVER=false METRICS_PORT=0 bin/fountain_server eval 'Fountain.Release.backfill_turn_replies()'
  """
  def backfill_turn_replies do
    load_app()

    for repo <- repos() do
      # ownership: a system-level sweep over every tenant's ended turns,
      # run by an operator beside the release — the same footing as migrate/0.
      {:ok, n, _} =
        Ecto.Migrator.with_repo(repo, fn _repo ->
          Fountain.Conversations._unsafe_backfill_reply_texts()
        end)

      IO.puts("backfilled reply_text on #{n} turn(s)")
    end
  end

  @doc """
  Gives accounts without a trial clock a status and a trial end date.

  Two cohorts land here, both of which the gate would otherwise handle badly
  after billing is (re-)enabled:

  - **Legacy trialing accounts** — `trialing` with `trial_ends_at` nil. 159
    production accounts were in this state, some since 2026-05-10, because a
    trial end was only ever recorded for users who got as far as Stripe
    customer creation. The gate treats nil as "no expiry" for pre-cutoff
    accounts, so they stay active until this is run.
  - **Accounts registered while billing was disabled** — `subscription_status`
    nil, no trial end (#480). Enabling billing on such an instance leaves them
    failing *closed* at the gate; this task is the documented way to start
    their trials.

  Not running it automatically is deliberate. Cutting off (or starting a paid
  clock for) people who have been using the product free is a business decision
  with a support cost, not something a deploy should do silently at 3am. Run it
  when you have decided.

  (Queried 2026-08-02: the legacy cohort turned out to be one internal test
  account plus 158 signups that never verified their email and so have never
  been able to log in — nobody real loses access when this runs.)

      # See who would be affected, change nothing:
      bin/fountain_server eval 'Fountain.Release.expire_legacy_trials(dry_run: true)'

      # Give them 14 days from now:
      bin/fountain_server eval 'Fountain.Release.expire_legacy_trials(days: 14)'

  `days:` is counted from now, not from signup. Backdating would expire everyone
  the instant it ran, which is the hostile version of this.
  """
  def expire_legacy_trials(opts \\ []) do
    with_repo(fn -> do_expire_legacy_trials(opts) end)
  end

  defp do_expire_legacy_trials(opts) do
    days = Keyword.get(opts, :days, 14)
    dry_run? = Keyword.get(opts, :dry_run, false)

    ends_at =
      DateTime.utc_now()
      |> DateTime.add(days * 24 * 60 * 60, :second)
      |> DateTime.truncate(:second)

    import Ecto.Query

    query =
      from u in Fountain.Accounts.User,
        where:
          (u.subscription_status == "trialing" and is_nil(u.trial_ends_at)) or
            is_nil(u.subscription_status)

    count = Fountain.Repo.aggregate(query, :count)

    if dry_run? do
      IO.puts("#{count} account(s) have no trial clock (trialing/nil or nil status).")
      IO.puts("Running without dry_run: would set trial_ends_at to #{ends_at} (#{days} days).")
      {:ok, count}
    else
      {updated, _} =
        Fountain.Repo.update_all(query,
          set: [subscription_status: "trialing", trial_ends_at: ends_at]
        )

      # One summary row, not one per account: a bulk backfill is a single
      # operator action. Without it the only trace of an operator moving every
      # account's billing clock was stdout on whichever shell ran it — and the
      # promote-admin task beside this one has recorded since it was written
      # (#551).
      Fountain.Audit.record(%{
        user_id: nil,
        action: "release.trials_backfilled",
        resource_type: "release_task",
        actor: "system:release_task",
        metadata: %{
          "accounts_updated" => updated,
          "trial_ends_at" => DateTime.to_iso8601(ends_at),
          "days" => days
        }
      })

      IO.puts("Set trial_ends_at to #{ends_at} on #{updated} account(s).")
      {:ok, updated}
    end
  end

  @doc """
  Backfills `users.current_period_start` from Stripe (#1016).

  The column arrived after every existing subscription had already been
  created, so until each account's next `customer.subscription.updated` event
  lands it has an end date and no start, and `Fountain.Billing.billing_period/2`
  reports a calendar month for it. That is correct behaviour, and it is also
  a month of every usage number being measured over a window that is not the
  one the customer is invoiced for. This closes the gap in one pass.

      # See who is missing a period start, call Stripe for none of them:
      bin/fountain_server eval 'Fountain.Release.backfill_billing_periods(dry_run: true)'

      # Do it:
      bin/fountain_server eval 'Fountain.Release.backfill_billing_periods()'

  Every account skipped means the run repaired nothing, which the task says
  out loud rather than reporting a clean pass.

  `eval`, not the `rpc` that `mix fountain.verify_plans` wants. Every task in
  this module goes through `with_repo/1`, and `Ecto.Migrator.with_repo`
  restarts the repo's pool child when it finds one already started — over
  `rpc` that would bounce the connection pool of a pod that is serving. The
  Stripe key this needs comes from `config/runtime.exs`, which a release
  `eval` does execute.

  One Stripe read per account, and only for accounts that have a subscription
  of record and no start recorded — so it is safe to re-run, and a second run
  after the first is a handful of queries and no API calls. Comped accounts
  are skipped: they have no invoiced period, which is the state the fallback
  exists for.

  Writes `current_period_start` and `current_period_end` only. Status, trial
  and plan are deliberately untouched — repairing those from Stripe is
  `Billing.resync_from_stripe/1`'s job, it participates in the webhook
  ordering guard, and a bulk backfill quietly flipping account statuses is
  exactly the kind of surprise a one-column migration helper should not have.
  """
  def backfill_billing_periods(opts \\ []) do
    with_repo(fn -> do_backfill_billing_periods(opts) end)
  end

  defp do_backfill_billing_periods(opts) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    import Ecto.Query

    query =
      from u in Fountain.Accounts.User,
        where: not is_nil(u.stripe_subscription_id) and u.stripe_subscription_id != "",
        where: is_nil(u.current_period_start),
        where: u.subscription_status != "comped",
        select: %{id: u.id, subscription_id: u.stripe_subscription_id}

    pending = Fountain.Repo.all(query)

    if dry_run? do
      IO.puts("#{length(pending)} subscribed account(s) have no current_period_start.")
      IO.puts("Running without dry_run: would read each one from Stripe and record its period.")
      {:ok, length(pending)}
    else
      {:ok, _} = Application.ensure_all_started(:stripity_stripe)
      tally = Enum.reduce(pending, %{updated: 0, skipped: 0}, &backfill_one/2)

      Fountain.Audit.record(%{
        user_id: nil,
        action: "release.billing_periods_backfilled",
        resource_type: "release_task",
        actor: "system:release_task",
        metadata: %{
          "accounts_considered" => length(pending),
          "accounts_updated" => tally.updated,
          "accounts_skipped" => tally.skipped
        }
      })

      IO.puts(
        "Recorded a billing period on #{tally.updated} account(s), #{tally.skipped} skipped."
      )

      # One skipped account is a deleted subscription. Every account skipped is
      # not a coincidence — it is an unset, revoked or wrong-mode
      # STRIPE_SECRET_KEY, or Stripe being unreachable — and without saying so
      # the task reports a successful run that repaired nothing. Checking the
      # outcome rather than the config catches all four.
      if tally.updated == 0 and tally.skipped > 0 do
        IO.warn(
          "every one of the #{tally.skipped} account(s) was skipped — check " <>
            "STRIPE_SECRET_KEY and the reasons above before assuming this ran"
        )
      end

      {:ok, tally.updated}
    end
  end

  # A subscription Stripe cannot hand back — deleted, or belonging to a key
  # this deployment no longer holds — is skipped rather than fatal. The point
  # of the pass is the accounts it can repair.
  defp backfill_one(%{id: user_id, subscription_id: subscription_id}, tally) do
    with {:ok, sub} <- Stripe.Subscription.retrieve(subscription_id),
         %DateTime{} = period_start <- unix_datetime(Map.get(sub, :current_period_start)) do
      user = Fountain.Repo.get!(Fountain.Accounts.User, user_id)

      user
      |> Fountain.Accounts.User.billing_changeset(%{
        current_period_start: period_start,
        current_period_end: unix_datetime(Map.get(sub, :current_period_end))
      })
      |> Fountain.Repo.update!()

      %{tally | updated: tally.updated + 1}
    else
      other ->
        IO.puts("  skipped #{user_id} (#{subscription_id}): #{inspect(other)}")
        %{tally | skipped: tally.skipped + 1}
    end
  end

  defp unix_datetime(ts) when is_integer(ts),
    do: ts |> DateTime.from_unix!() |> DateTime.truncate(:second)

  defp unix_datetime(_), do: nil

  @doc """
  Give every tenant their opening credit the day credits go live (ADR 0030,
  #1086 phase 5): the current period's tier grant, pro-rated to the part of
  the period after `CREDIT_PRICING_SINCE`, for every active subscriber, and
  the trial's opening grant for every live trial. Nobody starts at zero.

  Idempotent: each grant is keyed on the tenant and period, so a rerun writes
  nothing new, and the daily `CreditGranter` would have done the same within
  a day. Refuses to run while `CREDIT_PRICING_SINCE` is unset, because the
  pro-rating needs it and a grant with no floor would hand out a full month
  already spent unmetered.

      bin/fountain_server eval 'Fountain.Release.start_credits(dry_run: true)'
      bin/fountain_server eval 'Fountain.Release.start_credits()'
  """
  def start_credits(opts \\ []) do
    with_repo(fn -> do_start_credits(opts) end)
  end

  defp do_start_credits(opts) do
    import Ecto.Query
    dry_run? = Keyword.get(opts, :dry_run, false)
    since = Keyword.get(opts, :since) || Fountain.Workers.CreditPricer.pricing_since()
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    cond do
      not Fountain.Billing.enabled?() ->
        IO.puts("Billing is off on this instance; credits do not apply. Nothing to do.")
        {:ok, 0}

      is_nil(since) ->
        IO.warn("CREDIT_PRICING_SINCE is unset. Set it to the deploy time, then rerun.")
        {:error, :pricing_since_unset}

      true ->
        subscribers =
          Fountain.Repo.all(
            from u in Fountain.Accounts.User,
              where: u.subscription_status == "active",
              where: not is_nil(u.current_period_start) and not is_nil(u.current_period_end),
              where: u.current_period_start <= ^now and u.current_period_end > ^now
          )

        trials =
          Fountain.Repo.all(
            from u in Fountain.Accounts.User,
              where: u.subscription_status == "trialing",
              where: not is_nil(u.trial_ends_at) and u.trial_ends_at > ^now
          )

        if dry_run? do
          IO.puts(
            "#{length(subscribers)} active subscriber(s) inside a billing period and " <>
              "#{length(trials)} live trial(s) would be granted, pro-rated from #{DateTime.to_iso8601(since)}."
          )

          {:ok, length(subscribers) + length(trials)}
        else
          granted =
            (subscribers ++ trials)
            |> Enum.map(
              &Fountain.Workers.CreditGranter.grant_for_user(&1, since: since, now: now)
            )
            |> Enum.sum()

          Fountain.Audit.record(%{
            user_id: nil,
            action: "release.credits_started",
            resource_type: "release_task",
            actor: "system:release_task",
            metadata: %{
              "subscribers" => length(subscribers),
              "trials" => length(trials),
              "granted" => granted,
              "since" => DateTime.to_iso8601(since)
            }
          })

          IO.puts(
            "Granted #{granted} opening credit(s) across #{length(subscribers)} subscriber(s) " <>
              "and #{length(trials)} trial(s). Reruns write nothing."
          )

          {:ok, granted}
        end
    end
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  # Starts only the repo (and its deps), never the app. Booting the whole app
  # from an eval task cannot work in production: the running server already
  # holds the HTTP and metrics ports, and a task node that started Oban and
  # the Horde registry would compete with the real cluster for jobs and
  # conversation processes.
  defp with_repo(fun) do
    load_app()
    {:ok, result, _started} = Ecto.Migrator.with_repo(Fountain.Repo, fn _repo -> fun.() end)
    result
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
