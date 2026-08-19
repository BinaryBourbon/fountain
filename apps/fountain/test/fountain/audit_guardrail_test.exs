defmodule Fountain.AuditGuardrailTest do
  @moduledoc """
  The rule this campaign established, enforced (#552).

  #540 found auditing scattered across callers: a blanket plug on the `:api`
  pipeline, a handful of LiveViews that remembered, and seven contexts with no
  audit calls at all. Every fix in that campaign moved the recording **into the
  context function**, so a mutation is audited whichever door it came through.

  That property is invisible to the compiler. Without a test, the next context
  function to be added joins the gap list silently — which is exactly how the
  original gap grew. This file is the guard; ADR 0013 is the decision it
  guards.

  ## Adding a mutation

  If you add a context function that changes tenant-owned state, add it to
  `@must_audit` with a call that exercises it. If it genuinely should not audit
  (high-volume machine state — see the `Fountain.Audit` moduledoc), add it to
  `@deliberately_silent` with the reason, so the exclusion is a decision on the
  record rather than an omission.
  """

  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Agents, Audit, Buzz, Conversations, Environments, InferenceCredentials, Vaults}

  # {label, fun/1 taking the user, expected action}
  #
  # Each entry performs the mutation and names the event it must leave. The
  # point is coverage of the *rule*, not of each function's behaviour — the
  # per-child test files cover metadata, actors and redaction in depth.
  @must_audit [
    {"agent create", &__MODULE__.do_agent_create/1, "agent.created"},
    {"agent update", &__MODULE__.do_agent_update/1, "agent.updated"},
    {"agent delete", &__MODULE__.do_agent_delete/1, "agent.deleted"},
    {"environment create", &__MODULE__.do_env_create/1, "environment.created"},
    {"environment update", &__MODULE__.do_env_update/1, "environment.updated"},
    {"environment delete", &__MODULE__.do_env_delete/1, "environment.deleted"},
    {"vault create", &__MODULE__.do_vault_create/1, "vault.created"},
    {"vault update", &__MODULE__.do_vault_update/1, "vault.updated"},
    {"vault delete", &__MODULE__.do_vault_delete/1, "vault.deleted"},
    {"api key mint", &__MODULE__.do_key_create/1, "api_key.created"},
    {"api key revoke", &__MODULE__.do_key_revoke/1, "api_key.revoked"},
    {"inference credential write", &__MODULE__.do_cred_write/1, "inference_credential.write"},
    {"inference credential clear", &__MODULE__.do_cred_clear/1, "inference_credential.delete"},
    {"conversation delete", &__MODULE__.do_conv_delete/1, "conversation.deleted"},
    {"role change", &__MODULE__.do_role_change/1, "account.role_changed"},
    {"sandbox limit change", &__MODULE__.do_limit_change/1, "account.sandbox_limit_changed"},
    {"suspend", &__MODULE__.do_suspend/1, "account.suspended"},
    {"unsuspend", &__MODULE__.do_unsuspend/1, "account.unsuspended"},
    # Secrets and credentials (#593). These had five and four call sites
    # respectively before the recording moved into the context; the entries
    # below are what stops a sixth from being silent.
    {"environment secret write", &__MODULE__.do_env_secret_write/1, "environment.secret.write"},
    {"environment secret delete", &__MODULE__.do_env_secret_delete/1,
     "environment.secret.delete"},
    {"vault secret write", &__MODULE__.do_vault_secret_write/1, "vault.secret.write"},
    {"vault secret delete", &__MODULE__.do_vault_secret_delete/1, "vault.secret.delete"},
    {"password reset", &__MODULE__.do_password_reset/1, "auth.password.reset"},
    {"password change", &__MODULE__.do_password_change/1, "auth.password.changed"},
    {"email verification", &__MODULE__.do_verify_email/1, "auth.email.verified"},
    {"buzz identity create", &__MODULE__.do_buzz_create/1, "buzz_identity.created"},
    {"buzz identity update", &__MODULE__.do_buzz_update/1, "buzz_identity.updated"},
    {"buzz identity delete", &__MODULE__.do_buzz_delete/1, "buzz_identity.deleted"},
    # Team membership: a teammate is a channel-bound conversation, so add also
    # leaves conversation.created underneath; these are the team-side events.
    {"team member add", &__MODULE__.do_team_add/1, "team.member.added"},
    {"team member remove", &__MODULE__.do_team_remove/1, "team.member.removed"},
    {"team member rename", &__MODULE__.do_team_rename/1, "team.renamed"},
    # Team schedules: a cron that runs a teammate with a prompt. A run leaves
    # conversation events underneath; `.fired` is the schedule-side record.
    {"team schedule create", &__MODULE__.do_schedule_create/1, "team.schedule.created"},
    {"team schedule update", &__MODULE__.do_schedule_update/1, "team.schedule.updated"},
    {"team schedule delete", &__MODULE__.do_schedule_delete/1, "team.schedule.deleted"},
    {"team schedule run", &__MODULE__.do_schedule_run/1, "team.schedule.fired"},
    {"runner register", &__MODULE__.do_runner_register/1, "runner.registered"},
    {"runner delete", &__MODULE__.do_runner_delete/1, "runner.deleted"}
  ]

  # Documented non-coverage. Mirrors the `Fountain.Audit` moduledoc; if the two
  # ever disagree, the moduledoc is the one to trust and this list is stale.
  @deliberately_silent %{
    "ConversationServer per-turn state" => "high-volume machine state; log_events covers it",
    "Accounts.touch_api_key/1" => "a last-used stamp on every authenticated request",
    "Runners.touch/1 and reconnects" =>
      "a last-seen stamp on every heartbeat; a reconnect refreshes the same row",
    "Conversations.mark_read/2" => "reading is not a state change anyone audits",
    "theme and display preferences" => "not tenant data anyone reconstructs an incident from"
  }

  for {label, fun, action} <- @must_audit do
    test "#{label} leaves an audit event" do
      user = insert_verified_user()

      unquote(fun).(user)

      actions =
        user.id
        |> Audit.list_recent_for_user(200)
        |> Enum.map(& &1.action)

      assert unquote(action) in actions, """
      #{unquote(label)} produced no #{unquote(action)} event.

      Mutations audit in the context, not the caller (#540). If this function
      genuinely should not audit, move it to @deliberately_silent with a reason
      and update the Fountain.Audit moduledoc — do not delete the assertion.

      Events seen: #{inspect(actions)}
      """
    end
  end

  test "the exclusion list is documented, not empty" do
    # Guard the guard: an empty list would mean the exclusions had been quietly
    # dropped, and the moduledoc claim would be stale.
    assert map_size(@deliberately_silent) > 0

    for {what, reason} <- @deliberately_silent do
      assert is_binary(reason) and byte_size(reason) > 10,
             "#{what} is excluded from auditing with no stated reason"
    end
  end

  test "every audited context function takes an attribution opts list" do
    # The other half of the rule: a context that audits but cannot be told who
    # the caller was records everything as "self", which is worse than useless
    # on an admin-driven or system-driven path.
    for {mod, fun, arity} <- [
          {Agents, :create_agent, 2},
          {Agents, :update_agent, 3},
          {Agents, :delete_agent, 2},
          {Environments, :create_environment, 2},
          {Environments, :update_environment, 3},
          {Environments, :delete_environment, 2},
          {Vaults, :create_vault, 2},
          {Vaults, :update_vault, 3},
          {Vaults, :delete_vault, 2},
          {InferenceCredentials, :put_credential, 5},
          {Conversations, :start_conversation, 2},
          {Conversations, :delete_conversation, 2}
        ] do
      # `Code.ensure_loaded?/1` first: `function_exported?/3` answers about
      # *loaded* modules, so on a seed where this test ran before anything had
      # referenced the context it reported a perfectly present function as
      # missing.
      assert Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity),
             "#{inspect(mod)}.#{fun}/#{arity} is missing — an audited context " <>
               "function must accept an opts list carrying :actor and :request_ip"
    end
  end

  ## ── the mutations ─────────────────────────────────────────────────────────

  def do_agent_create(user),
    do: {:ok, _} = Agents.create_agent(agent_attrs(%{"user_id" => user.id}))

  def do_agent_update(user) do
    agent = insert_agent(user_id: user.id)
    {:ok, _} = Agents.update_agent(agent, %{"model" => "anthropic/claude-opus-4-5"})
  end

  def do_agent_delete(user) do
    {:ok, _} = Agents.delete_agent(insert_agent(user_id: user.id))
  end

  def do_env_create(user),
    do: {:ok, _} = Environments.create_environment(env_attrs(%{"user_id" => user.id}))

  def do_env_update(user) do
    {:ok, _} =
      Environments.update_environment(insert_env(user_id: user.id), %{"setup_script" => "x"})
  end

  def do_env_delete(user) do
    {:ok, _} = Environments.delete_environment(insert_env(user_id: user.id))
  end

  def do_vault_create(user),
    do: {:ok, _} = Vaults.create_vault(vault_attrs(%{"user_id" => user.id}))

  def do_vault_update(user) do
    {:ok, _} = Vaults.update_vault(insert_vault(user_id: user.id), %{"description" => "x"})
  end

  def do_vault_delete(user) do
    {:ok, _} = Vaults.delete_vault(insert_vault(user_id: user.id))
  end

  def do_buzz_create(user), do: {:ok, _} = Buzz.create_identity(buzz_attrs(user))

  def do_buzz_update(user) do
    {:ok, i} = Buzz.create_identity(buzz_attrs(user))
    {:ok, _} = Buzz.update_identity(i, %{"display_name" => "x"})
  end

  def do_buzz_delete(user) do
    {:ok, i} = Buzz.create_identity(buzz_attrs(user))
    {:ok, _} = Buzz.delete_identity(i)
  end

  defp buzz_attrs(user) do
    %{
      "user_id" => user.id,
      "agent_id" => insert_agent(user_id: user.id).id,
      "vault_id" => insert_vault(user_id: user.id).id,
      "name" => "buzz-#{System.unique_integer([:positive])}",
      "relay_url" => "wss://relay.test"
    }
  end

  def do_runner_register(user) do
    {:ok, _} = Fountain.Runners.register(user.id, %{"name" => "guard"})
  end

  def do_runner_delete(user) do
    {:ok, runner} = Fountain.Runners.register(user.id, %{"name" => "guard-delete"})
    {:ok, _} = Fountain.Runners.delete_runner(runner)
  end

  def do_key_create(user), do: {:ok, {_, _}} = Fountain.Accounts.create_api_key(user.id, "guard")

  def do_key_revoke(user) do
    {:ok, {key, _}} = Fountain.Accounts.create_api_key(user.id, "guard-revoke")
    {:ok, _} = Fountain.Accounts.revoke_api_key(user.id, key.id)
  end

  def do_cred_write(user) do
    {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
    {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-guard")
  end

  def do_cred_clear(user) do
    {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
    {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, nil)
  end

  def do_conv_delete(user) do
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, agent: agent, sandbox_id: sandbox.id)
    {:ok, _} = Conversations.delete_conversation(conv)
  end

  def do_team_add(user) do
    agent = insert_agent(user_id: user.id)

    stub(Horde.DynamicSupervisor, :start_child, fn _sup, _spec ->
      {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end)

    {:ok, _} = Fountain.Team.add_teammate(user.id, agent.id)
  end

  def do_team_rename(user) do
    agent = insert_agent(user_id: user.id)

    insert_conversation(
      user_id: user.id,
      agent: agent,
      status: "idle",
      channel_id: Fountain.Team.channel()
    )

    {:ok, _} = Fountain.Team.rename_teammate(user.id, agent.id, "Renamed")
  end

  def do_team_remove(user) do
    agent = insert_agent(user_id: user.id)

    insert_conversation(
      user_id: user.id,
      agent: agent,
      status: "idle",
      channel_id: Fountain.Team.channel()
    )

    :ok = Fountain.Team.remove_teammate(user.id, agent.id)
  end

  defp insert_schedule(user) do
    agent = insert_agent(user_id: user.id)

    {:ok, s} =
      Fountain.Team.Schedules.create_schedule(user.id, %{
        "agent_id" => agent.id,
        "cron" => "0 9 * * *",
        "prompt" => "hello"
      })

    s
  end

  def do_schedule_create(user), do: insert_schedule(user)

  def do_schedule_update(user),
    do:
      {:ok, _} =
        Fountain.Team.Schedules.update_schedule(insert_schedule(user), %{"cron" => "@hourly"})

  def do_schedule_delete(user),
    do: {:ok, _} = Fountain.Team.Schedules.delete_schedule(insert_schedule(user))

  def do_schedule_run(user) do
    # Off the team, so the in-thread run fails fast — the firing is what
    # must be recorded, however it went.
    {:error, :not_found} = Fountain.Team.Schedules.run_schedule(insert_schedule(user))
  end

  def do_role_change(user), do: {:ok, _} = Fountain.Accounts.update_user_role(user, "admin")

  def do_limit_change(user), do: {:ok, _} = Fountain.Accounts.update_sandbox_limit(user, 9)

  def do_suspend(user), do: {:ok, _, _} = Fountain.Accounts.suspend_user(user)

  def do_unsuspend(user) do
    {:ok, suspended, _} = Fountain.Accounts.suspend_user(user)
    {:ok, _} = Fountain.Accounts.unsuspend_user(suspended)
  end

  defp dek!(user_id) do
    {:ok, dek} = Fountain.Crypto.load_tenant_key(user_id)
    dek
  end

  def do_env_secret_write(user) do
    env = insert_env(user_id: user.id)
    {:ok, _} = Environments.upsert_secret(env, %{"key" => "K", "value" => "v"}, dek!(user.id))
  end

  def do_env_secret_delete(user) do
    env = insert_env(user_id: user.id)
    secret = insert_secret(env, %{"key" => "GONE"})
    {:ok, _} = Environments.delete_secret(env, secret)
  end

  def do_vault_secret_write(user) do
    vault = insert_vault(user_id: user.id)
    {:ok, _} = Vaults.upsert_secret(vault, %{"key" => "K", "value" => "v"}, dek!(user.id))
  end

  def do_vault_secret_delete(user) do
    vault = insert_vault(user_id: user.id)
    secret = insert_vault_secret(vault, %{"key" => "GONE"})
    {:ok, _} = Vaults.delete_secret(vault, secret)
  end

  def do_password_reset(user), do: {:ok, _} = Fountain.Accounts.reset_password(user, "newpass123")

  def do_password_change(user) do
    {:ok, _} = Fountain.Accounts.change_password(user, "password123", "newpass123")
  end

  def do_verify_email(user), do: {:ok, _} = Fountain.Accounts.verify_email(user)
end
