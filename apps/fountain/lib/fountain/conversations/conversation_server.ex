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
    Substitution,
    Vaults
  }

  alias Fountain.Conversations.{Conversation, HomeCheckpoint, Lifecycle}

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

  @registry_settle_ms 3_000
  @registry_poll_ms 50

  @doc """
  `whereis/1`, but willing to wait for the registry to catch up.

  Horde's registry is a CRDT: a server started on another node is visible
  here only once the delta has synced, which is milliseconds normally and
  longer under load. A caller that already knows a server *should* exist —
  the conversation's sandbox row is `pending`, so someone is provisioning it —
  polls for up to `:conversation_registry_settle_ms` (#{@registry_settle_ms} ms by
  default) before concluding there is none. Returns `{:ok, pid}` or `:timeout`.

  This is what keeps a `session/new` + first-prompt pair from provisioning
  two sprites for one conversation when the two requests land on different
  pods (#800): the prompt used to see a `pending` row, miss the registry, and
  take the `:create_new` arm while the first server was still 20 s from
  finishing.
  """
  def await_registered(conv_id, timeout_ms \\ nil) do
    timeout_ms =
      timeout_ms ||
        Application.get_env(:fountain, :conversation_registry_settle_ms, @registry_settle_ms)

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_registered(conv_id, deadline)
  end

  defp do_await_registered(conv_id, deadline) do
    case whereis(conv_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        if System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(@registry_poll_ms)
          do_await_registered(conv_id, deadline)
        end
    end
  end

  @doc """
  Send another prompt. If the conversation's GenServer is gone (e.g. server
  restart), transparently wake the conversation — provision a fresh sprite
  and queue this prompt as the first turn of the new sandbox.

  The persisted `runtime_session_id` is what the next turn resumes by
  (`session/resume` under ACP). Note that it only carries the conversation
  while the *sandbox* survives: a runtime session lives in the sandbox
  filesystem, so a wake that provisions a fresh sprite cannot resume it. The
  server clears the id when it provisions fresh (#778, `forget_runtime_session`)
  and the next turn starts a new session on the new disk; `log_events` still
  render the whole transcript.
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
  Answer an outstanding permission request (#940).

  Tenant scoping is the caller's job — reach this through
  `Conversations.answer_permission_request/4`, which establishes ownership
  first.

  `{:error, :no_pending_permission}` covers every "too late": another attached
  client answered it, the timeout denied it, the turn ended, or the server is
  no longer running. That is deliberately not distinguished from "never
  existed" — a client that lost the race and a client guessing ids get the same
  answer.
  """
  @spec answer_permission(binary(), String.t(), String.t()) ::
          :ok | {:error, :no_pending_permission | :unknown_option | :not_running}
  def answer_permission(conv_id, request_id, option_id) do
    case whereis(conv_id) do
      nil -> {:error, :not_running}
      pid -> call_server(pid, {:answer_permission, request_id, option_id})
    end
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

              # A sandbox handed on to a successor conversation
              # (`release_conversation/2`) is that conversation's computer now,
              # and a home is the agent's (ADR 0023); terminating this thread
              # must not take either down.
              sandbox_id = conv.sandbox_id

              if is_binary(sandbox_id) and
                   not Conversations._unsafe_sandbox_kept_on_terminate?(sandbox_id, conv.id) do
                sb = Conversations._unsafe_get_sandbox!(sandbox_id)

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

  @doc """
  End the conversation but keep its computer: the conversation goes
  `terminated` (past resuming, its transcript intact), the sandbox row and
  the sprite behind it are left exactly as they are, and this server stops
  holding them. The callback key this server minted is revoked on the way
  out (`terminate/2`), so nothing on the sandbox can act as the retired
  conversation.

  This is how a teammate starts a fresh conversation on the same computer
  (`Fountain.Team.open_fresh_conversation/3`): the successor conversation
  takes the `sandbox_id`, and its first prompt reattaches through the
  ordinary wake path — a new runtime session on the same disk.

  `{:error, :busy}` while a turn is running; nothing is interrupted. With no
  server alive the row alone is marked, the same as `terminate_conversation/2`.
  Audited as `conversation.released` unless `audit: false`.
  """
  def release_conversation(conv_id, opts \\ []) do
    result =
      case whereis(conv_id) do
        nil ->
          case Conversations._unsafe_get_conversation(conv_id) do
            nil ->
              {:error, :not_running}

            conv ->
              {:ok, _} = Conversations.update_conversation(conv, %{status: "terminated"})
              :ok
          end

        pid ->
          call_server(pid, :release_conv)
      end

    audit_lifecycle(conv_id, "conversation.released", result, opts)
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
      handle: nil,
      sprite_env: [],
      # ADR 0019 gate 1a. `brokered` holds the catalog secrets the sandbox
      # never sees (the broker gets them); `broker` is the minted session.
      # Both stay empty/nil on an unbrokered conversation.
      brokered: %{},
      # The tenant's enabled bindings by key (gate 1b), loaded once per
      # provision; what the broker's services are built from.
      broker_bindings: %{},
      broker: nil,
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
      # Timer refusing an unanswered permission request (#940).
      permission_timer: nil,
      acp_peer_mon: nil,
      # Timer closing an autonomous turn that went quiet without a
      # `cycle_end` (#817) — an adapter too old to mark its origin must not
      # hold a turn open forever. nil outside an autonomous turn.
      autonomous_quiet: nil,
      # Bytes of replayed output to drop on reattach, keyed by stream.
      # Empty map outside a reattach window. See attempt_session_attach.
      replay_skip: %{},
      # ACP reattach: the `acp` lines already persisted for the in-flight
      # turn, so the sprite's replayed tail is not written twice. Consumed as
      # matches arrive and cleared on a timer; empty outside a reattach
      # window. See attempt_session_attach.
      replay_dedup: MapSet.new(),
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

    # The conversation's own override wins over the agent's environment (#783);
    # nil falls back to the agent's, resolved fresh each provision.
    #
    # Scoped by the conversation's owner even though create/update_agent and
    # start_conversation already validate ownership: a cross-tenant
    # environment_id that predates that check (or slips in through a future
    # path) must not materialise another tenant's secrets or checkpoint here.
    env_id = conv.environment_id || (agent && agent.environment_id)

    env =
      if env_id do
        case Environments.get_environment(env_id, conv.user_id) do
          nil ->
            Logger.warning(
              "conv #{conv.id}: environment #{env_id} " <>
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
        bindings = broker_bindings(conv.user_id)

        {secrets, brokered} =
          split_brokered(conv.user_id, merge_secrets(env, vault, dek), bindings)

        state =
          %{
            state
            | user_id: conv.user_id,
              runtime_session_id: conv.runtime_session_id,
              tenant_key: dek,
              inference_credentials: inference_creds,
              brokered: brokered,
              broker_bindings: bindings
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
          s when s in ["ready", "suspended"] ->
            # The sprite already exists at sprites.dev and was fully provisioned
            # in a previous BEAM lifetime. Reattach instead of recreating.
            # `suspended` normally becomes `ready` under the quota reservation
            # in wake_conversation before this server starts; seeing it here
            # means the reaper parked the row mid-wake. Reattaching is still
            # right — the catch-all below would provision a second sprite over
            # a live one — and do_reattach flips the row back to ready.
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
    # The row only ever becomes `starting` right here, so finding it already
    # `starting` means an earlier attempt was interrupted mid-provision — a
    # deploy or a Horde rebalance killed the server while it was blocked in
    # this function. The sprite it was building is most likely still there.
    interrupted? = sandbox.status == "starting"

    {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "starting"})

    publish_stage(
      state.conversation_id,
      "provision",
      "started",
      if(interrupted?,
        do: %{retry: "an earlier attempt was interrupted; rebuilding the sandbox"},
        else: %{}
      )
    )

    # A `limited` environment on a backend with no `:network_policy` capability
    # can only fail. It failed closed before, but several steps in, after a
    # sandbox had been created and torn down, and wearing the shape of a
    # transport error. Refuse the pairing here, by name, before anything is
    # provisioned (#935).
    provider = Fountain.Conversations.sandbox_provider_atom(sandbox)

    handle_result =
      with :ok <-
             Fountain.Conversations.Provisioning.check_network_policy_support(
               provider,
               env,
               state.conversation_id
             ),
           :ok <-
             Fountain.Conversations.Provisioning.check_broker_support(
               brokered?(state),
               provider,
               env,
               state.conversation_id
             ),
           :ok <- discard_interrupted_attempt(provider, sandbox, interrupted?) do
        create_sandbox_handle(provider, sandbox)
      end

    case handle_result do
      {:ok, handle} ->
        skills = (agent && agent.skills) || []
        # conv.runtime is validated-required and outlives the agent; the agent
        # fallback only covers rows predating the runtime column.
        runtime = conv.runtime || (agent && agent.runtime) || "claude"
        Fountain.SandboxSkills.mount(handle, runtime, skills)

        {state, conv} = rotate_callback_api_key(state, conv)

        # Looked up once, here, because it is stable for the sandbox's life and
        # the agent needs it in its environment before the first turn runs.
        sandbox_url = record_sandbox_url(sandbox, handle)

        # The broker session is minted before the env is built, because the
        # env carries it; the CA is installed before anything dials out,
        # because nothing dials out without it (ADR 0019 gate 1a).
        with {:ok, state} <- broker_prepare(state),
             sprite_env = build_sprite_env(state, agent, env, secrets, sandbox_url),
             _ = write_runtime_config(handle, state.runtime_module, agent),
             _ = write_instructions(handle, runtime, agent),
             # The file is the machine's; the conversation's identity travels as
             # process env on every spawn (`Fountain.Conversations.Identity`).
             _ =
               Fountain.Conversations.Provisioning.write_env_file(
                 handle,
                 Fountain.Conversations.Identity.disk_env(sprite_env)
               ),
             :ok <- broker_install_ca(state, handle),
             :ok <-
               run_provisioning_pipeline(
                 handle,
                 env,
                 sprite_env,
                 secrets,
                 state.conversation_id,
                 brokered?(state)
               ),
             :ok <-
               prepare_runtime_sprite(handle, runtime, state.runtime_module, agent, sprite_env) do
          {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "ready"})
          publish_stage(state.conversation_id, "provision", "done")

          # Best-effort: snapshot the fully-provisioned state so subsequent
          # conversations on this env can warm-start from it. Async so it
          # doesn't block the user's first turn.
          maybe_create_checkpoint_async(handle, env)

          state = forget_runtime_session(state, conv)

          # Dated from the sandbox row, not from now, so the absolute lifetime
          # ceiling survives a restart and a reattach rather than resetting.
          new_state = %{
            state
            | handle: handle,
              sprite_env: sprite_env,
              sandbox_started_at: sandbox_clock_start(sandbox)
          }

          # Any prompt this conversation was started for arrives as a cast,
          # already queued behind this handle_continue. See
          # queue_initial_prompt/3.
          {:noreply, new_state}
        else
          {:error, reason} ->
            Logger.error("provision step failed: #{inspect(reason)}")
            _ = Fountain.Sandbox.destroy(handle)
            broker_release(state)
            {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "failed"})

            publish_stage(state.conversation_id, "provision", "failed", %{
              reason: inspect(reason)
            })

            Conversations.update_conversation(conv, %{status: "failed"})
            {:stop, :normal, state}
        end

      {:error, reason} ->
        Logger.error("provision could not start: #{inspect(reason)}")
        {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "failed"})
        publish_stage(state.conversation_id, "provision", "failed", %{reason: inspect(reason)})
        Conversations.update_conversation(conv, %{status: "failed"})
        {:stop, :normal, state}
    end
  end

  # Try a checkpoint restore first if the env has one. If restore succeeds,
  # skip the slow steps (packages + clone + setup_script) — they all wrote to
  # the disk the checkpoint captured, so restoring it restores their effect.
  # If restore fails, clear the checkpoint id and fall through to the full
  # pipeline.
  #
  # The network policy is **not** one of those steps and is applied on both
  # arms (#989). It is configuration on the sandbox, not a file: a warm start
  # creates a fresh sandbox and pours a disk image into it, and that sandbox
  # carries no policy. Skipping it turned a `limited` environment into an
  # unrestricted one, silently, and reported `provision/done`. It costs one
  # fast API call, so the warm start pays nothing for it.
  defp run_provisioning_pipeline(handle, env, sprite_env, secrets, conv_id, brokered?) do
    case attempt_warm_start(handle, env, conv_id) do
      :warm_started ->
        apply_egress_policy(handle, env, conv_id, brokered?)

      :cold ->
        with :ok <-
               Fountain.Conversations.Provisioning.install_packages(
                 handle,
                 env,
                 sprite_env,
                 conv_id
               ),
             :ok <- apply_egress_policy(handle, env, conv_id, brokered?),
             :ok <-
               Fountain.Conversations.Provisioning.clone_repositories(
                 handle,
                 env,
                 secrets,
                 sprite_env,
                 conv_id
               ) do
          run_setup_script(handle, env, sprite_env, conv_id)
        end
    end
  end

  defp attempt_warm_start(_handle, nil, _conv_id), do: :cold
  defp attempt_warm_start(_handle, %{checkpoint_id: nil}, _conv_id), do: :cold
  defp attempt_warm_start(_handle, %{checkpoint_id: ""}, _conv_id), do: :cold

  defp attempt_warm_start(handle, %{checkpoint_id: id} = env, conv_id) do
    publish_stage(conv_id, "checkpoint_restore", "started", %{checkpoint_id: id})

    # `restore_checkpoint/2` returns a bare `:ok` — `Fountain.Telemetry.span/3`
    # unwraps the `{result, metadata}` pair it is given, so the `{:ok, _}` this
    # used to match never occurred and a successful restore raised
    # CaseClauseError. Latent only because #652 kept `checkpoint_id` nil, so
    # this branch was unreachable.
    case Fountain.Conversations.Provisioning.restore_checkpoint(handle, id) do
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

  defp maybe_create_checkpoint_async(_handle, nil), do: :ok

  defp maybe_create_checkpoint_async(_handle, %{checkpoint_id: id})
       when is_binary(id) and id != "",
       do: :ok

  defp maybe_create_checkpoint_async(handle, %Fountain.Environments.Environment{} = env) do
    if checkpoint_creation_enabled?() do
      Task.start(fn ->
        try do
          Fountain.Conversations.Provisioning.create_checkpoint(handle, env)
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

  # The `started` event is published **after** the sprite answers, not on the
  # way in, and that is deliberate (#971).
  #
  # A `ConversationServer` is a Horde child, so cluster churn stops and starts
  # it — every rebalance runs this function again from the top. Announcing on
  # entry turned that into a transcript: production logged 51 `reattach`
  # `started` events for one conversation inside one second, in lockstep with a
  # second conversation on the same node, and exactly one of them reached
  # `done`. Fifty of those describe a process that was replaced before it
  # touched anything, which is a fact about our supervision tree and not about
  # the user's conversation.
  #
  # The provider round trip outlives a rebalance, so a start that is going to
  # be replaced is replaced before this line and writes nothing. What survives
  # to publish has a live sprite and is really reattaching.
  #
  # The node is stamped on every reattach event for the same incident: it is
  # what tells a redistribution storm (many nodes, one conversation) from a
  # crash loop (one node, restarting) without guessing.
  defp do_reattach(state, conv, sandbox, agent, env, secrets) do
    handle =
      Fountain.Sandbox.build_handle(
        Fountain.Conversations.sandbox_provider_atom(sandbox),
        sandbox.sprite_name
      )

    # A broker failure lands in the transient arm below: it says nothing
    # about the sandbox, and the next wake mints again.
    with {:ok, _info} <-
           Fountain.Retry.with_backoff(
             fn -> Fountain.Sandbox.get(handle) end,
             label: "sprite lookup on wake"
           ),
         {:ok, state} <- broker_prepare(state) do
      publish_stage(state.conversation_id, "reattach", "started", %{
        sprite_name: sandbox.sprite_name,
        node: to_string(node())
      })

      {state, _conv} = rotate_callback_api_key(state, conv)
      sprite_env = build_sprite_env(state, agent, env, secrets)

      # A machine provisioned before its tenant was brokered has no CA yet;
      # on one that has it this is an idempotent rewrite. Best effort here:
      # the turn's own failure says more than a refused wake would.
      case broker_install_ca(state, handle) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("broker CA install on wake: #{inspect(reason)}")
      end

      # Refresh the .env file in case secrets/env_vars were edited
      # between the original provision and this reattach.
      # The file is the machine's; the conversation's identity travels as
      # process env on every spawn (`Fountain.Conversations.Identity`).
      Fountain.Conversations.Provisioning.write_env_file(
        handle,
        Fountain.Conversations.Identity.disk_env(sprite_env)
      )

      # Same for the agent's system prompt: an edit reaches the existing
      # computer on its next wake (#848).
      write_instructions(handle, conv.runtime || (agent && agent.runtime) || "claude", agent)

      # Normally the wake path already flipped suspended → ready under the
      # quota reservation; this covers the reaper parking the row mid-wake.
      # Without it the row would stay `suspended` under a live server —
      # invisible to the quota and unreachable by any reaper pass.
      sandbox =
        if sandbox.status == "suspended" do
          {:ok, s} =
            Conversations.update_sandbox(sandbox, %{
              status: "ready",
              last_resumed_at: DateTime.utc_now() |> DateTime.truncate(:second)
            })

          s
        else
          sandbox
        end

      new_state = %{
        state
        | handle: handle,
          sprite_env: sprite_env,
          sandbox_started_at: sandbox_clock_start(sandbox)
      }

      new_state = reattach_running_turn(new_state)

      {:noreply, new_state}
    else
      {:error, :not_found} ->
        # The provider says the sandbox is gone. That is the one answer that
        # justifies retiring the row: the disk no longer exists, so the next
        # prompt must provision fresh.
        Logger.warning(
          "reattach failed for sprite #{sandbox.sprite_name}: not found — marking sandbox failed"
        )

        publish_stage(state.conversation_id, "reattach", "failed", %{
          reason: "not_found",
          retryable: false,
          node: to_string(node())
        })

        {:ok, _} =
          Conversations.update_sandbox(sandbox, %{
            status: "failed",
            terminated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })

        # Don't mark the conversation failed — the user can still send a
        # prompt and auto-wake will spin a fresh sandbox.
        {:stop, :normal, state}

      {:error, reason} ->
        # Anything else — a transport error, a timeout, a 5xx, a credential
        # problem — says nothing about the sandbox, only about our ability to
        # reach the provider right now. The row is left exactly as it was and
        # the server stops; the next prompt takes the same reattach path again.
        #
        # This arm used to mark the row `failed` too. On 2026-08-18 a 70-second
        # DNS outage did exactly that to nine live sandboxes at once (a Horde
        # failover re-ran reattach for every conversation on the partitioned
        # pod, and every probe answered nxdomain), and `SandboxReaper`'s
        # destroy pass would have taken the sprites — one of them holding a
        # completed turn and a live ACP session — an hour later (#799). A
        # transient failure must not become a destroyed disk; the same rule
        # `probe_sandbox/4` applies on the wake path.
        Logger.warning(
          "reattach failed for sprite #{sandbox.sprite_name}: #{inspect(reason)} — " <>
            "transient; sandbox row left untouched"
        )

        publish_stage(state.conversation_id, "reattach", "failed", %{
          reason: inspect(reason),
          retryable: true,
          node: to_string(node())
        })

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
      # No turn was in flight, but a deploy also killed the idle peer that
      # outlives a turn (#817), leaving its detachable adapter session running
      # with nothing to drive it. Reap it — by this conversation's tag, never
      # the head of the list: a co-tenant's live turn on the same machine must
      # not be touched (ADR 0023, #1058).
      reap_orphan_sessions(state)
    else
      case Fountain.Retry.with_backoff(fn -> Fountain.Sandbox.list_sessions(state.handle) end,
             label: "session list on reattach"
           ) do
        {:ok, sessions} ->
          # Don't filter by `is_active`: a detached session reports
          # `is_active: false` while no client is connected, but the
          # underlying exec is alive and `attach_session` resumes its
          # stream (replaying the session buffer + live-tailing).
          #
          # Match on the conversation tag, never the head of the list: with
          # several conversations on one machine, the head is as likely to be
          # someone else's process as ours (`Fountain.Conversations.Identity`).
          case Fountain.Conversations.Identity.pick_session(sessions, state.conversation_id) do
            :none ->
              mark_orphan(state, running_turn, "no_active_session")
              state

            {:tagged, session} ->
              attempt_session_attach(state, running_turn, session, "tag")

            {:untagged, session} ->
              attempt_session_attach(state, running_turn, session, "untagged_head")
          end

        {:error, reason} ->
          Logger.warning("list_sessions failed during reattach: #{inspect(reason)}")
          mark_orphan(state, running_turn, "list_sessions_failed")
          state
      end
    end
  end

  # After a restart with no turn in flight, stop this conversation's own
  # leftover adapter sessions (#817). Matched by tag; a session tagged for
  # another conversation, or untagged, is left alone.
  defp reap_orphan_sessions(state) do
    case Fountain.Sandbox.list_sessions(state.handle) do
      {:ok, sessions} ->
        mine =
          Enum.filter(
            sessions,
            &(Fountain.Conversations.Identity.conversation_id(&1) == state.conversation_id)
          )

        Enum.each(mine, fn session ->
          case Fountain.Sandbox.attach(state.handle, session.id, owner: self(), stdin: true) do
            {:ok, command} -> Fountain.Sandbox.stop_command(command)
            _ -> :ok
          end
        end)

        outcome = if mine == [], do: "no_running_turn", else: "orphan_session_reaped"

        publish_stage(state.conversation_id, "reattach", "done", %{
          outcome: outcome,
          reaped: length(mine)
        })

        state

      {:error, _reason} ->
        publish_stage(state.conversation_id, "reattach", "done", %{outcome: "no_running_turn"})
        state
    end
  end

  defp attempt_session_attach(state, running_turn, session, matched_by) do
    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
    acp? = Fountain.Runtimes.ACP.enabled?(conv.runtime)

    case Fountain.Sandbox.attach(state.handle, session.id, owner: self(), stdin: true) do
      {:ok, idle_command} when acp? and is_nil(running_turn.acp_prompt_id) ->
        # The previous peer died before it wrote `session/prompt` (or the turn
        # predates the column). The adapter is sitting idle in its handshake
        # with nothing to answer, and no peer can pick that up: the ids it
        # would need are gone with the process. Stop it — otherwise it lingers
        # as a session the next reattach could bind to — and orphan the turn.
        Fountain.Sandbox.stop_command(idle_command)
        mark_orphan(state, running_turn, "acp_prompt_not_sent")
        state

      {:ok, command} ->
        # sprites replays the tail of the session's buffered output before
        # live-tailing. On the legacy path, count the bytes we already
        # persisted for this turn so the stdout/stderr handlers can drop the
        # replayed prefix. On the ACP path the peer re-encodes protocol lines
        # so byte counts do not line up; the replayed lines are matched by
        # content instead (`replay_dedup`).
        replay_skip =
          if acp?,
            do: %{},
            else:
              Conversations._unsafe_output_bytes_by_stream(
                state.conversation_id,
                running_turn.id
              )

        publish_stage(state.conversation_id, "reattach", "done", %{
          outcome: "session_attached",
          matched_by: matched_by,
          session_id: session.id,
          turn_id: running_turn.id,
          turn_number: running_turn.turn_number,
          replay_skip_bytes: replay_skip,
          acp_prompt_id: running_turn.acp_prompt_id
        })

        {:ok, _} = Conversations.update_conversation(conv, %{status: "running"})

        # turn_metrics stays nil on purpose, so this turn contributes no
        # duration sample (#536). Its start is in a previous BEAM lifetime:
        # monotonic time isn't comparable across a restart, and measuring
        # from the row's started_at would fold the whole deploy gap into the
        # histogram. A missing sample beats a wrong one.
        state = %{
          state
          | current_command: command,
            current_command_ref: command.ref,
            current_turn: running_turn,
            replay_skip: replay_skip
        }

        if acp?, do: reattach_acp_peer(state, running_turn, conv), else: state

      {:error, reason} ->
        Logger.warning("attach_session failed: #{inspect(reason)}")
        mark_orphan(state, running_turn, "attach_failed")
        state
    end
  end

  @replay_dedup_ttl_ms 10_000

  # An autonomous turn with no `cycle_end` closes after this long a silence.
  @autonomous_quiet_ms :timer.minutes(10)

  # An ACP turn is only alive while something answers the agent: a
  # `session/request_permission` left unanswered blocks it forever, and the
  # `session/prompt` response is the only thing that ends it — the adapter
  # keeps running until stdin closes. Before this, a reattached ACP turn had
  # its stdout logged raw and no peer, so every turn in flight across a deploy
  # hung until the user prompted again (which interrupts it) or the sandbox
  # hit its lifetime ceiling.
  #
  # No tracer: the turn span belongs to a previous BEAM lifetime.
  defp reattach_acp_peer(state, running_turn, conv) do
    {:ok, peer} =
      Fountain.Runtimes.ACP.Peer.start(
        owner: self(),
        command: state.current_command,
        ref: state.current_command_ref,
        prompt: running_turn.prompt,
        mode: :continue,
        session_id: conv.runtime_session_id,
        attach: running_turn.acp_prompt_id,
        # A reattached peer answers `session/request_permission` exactly like a
        # fresh one — the adapter in the sprite is mid-turn and still asking.
        # Resolving from the agent here (rather than reading a policy frozen on
        # the conversation row) is what makes a tightening apply across a
        # deploy.
        permission_policy: effective_permission_policy(conv, agent_for(conv)),
        # Hand back the request the previous peer was holding, if any (#940).
        # The agent minted the JSON-RPC id and is still blocked on it, so the
        # id outlives our process — but only if we wrote it down. This is the
        # same trap `acp_prompt_id` exists for, and the reason the turn row
        # carries `pending_permission` at all.
        pending_permission: running_turn.pending_permission
      )

    dedup =
      Conversations._unsafe_recent_output_lines(state.conversation_id, running_turn.id, "acp")

    Process.send_after(self(), :clear_replay_dedup, @replay_dedup_ttl_ms)

    %{
      state
      | acp_peer: peer,
        acp_peer_mon: Process.monitor(peer),
        stream_tracer: nil,
        replay_dedup: dedup
    }
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

  defp build_sprite_env(state, agent, env, secrets, sandbox_url \\ nil) do
    state
    |> do_build_sprite_env(agent, env, secrets, sandbox_url)
    |> tap(fn sprite_env ->
      # Register before anything can log. Provisioning writes output from its
      # very first step, and the secrets are already in the sprite by then.
      Fountain.Conversations.Redaction.put(state.conversation_id, sprite_env)
    end)
  end

  defp do_build_sprite_env(state, agent, env, secrets, sandbox_url) do
    (state.runtime_module.default_env(agent, state.inference_credentials) || []) ++
      fountain_callback_env(state.callback_token) ++
      conversation_env(state.conversation_id) ++
      sandbox_id_env(state.sandbox_id) ++
      sandbox_url_env(sandbox_url) ++
      otel_propagation_env() ++
      git_author_env() ++
      if(env,
        do: Enum.map(env.env_vars, fn {k, v} -> {to_string(k), to_string(v)} end),
        else: []
      ) ++
      Enum.map(secrets, fn {k, v} -> {k, v} end) ++
      broker_env(state)
  end

  # ── Egress credential brokerage (ADR 0019 gate 1a) ─────────────────────────

  defp brokered?(state), do: Fountain.Broker.enabled_for?(state.user_id)

  # On a brokered conversation the catalog keys leave the secrets map here,
  # before the MCP substitution and the env are built from it, so both see
  # the placeholder and neither sees the value.
  defp split_brokered(user_id, secrets, bindings) do
    if Fountain.Broker.enabled_for?(user_id),
      do: Fountain.Broker.split(secrets, bindings),
      else: {secrets, %{}}
  end

  # Only read for a brokered tenant: for everyone else the table is rows
  # nobody consults, and this path stays free of a query.
  defp broker_bindings(user_id) do
    if Fountain.Broker.enabled_for?(user_id),
      do: Fountain.SecretBindings.enabled_by_key(user_id),
      else: %{}
  end

  defp broker_env(%{broker: nil}), do: []
  defp broker_env(%{broker: session}), do: Fountain.Broker.sandbox_env(session)

  # Mint (or re-mint) the conversation's proxy session. A no-op that returns
  # the state untouched when the conversation is not brokered.
  defp broker_prepare(state) do
    if brokered?(state) do
      publish_stage(state.conversation_id, "broker", "started", %{
        keys: state.brokered |> Map.keys() |> Enum.sort()
      })

      case Fountain.Broker.prepare(
             state.conversation_id,
             state.user_id,
             state.brokered,
             state.broker_bindings
           ) do
        {:ok, session} ->
          publish_stage(state.conversation_id, "broker", "done", %{
            vault: session.vault,
            expires_at: session.expires_at
          })

          {:ok, %{state | broker: session}}

        {:error, reason} ->
          publish_stage(state.conversation_id, "broker", "failed", %{reason: inspect(reason)})
          {:error, reason}
      end
    else
      {:ok, state}
    end
  end

  defp broker_install_ca(%{broker: nil}, _handle), do: :ok

  defp broker_install_ca(state, handle),
    do: Fountain.Conversations.Provisioning.install_broker_ca(handle, state.conversation_id)

  # A session near its end is replaced before the turn that would outlive it.
  # The env is rebuilt with the new token; everything else in it is unchanged.
  defp broker_refresh(%{broker: nil} = state), do: state

  defp broker_refresh(%{broker: session} = state) do
    if Fountain.Broker.expiring?(session) do
      case Fountain.Broker.prepare(
             state.conversation_id,
             state.user_id,
             state.brokered,
             state.broker_bindings
           ) do
        {:ok, fresh} ->
          keys = Fountain.Broker.env_keys()
          kept = Enum.reject(state.sprite_env, fn {k, _} -> to_string(k) in keys end)
          %{state | broker: fresh, sprite_env: kept ++ Fountain.Broker.sandbox_env(fresh)}

        {:error, reason} ->
          # The turn runs on the old token, and fails at the proxy if it has
          # expired. Fail loud there rather than silently here.
          Logger.warning(
            "conv #{state.conversation_id}: broker session refresh failed: #{inspect(reason)}"
          )

          state
      end
    else
      state
    end
  end

  # The conversation's sessions go when its sandbox does. Off the caller's
  # path: a store that is slow at teardown must not keep a sandbox alive,
  # and a session is minted afresh on the next provision anyway.
  defp broker_release(state) do
    if brokered?(state) do
      conv_id = state.conversation_id

      Task.Supervisor.start_child(Fountain.TaskSupervisor, fn ->
        Fountain.Broker.release(conv_id)
      end)
    end

    :ok
  end

  defp apply_egress_policy(handle, env, conv_id, false),
    do: Fountain.Conversations.Provisioning.apply_network_policy(handle, env, conv_id)

  defp apply_egress_policy(handle, _env, conv_id, true),
    do: Fountain.Conversations.Provisioning.apply_broker_floor(handle, conv_id)

  # The sandbox's own HTTP endpoint, so an agent asked "what's the URL?" can
  # answer. Without it the agent has no way to know: the platform assigns the
  # URL outside the sandbox, and inside it the hostname is just "sprite".
  #
  # `SANDBOX_URL` rather than `SPRITE_URL` because the value is provider-
  # neutral; a provider that has no such endpoint simply sets nothing, and an
  # unset variable is the honest answer to "no URL".
  defp sandbox_url_env(nil), do: []
  defp sandbox_url_env(url) when is_binary(url), do: [{"SANDBOX_URL", url}]

  # Best-effort, and deliberately not fatal: a sandbox with no reportable URL
  # is still a working sandbox. Stored on the row so the API and the UI can
  # show it without a provider round trip.
  defp record_sandbox_url(sandbox, handle) do
    case Fountain.Sandbox.public_url(handle) do
      {:ok, url} ->
        meta = Map.put(sandbox.provider_meta || %{}, "public_url", url)
        {:ok, _} = Conversations.update_sandbox(sandbox, %{provider_meta: meta})
        url

      {:error, :unsupported} ->
        nil

      {:error, reason} ->
        Logger.warning("could not read the sandbox URL for #{handle.name}: #{inspect(reason)}")
        nil
    end
  rescue
    # The URL is a convenience; provisioning is not. An adapter that raises
    # here — a provider SDK surprise, a probe against a sandbox that has not
    # settled — must not cost the user their conversation.
    error ->
      Logger.warning("sandbox URL lookup raised for #{handle.name}: #{inspect(error)}")
      nil
  end

  # Inject the current conversation ID so the bundled fountain skill can
  # propagate it as X-Fountain-Parent-Conversation-Id when spawning children.
  defp conversation_env(nil), do: []

  defp conversation_env(conv_id) when is_binary(conv_id),
    do: [{"FOUNTAIN_CONVERSATION_ID", conv_id}]

  # The machine's own id, so the bundled fountain skill can put a child
  # conversation onto this same sandbox (`sandbox_id` on the create, ADR 0023).
  # Machine-scoped, not conversation-scoped: every conversation on the sandbox
  # sees the same value, so unlike the conversation id it may live on the disk.
  defp sandbox_id_env(nil), do: []

  defp sandbox_id_env(sandbox_id) when is_binary(sandbox_id),
    do: [{"FOUNTAIN_SANDBOX_ID", sandbox_id}]

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

  defp run_setup_script(_handle, nil, _sprite_env, _conv_id), do: :ok
  defp run_setup_script(_handle, %{setup_script: ""}, _sprite_env, _conv_id), do: :ok

  defp run_setup_script(handle, %{setup_script: script}, sprite_env, conv_id) do
    Fountain.Telemetry.span(
      [:setup_script],
      %{conv_id: conv_id, script_size: byte_size(script)},
      fn ->
        publish_stage(conv_id, "setup", "started")

        case Fountain.Sandbox.exec(handle, "bash", ["-lc", script],
               env: sprite_env,
               stderr_to_stdout: true,
               timeout: 120_000
             ) do
          {:ok, output, code} ->
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

          {:error, reason} ->
            publish_stage(conv_id, "setup", "failed", %{reason: inspect(reason)})
            {{:error, {:setup_unreachable, reason}}, %{outcome: :failed, reason: inspect(reason)}}
        end
      end
    )
  end

  defp write_runtime_config(handle, runtime_module, agent) do
    Code.ensure_loaded(runtime_module)

    if function_exported?(runtime_module, :write_config, 2) do
      runtime_module.write_config(handle, agent)
    end
  end

  # The agent's `system` prompt, into the runtime's user-level instructions
  # file (#848). Best-effort: a sandbox that refuses the write still runs,
  # on the CLI's default persona, and says so in the log.
  defp write_instructions(handle, runtime, agent) do
    case Fountain.Runtimes.Instructions.write(handle, runtime, agent) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "could not write agent instructions for #{inspect(agent && agent.name)} (#{runtime}): #{inspect(reason)}"
        )

        :ok
    end
  end

  defp prepare_runtime_sprite(handle, runtime, runtime_module, agent, sprite_env) do
    Code.ensure_loaded(runtime_module)

    with :ok <- prepare_acp_adapter(handle, runtime, sprite_env) do
      if function_exported?(runtime_module, :prepare_sandbox, 3) do
        runtime_module.prepare_sandbox(handle, agent, sprite_env)
      else
        :ok
      end
    end
  end

  # The adapter is an npm install, so it has to happen here rather than at
  # spawn: by the time a turn runs, the network policy has been applied and the
  # install would fail in a way that reads as a protocol bug. Keyed on the
  # conversation's runtime, matching the spawn decision in kick_turn/4.
  defp prepare_acp_adapter(handle, runtime, sprite_env) do
    if Fountain.Runtimes.ACP.enabled?(runtime) do
      Fountain.Runtimes.ACP.install(handle, runtime, sprite_env)
    else
      :ok
    end
  end

  @impl true
  def handle_call({:send_prompt, prompt, images}, _from, state) do
    if user_turn_running?(state) do
      {:reply, {:error, :busy}, state}
    else
      # A background cycle the agent was still narrating is closed by the
      # human's prompt, not queued behind it (#817): its updates are already
      # on the transcript, and the agent will fold whatever it was doing into
      # the answer to this prompt.
      state = close_autonomous_turn(state, "superseded_by_prompt")
      conv = Conversations._unsafe_get_conversation!(state.conversation_id)

      with :ok <- turn_gate(conv.user_id),
           :ok <- capacity_gate(state, conv) do
        agent = if conv.agent_id, do: Agents._unsafe_get_agent!(conv.agent_id)
        {:reply, :ok, kick_turn(state, prompt, agent, images)}
      else
        {:error, _} = err -> {:reply, err, state}
      end
    end
  end

  # Busy means a turn, not a connection (#817): an idle adapter between
  # turns is nothing to interrupt. An autonomous turn is interruptible — it
  # is the one way to cut a background task the agent left running.
  def handle_call(:interrupt, _from, %{current_turn: nil} = state) do
    {:reply, {:error, :idle}, state}
  end

  def handle_call(:interrupt, _from, state) do
    {:reply, :ok, interrupt_turn(state)}
  end

  # First answer wins. The web apps and an editor (#708) are peer clients of
  # this door, not fallbacks for one another, so a second answer to the same
  # request is "too late" rather than an error in the caller.
  def handle_call({:answer_permission, request_id, option_id}, _from, state) do
    case state.acp_peer do
      nil ->
        {:reply, {:error, :no_pending_permission}, state}

      peer ->
        case Fountain.Runtimes.ACP.Peer.answer_permission(peer, request_id, option_id) do
          :ok ->
            {:reply, :ok, resolve_permission(state, request_id, "answered", option_id)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(:terminate_conv, _from, state) do
    kept? =
      Conversations._unsafe_sandbox_kept_on_terminate?(state.sandbox_id, state.conversation_id)

    if kept? do
      # The machine is shared, or it is the agent's home (ADR 0023): end this
      # conversation and leave the sprite — the same guard the no-server path
      # applies in terminate_conversation/2. A turn of ours still running is
      # cut first, since nothing would be left to drive it; `handle: nil` so
      # no stop path touches the sprite.
      state = if state.current_turn, do: interrupt_turn(state), else: state
      state = drop_connection(state, "terminated")
      conv = Conversations._unsafe_get_conversation!(state.conversation_id)
      {:ok, _} = Conversations.update_conversation(conv, %{status: "terminated"})

      publish_stage(state.conversation_id, "terminate", "done", %{
        sandbox: "kept",
        reason: if(home?(state), do: "persistent_home", else: "held_by_another_conversation")
      })

      {:stop, :normal, :ok, %{state | handle: nil}}
    else
      state = drop_connection(state, "terminated")
      if state.handle, do: _ = Fountain.Sandbox.destroy(state.handle)
      broker_release(state)
      sandbox = Conversations._unsafe_get_sandbox!(state.sandbox_id)

      {:ok, _} =
        Conversations.update_sandbox(sandbox, %{status: "terminated", terminated_at: now()})

      conv = Conversations._unsafe_get_conversation!(state.conversation_id)
      {:ok, _} = Conversations.update_conversation(conv, %{status: "terminated"})
      publish_stage(state.conversation_id, "terminate", "done")
      {:stop, :normal, :ok, state}
    end
  end

  # End the conversation, keep the sandbox — see release_conversation/2. A
  # running turn is refused rather than interrupted: the caller decides
  # whether to cut the agent off. `handle: nil` on the way out so no stop
  # path (terminate/2 included) touches the sprite; the sandbox row is not
  # written at all — it stays `ready`, a parked disk with no server, exactly
  # what the wake path expects when the successor's first prompt arrives.
  def handle_call(:release_conv, _from, %{current_turn: turn} = state) when not is_nil(turn) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call(:release_conv, _from, state) do
    state = drop_connection(state, "released")
    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
    {:ok, _} = Conversations.update_conversation(conv, %{status: "terminated"})
    publish_stage(state.conversation_id, "terminate", "done", %{event: "released"})
    {:stop, :normal, :ok, %{state | handle: nil}}
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
    if user_turn_running?(state) do
      Logger.warning(
        "conv #{state.conversation_id}: initial prompt arrived while a turn was running; dropping it"
      )

      {:noreply, state}
    else
      conv = Conversations._unsafe_get_conversation!(state.conversation_id)

      case turn_gate(conv.user_id) do
        :ok ->
          state = close_autonomous_turn(state, "superseded_by_prompt")
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

  # Another conversation on this machine parked or destroyed it (see
  # stop_cotenants/4). Record that on this transcript, cut a turn that has
  # nothing left to run on, and stop: with no handle there is nothing this
  # server can do, and the wake path is what brings the machine back.
  def handle_cast({:machine_gone, event, reason, message}, state) do
    state = if state.current_turn, do: interrupt_turn(state), else: state
    state = drop_connection(state, event)

    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
    if conv.status == "running", do: Conversations.update_conversation(conv, %{status: "idle"})

    publish_stage(state.conversation_id, "sandbox", "done", %{
      event: event,
      reason: reason,
      by: "another_conversation",
      message: message
    })

    {:stop, :normal, %{state | handle: nil}}
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
    # Raw stdout only arrives here on the legacy path (or from an ACP turn
    # whose peer died mid-turn). The tracer reads protocol lines from the
    # peer's reports, never raw chunks — the dialect tracer that used to eat
    # this stream went with the legacy claude path.
    state = maybe_emit_first_output(state)
    {:noreply, log_with_replay_skip(state, "stdout", data)}
  end

  def handle_info({:stderr, %{ref: ref}, data}, %{current_command_ref: ref} = state) do
    {:noreply, log_with_replay_skip(state, "stderr", data)}
  end

  # ── ACP peer reports (0014 gate 2) ────────────────────────────────────────

  # Persisting goes through the server's own path so the ACP stream inherits
  # the log budget, the redaction pass and the replay skip. A peer writing rows
  # itself would bypass all three.
  #
  # A protocol line with no turn open is the agent talking out of turn (#817):
  # a background task it left running has come back and it is narrating the
  # follow-up. That opens an autonomous turn — a real row, so the log budget,
  # redaction and the stage events apply unchanged — and every further line
  # re-arms the quiet timer that closes it if no `cycle_end` ever does.
  def handle_info({:acp, ref, {:lines, stream, data}}, %{current_command_ref: ref} = state) do
    cond do
      stream == "acp" and MapSet.member?(state.replay_dedup, data) ->
        # A replayed line we already hold (ACP reattach). Each persisted line
        # suppresses at most one arrival, so a legitimate later repeat survives.
        {:noreply, %{state | replay_dedup: MapSet.delete(state.replay_dedup, data)}}

      stream == "acp" and is_nil(state.current_turn) ->
        state = open_autonomous_turn(state)
        {:noreply, persist_acp_lines(state, stream, data)}

      stream == "acp" and autonomous_turn?(state) ->
        state = arm_autonomous_quiet(state)
        {:noreply, persist_acp_lines(state, stream, data)}

      true ->
        {:noreply, persist_acp_lines(state, stream, data)}
    end
  end

  # The adapter marked the end of a background cycle (#817). The turn it
  # opened closes here; a `cycle_end` with no autonomous turn open (its
  # updates never reached us) is nothing to close.
  def handle_info({:acp, ref, {:cycle_end, kind}}, %{current_command_ref: ref} = state) do
    if autonomous_turn?(state) do
      {:noreply,
       finish_acp_turn(state, "completed", %{"origin" => kind}, %{
         origin: "autonomous",
         cycle: kind
       })}
    else
      {:noreply, state}
    end
  end

  # No `cycle_end` came. Close the autonomous turn as completed — the updates
  # it collected are real — and say why.
  def handle_info({:autonomous_quiet, turn_id}, %{current_turn: %{id: turn_id}} = state) do
    if autonomous_turn?(state) do
      {:noreply,
       finish_acp_turn(state, "completed", %{"origin" => "quiet"}, %{
         origin: "autonomous",
         cycle: "quiet"
       })}
    else
      {:noreply, state}
    end
  end

  def handle_info({:autonomous_quiet, _turn_id}, state), do: {:noreply, state}

  # The runtime refused the agent's model. Published as a stage event so it
  # reaches every surface — the conversation view, the API, the CLI and an
  # editor's log — rather than only the `stderr` stream, which is the one
  # thing a protocol client filters out (#724). The turn continues on the
  # runtime's default, which is the peer's call and the right one mid-turn;
  # what changes here is that nobody has to guess which model answered.
  def handle_info(
        {:acp, ref, {:model_rejected, requested, detail}},
        %{current_command_ref: ref} = state
      ) do
    Logger.warning("conv #{state.conversation_id}: runtime refused model #{requested}: #{detail}")

    publish_stage(state.conversation_id, "model", "failed", %{
      requested: requested,
      detail: detail,
      using: "the runtime's default for this turn"
    })

    {:noreply, state}
  end

  # `session/new` chose an id. Persisted immediately, exactly as the legacy path
  # persists one before spawning: it is what the next turn resumes by, and a
  # server restart between here and the end of the turn must not lose it.
  def handle_info({:acp, ref, {:session, id}}, %{current_command_ref: ref} = state) do
    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
    {:ok, _} = Conversations.update_conversation(conv, %{runtime_session_id: id})
    {:noreply, %{state | runtime_session_id: id}}
  end

  # The peer wrote `session/prompt` under this JSON-RPC id. Persisted at once:
  # it is what a reattach after a restart needs to tell the prompt's answer
  # from the replayed handshake, and a turn without it cannot be resumed at
  # all — see `reattach_acp_peer/3`.
  def handle_info({:acp, ref, {:prompt_sent, id}}, %{current_command_ref: ref} = state) do
    {:ok, turn} = Conversations._unsafe_update_turn(state.current_turn, %{acp_prompt_id: id})
    {:noreply, %{state | current_turn: turn}}
  end

  # `ask`: the agent is blocked and a human has to answer (#940).
  #
  # Three things happen, and the order matters. The pending request is persisted
  # on the turn first, so a deploy landing a millisecond later can still be
  # answered; then the stage event goes out; then the timeout is armed.
  #
  # The timeout is not optional and it is not a tidiness measure.
  # `Lifecycle.check/4` suppresses only the *idle* verdict while a turn is in
  # flight, so an unanswered request would sail past the idle bound and be
  # resolved by the max-lifetime ceiling — and per 0017 the idle bound suspends
  # while the ceiling destroys. Left alone, a prompt nobody answers does not
  # hang forever; it burns the whole lifetime and then takes the agent's memory
  # with it (#649).
  def handle_info(
        {:acp, ref, {:permission_ask, request_id, tool, options}},
        %{current_command_ref: ref} = state
      ) do
    # An agent blocked mid-cycle asks out of turn (#817): the request needs a
    # turn row to live on, exactly as an out-of-turn update does.
    state = if is_nil(state.current_turn), do: open_autonomous_turn(state), else: state

    pending = %{
      "request_id" => request_id,
      "tool" => tool,
      "options" => options,
      "asked_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    state =
      case state.current_turn do
        nil ->
          state

        turn ->
          {:ok, turn} = Conversations._unsafe_update_turn(turn, %{pending_permission: pending})
          %{state | current_turn: turn}
      end

    publish_stage(state.conversation_id, "request", "started", %{
      request_id: request_id,
      tool: tool,
      # The agent's own list, verbatim. A client must never offer an option
      # that is not on it.
      options: options,
      timeout_ms: Fountain.Permissions.ask_timeout_ms()
    })

    timer =
      Process.send_after(
        self(),
        {:permission_timeout, request_id},
        Fountain.Permissions.ask_timeout_ms()
      )

    {:noreply, %{state | permission_timer: timer}}
  end

  # Nobody answered in time. Deny — the only safe default — and say so on the
  # stream so a card stops waiting.
  def handle_info({:permission_timeout, request_id}, state) do
    {:noreply, resolve_permission(state, request_id, "timeout", nil)}
  end

  # A tool the policy withheld (#939). Recorded in the context, per 0013: the
  # tool and the verdict, never the tool's input. Only refusals reach here —
  # the peer stays silent on `auto_allow`, because a turn makes dozens of tool
  # calls and a row each would turn the trail into a transcript.
  def handle_info(
        {:acp, ref, {:permission_denied, tool, verdict}},
        %{current_command_ref: ref} = state
      ) do
    Conversations.record_permission_denied(state.conversation_id, tool, verdict)
    {:noreply, state}
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
  #
  # `usage` is the turn's end-of-turn token figure (#827), recorded once here
  # — the response is the only place the runtime reports it — before the turn
  # row is closed. nil records nothing.
  def handle_info({:acp, ref, {:done, stop_reason, usage}}, %{current_command_ref: ref} = state) do
    status = if stop_reason in ["refusal", "cancelled"], do: "failed", else: "completed"
    record_turn_usage(state, usage)

    {:noreply,
     finish_acp_turn(state, status, %{"stop_reason" => stop_reason}, %{
       stop_reason: stop_reason
     })}
  end

  # #655: the org has refused this account's Claude OAuth token. Left alone,
  # every further turn on this conversation would fail the exact same way —
  # nothing about the token changes between attempts — while the Anthropic
  # API key sitting in the same `inference_credentials` row would work. Swap
  # it in for the rest of this server's life (not just a silent retry of this
  # one turn, so the failure and the fix are both visible in the transcript)
  # rather than leave the tenant to rediscover the swap by hand. Scoped to
  # this running conversation on purpose: a fresh conversation tries OAuth
  # again, so a policy that later reverts self-heals instead of staying
  # pinned to a credential this fix disabled.
  def handle_info(
        {:acp, ref, {:failed, {:oauth_org_not_allowed, detail}}},
        %{current_command_ref: ref, runtime_module: Fountain.Runtimes.Claude} = state
      ) do
    Logger.warning("conv #{state.conversation_id}: Claude OAuth token refused by org: #{detail}")

    fallback_env =
      Fountain.Runtimes.Claude.fall_back_to_api_key(state.sprite_env, state.inference_credentials)

    switched? = fallback_env != state.sprite_env

    # The API key was never in the sprite env before now, so `build_sprite_env`
    # never registered it for redaction — do it here, or the very value this
    # fix injects prints in plaintext into `log_events`. Registered as a union
    # with the outgoing env, not a replacement: the refused OAuth token is
    # still sitting in the sprite's `/home/sprite/.env` until a wake rewrites
    # it, so it stays worth scrubbing.
    Fountain.Conversations.Redaction.put(
      state.conversation_id,
      state.sprite_env ++ fallback_env
    )

    state = %{
      state
      | sprite_env: fallback_env,
        inference_credentials: Map.delete(state.inference_credentials, :claude_code_oauth_token)
    }

    message =
      if switched? do
        "Your organization has disabled Claude subscription (OAuth) access for Claude Code. " <>
          "Switched to the Anthropic API key on this account for the rest of this " <>
          "conversation — send your prompt again."
      else
        "Your organization has disabled Claude subscription (OAuth) access for Claude Code, " <>
          "and no Anthropic API key is on file for this account. Add one in Settings, then " <>
          "try again."
      end

    {:noreply,
     state
     |> finish_acp_turn(
       "failed",
       %{"error" => message, "acp.oauth_org_not_allowed" => true},
       %{reason: message}
     )
     |> drop_connection("failed")}
  end

  # #970: the provider refused the model, so this turn and every later one on
  # this agent fail the same way until someone changes the field. The peer
  # already read the kind out of the provider's sentence; what is left is to
  # deliver it as a sentence rather than as an inspected tuple, and to publish
  # the `model` stage so a client has the requested id as a field and can point
  # at the agent that carries it.
  #
  # Nothing is swapped in, unlike the OAuth clause above. There is no second
  # model to fall back to that the tenant did not choose, and picking one would
  # answer their prompt with a model they never asked for.
  def handle_info(
        {:acp, ref, {:failed, {:model_unavailable, requested, detail}}},
        %{current_command_ref: ref} = state
      ) do
    Logger.warning(
      "conv #{state.conversation_id}: provider refused model #{requested || "(unset)"}: #{detail}"
    )

    publish_stage(state.conversation_id, "model", "failed", %{
      requested: requested,
      detail: detail,
      using: "none, the turn failed"
    })

    message = model_unavailable_message(requested, detail)

    {:noreply,
     state
     |> finish_acp_turn("failed", %{"error" => message, "acp.model_unavailable" => true}, %{
       reason: message
     })
     |> drop_connection("failed")}
  end

  # A failed peer is not reusable: end the turn it was driving (if any) and
  # drop the connection, so the next prompt spawns a fresh adapter.
  def handle_info({:acp, ref, {:failed, reason}}, %{current_command_ref: ref} = state) do
    Logger.error("conv #{state.conversation_id}: acp peer failed: #{inspect(reason)}")

    state =
      if state.current_turn do
        finish_acp_turn(state, "failed", %{"error" => inspect(reason)}, %{
          reason: "acp: #{inspect(reason)}"
        })
      else
        state
      end

    {:noreply, drop_connection(state, "failed")}
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

  # The peer died between turns (#817): a lost connection, not a failed
  # turn. Say so on the transcript, let the adapter go, and let the next
  # prompt spawn a fresh one (`mode: :continue` → `session/resume`).
  def handle_info({:DOWN, mon, :process, _pid, reason}, %{acp_peer_mon: mon} = state) do
    Logger.warning("conv #{state.conversation_id}: idle acp peer down: #{inspect(reason)}")
    state = %{state | acp_peer: nil, acp_peer_mon: nil}
    {:noreply, drop_connection(state, "peer_down")}
  end

  # The adapter exited between turns (#817): the connection is gone, no turn
  # is. Record it and clear the connection; the next prompt spawns afresh.
  def handle_info(
        {:exit, %{ref: ref}, code},
        %{current_command_ref: ref, current_turn: nil} = state
      ) do
    Logger.info("conv #{state.conversation_id}: idle acp adapter exited #{code}")
    {:noreply, connection_lost(state, "adapter_exited", %{exit_code: code})}
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
    finalize_tracer(state.stream_tracer)

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
  # The adapter sends it when the transport to the sandbox drops mid-run,
  # then stops — and since the command process is neither linked nor
  # monitored, this message is the only signal there will ever be. Ignoring
  # it left current_command set forever: every prompt answered {:error,
  # :busy}, idle reclaim was suppressed (busy? true), the reaper skipped the
  # sandbox (server alive), and the sprite billed until max_lifetime. Fail
  # the turn and return to idle, exactly like a non-zero :exit.
  def handle_info(
        {:error, %{ref: ref}, reason},
        %{current_command_ref: ref, current_turn: nil} = state
      )
      when not is_nil(ref) do
    Logger.warning("sprite command error between turns: #{inspect(reason)} — connection lost")
    {:noreply, connection_lost(state, "transport_error", %{reason: inspect(reason)})}
  end

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

    finalize_tracer(state.stream_tracer)

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

  # The ACP reattach window is over; anything still in the set is a persisted
  # line the replay did not repeat, and must not suppress a genuine repeat.
  def handle_info(:clear_replay_dedup, state) do
    {:noreply, %{state | replay_dedup: MapSet.new()}}
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
        # Busy is a turn in flight, autonomous ones included (#817) — an idle
        # adapter between turns is not a reason to hold the sandbox open.
        case Lifecycle.check(started_at, state.last_activity_at, state.current_turn != nil) do
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

  # The one place a held request stops being held, whoever ended it: an answer,
  # the timeout, or the turn ending. Cancels the timer, clears the turn's
  # `pending_permission`, and publishes the resolution so a card can close.
  #
  # `state: "done"` for every outcome, including a deny and a timeout. The stage
  # and its status are the Prometheus counter's only tags and there is an alert
  # on them — a timeout emitting `failed` would page someone for a policy doing
  # exactly what it was told.
  defp resolve_permission(state, request_id, outcome, option_id) do
    if state.permission_timer, do: Process.cancel_timer(state.permission_timer)

    # Read before the clear below wipes it.
    tool = pending_tool(state)

    if outcome != "answered" and state.acp_peer do
      Fountain.Runtimes.ACP.Peer.deny_permission(state.acp_peer, request_id)
    end

    state =
      case state.current_turn do
        nil ->
          state

        turn ->
          {:ok, turn} = Conversations._unsafe_update_turn(turn, %{pending_permission: nil})
          %{state | current_turn: turn}
      end

    publish_stage(state.conversation_id, "request", "done", %{
      request_id: request_id,
      outcome: outcome,
      option_id: option_id
    })

    if outcome != "answered" do
      Conversations.record_permission_denied(state.conversation_id, tool, outcome)
    end

    %{state | permission_timer: nil}
  end

  defp pending_tool(%{current_turn: %{pending_permission: %{"tool" => tool}}}), do: tool
  defp pending_tool(_state), do: nil

  # Resolve whatever is held, if anything. The turn row is the source of truth
  # rather than the timer, so this is also correct for a request raised by a
  # previous BEAM lifetime and reattached to.
  defp resolve_pending_permission(state, outcome) do
    case state.current_turn do
      %{pending_permission: %{"request_id" => request_id}} ->
        resolve_permission(state, request_id, outcome, nil)

      _ ->
        state
    end
  end

  # The absolute lifetime ceiling measures a continuous run, not calendar age:
  # a wake from `suspended` stamps `last_resumed_at` and restarts the clock,
  # while a deploy reattach of a `ready` row stamps nothing and keeps it.
  # SandboxReaper.expired?/2 must agree with this — change both together.
  # The provider tag for telemetry: read off the live handle, which was
  # built from the sandbox row's provider column.
  defp provider(%{handle: %Fountain.Sandbox.Handle{provider: provider}}), do: provider
  defp provider(_state), do: :sprites

  defp sandbox_clock_start(sandbox), do: sandbox.last_resumed_at || sandbox.inserted_at

  defp schedule_lifecycle_check do
    # Interval overridable in tests so the timer wiring itself is testable —
    # dropping schedule_lifecycle_check() from init/1 used to pass the whole
    # suite (#337) while silently disabling idle/max-lifetime reclamation.
    interval = Application.get_env(:fountain, :lifecycle_check_ms, @lifecycle_check_ms)
    Process.send_after(self(), :lifecycle_check, interval)
  end

  defp touch_activity(state), do: %{state | last_activity_at: DateTime.utc_now()}

  # Idle: park where the provider can preserve the disk (the :suspend
  # capability — implicit scale-to-zero for Sprites, an explicit pause/stop
  # for providers that need one), destroy where it cannot. The disk holds the
  # runtime session — the agent's memory, which #649 proved cannot be rebuilt
  # on a fresh sandbox — so parking is always preferred; but an idle sandbox
  # that cannot park keeps billing, and a park *call* that fails leaves it
  # billing too, so both of those degrade to the destroy arm. The decision
  # lives in Lifecycle.idle_action/1.
  defp reclaim_sandbox(state, :idle) do
    if Conversations._unsafe_sandbox_busy_elsewhere?(
         state.sandbox_id,
         state.conversation_id,
         Lifecycle.idle_timeout_seconds()
       ) do
      # This conversation is idle; the machine is not. Another conversation
      # on it is mid-turn or was active more recently than the bound, so the
      # verdict is the machine's to reach, over all of them (ADR 0023 step 5).
      # Checked again on the next tick.
      {:noreply, state}
    else
      reclaim_idle_machine(state)
    end
  end

  # Max lifetime: tear down and stop, whatever the provider. This bound exists
  # for the conversation that never stops being busy; the conversation stays
  # `idle` and resumable — setting it `terminated` here would make a cost
  # control into data loss. See Fountain.Conversations.Lifecycle.
  #
  # A home is parked instead, where the provider can park: its disk is the
  # agent's memory across every conversation, and destroying it at a busy
  # ceiling would defeat the mode (ADR 0023 step 5). The ceiling itself is
  # slated to go; until then this is the interim it names. A home on a
  # provider that cannot park, or whose park call fails, is destroyed as an
  # ephemeral one would be — an unparked machine keeps billing.
  defp reclaim_sandbox(state, :max_lifetime) do
    with true <- home?(state),
         :suspend <- Lifecycle.idle_action(provider(state)),
         :ok <- suspend_sandbox(state) do
      park_sandbox(state, :max_lifetime)
    else
      _ -> destroy_sandbox(state, :max_lifetime)
    end
  end

  # Whether this server's machine is a persistent home (ADR 0023).
  defp home?(%{sandbox_id: sandbox_id}) when is_binary(sandbox_id) do
    match?(%{mode: "persistent"}, Conversations._unsafe_get_sandbox(sandbox_id))
  end

  defp home?(_state), do: false

  defp reclaim_idle_machine(state) do
    with :suspend <- Lifecycle.idle_action(provider(state)),
         :ok <- suspend_sandbox(state) do
      park_sandbox(state)
    else
      :destroy ->
        destroy_sandbox(state, :idle)

      {:error, reason} ->
        Logger.warning(
          "suspend call failed for conv #{state.conversation_id} " <>
            "(#{inspect(reason)}); destroying instead — an unparked sandbox keeps billing"
        )

        destroy_sandbox(state, :idle)
    end
  end

  # Explicitly park the sandbox before the row flips: for Sprites this is a
  # no-op (scale-to-zero), for pause/stop providers it is the call that stops
  # the meter. Ordering matters — a row marked suspended with the backend
  # still running would be invisible to every reclaim pass.
  defp suspend_sandbox(%{handle: nil}), do: :ok
  defp suspend_sandbox(state), do: Fountain.Sandbox.suspend(state.handle)

  defp park_sandbox(state, reason \\ :idle) do
    Logger.info(
      "suspending sandbox for conv #{state.conversation_id}: #{reason} " <>
        "(sprite #{inspect(state.handle && state.handle.name)})"
    )

    # A parked sprite never keeps a live adapter (#817).
    state = drop_connection(state, "suspended")

    if state.sandbox_id do
      sandbox = Conversations._unsafe_get_sandbox!(state.sandbox_id)

      if sandbox.status not in ["terminated", "failed"] do
        # A home's disk is kept at its quietest moment, where the provider
        # can (ADR 0023, #1073). Best-effort: the park goes ahead either way.
        HomeCheckpoint.on_park(sandbox)
        {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "suspended"})
      end
    end

    # The conversation stays idle and resumable; the sprite stays parked.
    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
    if conv.status == "running", do: Conversations.update_conversation(conv, %{status: "idle"})

    # Same stage/state as the reclaim below (LogEvent's state set is closed and
    # clients already key on the "sandbox" stage); `event` is the discriminator.
    publish_stage(state.conversation_id, "sandbox", "done", %{
      event: "suspended",
      reason: to_string(reason),
      message: Lifecycle.explain(reason, :suspend)
    })

    :telemetry.execute([:fountain, :sandbox, :suspended], %{count: 1}, %{
      provider: provider(state)
    })

    stop_cotenants(state, "suspended", to_string(reason), Lifecycle.explain(reason, :suspend))

    {:stop, :normal, %{state | handle: nil}}
  end

  # A park or a destroy is a machine operation: every other conversation on
  # the sandbox loses its handle with it. Tell their servers, so each records
  # what happened on its own transcript and stops — the next prompt then takes
  # the wake path, the only path that brings the machine back. A cast: a
  # co-tenant whose server is already gone is not an error here.
  defp stop_cotenants(state, event, reason, message) do
    state.sandbox_id
    |> Conversations._unsafe_list_cotenant_ids(state.conversation_id)
    |> Enum.each(fn conv_id ->
      case whereis(conv_id) do
        nil -> :ok
        pid -> GenServer.cast(pid, {:machine_gone, event, reason, message})
      end
    end)
  end

  # Tear down the sandbox and stop; the conversation stays `idle` and
  # resumable (setting it `terminated` here would make a cost control into
  # data loss). Serves both the max-lifetime ceiling and the idle bound on a
  # provider that cannot park. See Fountain.Conversations.Lifecycle.
  defp destroy_sandbox(state, reason) do
    Logger.info(
      "reclaiming sandbox for conv #{state.conversation_id}: #{reason} " <>
        "(sprite #{inspect(state.handle && state.handle.name)})"
    )

    state = drop_connection(state, "reclaimed")

    if state.handle, do: _ = Fountain.Sandbox.destroy(state.handle)
    broker_release(state)

    if state.sandbox_id do
      sandbox = Conversations._unsafe_get_sandbox!(state.sandbox_id)

      if sandbox.status not in ["terminated", "failed"] do
        {:ok, _} =
          Conversations.update_sandbox(sandbox, %{status: "terminated", terminated_at: now()})
      end
    end

    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
    if conv.status == "running", do: Conversations.update_conversation(conv, %{status: "idle"})

    # `state` is a stage-lifecycle vocabulary — LogEvent allows only
    # started/done/failed/interrupted, and both the CLI and the LiveView switch
    # on it. A reclaimed sandbox is a stage that reached its end, so "done" is
    # accurate and needs no client to learn a new word; the `reason` and
    # `message` fields carry what actually happened.
    publish_stage(state.conversation_id, "sandbox", "done", %{
      event: "reclaimed",
      reason: to_string(reason),
      message: reclaim_message(reason)
    })

    :telemetry.execute([:fountain, :sandbox, :reclaimed], %{count: 1}, %{
      reason: reason,
      provider: provider(state)
    })

    stop_cotenants(state, "reclaimed", to_string(reason), reclaim_message(reason))

    {:stop, :normal, %{state | handle: nil}}
  end

  defp reclaim_message(:max_lifetime), do: Lifecycle.explain(:max_lifetime)
  defp reclaim_message(:idle), do: Lifecycle.explain(:idle, :destroy)

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
      | handle: state.handle && %{state.handle | private: nil},
        sprite_env: Enum.map(state.sprite_env, fn {k, _v} -> {k, "[REDACTED]"} end),
        tenant_key: redact(state.tenant_key),
        inference_credentials: redact_map(state.inference_credentials),
        callback_token: redact(state.callback_token)
    }
  end

  defp redact_map(%{} = map), do: Map.new(map, fn {k, _v} -> {k, "[REDACTED]"} end)
  defp redact_map(other), do: redact(other)

  defp redact(nil), do: nil
  defp redact(_present), do: "[REDACTED]"

  # ── helpers ───────────────────────────────────────────────────────────────

  # A runtime session lives in the sandbox filesystem, so it cannot follow the
  # conversation onto a freshly provisioned one. Until #778 a wake that took
  # the `:create_new` arm kept the old id, the next turn ran in `:continue`
  # mode, and the ACP peer's `session/resume` failed `-32002 Resource not
  # found` against a disk that had never seen the session — on every prompt,
  # until the conversation was terminated. Clearing it here makes the next
  # turn `:run` → `session/new`: the same conversation, transcript and title,
  # a new runtime session on the new disk. The agent's in-context memory is
  # lost either way; the difference is a working turn instead of a failing
  # one, and a stage event that says so.
  #
  # Done inside the server rather than by the wake caller: the caller's row
  # update races this server's own read of the row in handle_continue.
  defp forget_runtime_session(%{runtime_session_id: nil} = state, _conv), do: state

  defp forget_runtime_session(state, conv) do
    {:ok, _} = Conversations.update_conversation(conv, %{runtime_session_id: nil})

    publish_stage(state.conversation_id, "session", "done", %{
      event: "reset",
      reason: "fresh_sandbox",
      detail: "the previous runtime session lived on a sandbox that no longer exists"
    })

    %{state | runtime_session_id: nil}
  end

  # The row's provider decides where the sandbox is created; adopt-on-
  # already-exists is the adapter's job.
  # A sandbox left behind by an interrupted attempt cannot be finished in
  # place: `Sandbox.create` adopts an existing sprite by name, so a restarted
  # server would re-run every step on a half-built machine — and the steps
  # are not idempotent (`git clone` refuses a checkout that already exists,
  # a setup script that starts services fails on the second start). Seen
  # live when a deploy landed during an environment's `setup` stage: the
  # restart re-provisioned onto the same sprite and died in `clone`. Tear the
  # remnant down first; a sprite that is already gone is not an error.
  defp discard_interrupted_attempt(_provider, _sandbox, false), do: :ok

  defp discard_interrupted_attempt(provider, sandbox, true) do
    Logger.warning(
      "sandbox #{sandbox.id}: sprite #{sandbox.sprite_name} was left mid-provision by an " <>
        "interrupted attempt; destroying it before provisioning again"
    )

    handle = Fountain.Sandbox.build_handle(provider, sandbox.sprite_name)

    case Fountain.Sandbox.destroy(handle) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.info(
          "sandbox #{sandbox.id}: discarding sprite #{sandbox.sprite_name} returned " <>
            "#{inspect(reason)}; provisioning anyway"
        )

        :ok
    end
  end

  defp create_sandbox_handle(provider, sandbox) do
    Fountain.Retry.with_backoff(
      fn -> Fountain.Sandbox.create(provider, sandbox.sprite_name) end,
      label: "sprite create #{sandbox.sprite_name}"
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

  # The Buzz reply tools (#737), injected into `session/new` only for a
  # Buzz-driven conversation and only once a callback token has been minted —
  # `Fountain.Buzz` decides both. `[]` for every other conversation.
  defp buzz_mcp_servers(%{callback_token: token, conversation_id: conv_id})
       when is_binary(token) and is_binary(conv_id) do
    Fountain.Buzz.conversation_mcp_servers(conv_id, token)
  end

  defp buzz_mcp_servers(_state), do: []

  # The team tools (#851), for conversations on the team channel.
  defp team_mcp_servers(%{callback_token: token, conversation_id: conv_id})
       when is_binary(token) and is_binary(conv_id),
       do: Fountain.Team.conversation_mcp_servers(conv_id, token)

  defp team_mcp_servers(_state), do: []

  # A teammate's email + phone tools (flag `team_comms`), injected the same
  # way: only for a team conversation whose teammate has a contact, and only
  # once a callback token exists — `Fountain.Team.Comms` decides. Computed
  # at every turn kick, so a contact given mid-session is there next turn.
  defp team_comms_mcp_servers(%{callback_token: token, conversation_id: conv_id})
       when is_binary(token) and is_binary(conv_id) do
    Fountain.Team.Comms.conversation_mcp_servers(conv_id, token)
  end

  defp team_comms_mcp_servers(_state), do: []

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

  # End the running turn without a verdict from the agent: the user asked, or
  # the machine under it is going away. Tells the agent before killing its
  # process — `session/cancel` is a notification with no reply, so it costs
  # one write and does not delay the kill, but it is the difference between
  # an agent that stops its tool calls and one that is shot mid-write. This is
  # the other reason stdin stays open on the ACP path.
  defp interrupt_turn(state) do
    if state.acp_peer, do: Fountain.Runtimes.ACP.Peer.cancel(state.acp_peer)
    # EOF before the handle goes: a detachable session survives its client
    # disconnecting, so closing the WebSocket alone would leave the adapter —
    # and whatever background task it was running — alive on the machine.
    if state.current_command, do: Fountain.Sandbox.close_stdin(state.current_command)
    if state.current_command, do: Fountain.Sandbox.stop_command(state.current_command)
    state = cancel_autonomous_quiet(state)

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
    finalize_tracer(state.stream_tracer)

    # An ACP turn can also end here — the adapter exits, is interrupted, or its
    # socket drops before it ever answers `session/prompt`. The peer has nothing
    # left to drive and must not outlive the turn.
    stop_acp_peer(state)

    end_turn_span(state.current_turn_span, :error, %{"outcome" => "interrupted"})

    emit_turn_completed(state, "interrupted")

    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
    {:ok, _} = Conversations.update_conversation(conv, %{status: "idle"})

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
    }
  end

  # Whether this machine can take a turn from this conversation right now. An
  # unlocked read — the locked check is inside the turn insert
  # (`_unsafe_create_turn_on_sandbox/3`); this one exists so the API door gets
  # a refusal to render rather than an `:ok` followed by a refused stage.
  defp capacity_gate(state, conv) do
    capacity = Fountain.Runtimes.ACP.concurrency(conv.runtime)

    if Conversations._unsafe_sandbox_at_capacity?(state.sandbox_id, conv.id, capacity),
      do: {:error, :sandbox_at_capacity},
      else: :ok
  end

  defp kick_turn(state, prompt, agent, images) do
    state = touch_activity(state)
    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
    turn_number = Conversations._unsafe_next_turn_number(state.conversation_id)

    attrs = %{
      conversation_id: conv.id,
      turn_number: turn_number,
      prompt: prompt,
      status: "running",
      started_at: now()
    }

    # The machine may be shared (ADR 0023). For a runtime that takes one turn
    # at a time the insert is checked under the sandbox's lock, so two
    # conversations prompting the same machine at once cannot both start.
    capacity = Fountain.Runtimes.ACP.concurrency(conv.runtime)

    case Conversations._unsafe_create_turn_on_sandbox(attrs, state.sandbox_id, capacity) do
      {:ok, turn} ->
        run_turn(state, conv, turn, prompt, agent, images)

      {:error, :sandbox_at_capacity} ->
        # Refused, not queued. Nothing was written; the conversation stays
        # idle and the caller sends again when the other turn ends.
        publish_stage(state.conversation_id, "sandbox", "done", %{
          event: "at_capacity",
          reason: "sandbox_at_capacity",
          runtime: conv.runtime,
          message:
            "Another conversation is running a turn on this sandbox, and #{conv.runtime} " <>
              "takes one turn at a time. Wait for it to finish, or interrupt it, then send again."
        })

        state
    end
  end

  defp run_turn(state, conv, turn, prompt, agent, images) do
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
    # Not for a teammate's conversation: there the title is the name the user
    # gave the teammate when adding it (or nothing, and the agent's name
    # shows), and a generated summary would rename the teammate on the team
    # page after its first message (#807).
    if turn.turn_number == 1 and conv.channel_id != Fountain.Team.channel() do
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

    # Keyed on the conversation's runtime, not the agent: a conversation
    # outlives its agent (deletion nilifies agent_id), and for a supported
    # runtime the legacy spawn path no longer exists to fall back to.
    acp? = Fountain.Runtimes.ACP.enabled?(conv.runtime)

    # The connection outlives the turn (#817). If a peer from an earlier turn
    # is still idle on this machine, this turn rides it — no spawn, no
    # handshake, no `session/resume`, no model pin — so a background task it
    # left running keeps running and codex's session grant survives.
    if acp? and connection_alive?(state) do
      resume_acp_connection(state, conv, turn, prompt, images)
    else
      run_fresh_turn(state, conv, turn, prompt, agent, images, acp?)
    end
  end

  defp run_fresh_turn(state, conv, turn, prompt, agent, images, acp?) do
    turn_number = turn.turn_number

    # Write image temp files to sprite. Only on the legacy path: ACP carries
    # images as content blocks inside `session/prompt`, so writing them into
    # the sandbox first would be a round trip whose product nothing reads.
    image_paths = if acp?, do: [], else: write_image_temp_files(state.handle, turn.id, images)

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
          # Under ACP this value is a placeholder, not an identity: the spec
          # makes the *agent* mint the session id, so `session/new` proposes
          # nothing and the id that comes back overwrites this one (see the
          # `{:acp, ref, {:session, id}}` handler). What the row still buys is
          # the `mode` decision above — a persisted id means "a turn has
          # happened", which is what picks `session/resume` or `session/load`
          # over `session/new`. It used to buy gemini's legacy `--resume` the
          # same signal; that argv is gone with #941.
          new_id = Ecto.UUID.generate()
          {:ok, _} = Conversations.update_conversation(conv, %{runtime_session_id: new_id})
          new_id

        existing ->
          existing
      end

    # 0014: a supported runtime spawns an ACP adapter instead of the CLI, and
    # everything about the turn — the prompt, the images, the session id, the
    # mode — travels over the protocol rather than in argv, so
    # `build_command/5` is not consulted at all on this path. There is no
    # opt-in left to check: gate 4 deleted the legacy spawn path for claude,
    # codex and opencode along with the per-agent flag, so `acp?` is a
    # property of `conv.runtime` alone.
    #
    # The `else` branch is now **unreachable in production**. It survived for
    # gemini until #659 put it on ACP and #941 deleted its `build_command/5`;
    # no runtime module implements that callback any more, and `for_runtime/1`
    # refuses a name that has no module, so a conversation whose runtime lacks
    # an ACP adapter cannot start in the first place. It is kept because the
    # turn machinery it leads to — the log budget, stdin handling, exit codes —
    # is shared, and `Fountain.Test.FakeRuntime` still drives it here.
    {cmd, args, build_opts} =
      if acp? do
        {c, a} = Fountain.Runtimes.ACP.command(conv.runtime)
        # The ACP `cwd` is validated in band by the agent CLI against the real
        # filesystem, so it must be the path a process inside the sandbox sees
        # — identity on hosted providers, the mapped directory on a runner
        # (ADR 0022).
        acp_cwd =
          Fountain.Sandbox.host_path(state.handle, Fountain.Runtimes.ACP.cwd(conv.runtime))

        {c, a, stdin?: true, dir: acp_cwd}
      else
        state.runtime_module.build_command(agent, prompt, mode, runtime_session_id,
          images: image_paths
        )
      end

    # If a runtime embeds the prompt in argv (codex), it returns
    # `stdin?: false` and we skip the write_stdin/close_stdin pipeline.
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
    turn_span = open_turn_span(state, conv, turn, mode, agent)
    previous_span = OpenTelemetry.Tracer.set_current_span(turn_span)

    # Tag the detachable session with this conversation, on its own command
    # line, so a reattach after a deploy can tell it from another
    # conversation's process on the same machine (ADR 0023 gate 1).
    {cmd, args} = Fountain.Conversations.Identity.tag_command(state.conversation_id, cmd, args)

    # Stamped before the spawn so the duration covers the round trip to
    # sprites.dev — that latency is part of what the user waits through.
    # Kept local until the spawn succeeds: a spawn that never starts has no
    # run to time, and a stamp left in state would attach itself to the
    # next turn.
    turn_started_mono = System.monotonic_time(:millisecond)

    state = broker_refresh(state)

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

      case Fountain.Sandbox.spawn(state.handle, cmd, args, spawn_opts) do
        {:ok, command} ->
          # write_stdin/2 is total by contract — a runtime that exits before
          # reading its prompt yields {:error, :command_exited} rather than
          # taking this server down (#603).
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
              # Tool-span tracing. Every ACP turn gets it, whatever the runtime
              # — `session/update` carries the id and status the tracer keys on
              # (#637). The legacy path traces nothing: its only tracer was a
              # parser over claude's dialect, deleted with that path.
              stream_tracer = if acp?, do: Fountain.Runtimes.ACP.Tracer.new(turn_span)

              {peer, peer_mon} =
                if acp? do
                  start_acp_peer(command, prompt, mode, runtime_session_id,
                    cwd: cwd,
                    images: images,
                    mcp_servers:
                      Fountain.Runtimes.ACP.mcp_servers(agent) ++
                        buzz_mcp_servers(state) ++
                        team_mcp_servers(state) ++
                        team_comms_mcp_servers(state),
                    model: agent && Fountain.Runtimes.Model.id(agent.model),
                    permission_policy: effective_permission_policy(conv, agent)
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
  # The adapter sends the owner `{:exit, %{ref: ref}, code}` — behind
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

  defp record_turn_usage(%{current_turn: %{} = turn}, %{} = usage) do
    case Conversations._unsafe_record_turn_usage(turn, usage) do
      {:ok, _} ->
        :ok

      other ->
        Logger.warning(
          "conv #{turn.conversation_id}: turn #{turn.id} usage not recorded: #{inspect(other)}"
        )
    end
  end

  defp record_turn_usage(_state, _usage), do: :ok

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
    case Fountain.Sandbox.write_stdin(command, payload) do
      :ok -> Fountain.Sandbox.close_stdin(command)
      {:error, reason} -> {:error, reason}
    end
  end

  # Persistence for peer-relayed lines: the log budget, redaction and the
  # legacy replay skip all live on this path; the tracer reads protocol lines
  # from the peer's reports, never raw chunks.
  defp persist_acp_lines(state, stream, data) do
    new_state = log_with_replay_skip(state, stream, data)

    # Each "acp" report is one session/update line; the tracer turns tool_call
    # / tool_call_update into child spans. Peer-relayed lines carry no byte
    # replay-suffix arithmetic: a fresh peer's lines never replay, and an
    # attached peer's replayed lines were matched by content before this.
    tracer =
      if stream == "acp" do
        Fountain.Runtimes.ACP.Tracer.handle_line(new_state.stream_tracer, data)
      else
        new_state.stream_tracer
      end

    %{new_state | stream_tracer: tracer}
  end

  # The permission policy in force for this turn (#939): the agent's own,
  # clamped by whatever narrowing the launch asked for. Resolved per turn from
  # the agent rather than read off a policy frozen on the conversation row, so
  # tightening an agent tightens the conversations already running under it.
  defp effective_permission_policy(conv, agent) do
    Fountain.Permissions.effective(agent && agent.permission_policy, conv.permission_policy)
  end

  # Ownership is already established: this server exists for this conversation.
  # See the `_unsafe_` rules in CLAUDE.md — a GenServer holding the conversation
  # is one of the legitimate callers.
  defp agent_for(conv), do: conv.agent_id && Agents._unsafe_get_agent(conv.agent_id)

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
        mcp_servers: Keyword.get(opts, :mcp_servers, []),
        model: Keyword.get(opts, :model),
        permission_policy: Keyword.get(opts, :permission_policy)
      )

    {peer, Process.monitor(peer)}
  end

  # Terminal path for an ACP turn. The order matters: stdin closes first so the
  # adapter starts exiting while we do the bookkeeping, and `current_command_ref`
  # is cleared at the end so the `{:exit, …}` that follows finds no match and
  # falls through to the catch-all. A turn ends on the prompt response *or* the
  # process exit, whichever arrives first, and never waits for both.
  # Called on every way a turn can end; ACP turns are the only ones that
  # trace, so nil is the legacy case.
  defp finalize_tracer(nil), do: :ok
  defp finalize_tracer(tracer), do: Fountain.Runtimes.ACP.Tracer.finalize(tracer)

  # The turn's OTel span. Opened explicitly (not via Telemetry.span) because a
  # turn finishes asynchronously, in a later handler; the context is carried in
  # state and closed there. `mode` is `:run` | `:continue` | `:autonomous`.
  defp open_turn_span(state, conv, turn, mode, agent) do
    OpenTelemetry.Tracer.start_span("fountain.turn", %{
      attributes: %{
        "conv_id" => conv.id,
        "turn_id" => turn.id,
        "turn_number" => turn.turn_number,
        "mode" => Atom.to_string(mode),
        "runtime" => to_string(conv.runtime),
        "model" => agent && agent.model,
        "agent_id" => agent && agent.id,
        "user_id" => state.user_id,
        "prompt_length" => byte_size(turn.prompt),
        "image_count" => 0
      }
    })
  end

  # gemini erases a session in the act of loading it (#659), so its store is
  # consolidated at the end of every turn — before the next turn's
  # `session/load` can collide with it. Best-effort and gemini-only; delete
  # with the workaround when gemini-cli#28775 lands.
  defp consolidate_gemini_session(%{handle: handle} = state) when not is_nil(handle) do
    conv = Conversations._unsafe_get_conversation!(state.conversation_id)

    if conv.runtime == "gemini" do
      Fountain.Runtimes.Gemini.SessionStore.consolidate(handle, conv.runtime_session_id)
    end

    :ok
  end

  defp consolidate_gemini_session(_state), do: :ok

  # End a turn, and only a turn (#817). The connection — `current_command`,
  # `current_command_ref`, `acp_peer` — is left alive and idle for the next
  # `prompt/3`; what is cleared here is the turn's own bookkeeping. The
  # connection is closed elsewhere, by `drop_connection/2`, when the sandbox
  # stops being this server's.
  defp finish_acp_turn(state, status, span_attrs, stage_meta) do
    # Resolve a held permission request as the turn ends (#940): a card left
    # open is a client waiting on an answer that can never come, and the
    # turn's `pending_permission` would stay set on a turn that is over.
    state = resolve_pending_permission(state, "turn_ended")
    state = cancel_autonomous_quiet(state)

    # Before the turn span ends: totals land on it, abandoned tool spans close.
    finalize_tracer(state.stream_tracer)

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
      | current_turn: nil,
        current_turn_span: nil,
        turn_metrics: nil,
        stream_tracer: nil
    }
  end

  # ── the connection (#817) ─────────────────────────────────────────────────

  # Whether an idle peer from an earlier turn is still driving this machine.
  defp connection_alive?(%{acp_peer: peer}) when is_pid(peer), do: Process.alive?(peer)
  defp connection_alive?(_state), do: false

  defp user_turn_running?(%{current_turn: %{origin: "autonomous"}}), do: false
  defp user_turn_running?(%{current_turn: turn}), do: not is_nil(turn)

  defp autonomous_turn?(%{current_turn: %{origin: "autonomous"}}), do: true
  defp autonomous_turn?(_state), do: false

  # This turn rides the open connection: no spawn, no handshake. `Peer.prompt/3`
  # reuses the session already open, so a background task keeps running and the
  # runtime's per-session grants survive (#817).
  defp resume_acp_connection(state, conv, turn, prompt, images) do
    turn_span = open_turn_span(state, conv, turn, :continue, agent_for(conv))
    previous_span = OpenTelemetry.Tracer.set_current_span(turn_span)

    publish_stage(state.conversation_id, "turn", "started", %{
      turn_id: turn.id,
      turn_number: turn.turn_number,
      mode: "continue",
      connection: "reused"
    })

    started_mono = System.monotonic_time(:millisecond)

    case Fountain.Runtimes.ACP.Peer.prompt(state.acp_peer, prompt, images) do
      :ok ->
        OpenTelemetry.Tracer.set_current_span(previous_span)

        %{
          touch_activity(state)
          | current_turn: turn,
            current_turn_span: turn_span,
            turn_metrics: %{
              started_mono: started_mono,
              runtime: conv.runtime,
              first_output?: false
            },
            stream_tracer: Fountain.Runtimes.ACP.Tracer.new(turn_span)
        }

      {:error, reason} ->
        # The idle peer would not take the prompt (it died between the check
        # and the call, or is wedged). Drop it and spawn fresh — the turn row
        # already exists, so run the fresh path against it.
        Logger.warning(
          "conv #{state.conversation_id}: idle peer refused prompt (#{inspect(reason)}); respawning"
        )

        OpenTelemetry.Tracer.set_current_span(previous_span)
        end_turn_span(turn_span, :error, %{"error" => "peer_refused_reuse"})
        state = drop_connection(state, "peer_refused_reuse")
        run_fresh_turn(state, conv, turn, prompt, agent_for(conv), images, true)
    end
  end

  # Close the ACP connection: EOF the adapter so it exits (a detachable
  # session outlives its client, so closing the socket alone leaves it and any
  # background task running), consolidate gemini's store before the next
  # `session/load` can collide, stop the peer, and clear the connection
  # fields. An autonomous turn still open is completed first — its updates are
  # real. Safe on a server with no connection.
  defp drop_connection(%{acp_peer: nil, current_command: nil} = state, _why), do: state

  defp drop_connection(state, why) do
    state =
      if autonomous_turn?(state) do
        finish_acp_turn(state, "completed", %{"origin" => "connection_closed"}, %{
          origin: "autonomous",
          cycle: "connection_closed"
        })
      else
        state
      end

    state = cancel_autonomous_quiet(state)
    if state.current_command, do: Fountain.Sandbox.close_stdin(state.current_command)
    consolidate_gemini_session(state)
    stop_acp_peer(state)
    if state.current_command, do: Fountain.Sandbox.stop_command(state.current_command)

    _ = why

    %{
      state
      | current_command: nil,
        current_command_ref: nil,
        acp_peer: nil,
        acp_peer_mon: nil
    }
  end

  # The adapter went away between turns with no turn to fail (#817). Record it
  # on the transcript and clear the connection; the next prompt spawns fresh.
  defp connection_lost(state, reason, meta) do
    publish_stage(
      state.conversation_id,
      "sandbox",
      "done",
      Map.merge(%{event: "connection_lost", reason: reason}, meta)
    )

    state = cancel_autonomous_quiet(state)
    consolidate_gemini_session(state)

    %{
      state
      | current_command: nil,
        current_command_ref: nil,
        acp_peer: nil,
        acp_peer_mon: nil
    }
  end

  # An out-of-turn protocol line opened a background cycle (#817). A real turn
  # row so the log budget, redaction and stage events all apply; `origin:
  # "autonomous"` and a marker prompt tell it from a user turn.
  defp open_autonomous_turn(state) do
    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
    turn_number = Conversations._unsafe_next_turn_number(state.conversation_id)

    {:ok, turn} =
      Conversations._unsafe_create_turn(%{
        conversation_id: conv.id,
        turn_number: turn_number,
        prompt: "(background task follow-up)",
        origin: "autonomous",
        status: "running",
        started_at: now()
      })

    turn_span = open_turn_span(state, conv, turn, :autonomous, agent_for(conv))

    publish_stage(state.conversation_id, "turn", "started", %{
      turn_id: turn.id,
      turn_number: turn_number,
      origin: "autonomous"
    })

    {:ok, _} = Conversations.update_conversation(conv, %{status: "running"})

    arm_autonomous_quiet(%{
      touch_activity(state)
      | current_turn: turn,
        current_turn_span: turn_span,
        turn_metrics: nil,
        stream_tracer: Fountain.Runtimes.ACP.Tracer.new(turn_span)
    })
  end

  defp close_autonomous_turn(state, why) do
    if autonomous_turn?(state) do
      finish_acp_turn(state, "completed", %{"origin" => why}, %{origin: "autonomous", cycle: why})
    else
      state
    end
  end

  defp arm_autonomous_quiet(state) do
    state = cancel_autonomous_quiet(state)
    turn_id = state.current_turn && state.current_turn.id

    timer =
      if turn_id do
        Process.send_after(self(), {:autonomous_quiet, turn_id}, autonomous_quiet_ms())
      end

    %{state | autonomous_quiet: timer}
  end

  defp cancel_autonomous_quiet(%{autonomous_quiet: nil} = state), do: state

  defp cancel_autonomous_quiet(%{autonomous_quiet: timer} = state) do
    Process.cancel_timer(timer)
    %{state | autonomous_quiet: nil}
  end

  defp autonomous_quiet_ms do
    Application.get_env(:fountain, :autonomous_turn_quiet_ms, @autonomous_quiet_ms)
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

  # The provider's own sentence is the useful half, and it usually names the
  # replacement, so it is quoted rather than summarised. Fountain adds only
  # what the provider cannot know: which field holds the model, and that no
  # retry helps until that field changes.
  defp model_unavailable_message(requested, detail) do
    named = if is_binary(requested) and requested != "", do: " (#{requested})", else: ""

    "The provider refused this agent's model#{named}: #{String.trim(detail)} " <>
      "Change the agent's model, then send your prompt again. " <>
      "Every turn fails the same way until it changes."
  end

  # Every turn passes through here, whichever door it came in by — the
  # controller/LiveView call above, or the queued initial prompt a wake
  # delivers as a cast. The provisioning gates cover fresh sprites only; a
  # live server (or the reuse arm of a wake) outlives the balance it was
  # started under, and each turn resets the idle clock, so a balance spent to
  # zero otherwise bought up to the 24h max lifetime of continued service per
  # live sandbox (#313). Suspension is the same shape.
  defp turn_gate(user_id) do
    with :ok <- Fountain.Accounts.check_not_suspended(user_id) do
      Fountain.Billing.check_spend(user_id)
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # Write each image to a temp path in the sprite filesystem and return
  # a list of {path, media_type} tuples for passing to the runtime.
  defp write_image_temp_files(_handle, _turn_id, []), do: []

  defp write_image_temp_files(handle, turn_id, images) do
    images
    |> Enum.with_index()
    |> Enum.map(fn {%{media_type: mt, data: data}, idx} ->
      ext = media_type_to_ext(mt)
      path = "/tmp/aod_turn_#{turn_id}_#{idx}.#{ext}"
      Fountain.Sandbox.write_file(handle, path, data)
      {path, mt}
    end)
  end

  defp media_type_to_ext("image/png"), do: "png"
  defp media_type_to_ext("image/jpeg"), do: "jpeg"
  defp media_type_to_ext("image/gif"), do: "gif"
  defp media_type_to_ext("image/webp"), do: "webp"
  defp media_type_to_ext(_), do: "bin"
end
