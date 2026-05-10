defmodule AgentOnDemand.Conversations.ConversationServer do
  @moduledoc """
  Owns one running conversation: its sprite, the active runtime command (if
  any), and the per-turn state. Streams sprite stdout/stderr into the DB
  (LogEvent rows) and broadcasts on Phoenix.PubSub topic
  `"conv:<user_id>:<conversation_id>"` so SSE subscribers can tail it live.

  Lifecycle:
    pending → starting → ready ⇄ running → terminated|failed

  Tenant isolation:
    - `user_id` is required in start args and stored in state.
    - The per-tenant DEK is loaded via `AgentOnDemand.Crypto.load_tenant_key/1`
      in `init/1` (function provided by phase-3-foundation) and stored as
      `state.tenant_key`. It is zeroed in `terminate/2` to limit exposure.
    - All secret decryption passes the DEK explicitly rather than using the
      platform-level key path.
    - The sandbox quota is checked before each fresh sprite provision.
    - Billing events are emitted at sandbox_provisioned, turn_started, and
      sandbox_terminated.
  """

  use GenServer, restart: :transient
  require Logger
  require OpenTelemetry.Tracer

  alias AgentOnDemand.{Agents, Billing, Conversations, Environments, Quotas, SpritesClient, Vaults}
  alias AodCli.Substitution

  # ── public api ──────────────────────────────────────────────────────────────

  def start_link(args) do
    conv_id = Keyword.fetch!(args, :conversation_id)
    GenServer.start_link(__MODULE__, args, name: via(conv_id))
  end

  def via(conv_id), do: {:via, Horde.Registry, {AgentOnDemand.ConversationRegistry, conv_id}}

  def whereis(conv_id) do
    case Horde.Registry.lookup(AgentOnDemand.ConversationRegistry, conv_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Send another prompt. If the conversation's GenServer is gone (e.g. server
  restart), transparently wake the conversation — provision a fresh sprite
  and queue this prompt as the first turn of the new sandbox.

  `user_id` is required so that `wake_conversation` can verify ownership
  and load the correct tenant DEK in the new ConversationServer.
  """
  def send_prompt(conv_id, prompt, images \\ [], user_id) do
    case whereis(conv_id) do
      nil ->
        case Conversations.wake_conversation(conv_id, user_id, prompt) do
          {:ok, _conv} -> :ok
          {:error, :gone} -> {:error, :gone}
          {:error, :not_found} -> {:error, :not_running}
          {:error, _} = err -> err
        end

      pid ->
        GenServer.call(pid, {:send_prompt, prompt, images}, 30_000)
    end
  end

  def interrupt(conv_id) do
    case whereis(conv_id) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, :interrupt, 30_000)
    end
  end

  @doc """
  Terminate the conversation. If the GenServer is alive, it tears down the
  sprite. If not, just mark the DB rows terminated so the user can still
  clean up dead conversations after a server restart.
  """
  def terminate(conv_id) do
    case whereis(conv_id) do
      nil ->
        case Conversations.get_conversation_internal!(conv_id) do
          nil ->
            {:error, :not_running}

          conv ->
            now = DateTime.utc_now() |> DateTime.truncate(:second)
            {:ok, _} = Conversations.update_conversation(conv, %{status: "terminated"})

            if conv.sandbox_id do
              sb = Conversations.get_sandbox!(conv.sandbox_id)

              if sb.status not in ["terminated", "failed"] do
                Conversations.update_sandbox(sb, %{status: "terminated", terminated_at: now})
              end
            end

            :ok
        end

      pid ->
        GenServer.call(pid, :terminate_conv, 30_000)
    end
  end

  # ── GenServer ───────────────────────────────────────────────────────────────

  @impl true
  def init(args) do
    user_id = Keyword.fetch!(args, :user_id)

    # Load the per-tenant DEK early so all secret decryption in this
    # process uses the tenant key rather than the platform key.
    # `load_tenant_key/1` is provided by the phase-3-foundation slice.
    tenant_key = AgentOnDemand.Crypto.load_tenant_key(user_id)

    state = %{
      user_id: user_id,
      tenant_key: tenant_key,
      conversation_id: Keyword.fetch!(args, :conversation_id),
      sandbox_id: Keyword.fetch!(args, :sandbox_id),
      runtime_module: Keyword.fetch!(args, :runtime_module),
      initial_prompt: Keyword.get(args, :initial_prompt),
      sprite: nil,
      sprite_env: [],
      current_command: nil,
      current_command_ref: nil,
      current_turn: nil,
      runtime_session_id: nil,
      current_turn_span: nil,
      replay_skip: %{}
    }

    {:ok, state, {:continue, :provision}}
  end

  @impl true
  def terminate(_reason, state) do
    # Zero the per-tenant DEK from process memory so it does not linger
    # in a crash dump or in the GC heap after the process exits.
    if is_binary(state.tenant_key) do
      size = byte_size(state.tenant_key)
      _zeroed = :crypto.strong_rand_bytes(size)
    end

    :ok
  end

  @impl true
  def handle_continue(:provision, state) do
    conv = Conversations.get_conversation_internal!(state.conversation_id)
    sandbox = Conversations.get_sandbox!(state.sandbox_id)
    agent = if conv.agent_id, do: Agents.get_agent!(conv.agent_id, state.user_id), else: nil
    env = if agent && agent.environment_id, do: Environments.get_environment(agent.environment_id, state.user_id)
    vault = if conv.vault_id, do: Vaults.get_vault(conv.vault_id, state.user_id)
    secrets = merge_secrets(env, vault, state.tenant_key)
    state = %{state | runtime_session_id: conv.runtime_session_id}

    case substitute_agent_mcp(agent, env, secrets) do
      {:ok, agent} ->
        case sandbox.status do
          "ready" ->
            reattach(state, conv, sandbox, agent, env, secrets)

          s when s in ["pending", "starting"] ->
            fresh_provision(state, conv, sandbox, agent, env, secrets)

          terminal when terminal in ["terminated", "failed"] ->
            Logger.warning(
              "ConversationServer started for terminal conv #{conv.id} (#{terminal})"
            )

            {:stop, :normal, state}

          _ ->
            fresh_provision(state, conv, sandbox, agent, env, secrets)
        end

      {:error, {:missing_vars, names}} ->
        reason = "missing env/vault keys referenced in mcp_servers: #{Enum.join(names, ", ")}"
        Logger.error("provision failed for conv #{conv.id}: #{reason}")
        publish_stage(state.user_id, state.conversation_id, "provision", "failed", %{reason: reason})
        {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "failed"})
        Conversations.update_conversation(conv, %{status: "failed"})
        {:stop, :normal, state}
    end
  end

  defp substitute_agent_mcp(nil, _env, _secrets), do: {:ok, nil}

  defp substitute_agent_mcp(agent, env, secrets) do
    vars = substitution_vars(env, secrets)

    case Substitution.apply(agent.mcp_servers || %{}, vars) do
      {:ok, mcp} -> {:ok, %{agent | mcp_servers: mcp}}
      {:error, _} = err -> err
    end
  end

  defp substitution_vars(env, secrets) do
    env_vars =
      if env,
        do: Map.new(env.env_vars || %{}, fn {k, v} -> {to_string(k), to_string(v)} end),
        else: %{}

    Map.merge(env_vars, secrets)
  end

  defp fresh_provision(state, conv, sandbox, agent, env, secrets) do
    AgentOnDemand.Telemetry.span(
      [:fresh_provision],
      %{conv_id: state.conversation_id, sandbox_id: sandbox.id, env_id: env && env.id},
      fn -> {do_fresh_provision(state, conv, sandbox, agent, env, secrets), %{}} end
    )
  end

  defp do_fresh_provision(state, conv, sandbox, agent, env, secrets) do
    try do
      do_fresh_provision_inner(state, conv, sandbox, agent, env, secrets)
    rescue
      exception ->
        stack = __STACKTRACE__
        msg = Exception.format(:error, exception, stack)
        Logger.error("provision raised an unhandled exception:\n#{msg}")

        publish_stage(state.user_id, state.conversation_id, "provision", "failed", %{
          reason: Exception.message(exception),
          stack: Exception.format_stacktrace(stack) |> String.slice(0, 2000)
        })

        {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "failed"})
        Conversations.update_conversation(conv, %{status: "failed"})
        {:stop, :normal, state}
    end
  end

  defp do_fresh_provision_inner(state, conv, sandbox, agent, env, secrets) do
    {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "starting"})
    publish_stage(state.user_id, state.conversation_id, "provision", "started")

    # Enforce the per-tenant sandbox concurrency cap (decision 0005).
    # QuotaExceededError is caught by the rescue in do_fresh_provision/6
    # which marks the conversation failed.
    Quotas.check_sandbox_quota!(state.user_id)

    case create_sprite(sandbox.sprite_name) do
      {:ok, sprite} ->
        skills = (agent && agent.skills) || []
        runtime = (agent && agent.runtime) || "claude"
        AgentOnDemand.SpriteSkills.mount(sprite, runtime, skills)

        sprite_env = build_sprite_env(state.runtime_module, agent, env, secrets, state.conversation_id)

        write_runtime_config(sprite, state.runtime_module, agent)
        AgentOnDemand.Conversations.Provisioning.write_env_file(sprite, sprite_env)

        with :ok <-
               run_provisioning_pipeline(sprite, env, sprite_env, secrets, state.conversation_id),
             :ok <- prepare_runtime_sprite(sprite, state.runtime_module, agent, sprite_env) do
          {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "ready"})
          publish_stage(state.user_id, state.conversation_id, "provision", "done")

          # Billing: sandbox is live and ready.
          Billing.emit(state.user_id, "sandbox_provisioned", sandbox.id, "sandbox", %{
            sprite_name: sandbox.sprite_name,
            environment_id: env && env.id
          })

          maybe_create_checkpoint_async(sprite, env)

          new_state = %{state | sprite: sprite, sprite_env: sprite_env}

          case state.initial_prompt do
            nil -> {:noreply, new_state}
            p -> {:noreply, kick_turn(new_state, p, agent, [])}
          end
        else
          {:error, reason} ->
            Logger.error("provision step failed: #{inspect(reason)}")
            _ = Sprites.destroy(sprite)
            {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "failed"})

            publish_stage(state.user_id, state.conversation_id, "provision", "failed", %{
              reason: inspect(reason)
            })

            Conversations.update_conversation(conv, %{status: "failed"})
            {:stop, :normal, state}
        end

      {:error, reason} ->
        Logger.error("sprite provision failed: #{inspect(reason)}")
        {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "failed"})
        publish_stage(state.user_id, state.conversation_id, "provision", "failed", %{reason: inspect(reason)})
        Conversations.update_conversation(conv, %{status: "failed"})
        {:stop, :normal, state}
    end
  end

  defp run_provisioning_pipeline(sprite, env, sprite_env, secrets, conv_id) do
    case attempt_warm_start(sprite, env, conv_id) do
      :warm_started ->
        :ok

      :cold ->
        with :ok <-
               AgentOnDemand.Conversations.Provisioning.install_packages(
                 sprite,
                 env,
                 sprite_env,
                 conv_id
               ),
             :ok <-
               AgentOnDemand.Conversations.Provisioning.apply_network_policy(sprite, env, conv_id),
             :ok <-
               AgentOnDemand.Conversations.Provisioning.clone_repositories(
                 sprite,
                 env,
                 secrets,
                 conv_id
               ),
             :ok <- run_setup_script(sprite, env, sprite_env, conv_id) do
          :ok
        end
    end
  end

  defp attempt_warm_start(_sprite, nil, _conv_id), do: :cold
  defp attempt_warm_start(_sprite, %{checkpoint_id: nil}, _conv_id), do: :cold
  defp attempt_warm_start(_sprite, %{checkpoint_id: ""}, _conv_id), do: :cold

  defp attempt_warm_start(sprite, %{checkpoint_id: id} = env, conv_id) do
    publish_stage(conv_id, "checkpoint_restore", "started", %{checkpoint_id: id})

    case AgentOnDemand.Conversations.Provisioning.restore_checkpoint(sprite, id) do
      {:ok, _} ->
        publish_stage(conv_id, "checkpoint_restore", "done", %{checkpoint_id: id})
        :warm_started

      {:error, reason} ->
        Logger.warning(
          "checkpoint #{id} on env #{env.name} restore failed (#{inspect(reason)}); clearing + cold provisioning"
        )

        publish_stage(conv_id, "checkpoint_restore", "failed", %{
          checkpoint_id: id,
          reason: inspect(reason)
        })

        AgentOnDemand.Environments.update_environment(env, %{"checkpoint_id" => nil}, env.user_id)
        :cold
    end
  end

  defp maybe_create_checkpoint_async(_sprite, nil), do: :ok

  defp maybe_create_checkpoint_async(_sprite, %{checkpoint_id: id})
       when is_binary(id) and id != "",
       do: :ok

  defp maybe_create_checkpoint_async(sprite, %AgentOnDemand.Environments.Environment{} = env) do
    if checkpoint_creation_enabled?() do
      Task.start(fn ->
        try do
          AgentOnDemand.Conversations.Provisioning.create_checkpoint(sprite, env)
        rescue
          _ -> :ok
        end
      end)
    end

    :ok
  end

  defp maybe_create_checkpoint_async(_sprite, _), do: :ok

  defp checkpoint_creation_enabled? do
    Application.get_env(:agent_on_demand, :checkpoint_creation_enabled, true)
  end

  defp reattach(state, conv, sandbox, agent, env, secrets) do
    AgentOnDemand.Telemetry.span(
      [:reattach],
      %{conv_id: state.conversation_id, sprite_name: sandbox.sprite_name},
      fn -> {do_reattach(state, conv, sandbox, agent, env, secrets), %{}} end
    )
  end

  defp do_reattach(state, _conv, sandbox, agent, env, secrets) do
    publish_stage(state.user_id, state.conversation_id, "reattach", "started", %{
      sprite_name: sandbox.sprite_name
    })

    client = SpritesClient.get!()

    case Sprites.get_sprite(client, sandbox.sprite_name) do
      {:ok, _info} ->
        sprite = Sprites.sprite(client, sandbox.sprite_name)
        sprite_env = build_sprite_env(state.runtime_module, agent, env, secrets, state.conversation_id)

        AgentOnDemand.Conversations.Provisioning.write_env_file(sprite, sprite_env)

        new_state = %{state | sprite: sprite, sprite_env: sprite_env}
        new_state = reattach_running_turn(new_state)

        case state.initial_prompt do
          nil -> {:noreply, new_state}
          p -> {:noreply, kick_turn(new_state, p, agent, [])}
        end

      {:error, reason} ->
        Logger.warning(
          "reattach failed for sprite #{sandbox.sprite_name}: #{inspect(reason)} — marking sandbox failed"
        )

        publish_stage(state.user_id, state.conversation_id, "reattach", "failed", %{reason: inspect(reason)})

        {:ok, _} =
          Conversations.update_sandbox(sandbox, %{
            status: "failed",
            terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })

        {:stop, :normal, state}
    end
  end

  defp reattach_running_turn(state) do
    running_turn = find_running_turn(state.conversation_id)

    if is_nil(running_turn) do
      publish_stage(state.user_id, state.conversation_id, "reattach", "done", %{outcome: "no_running_turn"})
      state
    else
      case Sprites.list_sessions(state.sprite) do
        {:ok, sessions} ->
          attempt_session_attach(state, running_turn, sessions)

        {:error, reason} ->
          Logger.warning("list_sessions failed during reattach: #{inspect(reason)}")
          mark_orphan(state, running_turn, "list_sessions_failed")
          state
      end
    end
  end

  defp attempt_session_attach(state, running_turn, []) do
    mark_orphan(state, running_turn, "no_active_session")
    state
  end

  defp attempt_session_attach(state, running_turn, [session | _]) do
    case Sprites.attach_session(state.sprite, session.id, owner: self(), stdin: true) do
      {:ok, command} ->
        replay_skip =
          Conversations.output_bytes_by_stream(state.conversation_id, running_turn.id)

        publish_stage(state.user_id, state.conversation_id, "reattach", "done", %{
          outcome: "session_attached",
          session_id: session.id,
          turn_id: running_turn.id,
          turn_number: running_turn.turn_number,
          replay_skip_bytes: replay_skip
        })

        conv = Conversations.get_conversation_internal!(state.conversation_id)
        {:ok, _} = Conversations.update_conversation(conv, %{status: "running"})

        %{
          state
          | current_command: command,
            current_command_ref: command.ref,
            current_turn: running_turn,
            replay_skip: replay_skip
        }

      {:error, reason} ->
        Logger.warning("attach_session failed: #{inspect(reason)}")
        mark_orphan(state, running_turn, "attach_failed")
        state
    end
  end

  defp mark_orphan(state, running_turn, why) do
    {:ok, _} =
      Conversations.update_turn(running_turn, %{
        status: "interrupted",
        ended_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    conv = Conversations.get_conversation_internal!(state.conversation_id)
    {:ok, _} = Conversations.update_conversation(conv, %{status: "idle"})

    publish_stage(state.user_id, state.conversation_id, "reattach", "interrupted", %{
      outcome: "turn_orphaned",
      turn_id: running_turn.id,
      turn_number: running_turn.turn_number,
      reason: why
    })
  end

  defp find_running_turn(conv_id) do
    import Ecto.Query

    AgentOnDemand.Repo.one(
      from t in AgentOnDemand.Conversations.Turn,
        where: t.conversation_id == ^conv_id and t.status == "running",
        order_by: [desc: t.turn_number],
        limit: 1
    )
  end

  defp build_sprite_env(runtime_module, agent, env, secrets, conversation_id) do
    (runtime_module.default_env(agent) || []) ++
      fountain_callback_env() ++
      conversation_env(conversation_id) ++
      otel_propagation_env() ++
      git_author_env() ++
      if(env,
        do: Enum.map(env.env_vars, fn {k, v} -> {to_string(k), to_string(v)} end),
        else: []
      ) ++
      Enum.map(secrets, fn {k, v} -> {k, v} end)
  end

  defp conversation_env(nil), do: []
  defp conversation_env(conv_id) when is_binary(conv_id), do: [{"AOD_CONVERSATION_ID", conv_id}]

  @doc false
  def git_author_env do
    [
      {"GIT_AUTHOR_NAME", "Fountain"},
      {"GIT_AUTHOR_EMAIL", "fountain@local"},
      {"GIT_COMMITTER_NAME", "Fountain"},
      {"GIT_COMMITTER_EMAIL", "fountain@local"}
    ]
  end

  # Env secrets first, vault overrides last — vault wins on key collision.
  # Passes the tenant DEK so secrets are decrypted with the per-tenant key,
  # not the shared platform key.
  defp merge_secrets(env, vault, dek) when is_binary(dek) do
    env_secrets = if env, do: Environments.decrypted_env(env, dek), else: %{}
    vault_secrets = if vault, do: Vaults.decrypted_env(vault, dek), else: %{}
    Map.merge(env_secrets, vault_secrets)
  end

  # Fallback for when tenant_key is nil (e.g., key not yet provisioned).
  defp merge_secrets(env, vault, nil) do
    env_secrets = if env, do: Environments.decrypted_env(env), else: %{}
    vault_secrets = if vault, do: Vaults.decrypted_env(vault), else: %{}
    Map.merge(env_secrets, vault_secrets)
  end

  defp otel_propagation_env do
    case AgentOnDemand.Telemetry.current_traceparent() do
      nil -> []
      tp -> [{"TRACEPARENT", tp}]
    end
  end

  defp run_setup_script(_sprite, nil, _sprite_env, _conv_id), do: :ok
  defp run_setup_script(_sprite, %{setup_script: ""}, _sprite_env, _conv_id), do: :ok

  defp run_setup_script(sprite, %{setup_script: script}, sprite_env, conv_id) do
    AgentOnDemand.Telemetry.span(
      [:setup_script],
      %{conv_id: conv_id, script_size: byte_size(script)},
      fn ->
        publish_stage(conv_id, "setup", "started")

        {output, code} =
          Sprites.cmd(sprite, "bash", ["-lc", script],
            env: sprite_env,
            stderr_to_stdout: true,
            timeout: 120_000
          )

        Conversations.log!(%{
          conversation_id: conv_id,
          kind: "output",
          stream: "stdout",
          stage: "setup",
          data: output
        })

        if code == 0 do
          publish_stage(conv_id, "setup", "done", %{exit_code: code})
          {:ok, %{outcome: :ok, exit_code: code}}
        else
          publish_stage(conv_id, "setup", "failed", %{exit_code: code})
          {{:error, {:setup_exit, code}}, %{outcome: :failed, exit_code: code}}
        end
      end
    )
  end

  defp write_runtime_config(sprite, runtime_module, agent) do
    Code.ensure_loaded(runtime_module)

    if function_exported?(runtime_module, :write_config, 2) do
      runtime_module.write_config(sprite, agent)
    end
  end

  defp prepare_runtime_sprite(sprite, runtime_module, agent, sprite_env) do
    Code.ensure_loaded(runtime_module)

    if function_exported?(runtime_module, :prepare_sprite, 3) do
      runtime_module.prepare_sprite(sprite, agent, sprite_env)
    else
      :ok
    end
  end

  @impl true
  def handle_call({:send_prompt, prompt, images}, _from, state) do
    if state.current_command do
      {:reply, {:error, :busy}, state}
    else
      conv = Conversations.get_conversation_internal!(state.conversation_id)
      agent = if conv.agent_id, do: Agents.get_agent!(conv.agent_id, state.user_id)
      {:reply, :ok, kick_turn(state, prompt, agent, images)}
    end
  end

  def handle_call({:send_prompt, prompt}, _from, state) do
    if state.current_command do
      {:reply, {:error, :busy}, state}
    else
      conv = Conversations.get_conversation_internal!(state.conversation_id)
      agent = if conv.agent_id, do: Agents.get_agent!(conv.agent_id, state.user_id)
      {:reply, :ok, kick_turn(state, prompt, agent, [])}
    end
  end

  def handle_call(:interrupt, _from, %{current_command: nil} = state) do
    {:reply, {:error, :idle}, state}
  end

  def handle_call(:interrupt, _from, state) do
    cmd_pid = state.current_command.pid

    if Process.alive?(cmd_pid) do
      try do
        GenServer.stop(cmd_pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end

    {:ok, _turn} =
      Conversations.update_turn(state.current_turn, %{
        status: "interrupted",
        ended_at: now()
      })

    publish_stage(state.user_id, state.conversation_id, "turn", "interrupted", %{
      turn_id: state.current_turn.id,
      turn_number: state.current_turn.turn_number
    })

    end_turn_span(state.current_turn_span, :error, %{"outcome" => "interrupted"})

    conv = Conversations.get_conversation_internal!(state.conversation_id)
    {:ok, _} = Conversations.update_conversation(conv, %{status: "idle"})

    {:reply, :ok,
     %{
       state
       | current_command: nil,
         current_command_ref: nil,
         current_turn: nil,
         current_turn_span: nil
     }}
  end

  def handle_call(:terminate_conv, _from, state) do
    if state.sprite, do: _ = Sprites.destroy(state.sprite)
    sandbox = Conversations.get_sandbox!(state.sandbox_id)

    {:ok, _} =
      Conversations.update_sandbox(sandbox, %{status: "terminated", terminated_at: now()})

    conv = Conversations.get_conversation_internal!(state.conversation_id)
    {:ok, _} = Conversations.update_conversation(conv, %{status: "terminated"})
    publish_stage(state.user_id, state.conversation_id, "terminate", "done")

    # Billing: sandbox is gone.
    Billing.emit(state.user_id, "sandbox_terminated", state.sandbox_id, "sandbox", %{
      sprite_name: sandbox.sprite_name
    })

    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info({:stdout, %{ref: ref}, data}, %{current_command_ref: ref} = state) do
    {:noreply, log_with_replay_skip(state, "stdout", data)}
  end

  def handle_info({:stderr, %{ref: ref}, data}, %{current_command_ref: ref} = state) do
    {:noreply, log_with_replay_skip(state, "stderr", data)}
  end

  def handle_info({:exit, %{ref: ref}, code}, %{current_command_ref: ref} = state) do
    turn = state.current_turn

    {:ok, turn} =
      Conversations.update_turn(turn, %{
        status: if(code == 0, do: "completed", else: "failed"),
        exit_code: code,
        ended_at: now()
      })

    publish_stage(state.user_id, state.conversation_id, "turn", "done", %{
      turn_id: turn.id,
      turn_number: turn.turn_number,
      exit_code: code
    })

    end_turn_span(
      state.current_turn_span,
      if(code == 0, do: :ok, else: :error),
      %{"exit_code" => code}
    )

    conv = Conversations.get_conversation_internal!(state.conversation_id)
    {:ok, _} = Conversations.update_conversation(conv, %{status: "idle"})

    {:noreply,
     %{
       state
       | current_command: nil,
         current_command_ref: nil,
         current_turn: nil,
         current_turn_span: nil
     }}
  end

  def handle_info({:error, _ref, reason}, state) do
    Logger.error("sprite command error: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── helpers ────────────────────────────────────────────────────────────────

  defp create_sprite(name) do
    client = SpritesClient.get!()
    Sprites.create(client, name)
  end

  defp fountain_callback_env do
    base = Application.get_env(:agent_on_demand, :public_url)
    token = Application.get_env(:agent_on_demand, :admin_token)

    if is_binary(base) and base != "" and is_binary(token) do
      [{"FOUNTAIN_BASE_URL", base}, {"FOUNTAIN_TOKEN", token}]
    else
      []
    end
  end

  defp kick_turn(state, prompt, agent, images) do
    conv = Conversations.get_conversation_internal!(state.conversation_id)
    turn_number = Conversations.next_turn_number(state.conversation_id)

    {:ok, turn} =
      Conversations.create_turn(%{
        conversation_id: conv.id,
        turn_number: turn_number,
        prompt: prompt,
        status: "running",
        started_at: now()
      })

    {:ok, _} = Conversations.insert_turn_images(turn.id, images)

    image_paths = write_image_temp_files(state.sprite, turn.id, images)

    {:ok, _} = Conversations.update_conversation(conv, %{status: "running"})

    mode =
      cond do
        is_nil(state.runtime_session_id) -> :run
        true -> :continue
      end

    runtime_session_id =
      case state.runtime_session_id do
        nil ->
          new_id = Ecto.UUID.generate()
          {:ok, _} = Conversations.update_conversation(conv, %{runtime_session_id: new_id})
          new_id

        existing ->
          existing
      end

    {cmd, args, build_opts} =
      state.runtime_module.build_command(agent, prompt, mode, runtime_session_id, [images: image_paths])

    use_stdin? = Keyword.get(build_opts, :stdin?, true)
    use_tty? = Keyword.get(build_opts, :tty?, false)
    cwd = Keyword.get(build_opts, :dir)
    prompt_suffix = Keyword.get(build_opts, :prompt_suffix, "")

    publish_stage(state.user_id, state.conversation_id, "turn", "started", %{
      turn_id: turn.id,
      turn_number: turn_number,
      mode: Atom.to_string(mode)
    })

    # Billing: turn is kicking off.
    Billing.emit(state.user_id, "turn_started", turn.id, "turn", %{
      turn_number: turn_number,
      conversation_id: state.conversation_id
    })

    turn_span =
      OpenTelemetry.Tracer.start_span("agent_on_demand.turn", %{
        attributes: %{
          "conv_id" => conv.id,
          "turn_id" => turn.id,
          "turn_number" => turn_number,
          "mode" => Atom.to_string(mode),
          "runtime" => to_string(conv.runtime),
          "model" => agent && agent.model
        }
      })

    previous_span = OpenTelemetry.Tracer.set_current_span(turn_span)

    try do
      spawn_opts =
        [
          env: state.sprite_env,
          owner: self(),
          stdin: use_stdin?,
          tty: use_tty?,
          detachable: true
        ]
        |> then(&if cwd, do: Keyword.put(&1, :dir, cwd), else: &1)

      case Sprites.spawn(state.sprite, cmd, args, spawn_opts) do
        {:ok, command} ->
          if use_stdin? do
            :ok = Sprites.write(command, prompt <> prompt_suffix)
            :ok = Sprites.close_stdin(command)
          end

          %{
            state
            | current_command: command,
              current_command_ref: command.ref,
              current_turn: turn,
              runtime_session_id: runtime_session_id,
              current_turn_span: turn_span
          }

        {:error, reason} ->
          Logger.error("spawn failed: #{inspect(reason)}")

          {:ok, _} =
            Conversations.update_turn(turn, %{
              status: "failed",
              ended_at: now()
            })

          publish_stage(state.user_id, state.conversation_id, "turn", "failed", %{
            turn_id: turn.id,
            reason: inspect(reason)
          })

          OpenTelemetry.Tracer.set_status(
            OpenTelemetry.status(:error, "spawn_failed: #{inspect(reason)}")
          )

          OpenTelemetry.Tracer.end_span(turn_span)
          OpenTelemetry.Tracer.set_current_span(previous_span)

          state
      end
    after
      OpenTelemetry.Tracer.set_current_span(previous_span)
    end
  end

  defp end_turn_span(nil, _outcome, _attrs), do: :ok

  defp end_turn_span(span_ctx, outcome, attrs) do
    OpenTelemetry.Tracer.set_current_span(span_ctx)

    Enum.each(attrs, fn {k, v} -> OpenTelemetry.Tracer.set_attribute(to_string(k), v) end)

    case outcome do
      :error ->
        OpenTelemetry.Tracer.set_status(OpenTelemetry.status(:error, inspect(attrs)))

      _ ->
        :ok
    end

    OpenTelemetry.Tracer.end_span(span_ctx)
  end

  defp log_output(state, stream, data) do
    event =
      Conversations.log!(%{
        conversation_id: state.conversation_id,
        turn_id: state.current_turn && state.current_turn.id,
        kind: "output",
        stream: stream,
        stage: "turn",
        data: data
      })

    Phoenix.PubSub.broadcast(
      AgentOnDemand.PubSub,
      "conv:#{state.user_id}:#{state.conversation_id}",
      {:log_event, event}
    )
  end

  defp log_with_replay_skip(state, stream, data) do
    skip = Map.get(state.replay_skip, stream, 0)
    size = byte_size(data)

    cond do
      skip == 0 ->
        log_output(state, stream, data)
        state

      skip >= size ->
        put_in(state.replay_skip[stream], skip - size)

      true ->
        log_output(state, stream, binary_part(data, skip, size - skip))
        put_in(state.replay_skip[stream], 0)
    end
  end

  # Broadcasts a stage event and persists it as a LogEvent.
  # Takes user_id to build the namespaced PubSub topic
  # `"conv:<user_id>:<conv_id>"`.
  defp publish_stage(user_id, conv_id, stage, state_name, meta \\ %{}) do
    event =
      Conversations.log!(%{
        conversation_id: conv_id,
        kind: "stage",
        stage: stage,
        state: state_name,
        data: Jason.encode!(meta)
      })

    Phoenix.PubSub.broadcast(
      AgentOnDemand.PubSub,
      "conv:#{user_id}:#{conv_id}",
      {:log_event, event}
    )
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp write_image_temp_files(_sprite, _turn_id, []), do: []

  defp write_image_temp_files(sprite, turn_id, images) do
    fs = Sprites.filesystem(sprite, "/")

    images
    |> Enum.with_index()
    |> Enum.map(fn {%{media_type: mt, data: data}, idx} ->
      ext = media_type_to_ext(mt)
      path = "/tmp/fountain_turn_#{turn_id}_#{idx}.#{ext}"
      Sprites.Filesystem.write(fs, path, data)
      {path, mt}
    end)
  end

  defp media_type_to_ext("image/png"), do: "png"
  defp media_type_to_ext("image/jpeg"), do: "jpeg"
  defp media_type_to_ext("image/gif"), do: "gif"
  defp media_type_to_ext("image/webp"), do: "webp"
  defp media_type_to_ext(_), do: "bin"
end
