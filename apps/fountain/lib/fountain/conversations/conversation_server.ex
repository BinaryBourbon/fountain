defmodule Fountain.Conversations.ConversationServer do
  @moduledoc """
  Owns one running conversation: its sprite, the active runtime command (if
  any), and the per-turn state. Streams sprite stdout/stderr into the DB
  (LogEvent rows) and broadcasts on Phoenix.PubSub topic `"conv:<id>"` so
  SSE subscribers can tail it live.

  Lifecycle:
    pending → starting → ready ⇄ running → terminated|failed
  """

  use GenServer, restart: :transient
  require Logger
  require OpenTelemetry.Tracer

  alias Fountain.{Accounts, Agents, Conversations, Crypto, Environments, InferenceCredentials, SpritesClient, Substitution, Vaults}
  alias Fountain.Conversations.Conversation

  # ── public api ────────────────────────────────────────────────────────────

  def start_link(args) do
    conv_id = Keyword.fetch!(args, :conversation_id)
    GenServer.start_link(__MODULE__, args, name: via(conv_id))
  end

  def via(conv_id), do: {:via, Horde.Registry, {Fountain.ConversationRegistry, conv_id}}

  def whereis(conv_id) do
    case Horde.Registry.lookup(Fountain.ConversationRegistry, conv_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Send another prompt. If the conversation's GenServer is gone (e.g. server
  restart), transparently wake the conversation — provision a fresh sprite
  and queue this prompt as the first turn of the new sandbox. claude
  `--resume` preserves the chat via the persisted runtime_session_id.
  """
  def send_prompt(conv_id, prompt, images \\ []) do
    case whereis(conv_id) do
      nil ->
        case Conversations.wake_conversation(conv_id, prompt) do
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
        case Conversations._unsafe_get_conversation(conv_id) do
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

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(args) do
    state = %{
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
      # OTel span context for the in-flight turn (started in kick_turn,
      # ended in the :exit / :interrupt handlers).
      current_turn_span: nil,
      # Bytes of replayed output to drop on reattach, keyed by stream.
      # Empty map outside a reattach window. See attempt_session_attach.
      replay_skip: %{},
      # Per-tenant DEK + decrypted inference credentials. Loaded in
      # handle_continue(:provision) once the conversation row tells us the
      # owning user_id; held for the conversation lifetime; dropped on
      # terminate. See ADR 0008 (BYO inference credentials).
      tenant_key: nil,
      inference_credentials: %{},
      # Plaintext of the per-conversation API key that's injected into the
      # sprite as FOUNTAIN_TOKEN. The hash and a row in `api_keys` is the
      # durable record; we keep the raw value in memory only while this
      # GenServer is alive. Rotated on every fresh provision/reattach;
      # revoked in terminate/2.
      callback_token: nil
    }

    {:ok, state, {:continue, :provision}}
  end

  @impl true
  def handle_continue(:provision, state) do
    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
    sandbox = Conversations.get_sandbox!(state.sandbox_id)
    agent = if conv.agent_id, do: Agents._unsafe_get_agent!(conv.agent_id), else: nil
    env = if agent && agent.environment_id, do: Environments._unsafe_get_environment(agent.environment_id)
    vault = if conv.vault_id, do: Vaults._unsafe_get_vault(conv.vault_id)

    case load_tenant_state(conv.user_id) do
      {:ok, dek, inference_creds} ->
        secrets = merge_secrets(env, vault, dek)

        state =
          %{state | runtime_session_id: conv.runtime_session_id, tenant_key: dek, inference_credentials: inference_creds}

        dispatch_provision(state, conv, sandbox, agent, env, vault, secrets)

      {:error, reason} ->
        Logger.error(
          "ConversationServer could not load tenant credentials for conv #{conv.id} (user #{conv.user_id}): #{inspect(reason)}"
        )

        publish_stage(state.conversation_id, "provision", "failed", %{
          reason: "tenant_credential_load_failed: #{inspect(reason)}"
        })

        {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "failed"})
        Conversations.update_conversation(conv, %{status: "failed"})
        {:stop, :normal, state}
    end
  end

  # Load the per-tenant DEK and decrypted inference credentials. Both are
  # held in GenServer state for the conversation lifetime; the DEK is used
  # for ad-hoc decryption (vaults, environments) and the credentials map
  # is passed to runtime modules via build_sprite_env.
  defp load_tenant_state(user_id) when is_binary(user_id) do
    with {:ok, dek} <- Crypto.load_tenant_key(user_id),
         {:ok, creds} <- InferenceCredentials.decrypted_for_user(user_id, dek) do
      {:ok, dek, creds}
    end
  end

  defp dispatch_provision(state, conv, sandbox, agent, env, _vault, secrets) do
    case substitute_agent_mcp(agent, env, secrets) do
      {:ok, agent} ->
        case sandbox.status do
          "ready" ->
            # The sprite already exists at sprites.dev and was fully provisioned
            # in a previous BEAM lifetime. Reattach instead of recreating.
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
        publish_stage(state.conversation_id, "provision", "failed", %{reason: reason})
        {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "failed"})
        Conversations.update_conversation(conv, %{status: "failed"})
        {:stop, :normal, state}
    end
  end

  # Resolve `${VAR}` references in the agent's MCP server config against
  # env_vars + env_secrets + vault_secrets (vault wins). Env vars values
  # are coerced to strings; non-string values further down the tree pass
  # through untouched.
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
    Fountain.Telemetry.span(
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

        publish_stage(state.conversation_id, "provision", "failed", %{
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
    publish_stage(state.conversation_id, "provision", "started")

    case create_sprite(sandbox.sprite_name) do
      {:ok, sprite} ->
        skills = (agent && agent.skills) || []
        runtime = (agent && agent.runtime) || "claude"
        Fountain.SpriteSkills.mount(sprite, runtime, skills)

        {state, conv} = rotate_callback_api_key(state, conv)

        sprite_env = build_sprite_env(state, agent, env, secrets)

        write_runtime_config(sprite, state.runtime_module, agent)
        Fountain.Conversations.Provisioning.write_env_file(sprite, sprite_env)

        with :ok <-
               run_provisioning_pipeline(sprite, env, sprite_env, secrets, state.conversation_id),
             :ok <- prepare_runtime_sprite(sprite, state.runtime_module, agent, sprite_env) do
          {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "ready"})
          publish_stage(state.conversation_id, "provision", "done")

          # Best-effort: snapshot the fully-provisioned state so subsequent
          # conversations on this env can warm-start from it. Async so it
          # doesn't block the user's first turn.
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

            publish_stage(state.conversation_id, "provision", "failed", %{
              reason: inspect(reason)
            })

            Conversations.update_conversation(conv, %{status: "failed"})
            {:stop, :normal, state}
        end

      {:error, reason} ->
        Logger.error("sprite provision failed: #{inspect(reason)}")
        {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "failed"})
        publish_stage(state.conversation_id, "provision", "failed", %{reason: inspect(reason)})
        Conversations.update_conversation(conv, %{status: "failed"})
        {:stop, :normal, state}
    end
  end

  # Try a checkpoint restore first if the env has one. If restore
  # succeeds, skip the slow steps (network policy + packages + clone +
  # setup_script) — they all ran when the checkpoint was originally
  # taken. If restore fails, clear the checkpoint id and fall through to
  # the full pipeline.
  defp run_provisioning_pipeline(sprite, env, sprite_env, secrets, conv_id) do
    case attempt_warm_start(sprite, env, conv_id) do
      :warm_started ->
        :ok

      :cold ->
        with :ok <-
               Fountain.Conversations.Provisioning.install_packages(
                 sprite,
                 env,
                 sprite_env,
                 conv_id
               ),
             :ok <-
               Fountain.Conversations.Provisioning.apply_network_policy(sprite, env, conv_id),
             :ok <-
               Fountain.Conversations.Provisioning.clone_repositories(
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

    case Fountain.Conversations.Provisioning.restore_checkpoint(sprite, id) do
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

        # Clear the stale checkpoint so future runs don't keep retrying.
        Fountain.Environments.update_environment(env, %{"checkpoint_id" => nil})
        :cold
    end
  end

  defp maybe_create_checkpoint_async(_sprite, nil), do: :ok

  defp maybe_create_checkpoint_async(_sprite, %{checkpoint_id: id})
       when is_binary(id) and id != "",
       do: :ok

  defp maybe_create_checkpoint_async(sprite, %Fountain.Environments.Environment{} = env) do
    if checkpoint_creation_enabled?() do
      Task.start(fn ->
        try do
          Fountain.Conversations.Provisioning.create_checkpoint(sprite, env)
        rescue
          # Best-effort: if the env was deleted or the DB is gone (test
          # teardown), don't crash the Task and pollute logs.
          _ -> :ok
        end
      end)
    end

    :ok
  end

  defp maybe_create_checkpoint_async(_sprite, _), do: :ok

  defp checkpoint_creation_enabled? do
    Application.get_env(:fountain, :checkpoint_creation_enabled, true)
  end

  defp reattach(state, conv, sandbox, agent, env, secrets) do
    Fountain.Telemetry.span(
      [:reattach],
      %{conv_id: state.conversation_id, sprite_name: sandbox.sprite_name},
      fn -> {do_reattach(state, conv, sandbox, agent, env, secrets), %{}} end
    )
  end

  defp do_reattach(state, conv, sandbox, agent, env, secrets) do
    publish_stage(state.conversation_id, "reattach", "started", %{
      sprite_name: sandbox.sprite_name
    })

    client = SpritesClient.get!()

    case Sprites.get_sprite(client, sandbox.sprite_name) do
      {:ok, _info} ->
        sprite = Sprites.sprite(client, sandbox.sprite_name)
        {state, _conv} = rotate_callback_api_key(state, conv)
        sprite_env = build_sprite_env(state, agent, env, secrets)

        # Refresh the .env file in case secrets/env_vars were edited
        # between the original provision and this reattach.
        Fountain.Conversations.Provisioning.write_env_file(sprite, sprite_env)

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

        publish_stage(state.conversation_id, "reattach", "failed", %{reason: inspect(reason)})

        {:ok, _} =
          Conversations.update_sandbox(sandbox, %{
            status: "failed",
            terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })

        # Don't mark the conversation failed — the user can still send a
        # prompt and auto-wake will spin a fresh sandbox.
        {:stop, :normal, state}
    end
  end

  # If a turn is marked `running` in the DB and the sprite has an active
  # detachable session, reattach to it: the WebSocket reconnects, stdout
  # continues streaming where it left off, and the eventual `:exit` message
  # closes the turn cleanly. If no active session is found, the command
  # finished while the BEAM was down — we don't know the exit code, so
  # mark the orphaned turn `interrupted` so the user gets a clear signal.
  defp reattach_running_turn(state) do
    running_turn = find_running_turn(state.conversation_id)

    if is_nil(running_turn) do
      publish_stage(state.conversation_id, "reattach", "done", %{outcome: "no_running_turn"})
      state
    else
      case Sprites.list_sessions(state.sprite) do
        {:ok, sessions} ->
          # Don't filter by `is_active`: a detached session reports
          # `is_active: false` while no client is connected, but the
          # underlying exec is alive and `attach_session` resumes its
          # stream (replaying the session buffer + live-tailing).
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
        # sprites replays the session's buffered output before live-tailing.
        # Count the bytes we already persisted for this turn so the
        # stdout/stderr handlers can drop the replayed prefix.
        replay_skip =
          Conversations.output_bytes_by_stream(state.conversation_id, running_turn.id)

        publish_stage(state.conversation_id, "reattach", "done", %{
          outcome: "session_attached",
          session_id: session.id,
          turn_id: running_turn.id,
          turn_number: running_turn.turn_number,
          replay_skip_bytes: replay_skip
        })

        conv = Conversations._unsafe_get_conversation!(state.conversation_id)
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

    # The orphaned turn was the only thing keeping the conversation in
    # `running`. Flip it back to `idle` so the UI accurately reflects
    # state and the user can prompt without going through wake.
    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
    {:ok, _} = Conversations.update_conversation(conv, %{status: "idle"})

    publish_stage(state.conversation_id, "reattach", "interrupted", %{
      outcome: "turn_orphaned",
      turn_id: running_turn.id,
      turn_number: running_turn.turn_number,
      reason: why
    })
  end

  defp find_running_turn(conv_id) do
    import Ecto.Query

    Fountain.Repo.one(
      from t in Fountain.Conversations.Turn,
        where: t.conversation_id == ^conv_id and t.status == "running",
        order_by: [desc: t.turn_number],
        limit: 1
    )
  end

  defp build_sprite_env(state, agent, env, secrets) do
    (state.runtime_module.default_env(agent, state.inference_credentials) || []) ++
      fountain_callback_env(state.callback_token) ++
      conversation_env(state.conversation_id) ++
      otel_propagation_env() ++
      git_author_env() ++
      if(env,
        do: Enum.map(env.env_vars, fn {k, v} -> {to_string(k), to_string(v)} end),
        else: []
      ) ++
      Enum.map(secrets, fn {k, v} -> {k, v} end)
  end

  # Inject the current conversation ID so the bundled fountain skill can
  # propagate it as X-Fountain-Parent-Conversation-Id when spawning children.
  defp conversation_env(nil), do: []
  defp conversation_env(conv_id) when is_binary(conv_id), do: [{"FOUNTAIN_CONVERSATION_ID", conv_id}]

  @doc false
  def git_author_env do
    [
      {"GIT_AUTHOR_NAME", "AoD"},
      {"GIT_AUTHOR_EMAIL", "aod@local"},
      {"GIT_COMMITTER_NAME", "AoD"},
      {"GIT_COMMITTER_EMAIL", "aod@local"}
    ]
  end

  # Env secrets first, vault overrides last — vault wins on key collision.
  # Same merged map feeds repositories[].secret_key resolution.
  defp merge_secrets(env, vault, dek) do
    env_secrets = if env, do: Environments.decrypted_env(env, dek), else: %{}
    vault_secrets = if vault, do: Vaults.decrypted_env(vault, dek), else: %{}
    Map.merge(env_secrets, vault_secrets)
  end

  # Inject the W3C trace context as TRACEPARENT into the sprite env when
  # we're inside an active OTel span. claude / codex / gemini / opencode
  # all read TRACEPARENT and tag their API calls into the trace, so a
  # turn span has every model API request as a child.
  defp otel_propagation_env do
    case Fountain.Telemetry.current_traceparent() do
      nil -> []
      tp -> [{"TRACEPARENT", tp}]
    end
  end

  defp run_setup_script(_sprite, nil, _sprite_env, _conv_id), do: :ok
  defp run_setup_script(_sprite, %{setup_script: ""}, _sprite_env, _conv_id), do: :ok

  defp run_setup_script(sprite, %{setup_script: script}, sprite_env, conv_id) do
    Fountain.Telemetry.span(
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
      conv = Conversations._unsafe_get_conversation!(state.conversation_id)
      agent = if conv.agent_id, do: Agents._unsafe_get_agent!(conv.agent_id)
      {:reply, :ok, kick_turn(state, prompt, agent, images)}
    end
  end

  def handle_call({:send_prompt, prompt}, _from, state) do
    if state.current_command do
      {:reply, {:error, :busy}, state}
    else
      conv = Conversations._unsafe_get_conversation!(state.conversation_id)
      agent = if conv.agent_id, do: Agents._unsafe_get_agent!(conv.agent_id)
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

    publish_stage(state.conversation_id, "turn", "interrupted", %{
      turn_id: state.current_turn.id,
      turn_number: state.current_turn.turn_number
    })

    end_turn_span(state.current_turn_span, :error, %{"outcome" => "interrupted"})

    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
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

    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
    {:ok, _} = Conversations.update_conversation(conv, %{status: "terminated"})
    publish_stage(state.conversation_id, "terminate", "done")
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

    publish_stage(state.conversation_id, "turn", "done", %{
      turn_id: turn.id,
      turn_number: turn.turn_number,
      exit_code: code
    })

    # Close the OTel turn span we opened in kick_turn.
    end_turn_span(
      state.current_turn_span,
      if(code == 0, do: :ok, else: :error),
      %{"exit_code" => code}
    )

    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
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

  # Best-effort revoke of the per-conversation API key when this server
  # exits — covers both clean termination (`:terminate_conv`) and crash
  # paths that hit `{:stop, :normal, state}` after a provision failure.
  # If the BEAM crashes hard, the row in `api_keys` is orphaned and lives
  # until an admin/janitor sweeps it; that's a known gap, not a regression.
  @impl true
  def terminate(_reason, state) do
    if state.conversation_id do
      case Conversations._unsafe_get_conversation(state.conversation_id) do
        %Conversation{user_id: user_id, callback_api_key_id: id}
        when is_binary(user_id) and is_binary(id) ->
          _ = Accounts.revoke_api_key(user_id, id)

        _ ->
          :ok
      end
    end

    :ok
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp create_sprite(name) do
    client = SpritesClient.get!()
    Sprites.create(client, name)
  end

  defp fountain_callback_env(token) do
    base = Application.get_env(:fountain, :public_url)

    if is_binary(base) and base != "" and is_binary(token) and token != "" do
      [{"FOUNTAIN_BASE_URL", base}, {"FOUNTAIN_TOKEN", token}]
    else
      []
    end
  end

  # Issue a fresh per-conversation API key scoped to the conversation
  # owner, revoking any prior one. The plaintext is only kept in
  # `state.callback_token` — the durable record is a hash in `api_keys`,
  # which we can't reverse, so we rotate on every fresh provision /
  # reattach instead of trying to recover the old plaintext.
  defp rotate_callback_api_key(state, %Conversation{} = conv) do
    if id = conv.callback_api_key_id do
      _ = Accounts.revoke_api_key(conv.user_id, id)
    end

    case Accounts.create_api_key(conv.user_id, "sprite:#{String.slice(conv.id, 0, 8)}") do
      {:ok, {%Accounts.ApiKey{id: key_id}, raw}} ->
        {:ok, conv} = Conversations.update_conversation(conv, %{callback_api_key_id: key_id})
        {%{state | callback_token: raw}, conv}

      {:error, cs} ->
        Logger.warning(
          "could not issue callback api key for conv #{conv.id}: #{inspect(cs.errors)}"
        )

        {%{state | callback_token: nil}, conv}
    end
  end

  defp kick_turn(state, prompt, agent, images) do
    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
    turn_number = Conversations.next_turn_number(state.conversation_id)

    {:ok, turn} =
      Conversations.create_turn(%{
        conversation_id: conv.id,
        turn_number: turn_number,
        prompt: prompt,
        status: "running",
        started_at: now()
      })

    # Store images in DB
    {:ok, _} = Conversations.insert_turn_images(turn.id, images)

    # Write image temp files to sprite
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
          # Generate one and persist immediately so a server restart can resume.
          # claude uses --session-id <X> verbatim, so this is the value claude
          # will know us by; turn 2+ will pass --resume <X>.
          new_id = Ecto.UUID.generate()
          {:ok, _} = Conversations.update_conversation(conv, %{runtime_session_id: new_id})
          new_id

        existing ->
          existing
      end

    {cmd, args, build_opts} =
      state.runtime_module.build_command(agent, prompt, mode, runtime_session_id, [images: image_paths])

    # If a runtime embeds the prompt in argv (codex), it returns
    # `stdin?: false` and we skip the Sprites.write/close_stdin pipeline.
    # claude / gemini / opencode default to true and read from stdin.
    use_stdin? = Keyword.get(build_opts, :stdin?, true)

    # codex emits a noisy "additional input from stdin" warning when
    # `isatty(0)` is false; allocating a PTY suppresses it. Other
    # runtimes default to no PTY.
    use_tty? = Keyword.get(build_opts, :tty?, false)

    # opencode + gemini set this to point at a workspace dir that has a
    # local .git (so neither runtime trips on /home/sprite's perms).
    cwd = Keyword.get(build_opts, :dir)

    # Runtimes that cannot accept images as CLI flags (claude, gemini)
    # return a prompt_suffix with image references to append to stdin.
    prompt_suffix = Keyword.get(build_opts, :prompt_suffix, "")

    publish_stage(state.conversation_id, "turn", "started", %{
      turn_id: turn.id,
      turn_number: turn_number,
      mode: Atom.to_string(mode)
    })

    # Open an OTel span for the turn. We can't use Telemetry.span here
    # because the turn finishes asynchronously (in the :exit handler);
    # so we open it explicitly and store the span context in state to
    # close it later. While this span is current, build_sprite_env
    # picks up the trace context as TRACEPARENT for the runtime CLI.
    turn_span =
      OpenTelemetry.Tracer.start_span("fountain.turn", %{
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
          # Detachable: the sprite-side session survives a WebSocket
          # disconnect, so a BEAM restart can list_sessions + reattach.
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

          publish_stage(state.conversation_id, "turn", "failed", %{
            turn_id: turn.id,
            reason: inspect(reason)
          })

          # Spawn never started; close the span we just opened so it
          # doesn't leak.
          OpenTelemetry.Tracer.set_status(
            OpenTelemetry.status(:error, "spawn_failed: #{inspect(reason)}")
          )

          OpenTelemetry.Tracer.end_span(turn_span)
          OpenTelemetry.Tracer.set_current_span(previous_span)

          state
      end
    after
      # The successful path keeps the span open until :exit; the error
      # path above closes it explicitly. In both cases we restore the
      # caller's previous current-span here.
      OpenTelemetry.Tracer.set_current_span(previous_span)
    end
  end

  # End the OTel turn span (if any) with a status reflecting the
  # outcome. Called from the :exit and :interrupt handlers.
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
    # Tag this output with the stage that's active right now. The
    # runtime CLI is always spawned inside a `turn` so all stdout /
    # stderr from it gets `stage: "turn"`. Any operator on the
    # presentation side (LiveView grouping, SSE consumers) can group
    # output by stage without inferring it from event interleaving.
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
      Fountain.PubSub,
      "conv:#{state.conversation_id}",
      {:log_event, event}
    )
  end

  # Drop replayed bytes before persisting. After reattach, sprites replays
  # the session's buffered output up to where it left off, then live-tails.
  # We pre-loaded the byte count we'd already persisted for the in-flight
  # turn into `state.replay_skip[stream]`; consume that many bytes off the
  # front of incoming data, then start logging the remainder normally.
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

  defp publish_stage(conv_id, stage, state, meta \\ %{}) do
    event =
      Conversations.log!(%{
        conversation_id: conv_id,
        kind: "stage",
        stage: stage,
        state: state,
        data: Jason.encode!(meta)
      })

    Phoenix.PubSub.broadcast(
      Fountain.PubSub,
      "conv:#{conv_id}",
      {:log_event, event}
    )
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # Write each image to a temp path in the sprite filesystem and return
  # a list of {path, media_type} tuples for passing to the runtime.
  defp write_image_temp_files(_sprite, _turn_id, []), do: []

  defp write_image_temp_files(sprite, turn_id, images) do
    fs = Sprites.filesystem(sprite, "/")

    images
    |> Enum.with_index()
    |> Enum.map(fn {%{media_type: mt, data: data}, idx} ->
      ext = media_type_to_ext(mt)
      path = "/tmp/aod_turn_#{turn_id}_#{idx}.#{ext}"
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
