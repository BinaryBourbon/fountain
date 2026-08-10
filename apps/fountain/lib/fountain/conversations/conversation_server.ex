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

  alias Fountain.{
    Accounts,
    Agents,
    Conversations,
    Crypto,
    Environments,
    InferenceCredentials,
    SpritesClient,
    SpriteStdin,
    Substitution,
    Vaults
  }

  alias Fountain.Conversations.{Conversation, Lifecycle}

  # How often the sandbox lifetime bounds are evaluated. A minute is far finer
  # than the bounds themselves (an hour, a day), so the cost of the tick is
  # irrelevant and the overshoot is bounded by it.
  @lifecycle_check_ms :timer.minutes(1)

  # Absolute ceiling on provisioning (#329). Generous against the summed
  # per-step timeouts (packages 300s + clone 600s + setup 120s + slack), so
  # it only ever fires when a step stalls without raising — the case where
  # the row sat in `starting` holding a quota slot until the next deploy:
  # the reaper exempts rows whose server is alive, and the server's own
  # timers queue behind the stuck handle_continue. Overridable in tests.
  @provision_deadline_ms :timer.minutes(30)

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
  def send_prompt(conv_id, prompt, images \\ [], opts \\ []) do
    result =
      case whereis(conv_id) do
        nil ->
          case Conversations.wake_conversation(conv_id, prompt) do
            {:ok, _conv} -> :ok
            {:error, :gone} -> {:error, :gone}
            {:error, :not_found} -> {:error, :not_running}
            {:error, _} = err -> err
          end

        pid ->
          call_server(pid, {:send_prompt, prompt, images})
      end

    # Size and image count, never the text. A prompt is the tenant's content —
    # frequently the most sensitive thing in the system — and #545 is explicit
    # that the trail records that a prompt happened, not what it said.
    audit_lifecycle(conv_id, "conversation.prompted", result, opts, %{
      "prompt_bytes" => byte_size(prompt),
      "image_count" => length(images)
    })

    result
  end

  # Every public entry point calls through here so a GenServer.call exit
  # cannot escape to the caller (#412). The realistic exit is :timeout: a
  # handle_continue(:provision) blocks the mailbox for up to the provision
  # deadline, so any call issued during provisioning waits 30s and then
  # *exits* — which none of the seven controller/LiveView call sites caught,
  # turning prompt/interrupt/terminate into 500s and making
  # delete_conversation/1 return before its Repo.delete. :noproc and
  # shutdown-shaped exits are the server dying between whereis and call.
  defp call_server(pid, msg) do
    GenServer.call(
      pid,
      msg,
      Application.get_env(:fountain, :conversation_call_timeout_ms, 30_000)
    )
  catch
    :exit, {:timeout, _} -> {:error, :provisioning}
    :exit, {:noproc, _} -> {:error, :not_running}
    :exit, {:normal, _} -> {:error, :not_running}
    :exit, {:shutdown, _} -> {:error, :not_running}
    :exit, {{:shutdown, _}, _} -> {:error, :not_running}
  end

  @doc """
  Deliver the prompt a conversation was started for, after the server exists.

  Deliberately not a `start_link` argument. Horde restarts a redistributed
  child from its *stored child spec*, so anything in there is replayed on every
  cluster membership change — which every deploy causes. A prompt in the spec
  therefore re-ran the user's last message on each rollout.

  Takes the pid `start_child` returned, not the conversation id: Horde's
  registry is a CRDT whose registrations propagate asynchronously, and a cast
  to a via-name that hasn't resolved yet is a silent no-op — the server
  provisions, the user's first prompt is simply gone (#367). The pid needs no
  resolution, works across nodes, and is for exactly the server just started;
  if that server already died, losing the cast is the right outcome.

  A cast rather than a call: it queues behind `handle_continue(:provision)`,
  which can take minutes, and no caller is waiting on the turn to finish.
  """
  def queue_initial_prompt(pid, prompt, images \\ []) when is_pid(pid) do
    GenServer.cast(pid, {:initial_prompt, prompt, images})
  end

  def interrupt(conv_id, opts \\ []) do
    result =
      case whereis(conv_id) do
        nil -> {:error, :not_running}
        pid -> call_server(pid, :interrupt)
      end

    audit_lifecycle(conv_id, "conversation.interrupted", result, opts)
    result
  end

  @doc """
  Terminate the conversation. If the GenServer is alive, it tears down the
  sprite. If not, just mark the DB rows terminated so the user can still
  clean up dead conversations after a server restart.

  Named `terminate_conversation` rather than `terminate`: taking `opts` for
  audit attribution (#545) would have made this `terminate/2`, which is the
  OTP callback below. Two different meanings under one name in one module was
  already a readability trap — `ConversationServer.terminate/1` (stop this
  tenant's conversation) and `terminate/2` (OTP teardown) are unrelated — so
  the client half gets the unambiguous name.
  """
  def terminate_conversation(conv_id, opts \\ []) do
    result =
      case whereis(conv_id) do
        nil ->
          case Conversations._unsafe_get_conversation(conv_id) do
            nil ->
              {:error, :not_running}

            conv ->
              now = DateTime.utc_now() |> DateTime.truncate(:second)
              {:ok, _} = Conversations.update_conversation(conv, %{status: "terminated"})

              if conv.sandbox_id do
                sb = Conversations._unsafe_get_sandbox!(conv.sandbox_id)

                if sb.status not in ["terminated", "failed"] do
                  Conversations.update_sandbox(sb, %{status: "terminated", terminated_at: now})
                end
              end

              :ok
          end

        pid ->
          call_server(pid, :terminate_conv)
      end

    audit_lifecycle(conv_id, "conversation.terminated", result, opts)
    result
  end

  # Records a lifecycle action against the conversation's owner.
  #
  # Only on success: an attempt against a conversation that is not running
  # changed nothing, and a trail that logged it would show terminations that
  # never happened.
  #
  # `audit: false` suppresses the row where a caller's own higher-level event
  # already describes the action — `delete_conversation/2` and account
  # deletion both cascade through `terminate/2`, and neither is a second thing
  # the user asked for.
  #
  # The `_unsafe_` read is legitimate here under the rule in CLAUDE.md: these
  # are GenServer client functions, reached only after a tenant-scoped fetch
  # established ownership at the controller or LiveView, and the read exists
  # solely to attribute the event to that same owner.
  defp audit_lifecycle(conv_id, action, result, opts, metadata \\ %{}) do
    if Keyword.get(opts, :audit, true) and result == :ok do
      case Conversations._unsafe_get_conversation(conv_id) do
        nil ->
          :ok

        conv ->
          Fountain.Audit.record(%{
            user_id: conv.user_id,
            action: action,
            resource_type: "conversation",
            resource_id: conv_id,
            actor: Keyword.get(opts, :actor, "self"),
            request_ip: Keyword.get(opts, :request_ip),
            metadata: metadata
          })
      end
    end

    :ok
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(args) do
    # Without trap_exit, terminate/2 only runs on {:stop, …} or a raise — a
    # Horde rebalance or application shutdown (i.e. every deploy) sends an
    # exit signal and skips it, so the callback-token revoke never fired on
    # the most common teardown there is (#322). Trapping makes OTP call
    # terminate/2 on supervisor shutdown, bounded by the child shutdown
    # timeout.
    Process.flag(:trap_exit, true)

    state = %{
      conversation_id: Keyword.fetch!(args, :conversation_id),
      sandbox_id: Keyword.fetch!(args, :sandbox_id),
      runtime_module: Keyword.fetch!(args, :runtime_module),
      user_id: nil,
      sprite: nil,
      sprite_env: [],
      current_command: nil,
      current_command_ref: nil,
      current_turn: nil,
      runtime_session_id: nil,
      # OTel span context for the in-flight turn (started in kick_turn,
      # ended in the :exit / :interrupt handlers).
      current_turn_span: nil,
      # Aggregate-metric bookkeeping for the in-flight turn (#536, #535):
      # `%{started_mono: ms, runtime: "claude", first_output?: bool}`, set
      # once the turn's command is spawned and dropped on every terminal
      # path. nil whenever no turn is running. Monotonic rather than the
      # turn row's timestamps because `now/0` truncates to the second,
      # which rounds a sub-second turn to a duration of zero.
      turn_metrics: nil,
      # Stream tracer for parsing Claude's stream-json stdout into OTel
      # child spans and events. nil for non-Claude runtimes.
      stream_tracer: nil,
      # The ACP peer driving the in-flight turn, when the agent has opted in
      # (0014 gate 2). nil on the legacy path, which is the default. Monitored
      # rather than linked: a protocol bug must fail a turn, not take down a
      # server that is holding a sprite handle and a tenant's secrets.
      acp_peer: nil,
      acp_peer_mon: nil,
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
      callback_token: nil,
      # The id of the key THIS server minted. Revocation acts only on this
      # id, never on whatever the conversation row currently points at:
      # duplicate servers exist (Horde CRDT merges mass-terminate losers,
      # registry lag starts seconds-apart doubles — #367), and a server
      # that revokes the row's key can be revoking the credential the
      # SURVIVING server's sprite is actively using.
      callback_api_key_id: nil,
      # Sandbox lifetime bookkeeping. `started_at` is set once the sprite
      # exists; `last_activity_at` moves on every turn start and end. See
      # Fountain.Conversations.Lifecycle for what the bounds are and why
      # reclaiming a sandbox does not end the conversation.
      sandbox_started_at: nil,
      last_activity_at: DateTime.utc_now(),
      # Durable-output budget bookkeeping (#331). `output_bytes` is loaded
      # lazily from the DB on the first output of this server's lifetime, so
      # the budget is cumulative per conversation across wakes rather than
      # per BEAM lifetime.
      output_bytes: nil,
      output_capped: false
    }

    schedule_lifecycle_check()
    start_provision_watchdog(state.conversation_id, state.sandbox_id)
    {:ok, state, {:continue, :provision}}
  end

  # A deadline for provisioning cannot live inside this server: a stuck
  # handle_continue(:provision) blocks the mailbox, so a send_after (or a
  # trapped exit signal) queues behind the very thing it is meant to bound.
  # The watchdog is a separate process that, at the deadline, consults the
  # sandbox row — the provision path's own source of truth — and only if it
  # is still pending/starting brutally kills the server and applies the same
  # failed/failed row transitions as the normal provision-failure path. The
  # sprite, if one was created, is picked up by SandboxReaper's untracked
  # sweep. A monitor exits the watchdog quietly whenever the server stops
  # first, which covers every success and ordinary-failure path.
  defp start_provision_watchdog(conv_id, sandbox_id) do
    server = self()
    deadline_ms = Application.get_env(:fountain, :provision_deadline_ms, @provision_deadline_ms)

    spawn(fn ->
      ref = Process.monitor(server)

      receive do
        {:DOWN, ^ref, :process, ^server, _reason} -> :ok
      after
        deadline_ms ->
          sandbox = Conversations._unsafe_get_sandbox!(sandbox_id)

          if sandbox.status in ["pending", "starting"] do
            Logger.error(
              "conv #{conv_id}: provisioning exceeded #{deadline_ms}ms; " <>
                "failing the sandbox and killing the stuck server"
            )

            # Rows BEFORE the kill (#394). The server is restart: :transient
            # and :killed is an abnormal exit, so a kill-first ordering let
            # Horde restart it into handle_continue(:provision) while the row
            # still said pending — and the restart re-provisioned a second
            # billable sprite, then kept streaming into it while this stale
            # struct's late "failed" write made the row lie about it. With
            # the terminal status committed first, a restarted server stops
            # at the terminal-status guard in :provision.
            {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "failed"})

            case Conversations._unsafe_get_conversation(conv_id) do
              %Conversation{status: status} = conv when status not in ["terminated", "failed"] ->
                Conversations.update_conversation(conv, %{status: "failed"})

              _ ->
                :ok
            end

            publish_stage(conv_id, "provision", "failed", %{reason: "provision deadline exceeded"})

            # Prefer supervisor termination over Process.exit: it removes the
            # child, so no restart happens at all, and it bounds the wait —
            # the server traps exits and is stuck in a callback, so the
            # :shutdown signal queues until the child-spec shutdown timeout
            # expires and the supervisor escalates to :kill. terminate/2
            # still does not run for the stuck server; expires_at bounds the
            # un-revoked callback key, and the reaper reclaims the sprite.
            # The fallback covers a server not running under the supervisor
            # (tests) or one that died in the meantime.
            case Horde.DynamicSupervisor.terminate_child(Fountain.ConversationSupervisor, server) do
              :ok -> :ok
              {:error, _} -> Process.exit(server, :kill)
            end

            :telemetry.execute([:fountain, :provision, :deadline_exceeded], %{count: 1}, %{
              conversation_id: conv_id
            })
          end
      end
    end)
  end

  @impl true
  def handle_continue(:provision, state) do
    conv = Conversations._unsafe_get_conversation(state.conversation_id)
    sandbox = state.sandbox_id && Conversations._unsafe_get_sandbox(state.sandbox_id)

    if is_nil(conv) or is_nil(sandbox) do
      # A conversation or sandbox deleted between start_child and this
      # continue used to raise Ecto.NoResultsError — unrescued, in a
      # restart: :transient child, so the supervisor restarted it straight
      # back into the same raise. That burns the supervisor's SHARED
      # restart budget, and exhausting it terminates every conversation on
      # the node. A server whose rows are gone has nothing to provision.
      Logger.warning(
        "conv #{state.conversation_id}: row missing before provisioning " <>
          "(conversation_gone=#{is_nil(conv)}, sandbox_gone=#{is_nil(sandbox)}); stopping"
      )

      {:stop, :normal, state}
    else
      provision_with_rows(state, conv, sandbox)
    end
  end

  defp provision_with_rows(state, conv, sandbox) do
    # Non-bang for the same reason as the rows above: a deleted agent must
    # not crash-loop the server. Provisioning proceeds without it, exactly
    # as for a conversation created with no agent.
    agent = conv.agent_id && Agents._unsafe_get_agent(conv.agent_id)

    if conv.agent_id && is_nil(agent) do
      Logger.warning("conv #{conv.id}: agent #{conv.agent_id} is gone; provisioning without it")
    end

    # Scoped by the conversation's owner even though create/update_agent
    # already validates ownership: a cross-tenant environment_id that
    # predates that check (or slips in through a future path) must not
    # materialise another tenant's secrets or checkpoint here.
    env =
      if agent && agent.environment_id do
        case Environments.get_environment(agent.environment_id, conv.user_id) do
          nil ->
            Logger.warning(
              "Agent #{agent.id} references environment #{agent.environment_id} " <>
                "not owned by user #{conv.user_id}; provisioning without it"
            )

            nil

          env ->
            env
        end
      end

    vault = if conv.vault_id, do: Vaults._unsafe_get_vault(conv.vault_id)

    case load_tenant_state(conv.user_id) do
      {:ok, dek, inference_creds} ->
        secrets = merge_secrets(env, vault, dek)

        state =
          %{
            state
            | user_id: conv.user_id,
              runtime_session_id: conv.runtime_session_id,
              tenant_key: dek,
              inference_credentials: inference_creds
          }

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

          # Dated from the sandbox row, not from now, so the absolute lifetime
          # ceiling survives a restart and a reattach rather than resetting.
          new_state = %{
            state
            | sprite: sprite,
              sprite_env: sprite_env,
              sandbox_started_at: sandbox.inserted_at
          }

          # Any prompt this conversation was started for arrives as a cast,
          # already queued behind this handle_continue. See
          # queue_initial_prompt/3.
          {:noreply, new_state}
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
               ) do
          run_setup_script(sprite, env, sprite_env, conv_id)
        end
    end
  end

  defp attempt_warm_start(_sprite, nil, _conv_id), do: :cold
  defp attempt_warm_start(_sprite, %{checkpoint_id: nil}, _conv_id), do: :cold
  defp attempt_warm_start(_sprite, %{checkpoint_id: ""}, _conv_id), do: :cold

  defp attempt_warm_start(sprite, %{checkpoint_id: id} = env, conv_id) do
    publish_stage(conv_id, "checkpoint_restore", "started", %{checkpoint_id: id})

    # `restore_checkpoint/2` returns a bare `:ok` — `Fountain.Telemetry.span/3`
    # unwraps the `{result, metadata}` pair it is given, so the `{:ok, _}` this
    # used to match never occurred and a successful restore raised
    # CaseClauseError. Latent only because #652 kept `checkpoint_id` nil, so
    # this branch was unreachable.
    case Fountain.Conversations.Provisioning.restore_checkpoint(sprite, id) do
      ok when ok == :ok or (is_tuple(ok) and elem(ok, 0) == :ok) ->
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
        Fountain.Environments.update_environment(env, %{"checkpoint_id" => nil},
          actor: "system:conversation_server"
        )

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

  # No catch-all clause: callers pass nil or an %Environment{}, both covered
  # above. A new caller passing anything else should crash loudly here rather
  # than silently skip checkpointing.

  # Off by default since #654: a checkpoint id is scoped to the sprite that
  # created it, and an environment's checkpoint is only ever restored into a
  # *different* sprite (sandboxes are per-conversation, with a fresh name each
  # time). Measured against the API — a fresh sprite lists only `Current`, and
  # restoring another sprite's `v1` answers `checkpoint not found: checkpoint
  # with path checkpoints/v1 not found`. So the warm start this feature exists
  # for cannot happen, and creating checkpoints only spends time and storage to
  # record an id that every later conversation will fail to restore.
  #
  # Left as a flag rather than deleted: if the platform grows a fork-from-
  # checkpoint or create-sprite-from-checkpoint call, this becomes a one-line
  # re-enable plus a restore that can finally work.
  defp checkpoint_creation_enabled? do
    Application.get_env(:fountain, :checkpoint_creation_enabled, false)
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

    case Fountain.Retry.with_backoff(
           fn -> Sprites.get_sprite(client, sandbox.sprite_name) end,
           label: "sprite lookup on wake"
         ) do
      {:ok, _info} ->
        sprite = Sprites.sprite(client, sandbox.sprite_name)
        {state, _conv} = rotate_callback_api_key(state, conv)
        sprite_env = build_sprite_env(state, agent, env, secrets)

        # Refresh the .env file in case secrets/env_vars were edited
        # between the original provision and this reattach.
        Fountain.Conversations.Provisioning.write_env_file(sprite, sprite_env)

        new_state = %{
          state
          | sprite: sprite,
            sprite_env: sprite_env,
            sandbox_started_at: sandbox.inserted_at
        }

        new_state = reattach_running_turn(new_state)

        {:noreply, new_state}

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
      case Fountain.Retry.with_backoff(fn -> Sprites.list_sessions(state.sprite) end,
             label: "session list on reattach"
           ) do
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
          Conversations._unsafe_output_bytes_by_stream(state.conversation_id, running_turn.id)

        publish_stage(state.conversation_id, "reattach", "done", %{
          outcome: "session_attached",
          session_id: session.id,
          turn_id: running_turn.id,
          turn_number: running_turn.turn_number,
          replay_skip_bytes: replay_skip
        })

        conv = Conversations._unsafe_get_conversation!(state.conversation_id)
        {:ok, _} = Conversations.update_conversation(conv, %{status: "running"})

        # turn_metrics stays nil on purpose, so this turn contributes no
        # duration sample (#536). Its start is in a previous BEAM lifetime:
        # monotonic time isn't comparable across a restart, and measuring
        # from the row's started_at would fold the whole deploy gap into the
        # histogram. A missing sample beats a wrong one.
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
      Conversations._unsafe_update_turn(running_turn, %{
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
    state
    |> do_build_sprite_env(agent, env, secrets)
    |> tap(fn sprite_env ->
      # Register before anything can log. Provisioning writes output from its
      # very first step, and the secrets are already in the sprite by then.
      Fountain.Conversations.Redaction.put(state.conversation_id, sprite_env)
    end)
  end

  defp do_build_sprite_env(state, agent, env, secrets) do
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

  defp conversation_env(conv_id) when is_binary(conv_id),
    do: [{"FOUNTAIN_CONVERSATION_ID", conv_id}]

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

    with :ok <- prepare_acp_adapter(sprite, agent, sprite_env) do
      if function_exported?(runtime_module, :prepare_sprite, 3) do
        runtime_module.prepare_sprite(sprite, agent, sprite_env)
      else
        :ok
      end
    end
  end

  # The adapter is an npm install, so it has to happen here rather than at
  # spawn: by the time a turn runs, the network policy has been applied and the
  # install would fail in a way that reads as a protocol bug.
  defp prepare_acp_adapter(sprite, agent, sprite_env) do
    if Fountain.Runtimes.ACP.enabled?(agent) do
      Fountain.Runtimes.ACP.install(sprite, sprite_env)
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

      case turn_gate(conv.user_id) do
        :ok ->
          agent = if conv.agent_id, do: Agents._unsafe_get_agent!(conv.agent_id)
          {:reply, :ok, kick_turn(state, prompt, agent, images)}

        {:error, _} = err ->
          {:reply, err, state}
      end
    end
  end

  def handle_call(:interrupt, _from, %{current_command: nil} = state) do
    {:reply, {:error, :idle}, state}
  end

  def handle_call(:interrupt, _from, state) do
    # Tell the agent before killing its process. `session/cancel` is a
    # notification with no reply, so this costs one write and does not delay the
    # kill below — but it is the difference between an agent that stops its
    # tool calls and one that is shot mid-write. This is the other reason stdin
    # stays open on the ACP path.
    if state.acp_peer, do: Fountain.Runtimes.ACP.Peer.cancel(state.acp_peer)

    cmd_pid = state.current_command.pid

    if Process.alive?(cmd_pid) do
      try do
        GenServer.stop(cmd_pid, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end
    end

    {:ok, _turn} =
      Conversations._unsafe_update_turn(state.current_turn, %{
        status: "interrupted",
        ended_at: now()
      })

    publish_stage(state.conversation_id, "turn", "interrupted", %{
      turn_id: state.current_turn.id,
      turn_number: state.current_turn.turn_number
    })

    # Finalize stream tracer: close any tool spans still open (abandoned calls).
    Fountain.Runtimes.Claude.StreamTracer.finalize(state.stream_tracer)

    # An ACP turn can also end here — the adapter exits, is interrupted, or its
    # socket drops before it ever answers `session/prompt`. The peer has nothing
    # left to drive and must not outlive the turn.
    stop_acp_peer(state)

    end_turn_span(state.current_turn_span, :error, %{"outcome" => "interrupted"})

    emit_turn_completed(state, "interrupted")

    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
    {:ok, _} = Conversations.update_conversation(conv, %{status: "idle"})

    {:reply, :ok,
     %{
       state
       | current_command: nil,
         current_command_ref: nil,
         current_turn: nil,
         current_turn_span: nil,
         turn_metrics: nil,
         stream_tracer: nil,
         acp_peer: nil,
         acp_peer_mon: nil
     }}
  end

  def handle_call(:terminate_conv, _from, state) do
    if state.sprite, do: _ = Sprites.destroy(state.sprite)
    sandbox = Conversations._unsafe_get_sandbox!(state.sandbox_id)

    {:ok, _} =
      Conversations.update_sandbox(sandbox, %{status: "terminated", terminated_at: now()})

    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
    {:ok, _} = Conversations.update_conversation(conv, %{status: "terminated"})
    publish_stage(state.conversation_id, "terminate", "done")
    {:stop, :normal, :ok, state}
  end

  # Catch-all: an unmatched call must not die with a FunctionClauseError at
  # the callback head — that exception's message embeds the full state
  # (plaintext secrets included) in the crash report, and format_status/1
  # cannot redact an exception message (#315).
  def handle_call(msg, _from, state) do
    Logger.warning("conv #{state.conversation_id}: unexpected call #{inspect(msg)}")
    {:reply, {:error, :unknown_call}, state}
  end

  # The prompt a conversation was started for. Ignored if a turn is somehow
  # already running — the cast is queued behind provisioning, so that should not
  # happen, and re-running is the failure this whole mechanism exists to avoid.
  @impl true
  def handle_cast({:initial_prompt, prompt, images}, state) do
    if state.current_command do
      Logger.warning(
        "conv #{state.conversation_id}: initial prompt arrived while a turn was running; dropping it"
      )

      {:noreply, state}
    else
      conv = Conversations._unsafe_get_conversation!(state.conversation_id)

      case turn_gate(conv.user_id) do
        :ok ->
          agent = if conv.agent_id, do: Agents._unsafe_get_agent!(conv.agent_id)
          {:noreply, kick_turn(state, prompt, agent, images)}

        {:error, reason} ->
          # No caller to reply to — the wake door reports the same refusal
          # synchronously; this backstop only has to not run the turn.
          Logger.info(
            "conv #{state.conversation_id}: dropping initial prompt (#{inspect(reason)})"
          )

          {:noreply, state}
      end
    end
  end

  # Catch-all for the same reason as the handle_call one above (#315).
  def handle_cast(msg, state) do
    Logger.warning("conv #{state.conversation_id}: unexpected cast #{inspect(msg)}")
    {:noreply, state}
  end

  # ACP path: stdout is protocol, not transcript. The peer frames it, decides
  # what is worth keeping and reports that back as `{:acp, ref, _}` — a
  # JSON-RPC response to `initialize` is not something a user should find in
  # their conversation, and a `session/load` replay is history we already hold.
  @impl true
  def handle_info(
        {:stdout, %{ref: ref}, data},
        %{current_command_ref: ref, acp_peer: peer} = state
      )
      when is_pid(peer) do
    Fountain.Runtimes.ACP.Peer.stdout(peer, data)
    {:noreply, maybe_emit_first_output(state)}
  end

  def handle_info({:stdout, %{ref: ref}, data}, %{current_command_ref: ref} = state) do
    state = maybe_emit_first_output(state)
    new_state = log_with_replay_skip(state, "stdout", data)

    # Feed non-replayed bytes into the stream tracer (Claude only).
    # Replayed bytes were already processed in a prior BEAM lifetime; skip them
    # to avoid duplicate spans. The replay window shrinks as we consume bytes,
    # so we compute how much of this chunk is genuinely new.
    skip = Map.get(state.replay_skip, "stdout", 0)
    size = byte_size(data)

    new_tracer =
      cond do
        is_nil(state.stream_tracer) ->
          nil

        skip == 0 ->
          Fountain.Runtimes.Claude.StreamTracer.handle_chunk(state.stream_tracer, data)

        skip >= size ->
          # Entire chunk is replayed — discard.
          state.stream_tracer

        true ->
          # Partial replay: only forward the fresh suffix.
          Fountain.Runtimes.Claude.StreamTracer.handle_chunk(
            state.stream_tracer,
            binary_part(data, skip, size - skip)
          )
      end

    {:noreply, %{new_state | stream_tracer: new_tracer}}
  end

  def handle_info({:stderr, %{ref: ref}, data}, %{current_command_ref: ref} = state) do
    {:noreply, log_with_replay_skip(state, "stderr", data)}
  end

  # ── ACP peer reports (0014 gate 2) ────────────────────────────────────────

  # Persisting goes through the server's own path so the ACP stream inherits
  # the log budget, the redaction pass and the replay skip. A peer writing rows
  # itself would bypass all three.
  def handle_info({:acp, ref, {:lines, stream, data}}, %{current_command_ref: ref} = state) do
    {:noreply, log_with_replay_skip(state, stream, data)}
  end

  # `session/new` chose an id. Persisted immediately, exactly as the legacy path
  # persists one before spawning: it is what the next turn resumes by, and a
  # server restart between here and the end of the turn must not lose it.
  def handle_info({:acp, ref, {:session, id}}, %{current_command_ref: ref} = state) do
    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
    {:ok, _} = Conversations.update_conversation(conv, %{runtime_session_id: id})
    {:noreply, %{state | runtime_session_id: id}}
  end

  # The number gate 2 exists to produce: what a turn pays for `initialize` plus
  # resumption, which the legacy path does not pay at all. Emitted per turn so
  # the cost of a disposable sandbox is measurable rather than argued about.
  #
  # Also stamped on the turn's OTel span, because the comparison that decides
  # the gate is against *this same turn's* total — a handshake figure in an
  # unrelated metrics stream tells you the cost but not the share.
  def handle_info({:acp, ref, {:handshake_ms, ms, method}}, %{current_command_ref: ref} = state) do
    :telemetry.execute([:fountain, :acp, :handshake], %{duration_ms: ms}, %{
      conversation_id: state.conversation_id,
      turn_id: state.current_turn && state.current_turn.id,
      method: method
    })

    stamp_turn_span(state.current_turn_span, %{
      "acp.handshake_ms" => ms,
      "acp.session_method" => method
    })

    {:noreply, state}
  end

  # The turn's first terminator: `session/prompt` answered with a stop reason.
  # Closing stdin here is what makes the adapter exit, and clearing the command
  # ref is what makes that exit a no-op instead of a second ending.
  def handle_info({:acp, ref, {:done, stop_reason}}, %{current_command_ref: ref} = state) do
    status = if stop_reason in ["refusal", "cancelled"], do: "failed", else: "completed"

    {:noreply,
     finish_acp_turn(state, status, %{"stop_reason" => stop_reason}, %{
       stop_reason: stop_reason
     })}
  end

  def handle_info({:acp, ref, {:failed, reason}}, %{current_command_ref: ref} = state) do
    Logger.error("conv #{state.conversation_id}: acp peer failed: #{inspect(reason)}")

    {:noreply,
     finish_acp_turn(state, "failed", %{"error" => inspect(reason)}, %{
       reason: "acp: #{inspect(reason)}"
     })}
  end

  # A report from a superseded turn's peer. The turn it belonged to is already
  # over; acting on it would end the *current* one.
  def handle_info({:acp, _stale_ref, _payload}, state), do: {:noreply, state}

  # The peer died without reporting. Whatever it was, the turn has no driver
  # any more, and leaving `current_command` set is the #413 shape: every prompt
  # answered `:busy`, idle reclaim suppressed, sprite billing to the ceiling.
  def handle_info(
        {:DOWN, mon, :process, _pid, reason},
        %{acp_peer_mon: mon, current_turn: turn} = state
      )
      when not is_nil(turn) do
    Logger.error("conv #{state.conversation_id}: acp peer down: #{inspect(reason)}")

    {:noreply,
     finish_acp_turn(state, "failed", %{"error" => "peer_down"}, %{
       reason: "acp peer down: #{inspect(reason)}"
     })}
  end

  def handle_info({:DOWN, mon, :process, _pid, _reason}, %{acp_peer_mon: mon} = state) do
    {:noreply, %{state | acp_peer: nil, acp_peer_mon: nil}}
  end

  def handle_info({:exit, %{ref: ref}, code}, %{current_command_ref: ref} = state) do
    turn = state.current_turn

    {:ok, turn} =
      Conversations._unsafe_update_turn(turn, %{
        status: if(code == 0, do: "completed", else: "failed"),
        exit_code: code,
        ended_at: now()
      })

    publish_stage(state.conversation_id, "turn", "done", %{
      turn_id: turn.id,
      turn_number: turn.turn_number,
      exit_code: code
    })

    # Finalize stream tracer: close any tool spans still open (abandoned calls).
    Fountain.Runtimes.Claude.StreamTracer.finalize(state.stream_tracer)

    # An ACP turn can also end here — the adapter exits, is interrupted, or its
    # socket drops before it ever answers `session/prompt`. The peer has nothing
    # left to drive and must not outlive the turn.
    stop_acp_peer(state)

    # Close the OTel turn span we opened in kick_turn.
    end_turn_span(
      state.current_turn_span,
      if(code == 0, do: :ok, else: :error),
      %{"exit_code" => code}
    )

    emit_turn_completed(state, turn.status)

    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
    {:ok, _} = Conversations.update_conversation(conv, %{status: "idle"})

    {:noreply,
     %{
       touch_activity(state)
       | current_command: nil,
         current_command_ref: nil,
         current_turn: nil,
         current_turn_span: nil,
         turn_metrics: nil,
         stream_tracer: nil,
         acp_peer: nil,
         acp_peer_mon: nil
     }}
  end

  # An error naming the CURRENT command is terminal for the turn (#413):
  # Sprites.Command sends it when the WebSocket to the sprite drops mid-run,
  # then stops — and since the command process is neither linked nor
  # monitored, this message is the only signal there will ever be. Ignoring
  # it left current_command set forever: every prompt answered {:error,
  # :busy}, idle reclaim was suppressed (busy? true), the reaper skipped the
  # sandbox (server alive), and the sprite billed until max_lifetime. Fail
  # the turn and return to idle, exactly like a non-zero :exit.
  def handle_info({:error, %{ref: ref}, reason}, %{current_command_ref: ref} = state)
      when not is_nil(ref) do
    Logger.error("sprite command error mid-turn: #{inspect(reason)} — failing the turn")

    {:ok, turn} =
      Conversations._unsafe_update_turn(state.current_turn, %{
        status: "failed",
        ended_at: now()
      })

    publish_stage(state.conversation_id, "turn", "failed", %{
      turn_id: turn.id,
      turn_number: turn.turn_number,
      reason: "sprite connection lost: #{inspect(reason)}"
    })

    Fountain.Runtimes.Claude.StreamTracer.finalize(state.stream_tracer)

    # An ACP turn can also end here — the adapter exits, is interrupted, or its
    # socket drops before it ever answers `session/prompt`. The peer has nothing
    # left to drive and must not outlive the turn.
    stop_acp_peer(state)
    end_turn_span(state.current_turn_span, :error, %{"error" => inspect(reason)})

    emit_turn_completed(state, turn.status)

    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
    {:ok, _} = Conversations.update_conversation(conv, %{status: "idle"})

    {:noreply,
     %{
       touch_activity(state)
       | current_command: nil,
         current_command_ref: nil,
         current_turn: nil,
         current_turn_span: nil,
         turn_metrics: nil,
         stream_tracer: nil,
         acp_peer: nil,
         acp_peer_mon: nil
     }}
  end

  # A stale ref — an error from a command already superseded or finished.
  def handle_info({:error, _ref, reason}, state) do
    Logger.error("sprite command error: #{inspect(reason)}")
    {:noreply, state}
  end

  # ── sandbox lifetime ──────────────────────────────────────────────────────

  def handle_info(:lifecycle_check, state) do
    schedule_lifecycle_check()

    started_at = state.sandbox_started_at

    cond do
      # No sprite yet: provisioning is still in flight and there is nothing to
      # reclaim. The reaper handles a provision that never finishes.
      is_nil(started_at) ->
        {:noreply, state}

      true ->
        case Lifecycle.check(started_at, state.last_activity_at, state.current_command != nil) do
          {:expired, reason} -> reclaim_sandbox(state, reason)
          :ok -> {:noreply, state}
        end
    end
  end

  # trap_exit is on (see init/1), so exit signals from linked processes
  # arrive here instead of killing the server outright. Preserve the
  # pre-trap semantics: a linked crash still takes the server down (through
  # terminate/2, which is the point), a :normal exit is ignored. Exits from
  # the parent supervisor never reach this clause — OTP intercepts those
  # and calls terminate/2 directly.
  def handle_info({:EXIT, _from, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _from, reason}, state), do: {:stop, reason, state}

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_lifecycle_check do
    # Interval overridable in tests so the timer wiring itself is testable —
    # dropping schedule_lifecycle_check() from init/1 used to pass the whole
    # suite (#337) while silently disabling idle/max-lifetime reclamation.
    interval = Application.get_env(:fountain, :lifecycle_check_ms, @lifecycle_check_ms)
    Process.send_after(self(), :lifecycle_check, interval)
  end

  defp touch_activity(state), do: %{state | last_activity_at: DateTime.utc_now()}

  # Tear down the sprite and stop, leaving the conversation `idle` so the next
  # prompt wakes it with a fresh sandbox. Setting the conversation `terminated`
  # here would make it permanently unresumable — a cost control turning into
  # data loss. See Fountain.Conversations.Lifecycle.
  defp reclaim_sandbox(state, reason) do
    Logger.info(
      "reclaiming sandbox for conv #{state.conversation_id}: #{reason} " <>
        "(sprite #{inspect(state.sprite && state.sprite.name)})"
    )

    if state.sprite, do: _ = Sprites.destroy(state.sprite)

    if state.sandbox_id do
      sandbox = Conversations._unsafe_get_sandbox!(state.sandbox_id)

      if sandbox.status not in ["terminated", "failed"] do
        {:ok, _} =
          Conversations.update_sandbox(sandbox, %{status: "terminated", terminated_at: now()})
      end
    end

    # The conversation stays idle and resumable; only the sandbox is gone.
    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
    if conv.status == "running", do: Conversations.update_conversation(conv, %{status: "idle"})

    # `state` is a stage-lifecycle vocabulary — LogEvent allows only
    # started/done/failed/interrupted, and both the CLI and the LiveView switch
    # on it. A reclaimed sandbox is a stage that reached its end, so "done" is
    # accurate and needs no client to learn a new word; the `reason` and
    # `message` fields carry what actually happened. The new part clients key on
    # is the "sandbox" stage itself.
    publish_stage(state.conversation_id, "sandbox", "done", %{
      event: "reclaimed",
      reason: to_string(reason),
      message: Lifecycle.explain(reason)
    })

    :telemetry.execute([:fountain, :sandbox, :reclaimed], %{count: 1}, %{reason: reason})

    {:stop, :normal, %{state | sprite: nil}}
  end

  # Best-effort revoke of the per-conversation API key when this server
  # exits — clean termination (`:terminate_conv`), crash paths that hit
  # `{:stop, :normal, state}`, and (because init/1 traps exits, #322)
  # supervisor shutdown on deploys and Horde rebalances.
  #
  # Revokes only the key THIS server minted, and only while the
  # conversation row still points at it. Reading the row's id at call time
  # made a dying duplicate (Horde's CRDT merge mass-terminates losers)
  # revoke the SURVIVING server's live credential — its sprite then 401'd
  # on every callback and sub-agent spawn, surfaced nowhere. If the row has
  # moved past our key, a successor owns the live credential and ours is
  # already dead or inert.
  #
  # If the BEAM crashes hard (SIGKILL — untrappable) the row in `api_keys`
  # is left behind, but it is not dangerous: `callback_api_key_opts/0`
  # sets an `expires_at`, so an un-revoked key stops authenticating on its
  # own, and RetentionPruner deletes long-expired rows. See SandboxReaper
  # for the sprite half, which does not self-heal.
  @impl true
  def terminate(_reason, state) do
    Fountain.Conversations.Redaction.delete(state.conversation_id)

    if state.conversation_id && state.callback_api_key_id do
      case Conversations._unsafe_get_conversation(state.conversation_id) do
        %Conversation{user_id: user_id, callback_api_key_id: row_id}
        when is_binary(user_id) and row_id == state.callback_api_key_id ->
          _ =
            Accounts.revoke_api_key(user_id, state.callback_api_key_id,
              actor: "system:conversation_server"
            )

        _ ->
          :ok
      end
    end

    :ok
  end

  # Redacts secrets from crash reports and :sys.get_status output (#315). An
  # unhandled raise in any callback logs `State:` via inspect — without this,
  # that meant plaintext env secrets, the raw tenant DEK, decrypted BYO
  # inference credentials, the callback API key, and the platform Sprites
  # token (inside sprite.client) on stdout and, with SENTRY_DSN set, in a
  # Sentry event body. Sentry's PlugContext scrubbing never sees process
  # crash reports, so the redaction has to happen here.
  #
  # Key names are kept (values replaced) so crash reports stay debuggable.
  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, %{conversation_id: _} = state} -> {:state, redact_state(state)}
      other -> other
    end)
  end

  defp redact_state(state) do
    %{
      state
      | sprite: redact_sprite(state.sprite),
        sprite_env: Enum.map(state.sprite_env, fn {k, _v} -> {k, "[REDACTED]"} end),
        tenant_key: redact(state.tenant_key),
        inference_credentials: redact_map(state.inference_credentials),
        callback_token: redact(state.callback_token)
    }
  end

  defp redact_sprite(%{client: _} = sprite), do: Map.put(sprite, :client, "[REDACTED]")
  defp redact_sprite(other), do: other

  defp redact_map(%{} = map), do: Map.new(map, fn {k, _v} -> {k, "[REDACTED]"} end)
  defp redact_map(other), do: redact(other)

  defp redact(nil), do: nil
  defp redact(_present), do: "[REDACTED]"

  # ── helpers ───────────────────────────────────────────────────────────────

  defp create_sprite(name) do
    client = SpritesClient.get!()

    Fountain.Retry.with_backoff(
      fn ->
        case Sprites.create(client, name) do
          # A 409 means a sprite with this name already exists. Names are
          # unique per sandbox row, so the only way that happens is an earlier
          # attempt that created it but lost the response — adopt it.
          {:error, {:api_error, 409, _body}} -> {:ok, Sprites.sprite(client, name)}
          other -> other
        end
      end,
      label: "sprite create #{name}"
    )
  end

  # The `x != ""` guards here defend against operator configuration, not against
  # types. Dialyzer proves them always-true from today's success typings —
  # `PublicUrl.base/0` cannot currently return `""` — and flags both the
  # comparison (`exact_compare`) and the `if`'s consequently-dead else branch
  # (`pattern_match`). The guards stay: a future config path that yields an
  # empty base or token must produce no callback env, not a sprite told to call
  # back to `""`.
  #
  # Suppressed here rather than in `.dialyzer_ignore.exs` because that file
  # pins by `{line, column}`, and this function sits near the bottom of a
  # 1400-line module: the pin moved three times during #540 alone, each time
  # failing the build with a misleading "Unnecessary Skips: 1" that reads like
  # a stale suppression rather than "you added lines above". A function-scoped
  # attribute travels with the code it describes and is narrower than the
  # file-wide alternative.
  @dialyzer {:nowarn_function, fountain_callback_env: 1}
  defp fountain_callback_env(token) do
    base = Fountain.PublicUrl.base()

    if is_binary(base) and base != "" and is_binary(token) and token != "" do
      [{"FOUNTAIN_BASE_URL", base}, {"FOUNTAIN_TOKEN", token}]
    else
      []
    end
  end

  # How long a sprite's callback key stays valid.
  #
  # This is a backstop, not the primary control: the key is revoked at
  # terminate/2 and rotated on every provision and reattach, so under normal
  # operation it is replaced long before expiry. It exists for the hard-crash
  # case, where the row is orphaned and would otherwise be valid forever.
  #
  # The default is deliberately generous. The token is only rotated on provision
  # and reattach, so a TTL shorter than the longest continuously-running
  # conversation would expire a token mid-flight and break the agent's callbacks
  # — a worse failure than a long-lived orphan. Lower it if conversations in your
  # deployment are short.
  @default_callback_key_ttl_seconds 30 * 24 * 60 * 60

  defp callback_key_ttl_seconds do
    Application.get_env(:fountain, :callback_key_ttl_seconds, @default_callback_key_ttl_seconds)
  end

  @doc """
  Options used when minting a sprite's callback key.

  `"sprite"` scope, not full: the sandbox can stream, prompt and spawn
  sub-agents, but cannot mint a key that would survive the revoke at teardown.
  The expiry is a backstop for the orphan case — if the BEAM dies hard the row
  is never revoked, and without it the key stays valid forever.

  Public so the scope and expiry can be asserted directly: this module has no
  test coverage of its own (#192), and an unscoped callback token is the
  privilege-escalation path the scoping exists to close.
  """
  def callback_api_key_opts do
    [
      scopes: ["sprite"],
      expires_at:
        DateTime.utc_now()
        |> DateTime.add(callback_key_ttl_seconds(), :second)
        |> DateTime.truncate(:second),
      # Minting a sprite credential is exactly the event the trail is for, and
      # this is the one mint the account owner did not ask for by hand. Low
      # volume by construction: rotation happens on fresh provision and on
      # wake, not per turn.
      actor: "system:conversation_server"
    ]
  end

  # Issue a fresh per-conversation API key scoped to the conversation
  # owner, revoking the one THIS server previously minted (a re-provision
  # or reattach within one server life). The plaintext is only kept in
  # `state.callback_token` — the durable record is a hash in `api_keys`,
  # which we can't reverse, so we rotate on every fresh provision /
  # reattach instead of trying to recover the old plaintext.
  #
  # Deliberately NOT revoking `conv.callback_api_key_id` when it isn't
  # ours: with duplicate servers (registry lag, #367), the row's id can be
  # the live credential of the other server's sprite — revoking it 401s
  # every callback and sub-agent spawn there, surfaced nowhere. A
  # predecessor's un-revoked key goes inert at its `expires_at` and its
  # row is pruned by RetentionPruner.
  defp rotate_callback_api_key(state, %Conversation{} = conv) do
    if id = state.callback_api_key_id do
      _ = Accounts.revoke_api_key(conv.user_id, id, actor: "system:conversation_server")
    end

    case Accounts.create_api_key(
           conv.user_id,
           "sprite:#{String.slice(conv.id, 0, 8)}",
           callback_api_key_opts()
         ) do
      {:ok, {%Accounts.ApiKey{id: key_id}, raw}} ->
        {:ok, conv} = Conversations.update_conversation(conv, %{callback_api_key_id: key_id})
        {%{state | callback_token: raw, callback_api_key_id: key_id}, conv}

      {:error, cs} ->
        Logger.warning(
          "could not issue callback api key for conv #{conv.id}: #{inspect(cs.errors)}"
        )

        {%{state | callback_token: nil}, conv}
    end
  end

  defp kick_turn(state, prompt, agent, images) do
    state = touch_activity(state)
    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
    turn_number = Conversations._unsafe_next_turn_number(state.conversation_id)

    {:ok, turn} =
      Conversations._unsafe_create_turn(%{
        conversation_id: conv.id,
        turn_number: turn_number,
        prompt: prompt,
        status: "running",
        started_at: now()
      })

    # Store images. A rejected image must not take the turn down with it: this
    # used to hard-match {:ok, _}, which is why validation could not be added to
    # the insert path without crashing the server mid-turn.
    case Conversations._unsafe_insert_turn_images(turn.id, images) do
      {:ok, _count} ->
        :ok

      {:error, changeset} ->
        # Log only. A `turn`/`started` stage event is what the LiveView uses to
        # create a turn row, so publishing one here would invent a second turn.
        Logger.warning(
          "turn #{turn.id}: image rejected, continuing without it: " <>
            inspect(changeset.errors)
        )

        :ok
    end

    # On the first turn, asynchronously generate a short title for the sidebar.
    if turn.turn_number == 1 do
      conv_id = state.conversation_id
      creds = state.inference_credentials

      Task.start(fn ->
        case Fountain.Conversations.TitleGenerator.generate(prompt, creds) do
          {:ok, title} ->
            fresh = Conversations._unsafe_get_conversation!(conv_id)
            Conversations.update_conversation(fresh, %{title: title})

          {:error, reason} ->
            Logger.warning("Title generation failed for conv #{conv_id}: #{inspect(reason)}")
        end
      end)
    end

    acp? = Fountain.Runtimes.ACP.enabled?(agent)

    # Write image temp files to sprite. Only on the legacy path: ACP carries
    # images as content blocks inside `session/prompt`, so writing them into
    # the sandbox first would be a round trip whose product nothing reads.
    image_paths = if acp?, do: [], else: write_image_temp_files(state.sprite, turn.id, images)

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

    # 0014 gate 2: when the agent has opted in and its runtime is one gate 1
    # cleared, the turn spawns an ACP adapter instead of the CLI. Everything
    # about the turn — the prompt, the images, the session id, the mode —
    # travels over the protocol rather than in argv, so `build_command/5` is
    # not consulted at all on this path.
    {cmd, args, build_opts} =
      if acp? do
        {c, a} = Fountain.Runtimes.ACP.command()
        {c, a, stdin?: true}
      else
        state.runtime_module.build_command(agent, prompt, mode, runtime_session_id,
          images: image_paths
        )
      end

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
          "model" => agent && agent.model,
          "agent_id" => agent && agent.id,
          "user_id" => state.user_id,
          "prompt_length" => byte_size(prompt),
          "image_count" => length(images)
        }
      })

    previous_span = OpenTelemetry.Tracer.set_current_span(turn_span)

    # Stamped before the spawn so the duration covers the round trip to
    # sprites.dev — that latency is part of what the user waits through.
    # Kept local until the spawn succeeds: a spawn that never starts has no
    # run to time, and a stamp left in state would attach itself to the
    # next turn.
    turn_started_mono = System.monotonic_time(:millisecond)

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
          # SpriteStdin.write/2 rather than Sprites.write/2: the latter exits
          # its caller when the runtime has already gone, and this process
          # being mid-turn is exactly what turned that into an orphaned turn
          # (#603). See `Fountain.SpriteStdin` for the whole chain.
          # On the ACP path stdin stays **open**: it is the return path for
          # `session/request_permission` answers and `session/cancel`, and the
          # peer writes the prompt itself as `session/prompt`. Closing it here
          # would hang up on the agent mid-handshake. It is closed when the
          # turn ends — see `finish_turn/4`.
          stdin_result =
            cond do
              acp? -> :ok
              use_stdin? -> write_prompt_and_close(command, prompt <> prompt_suffix)
              true -> :ok
            end

          case stdin_result do
            :ok ->
              # Start a stream tracer for Claude (stream-json → OTel child spans).
              # Other runtimes produce unstructured output; tracer stays nil.
              stream_tracer =
                if not acp? and state.runtime_module == Fountain.Runtimes.Claude do
                  Fountain.Runtimes.Claude.StreamTracer.new(turn_span)
                end

              {peer, peer_mon} =
                if acp? do
                  start_acp_peer(command, prompt, mode, runtime_session_id,
                    cwd: cwd,
                    images: images,
                    mcp_servers: Fountain.Runtimes.ACP.mcp_servers(agent)
                  )
                else
                  {nil, nil}
                end

              %{
                state
                | current_command: command,
                  current_command_ref: command.ref,
                  current_turn: turn,
                  runtime_session_id: runtime_session_id,
                  current_turn_span: turn_span,
                  turn_metrics: %{
                    started_mono: turn_started_mono,
                    runtime: conv.runtime,
                    first_output?: false
                  },
                  stream_tracer: stream_tracer,
                  acp_peer: peer,
                  acp_peer_mon: peer_mon
              }

            {:error, reason} ->
              # The runtime exited before it read the prompt, so nothing is
              # running and no output will ever arrive: a spawn-level failure
              # in every way that matters. The turn ends `failed` naming the
              # reason instead of the server dying and its restart orphaning
              # the turn behind a reattach.
              #
              # Take the runtime's exit code and last words with us (#608).
              # `:command_exited` names the mechanism; the code and whatever
              # it printed on the way out are the diagnosis, and they are
              # already sitting in our mailbox.
              {exit_code, output} = drain_exited_command(command.ref)

              fail_turn_before_start(
                state,
                turn,
                reason,
                "prompt write failed",
                exit_code,
                output
              )
          end

        {:error, reason} ->
          fail_turn_before_start(state, turn, reason, "spawn failed")
      end
    after
      # The successful path keeps the span open until :exit; the error
      # path above closes it explicitly. In both cases we restore the
      # caller's previous current-span here.
      OpenTelemetry.Tracer.set_current_span(previous_span)
    end
  end

  # A turn that never got as far as running: either the spawn itself failed,
  # or the runtime exited before the prompt reached its stdin (#603). Both
  # leave nothing running, so both end the same way — the turn `failed` with
  # the reason, a `turn`/`failed` stage event, and the conversation back to
  # "idle".
  #
  # `exit_code` and `output` are what the runtime managed to say before it
  # went (#608); the spawn-failure path has neither, since there was never a
  # process to say anything.
  #
  # Called only from inside kick_turn's try block, which restores the caller's
  # previous current-span in its `after`; the span this ends is the turn span
  # kick_turn opened a few lines above the call.
  defp fail_turn_before_start(state, turn, reason, what, exit_code \\ nil, output \\ []) do
    detail = "#{inspect(reason)}#{exit_detail(exit_code)}"
    Logger.error("#{what}: #{detail}")

    # Persist the runtime's parting words against the turn they explain.
    # current_turn is nil on this path — it is only assigned once the prompt
    # is away — and persist_output reads it for the turn_id, so stand it up
    # for the duration and clear it again before returning.
    state =
      Enum.reduce(output, %{state | current_turn: turn}, fn {stream, data}, acc ->
        log_output(acc, stream, data)
      end)

    {:ok, _} =
      Conversations._unsafe_update_turn(turn, %{
        status: "failed",
        exit_code: exit_code,
        ended_at: now()
      })

    publish_stage(state.conversation_id, "turn", "failed", %{
      turn_id: turn.id,
      reason: detail,
      exit_code: exit_code
    })

    # The conversation was set to "running" just before the spawn attempt;
    # without this it stays "running" in the API and UI until some later turn
    # completes, even though nothing is executing. The :exit and :interrupt
    # handlers both do the same reset.
    failed_conv = Conversations._unsafe_get_conversation!(state.conversation_id)

    if failed_conv.status == "running" do
      {:ok, _} = Conversations.update_conversation(failed_conv, %{status: "idle"})
    end

    # The turn never started; close the span we just opened so it doesn't leak.
    if exit_code, do: OpenTelemetry.Tracer.set_attribute("exit_code", exit_code)
    OpenTelemetry.Tracer.set_status(OpenTelemetry.status(:error, "#{what}: #{detail}"))

    # No-arg: end_span/1 takes a timestamp, not a span. turn_span is the
    # current span here (kick_turn made it current), which is what no-arg ends.
    OpenTelemetry.Tracer.end_span()

    %{state | current_turn: nil}
  end

  # Appended to the reason everywhere it is reported. `:command_exited` stays
  # in front of it: it is what downstream consumers (fountain-ops' e2e gate
  # among them) match on, and it is still true — this only says why.
  defp exit_detail(nil), do: ""
  defp exit_detail(code), do: " (runtime exited #{code})"

  # How long to wait for an exit that is, on this path, already queued.
  @drain_timeout_ms 50

  # Collect what a command said before it stopped: `{exit_code, output}`,
  # with a nil code if no exit arrives.
  #
  # `Sprites.Command` sends the owner `{:exit, %{ref: ref}, code}` — behind
  # any `{:stdout, …}` / `{:stderr, …}` the runtime produced first — and only
  # *then* stops. So when a stdin write comes back `{:error, :command_exited}`
  # it is because that already happened, and those messages are in this
  # server's mailbox as we handle the failure.
  #
  # They have nowhere to land on their own: `current_command_ref` is assigned
  # only on the success branch, so every handler guard misses and the
  # catch-all drops them silently (#608). Receive them here instead, while we
  # still have the ref and a turn to attribute them to. The triggers for this
  # path — a bad flag, a missing binary, an OOM kill, an immediate non-zero
  # exit — are exactly the ones where the code is the whole diagnosis, and
  # for a runtime that prints `invalid api key` and exits 1, that line is the
  # answer.
  #
  # The deadline is absolute rather than per-message: a `receive` timeout
  # restarts on every match, and this runs inside a GenServer callback.
  defp drain_exited_command(ref) do
    drain_exited_command(ref, System.monotonic_time(:millisecond) + @drain_timeout_ms, [])
  end

  defp drain_exited_command(ref, deadline, output) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:exit, %{ref: ^ref}, code} ->
        {code, Enum.reverse(output)}

      {:stdout, %{ref: ^ref}, data} ->
        drain_exited_command(ref, deadline, [{"stdout", data} | output])

      {:stderr, %{ref: ^ref}, data} ->
        drain_exited_command(ref, deadline, [{"stderr", data} | output])
    after
      timeout -> {nil, Enum.reverse(output)}
    end
  end

  # Emit the aggregate turn-duration event (#536). Called from every path
  # that ends a turn which actually ran: the :exit handler, the mid-turn
  # {:error, ...} handler (#413) and :interrupt.
  #
  # The `fountain.turn` OTel span and the turn row's started_at/ended_at
  # both already describe one turn each; neither trends. This is the
  # dashboard/alert signal.
  #
  # Tags are `runtime` (four values, gated by Runtimes.for_runtime/1 on the
  # only path that starts a server) and the terminal `status`
  # (completed/failed/interrupted). conv_id rides along as metadata — it is
  # what makes the JSON log line actionable, and as a tag it would mint a
  # time series per conversation.
  # Time to first token (#535): the gap a user actually feels between
  # hitting enter and seeing the agent do something. Provision time and
  # turn duration are both trended; a regression that delays *first
  # output* — slow runtime startup inside the sprite, model latency,
  # stdin plumbing — sat between them, visible only per-trace in
  # Honeycomb, only for Claude, and only with OTLP export configured.
  #
  # One-shot per turn: the first stdout chunk wins and the flag is set,
  # so the whole rest of a streaming turn costs one map update.
  #
  # First *bytes*, not first parsed token. Only Claude emits structured
  # stream-json; measuring bytes keeps this identical for codex, gemini
  # and opencode. It does mean a runtime that greets on stdout before
  # calling a model reports its own startup — which is still the number
  # the user is waiting on.
  defp maybe_emit_first_output(%{turn_metrics: %{first_output?: false} = metrics} = state) do
    Fountain.Telemetry.event(
      [:turn, :first_output],
      %{runtime: metrics.runtime, conv_id: state.conversation_id},
      %{elapsed_ms: System.monotonic_time(:millisecond) - metrics.started_mono}
    )

    %{state | turn_metrics: %{metrics | first_output?: true}}
  end

  # No turn running, or this turn already reported. Also the reattach case:
  # turn_metrics is nil there, so the replayed output a resumed session
  # opens with can't be mistaken for a first token (its real one arrived in
  # a previous BEAM lifetime).
  defp maybe_emit_first_output(state), do: state

  defp emit_turn_completed(%{turn_metrics: nil}, _status), do: :ok

  defp emit_turn_completed(%{turn_metrics: metrics} = state, status) do
    Fountain.Telemetry.event(
      [:turn, :completed],
      %{runtime: metrics.runtime, status: status, conv_id: state.conversation_id},
      %{duration_ms: System.monotonic_time(:millisecond) - metrics.started_mono}
    )
  end

  # End the OTel turn span (if any) with a status reflecting the
  # outcome. Called from the :exit and :interrupt handlers.
  # Attributes on a turn's span from outside `kick_turn`, which restores the
  # caller's current span in its `after` block — so by the time a peer report
  # arrives the turn span is no longer current and a bare `set_attribute` would
  # land on whatever is.
  defp stamp_turn_span(nil, _attrs), do: :ok

  defp stamp_turn_span(span_ctx, attrs) do
    previous = OpenTelemetry.Tracer.set_current_span(span_ctx)
    Enum.each(attrs, fn {k, v} -> OpenTelemetry.Tracer.set_attribute(to_string(k), v) end)
    OpenTelemetry.Tracer.set_current_span(previous)
    :ok
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

    # No-arg: end_span/1 takes a timestamp, not a span. span_ctx was just
    # made current above, which is what no-arg ends.
    OpenTelemetry.Tracer.end_span()
  end

  # Persist + broadcast one chunk of sandbox output, subject to the
  # per-conversation byte budget (#331). log_events is unbounded per row
  # count and lives on the same Postgres volume the app depends on, so a
  # `while true; do base64 /dev/urandom; done` sandbox was an availability
  # risk, not just a storage bill — retention (#217) bounds age, not rate.
  # Once the budget is exceeded, one truncation marker is persisted and
  # every later chunk is dropped. Dropped rather than broadcast-only:
  # consumers key ordering off the DB-assigned event id, and an unbounded
  # broadcast stream would still let a hostile sandbox saturate PubSub.
  # The legacy stdin dance, unchanged and lifted out so the ACP branch above
  # reads as one condition rather than a nested `if`.
  defp write_prompt_and_close(command, payload) do
    case SpriteStdin.write(command, payload) do
      :ok -> Sprites.close_stdin(command)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_acp_peer(command, prompt, mode, runtime_session_id, opts) do
    {:ok, peer} =
      Fountain.Runtimes.ACP.Peer.start(
        owner: self(),
        command: command,
        ref: command.ref,
        prompt: prompt,
        mode: mode,
        session_id: runtime_session_id,
        cwd: Keyword.get(opts, :cwd) || "/home/sprite",
        images: Keyword.get(opts, :images, []),
        mcp_servers: Keyword.get(opts, :mcp_servers, [])
      )

    {peer, Process.monitor(peer)}
  end

  # Terminal path for an ACP turn. The order matters: stdin closes first so the
  # adapter starts exiting while we do the bookkeeping, and `current_command_ref`
  # is cleared at the end so the `{:exit, …}` that follows finds no match and
  # falls through to the catch-all. A turn ends on the prompt response *or* the
  # process exit, whichever arrives first, and never waits for both.
  defp finish_acp_turn(state, status, span_attrs, stage_meta) do
    if state.current_command, do: Sprites.close_stdin(state.current_command)
    stop_acp_peer(state)

    {:ok, turn} =
      Conversations._unsafe_update_turn(state.current_turn, %{
        status: status,
        ended_at: now()
      })

    publish_stage(
      state.conversation_id,
      "turn",
      if(status == "completed", do: "done", else: "failed"),
      Map.merge(%{turn_id: turn.id, turn_number: turn.turn_number}, stage_meta)
    )

    end_turn_span(
      state.current_turn_span,
      if(status == "completed", do: :ok, else: :error),
      span_attrs
    )

    emit_turn_completed(state, turn.status)

    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
    {:ok, _} = Conversations.update_conversation(conv, %{status: "idle"})

    %{
      touch_activity(state)
      | current_command: nil,
        current_command_ref: nil,
        current_turn: nil,
        current_turn_span: nil,
        turn_metrics: nil,
        stream_tracer: nil,
        acp_peer: nil,
        acp_peer_mon: nil
    }
  end

  # Demonitor before stopping so the peer's own exit does not arrive as a
  # `:DOWN` that fails the turn we just finished.
  defp stop_acp_peer(%{acp_peer: nil}), do: :ok

  defp stop_acp_peer(%{acp_peer: peer, acp_peer_mon: mon}) do
    if mon, do: Process.demonitor(mon, [:flush])
    if Process.alive?(peer), do: GenServer.stop(peer, :normal, 1_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp log_output(state, stream, data) do
    state = ensure_output_bytes(state)
    budget = output_byte_budget()

    cond do
      state.output_capped ->
        state

      budget > 0 and state.output_bytes + byte_size(data) > budget ->
        Logger.warning(
          "conv #{state.conversation_id}: durable output budget " <>
            "(#{budget} bytes) reached; dropping further sandbox output"
        )

        :telemetry.execute([:fountain, :log_output, :capped], %{count: 1}, %{
          conversation_id: state.conversation_id
        })

        persist_output(state, "stderr", cap_marker(budget))
        %{state | output_capped: true}

      true ->
        persist_output(state, stream, data)
        %{state | output_bytes: state.output_bytes + byte_size(data)}
    end
  end

  defp cap_marker(budget) do
    "\n[fountain] This conversation reached its durable log budget of " <>
      "#{div(budget, 1_000_000)} MB. Further sandbox output is discarded — " <>
      "the turn keeps running, and stage events still appear.\n"
  end

  defp ensure_output_bytes(%{output_bytes: nil} = state) do
    %{state | output_bytes: Conversations._unsafe_output_byte_total(state.conversation_id)}
  end

  defp ensure_output_bytes(state), do: state

  # 0 disables the cap.
  defp output_byte_budget do
    Application.get_env(:fountain, :log_output_byte_budget, 50_000_000)
  end

  defp persist_output(state, stream, data) do
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

    if state.user_id do
      Phoenix.PubSub.broadcast(
        Fountain.PubSub,
        "sidebar:#{state.user_id}",
        {:sidebar_update, state.user_id}
      )
    end
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

      skip >= size ->
        put_in(state.replay_skip[stream], skip - size)

      true ->
        state = log_output(state, stream, binary_part(data, skip, size - skip))
        put_in(state.replay_skip[stream], 0)
    end
  end

  defp publish_stage(conv_id, stage, status, meta \\ %{}) do
    Conversations.publish_stage(conv_id, stage, status, meta)
  end

  # Every turn passes through here, whichever door it came in by — the
  # controller/LiveView call above, or the queued initial prompt a wake
  # delivers as a cast. The provisioning gates cover fresh sprites only; a
  # live server (or the reuse arm of a wake) outlives the subscription state
  # it was started under, and each turn resets the idle clock, so an expired
  # trial or failed card otherwise bought up to the 24h max lifetime of
  # continued service per live sandbox (#313). Suspension is the same shape.
  defp turn_gate(user_id) do
    with :ok <- Fountain.Accounts.check_not_suspended(user_id) do
      Fountain.Billing.check_active(user_id)
    end
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
