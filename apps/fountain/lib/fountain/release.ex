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

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Mark an account's email verified, without sending anything.

  The escape hatch for an instance whose mail provider is misconfigured or
  broken — login is refused while `email_verified_at` is nil. Under
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
        case Fountain.Accounts.verify_email(user) do
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
        case Fountain.Accounts.update_user_role(user, "admin") do
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
  Gives existing trialing accounts a trial end date.

  159 production accounts are `trialing` with `trial_ends_at` set to nil, some
  since 2026-05-10, because a trial end was only ever recorded for users who got
  as far as Stripe customer creation. The gate treats nil as "no expiry", so
  those accounts stay active until this is run.

  That is deliberate. Cutting off people who have been using the product free
  for months is a business decision with a support cost, not something a deploy
  should do silently at 3am. Run it when you have decided.

  (Queried 2026-08-02: the cohort turned out to be one internal test account
  plus 158 signups that never verified their email and so have never been able
  to log in — nobody real loses access when this runs.)

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
        where: u.subscription_status == "trialing" and is_nil(u.trial_ends_at)

    count = Fountain.Repo.aggregate(query, :count)

    if dry_run? do
      IO.puts("#{count} trialing account(s) have no trial end.")
      IO.puts("Running without dry_run: would set trial_ends_at to #{ends_at} (#{days} days).")
      {:ok, count}
    else
      {updated, _} = Fountain.Repo.update_all(query, set: [trial_ends_at: ends_at])
      IO.puts("Set trial_ends_at to #{ends_at} on #{updated} account(s).")
      {:ok, updated}
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
