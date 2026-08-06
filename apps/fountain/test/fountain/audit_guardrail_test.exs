defmodule Fountain.AuditGuardrailTest do
  @moduledoc """
  The rule this campaign established, enforced (#552).

  #540 found auditing scattered across callers: a blanket plug on the `:api`
  pipeline, a handful of LiveViews that remembered, and seven contexts with no
  audit calls at all. Every fix in that campaign moved the recording **into the
  context function**, so a mutation is audited whichever door it came through.

  That property is invisible to the compiler. Without a test, the next context
  function to be added joins the gap list silently — which is exactly how the
  original gap grew. This file is the guard.

  ## Adding a mutation

  If you add a context function that changes tenant-owned state, add it to
  `@must_audit` with a call that exercises it. If it genuinely should not audit
  (high-volume machine state — see the `Fountain.Audit` moduledoc), add it to
  `@deliberately_silent` with the reason, so the exclusion is a decision on the
  record rather than an omission.
  """

  use Fountain.DataCase, async: true

  alias Fountain.{Agents, Audit, Conversations, Environments, InferenceCredentials, Vaults}

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
    {"unsuspend", &__MODULE__.do_unsuspend/1, "account.unsuspended"}
  ]

  # Documented non-coverage. Mirrors the `Fountain.Audit` moduledoc; if the two
  # ever disagree, the moduledoc is the one to trust and this list is stale.
  @deliberately_silent %{
    "ConversationServer per-turn state" => "high-volume machine state; log_events covers it",
    "Accounts.touch_api_key/1" => "a last-used stamp on every authenticated request",
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
      assert function_exported?(mod, fun, arity),
             "#{inspect(mod)}.#{fun}/#{arity} is missing — an audited context " <>
               "function must accept an opts list carrying :actor and :request_ip"
    end
  end

  ## ── the mutations ─────────────────────────────────────────────────────────

  def do_agent_create(user), do: {:ok, _} = Agents.create_agent(agent_attrs(%{"user_id" => user.id}))

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
    {:ok, _} = Environments.update_environment(insert_env(user_id: user.id), %{"setup_script" => "x"})
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

  def do_role_change(user), do: {:ok, _} = Fountain.Accounts.update_user_role(user, "admin")

  def do_limit_change(user), do: {:ok, _} = Fountain.Accounts.update_sandbox_limit(user, 9)

  def do_suspend(user), do: {:ok, _, _} = Fountain.Accounts.suspend_user(user)

  def do_unsuspend(user) do
    {:ok, suspended, _} = Fountain.Accounts.suspend_user(user)
    {:ok, _} = Fountain.Accounts.unsuspend_user(suspended)
  end
end
