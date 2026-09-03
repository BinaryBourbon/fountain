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
    Environments,
    Vaults
  }

  alias Fountain.Conversations.{
    CallbackKey,
    Conversation,
    Egress,
    Lifecycle,
    McpServers,
    Pending,
    Provisioning,
    SpriteEnv,
    TurnMachine
  }

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

  @doc """
  Interrupt the turn in flight, if any.

  If no server answers for this conversation, that alone doesn't mean there
  is nothing to interrupt: the process can have exited (deploy, Horde
  rebalance, a plain `{:stop, :normal, _}` return) while a turn was still
  marked `running`, with nothing left to close it (#1179 — an autonomous
  "background task follow-up" turn stuck this way for 4+ hours, `interrupt`
  404ing the whole time, indistinguishable from hitting a conversation that
  doesn't exist). Mirror `send_prompt/4`'s wake-on-miss fallback, but only
  when the row says `running` — an idle/terminated/unknown conversation has
  nothing running regardless, and must not pay for a wake it doesn't need.
  Waking reattaches to a live sprite session if one exists (and this second
  `interrupt` call then really does end it), or reconciles the orphaned turn
  itself when none does.
  """
  def interrupt(conv_id, opts \\ []) do
    result =
      case whereis(conv_id) do
        nil -> interrupt_dead(conv_id)
        pid -> call_server(pid, :interrupt)
      end

    audit_lifecycle(conv_id, "conversation.interrupted", result, opts)
    result
  end

  defp interrupt_dead(conv_id) do
    case Conversations._unsafe_get_conversation(conv_id) do
      %Conversation{status: "running"} ->
        case Conversations.wake_conversation(conv_id) do
          {:ok, conv} ->
            case whereis(conv.id) do
              nil -> {:error, :not_running}
              pid -> call_server(pid, :interrupt)
            end

          {:error, _} ->
            {:error, :not_running}
        end

      _ ->
        {:error, :not_running}
    end
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

  ## ─── The tool bridge (#1202, `Fountain.CallerTools`) ─────────────────────

  @doc """
  Park a caller-tool call the agent just made. The call gets an id, a
  `caller_tool`/`started` stage event goes out (which is what closes the
  client's completion with `tool_calls`), and a deadline is armed. `waiter`
  receives `{:caller_tool_result, id, result}` when the call resolves.

  `{:error, :no_turn}` when nothing is running: a call needs a turn to belong
  to, and the client following that turn is the only party that can answer.
  """
  @spec park_caller_tool(binary(), String.t(), map(), pid()) ::
          {:ok, String.t()} | {:error, :not_running | :no_turn}
  def park_caller_tool(conv_id, name, arguments, waiter) do
    case whereis(conv_id) do
      nil -> {:error, :not_running}
      pid -> call_server(pid, {:park_caller_tool, name, arguments, waiter})
    end
  end

  @doc """
  Re-attach `waiter` to a parked call (the MCP handler's in-request wait ran
  out and the agent is asking again). `{:ok, result}` at once if it resolved
  meanwhile — a result is kept until the turn ends, so an answer that landed
  between two waits is not lost.
  """
  @spec await_caller_tool(binary(), String.t(), pid()) ::
          {:ok, {:ok, String.t()} | {:error, String.t()}}
          | :pending
          | {:error, :unknown_call | :not_running}
  def await_caller_tool(conv_id, call_id, waiter) do
    case whereis(conv_id) do
      nil -> {:error, :not_running}
      pid -> call_server(pid, {:await_caller_tool, call_id, waiter})
    end
  end

  @doc "The calls parked and unanswered, oldest first: `%{id, name, arguments, turn_id}`."
  @spec pending_caller_calls(binary()) :: [map()]
  def pending_caller_calls(conv_id) do
    case whereis(conv_id) do
      nil -> []
      pid -> call_server(pid, :pending_caller_calls)
    end
  end

  @doc """
  Resolve parked calls with the client's answers, `%{call_id => content}`.
  Ids that match nothing are ignored; if none match, `{:error, :no_pending_calls}`
  and nothing changes. Returns the turn the calls belong to and whatever is
  still parked, so the controller can emit the remainder at once instead of
  waiting for a stage event that is already behind its cursor.
  """
  @spec answer_caller_tools(binary(), %{String.t() => String.t()}) ::
          {:ok, %{turn_id: binary() | nil, remaining: [map()]}}
          | {:error, :no_pending_calls | :not_running}
  def answer_caller_tools(conv_id, answers) when is_map(answers) do
    case whereis(conv_id) do
      nil -> {:error, :not_running}
      pid -> call_server(pid, {:answer_caller_tools, answers})
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
      # The env var names of the tenant's connections brokered into this
      # conversation (#1178): their access tokens rotate hourly, so each turn
      # kick re-reads them and re-prepares the vault when one has changed.
      connection_keys: [],
      # The environment's networking shape, enforced at the broker (gate 2).
      broker_network: :unrestricted,
      # What the runtime's default_env/2 is handed (gate 3): the real
      # credentials, or placeholders when the conversation is brokered.
      env_credentials: %{},
      # #1388; see `SpriteEnv.select_inference/2`, which decides both.
      inference_source: nil,
      inference_model: nil,
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
      # Caller-tool calls parked on the turn (#1202): id => %{name, arguments,
      # turn_id, waiter, timer, result}. `result` is nil while parked and the
      # answer once resolved; entries are dropped when the turn ends.
      caller_calls: %{},
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

    Lifecycle.schedule_check()
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

    case SpriteEnv.load_tenant_state(conv.user_id) do
      {:ok, dek, own_creds} ->
        {inference_source, inference_creds} = SpriteEnv.select_inference(agent, own_creds)
        bindings = Egress.bindings(conv.user_id)

        {merged, bindings, connection_keys} =
          Egress.add_connection_secrets(
            conv.user_id,
            SpriteEnv.merge_secrets(env, vault, dek),
            bindings,
            agent
          )

        {secrets, brokered} = Egress.split_brokered(conv.user_id, merged, bindings)

        {env_creds, brokered, bindings} =
          Egress.split_inference(conv.user_id, inference_creds, brokered, bindings)

        state =
          %{
            state
            | user_id: conv.user_id,
              runtime_session_id: conv.runtime_session_id,
              tenant_key: dek,
              inference_credentials: inference_creds,
              inference_source: inference_source,
              inference_model: agent && agent.model,
              env_credentials: env_creds,
              brokered: brokered,
              broker_bindings: bindings,
              connection_keys: connection_keys,
              broker_network: Fountain.Broker.network_for(env)
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

  defp dispatch_provision(state, conv, sandbox, agent, env, _vault, secrets) do
    case McpServers.substitute_agent(agent, env, secrets) do
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
               Egress.brokered?(state.user_id),
               provider,
               env,
               state.conversation_id
             ),
           :ok <- Provisioning.discard_interrupted_attempt(provider, sandbox, interrupted?) do
        Provisioning.create_sandbox_handle(provider, sandbox)
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
        sandbox_url = Provisioning.record_sandbox_url(sandbox, handle)

        # The broker session is minted before the env is built, because the
        # env carries it; the CA is installed before anything dials out,
        # because nothing dials out without it (ADR 0019 gate 1a).
        with {:ok, state} <- broker_prepare(state),
             sprite_env = build_sprite_env(state, agent, env, secrets, sandbox_url),
             # A real step, not best effort: an agent whose MCP servers could
             # not be written would otherwise run without them and report
             # `provision/done`. The runtimes retry the write themselves.
             :ok <-
               Provisioning.write_runtime_config(
                 handle,
                 state.runtime_module,
                 Egress.with_connection_servers(
                   agent,
                   state.user_id,
                   state.conversation_id,
                   state.callback_token
                 )
               ),
             _ = Provisioning.write_instructions(handle, runtime, agent),
             # The file is the machine's; the conversation's identity travels as
             # process env on every spawn (`Fountain.Conversations.Identity`).
             _ =
               Fountain.Conversations.Provisioning.write_env_file(
                 handle,
                 Fountain.Conversations.Identity.disk_env(sprite_env)
               ),
             :ok <- Egress.install_ca(state.broker, handle, state.conversation_id),
             :ok <-
               run_provisioning_pipeline(
                 handle,
                 env,
                 sprite_env,
                 secrets,
                 state.conversation_id,
                 Egress.brokered?(state.user_id)
               ),
             :ok <-
               Provisioning.prepare_runtime_sprite(
                 handle,
                 runtime,
                 state.runtime_module,
                 agent,
                 sprite_env
               ) do
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
              sandbox_started_at: Lifecycle.clock_start(sandbox)
          }

          # Any prompt this conversation was started for arrives as a cast,
          # already queued behind this handle_continue. See
          # queue_initial_prompt/3.
          {:noreply, new_state}
        else
          {:error, reason} ->
            Logger.error("provision step failed: #{inspect(reason)}")
            _ = Managoat.Sandbox.destroy(handle)
            Egress.release(state.user_id, state.conversation_id)
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
        Egress.apply_policy(handle, env, conv_id, brokered?)

      :cold ->
        with :ok <-
               Fountain.Conversations.Provisioning.install_packages(
                 handle,
                 env,
                 sprite_env,
                 conv_id
               ),
             :ok <- Egress.apply_policy(handle, env, conv_id, brokered?),
             :ok <-
               Fountain.Conversations.Provisioning.clone_repositories(
                 handle,
                 env,
                 secrets,
                 sprite_env,
                 conv_id
               ) do
          Provisioning.run_setup_script(handle, env, sprite_env, conv_id)
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
      Managoat.Sandbox.build_handle(
        Fountain.Conversations.sandbox_provider_atom(sandbox),
        sandbox.sprite_name
      )

    # A broker failure lands in the transient arm below: it says nothing
    # about the sandbox, and the next wake mints again.
    with {:ok, _info} <-
           Managoat.Sandbox.Retry.with_backoff(
             fn -> Managoat.Sandbox.get(handle) end,
             label: "sprite lookup on wake"
           ),
         {:ok, state} <- broker_prepare(state) do
      publish_stage(state.conversation_id, "reattach", "started", %{
        sprite_name: sandbox.sprite_name,
        node: to_string(node())
      })

      {state, _conv} = rotate_callback_api_key(state, conv)
      sprite_env = build_sprite_env(state, agent, env, secrets)

      # The callback token just rotated, and for claude the connection MCP
      # servers carry it in `.mcp.json` (#1178): rewrite the file so the
      # next turn's tools authenticate. Idempotent for an agent without one.
      # Best effort here, like the CA below: the turn's own failure says more
      # than a refused wake would.
      case Provisioning.write_runtime_config(
             handle,
             state.runtime_module,
             Egress.with_connection_servers(
               agent,
               state.user_id,
               state.conversation_id,
               state.callback_token
             )
           ) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("runtime config write on wake: #{inspect(reason)}")
      end

      # A machine provisioned before its tenant was brokered has no CA yet;
      # on one that has it this is an idempotent rewrite. Best effort here:
      # the turn's own failure says more than a refused wake would.
      case Egress.install_ca(state.broker, handle, state.conversation_id) do
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
      Provisioning.write_instructions(
        handle,
        conv.runtime || (agent && agent.runtime) || "claude",
        agent
      )

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
          sandbox_started_at: Lifecycle.clock_start(sandbox)
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
      case Managoat.Sandbox.Retry.with_backoff(
             fn -> Managoat.Sandbox.list_sessions(state.handle) end,
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
    case Managoat.Sandbox.list_sessions(state.handle) do
      {:ok, sessions} ->
        mine =
          Enum.filter(
            sessions,
            &(Fountain.Conversations.Identity.conversation_id(&1) == state.conversation_id)
          )

        Enum.each(mine, fn session ->
          case Managoat.Sandbox.attach(state.handle, session.id, owner: self(), stdin: true) do
            {:ok, command} -> Managoat.Sandbox.stop_command(command)
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
    acp? = Managoat.Runtimes.ACP.enabled?(conv.runtime)

    case Managoat.Sandbox.attach(state.handle, session.id, owner: self(), stdin: true) do
      {:ok, idle_command} when acp? and is_nil(running_turn.acp_prompt_id) ->
        # The previous peer died before it wrote `session/prompt` (or the turn
        # predates the column). The adapter is sitting idle in its handshake
        # with nothing to answer, and no peer can pick that up: the ids it
        # would need are gone with the process. Stop it — otherwise it lingers
        # as a session the next reattach could bind to — and orphan the turn.
        Managoat.Sandbox.stop_command(idle_command)
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
      Managoat.ACP.Peer.start(
        owner: self(),
        # The transport seam (Managoat.ACP.Transport): the peer writes through
        # this function and never sees the sandbox. `write_stdin/2` is total —
        # a runtime that has already exited answers {:error, :command_exited},
        # which the peer reports as {:failed, {:acp_write_failed, _}}.
        writer: fn iodata -> Managoat.Sandbox.write_stdin(state.current_command, iodata) end,
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
        permission_policy:
          TurnMachine.effective_permission_policy(conv, TurnMachine.agent_for(conv)),
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

  # ── sprite environment and egress (ADR 0019 gate 1a) ──────────────────────

  # The server's half of `SpriteEnv.build/4`: unpack what the state holds and
  # hand it over. The name stays because the tests and the comments that say
  # "build_sprite_env registers the secrets" still mean this call.
  defp build_sprite_env(state, agent, env, secrets, sandbox_url \\ nil) do
    SpriteEnv.build(agent, env, secrets,
      runtime_module: state.runtime_module,
      env_credentials: state.env_credentials,
      callback_token: state.callback_token,
      conversation_id: state.conversation_id,
      sandbox_id: state.sandbox_id,
      sandbox_url: sandbox_url,
      brokered: Egress.sandbox_env(state.broker)
    )
  end

  # Mint (or re-mint) the conversation's proxy session (`Egress.prepare/4`)
  # and hold it. A no-op that returns the state untouched when the
  # conversation is not brokered.
  defp broker_prepare(state) do
    if Egress.brokered?(state.user_id) do
      case Egress.prepare(state.conversation_id, state.brokered, state.broker_bindings,
             network: state.broker_network,
             user_id: state.user_id
           ) do
        {:ok, session} -> {:ok, %{state | broker: session}}
        {:error, _} = error -> error
      end
    else
      {:ok, state}
    end
  end

  # The OAuth token was refused: forget it on both sides and, when brokered,
  # re-prepare the vault so the API key is what the substitution carries.
  # Best effort — a broker error here leaves the turn to fail at the proxy,
  # which names the cause, rather than silently injecting a plaintext key.
  defp broker_switch_to_api_key(%{broker: nil} = state), do: state

  defp broker_switch_to_api_key(state) do
    {env_creds, brokered, bindings} =
      Egress.drop_oauth_token(state.inference_credentials, state.brokered, state.broker_bindings)

    state = %{state | brokered: brokered, broker_bindings: bindings, env_credentials: env_creds}

    case Egress.reprepare(state.conversation_id, brokered, bindings, state.sprite_env,
           network: state.broker_network,
           user_id: state.user_id
         ) do
      {:ok, session, sprite_env} ->
        %{state | broker: session, sprite_env: sprite_env}

      {:error, reason} ->
        Logger.warning(
          "conv #{state.conversation_id}: broker re-prepare after OAuth refusal failed: #{inspect(reason)}"
        )

        state
    end
  end

  # A session near its end is replaced before the turn that would outlive it.
  # The env is rebuilt with the new token; everything else in it is unchanged.
  defp broker_refresh(%{broker: nil} = state), do: state

  defp broker_refresh(%{broker: session} = state) do
    {brokered, rotated?} =
      Egress.refresh_connection_secrets(state.connection_keys, state.user_id, state.brokered)

    state = %{state | brokered: brokered}

    if rotated? or Fountain.Broker.expiring?(session) do
      case Egress.reprepare(
             state.conversation_id,
             state.brokered,
             state.broker_bindings,
             state.sprite_env,
             network: state.broker_network,
             user_id: state.user_id
           ) do
        {:ok, fresh, sprite_env} ->
          %{state | broker: fresh, sprite_env: sprite_env}

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

      with :ok <- TurnMachine.gate(conv.user_id, state.inference_source),
           :ok <- TurnMachine.capacity_gate(state.sandbox_id, conv) do
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

  # First answer wins (`Pending.answer_permission/6`): the web apps and an
  # editor (#708) are peer clients of this door, not fallbacks for one
  # another, so a second answer to the same request is "too late" rather
  # than an error in the caller.
  def handle_call({:answer_permission, request_id, option_id}, _from, state) do
    {reply, turn, pending} =
      Pending.answer_permission(
        Pending.from_state(state),
        state.conversation_id,
        state.current_turn,
        state.acp_peer,
        request_id,
        option_id
      )

    {:reply, reply, %{Pending.into_state(state, pending) | current_turn: turn}}
  end

  # A call needs a turn to belong to, and the client following that turn is
  # the only party that can answer.
  def handle_call({:park_caller_tool, name, arguments, waiter}, _from, state) do
    case state.current_turn do
      nil ->
        {:reply, {:error, :no_turn}, state}

      turn ->
        {call_id, pending} =
          Pending.park(
            Pending.from_state(state),
            state.conversation_id,
            turn,
            name,
            arguments,
            waiter
          )

        {:reply, {:ok, call_id}, Pending.into_state(state, pending)}
    end
  end

  def handle_call({:await_caller_tool, call_id, waiter}, _from, state) do
    {reply, pending} = Pending.await(Pending.from_state(state), call_id, waiter)
    {:reply, reply, Pending.into_state(state, pending)}
  end

  def handle_call(:pending_caller_calls, _from, state) do
    {:reply, Pending.calls(Pending.from_state(state)), state}
  end

  def handle_call({:answer_caller_tools, answers}, _from, state) do
    {reply, pending} =
      Pending.answer_calls(Pending.from_state(state), state.conversation_id, answers)

    {:reply, reply, Pending.into_state(state, pending)}
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
        reason:
          if(Lifecycle.home?(state.sandbox_id),
            do: "persistent_home",
            else: "held_by_another_conversation"
          )
      })

      {:stop, :normal, :ok, %{state | handle: nil}}
    else
      state = drop_connection(state, "terminated")
      if state.handle, do: _ = Managoat.Sandbox.destroy(state.handle)
      Egress.release(state.user_id, state.conversation_id)
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

      case TurnMachine.gate(conv.user_id, state.inference_source) do
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
    Managoat.ACP.Peer.stdout(peer, data)
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

  # No `cycle_end` came. Close the autonomous turn as completed — the updates
  # it collected are real — and say why.
  def handle_info({:autonomous_quiet, turn_id}, %{current_turn: %{id: turn_id}} = state) do
    if TurnMachine.autonomous_turn?(state) do
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

  # Nobody answered in time. Deny — the only safe default — and say so on the
  # stream so a card stops waiting.
  def handle_info({:permission_timeout, request_id}, state) do
    {:noreply, resolve_permission(state, request_id, "timeout", nil)}
  end

  # The caller never answered a parked tool call (#1202). The agent gets an
  # error result and carries on; the stream records the outcome.
  def handle_info({:caller_tool_timeout, call_id}, state) do
    pending =
      Pending.resolve_call(
        Pending.from_state(state),
        state.conversation_id,
        call_id,
        "timeout",
        {:error, "the caller did not answer within the deadline"}
      )

    {:noreply, Pending.into_state(state, pending)}
  end

  # #655: the org has refused this account's Claude OAuth token. The machine
  # words the outcome and ends the turn; what has to happen first, and here,
  # is the swap: the API key sitting in the same `inference_credentials` row
  # replaces the refused token in the sprite env and the broker session for
  # the rest of this server's life. Whether a key was there to swap in is
  # what the machine's message turns on.
  def handle_info(
        {:acp, ref, {:failed, {:oauth_org_not_allowed, detail}} = payload},
        %{current_command_ref: ref, runtime_module: Managoat.Runtimes.Claude} = state
      ) do
    Logger.warning("conv #{state.conversation_id}: Claude OAuth token refused by org: #{detail}")

    # On a brokered conversation the API key is a placeholder in the env and
    # the value moves to the broker; the vault is re-prepared so its
    # substitution now carries the key instead of the refused OAuth token.
    state = broker_switch_to_api_key(state)

    fallback_env =
      Managoat.Runtimes.Claude.fall_back_to_api_key(state.sprite_env, state.env_credentials)

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
        inference_credentials: Map.delete(state.inference_credentials, :claude_code_oauth_token),
        env_credentials: Map.delete(state.env_credentials, :claude_code_oauth_token)
    }

    {:noreply, drive_turn(state, payload, oauth_switched?: switched?)}
  end

  # Every other report is the turn state machine's (#1374): one call, then
  # the effects it hands back, applied in order.
  def handle_info({:acp, ref, payload}, %{current_command_ref: ref} = state) do
    {:noreply, drive_turn(state, payload)}
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
    TurnMachine.finalize_tracer(state.stream_tracer)

    # An ACP turn can also end here — the adapter exits, is interrupted, or its
    # socket drops before it ever answers `session/prompt`. The peer has nothing
    # left to drive and must not outlive the turn.
    stop_acp_peer(state)

    # Close the OTel turn span we opened in kick_turn.
    TurnMachine.end_span(
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

    TurnMachine.finalize_tracer(state.stream_tracer)

    # An ACP turn can also end here — the adapter exits, is interrupted, or its
    # socket drops before it ever answers `session/prompt`. The peer has nothing
    # left to drive and must not outlive the turn.
    stop_acp_peer(state)
    TurnMachine.end_span(state.current_turn_span, :error, %{"error" => inspect(reason)})

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

  # ── permissions, reclaim and redaction ────────────────────────────────────

  def handle_info(:lifecycle_check, state) do
    Lifecycle.schedule_check()

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

  # The permission request's end, whichever way (`Pending.resolve_permission/7`):
  # the turn row and the timer are the server's to hold.
  defp resolve_permission(state, request_id, outcome, option_id) do
    {turn, pending} =
      Pending.resolve_permission(
        Pending.from_state(state),
        state.conversation_id,
        state.current_turn,
        state.acp_peer,
        request_id,
        outcome,
        option_id
      )

    %{Pending.into_state(state, pending) | current_turn: turn}
  end

  # Resolve whatever is held, if anything, as the turn ends.
  defp resolve_pending_permission(state, outcome) do
    {turn, pending} =
      Pending.resolve_pending_permission(
        Pending.from_state(state),
        state.conversation_id,
        state.current_turn,
        state.acp_peer,
        outcome
      )

    %{Pending.into_state(state, pending) | current_turn: turn}
  end

  # Everything still parked when the turn ends (`Pending.drop_calls/3`).
  defp drop_caller_tools(state, outcome) do
    pending = Pending.drop_calls(Pending.from_state(state), state.conversation_id, outcome)
    Pending.into_state(state, pending)
  end

  # The server's own clock stamp: the input `Lifecycle.check/4` reads. Nothing
  # but this process writes it.
  defp touch_activity(state), do: %{state | last_activity_at: DateTime.utc_now()}

  # Idle: the machine's verdict, not this conversation's (ADR 0023 step 5).
  defp reclaim_sandbox(state, :idle) do
    if Lifecycle.busy_elsewhere?(state.sandbox_id, state.conversation_id) do
      # This conversation is idle; the machine is not. Another conversation
      # on it is mid-turn or was active more recently than the bound, so the
      # verdict is the machine's to reach, over all of them (ADR 0023 step 5).
      # Checked again on the next tick.
      {:noreply, state}
    else
      case Lifecycle.idle_machine_action(state.conversation_id, state.handle) do
        :park -> park_sandbox(state)
        :destroy -> destroy_sandbox(state, :idle)
      end
    end
  end

  # Max lifetime: `Lifecycle.max_lifetime_action/2` decides, and has already
  # made the suspend call by the time it answers `:park`.
  defp reclaim_sandbox(state, :max_lifetime) do
    case Lifecycle.max_lifetime_action(state.sandbox_id, state.handle) do
      :park -> park_sandbox(state, :max_lifetime)
      :destroy -> destroy_sandbox(state, :max_lifetime)
    end
  end

  # The log line and the connection are the process's; the rest of a park is
  # `Lifecycle.park/4`.
  defp park_sandbox(state, reason \\ :idle) do
    Logger.info(
      "suspending sandbox for conv #{state.conversation_id}: #{reason} " <>
        "(sprite #{inspect(state.handle && state.handle.name)})"
    )

    # A parked sprite never keeps a live adapter (#817).
    state = drop_connection(state, "suspended")
    Lifecycle.park(state.conversation_id, state.sandbox_id, state.handle, reason)

    # The conversation stays idle and resumable; the sprite stays parked.
    {:stop, :normal, %{state | handle: nil}}
  end

  # The same shape for a destroy (`Lifecycle.destroy/5`).
  defp destroy_sandbox(state, reason) do
    Logger.info(
      "reclaiming sandbox for conv #{state.conversation_id}: #{reason} " <>
        "(sprite #{inspect(state.handle && state.handle.name)})"
    )

    state = drop_connection(state, "reclaimed")

    Lifecycle.destroy(
      state.conversation_id,
      state.sandbox_id,
      state.user_id,
      state.handle,
      reason
    )

    {:stop, :normal, %{state | handle: nil}}
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
  # is left behind, but it is not dangerous: `CallbackKey.api_key_opts/0`
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

  # ── turns ─────────────────────────────────────────────────────────────────

  # A runtime session cannot follow the conversation onto a fresh sandbox
  # (`TurnMachine.reset_runtime_session/2`, #778). Done inside the server
  # rather than by the wake caller: the caller's row update races this
  # server's own read of the row in handle_continue.
  defp forget_runtime_session(%{runtime_session_id: nil} = state, _conv), do: state

  defp forget_runtime_session(state, conv) do
    TurnMachine.reset_runtime_session(conv, state.conversation_id)
    %{state | runtime_session_id: nil}
  end

  @doc """
  The options a sprite's callback key is minted with: `CallbackKey.api_key_opts/0`.

  Re-exported here because `conversation_server_shutdown_revoke_test`,
  `api_key_scope_test` and `audit_coverage_test` pin the scope and expiry
  through this module, and the server tests do not change (#1369).
  """
  def callback_api_key_opts, do: CallbackKey.api_key_opts()

  # Rotate the sandbox's callback key (`CallbackKey.rotate/2`) and hold the
  # result: the plaintext and the row id on success. On failure only the
  # token is cleared; `callback_api_key_id` is left as it was.
  defp rotate_callback_api_key(state, %Conversation{} = conv) do
    case CallbackKey.rotate(conv, state.callback_api_key_id) do
      {:ok, raw, key_id, conv} ->
        {%{state | callback_token: raw, callback_api_key_id: key_id}, conv}

      {:error, conv} ->
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
    if state.acp_peer, do: Managoat.ACP.Peer.cancel(state.acp_peer)
    # EOF before the handle goes: a detachable session survives its client
    # disconnecting, so closing the WebSocket alone would leave the adapter —
    # and whatever background task it was running — alive on the machine.
    if state.current_command, do: Managoat.Sandbox.close_stdin(state.current_command)
    if state.current_command, do: Managoat.Sandbox.stop_command(state.current_command)
    state = cancel_autonomous_quiet(state)

    turn = TurnMachine.mark_interrupted(TurnMachine.from_state(state))

    # An ACP turn can also end here — the adapter exits, is interrupted, or its
    # socket drops before it ever answers `session/prompt`. The peer has nothing
    # left to drive and must not outlive the turn.
    stop_acp_peer(state)

    state = TurnMachine.into_state(state, TurnMachine.close_interrupted(turn))

    %{
      state
      | current_command: nil,
        current_command_ref: nil,
        acp_peer: nil,
        acp_peer_mon: nil
    }
  end

  defp kick_turn(state, prompt, agent, images) do
    state = touch_activity(state)

    case TurnMachine.open(state.conversation_id, state.sandbox_id, prompt) do
      {:ok, conv, turn} -> run_turn(state, conv, turn, prompt, agent, images)
      :at_capacity -> state
    end
  end

  defp run_turn(state, conv, turn, prompt, agent, images) do
    TurnMachine.store_images(turn, images)
    TurnMachine.generate_title(conv, turn, prompt, state.inference_credentials)

    # Keyed on the conversation's runtime, not the agent: a conversation
    # outlives its agent (deletion nilifies agent_id), and for a supported
    # runtime the legacy spawn path no longer exists to fall back to.
    acp? = Managoat.Runtimes.ACP.enabled?(conv.runtime)

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

  # `conv.runtime || agent.runtime` below is the fallback for rows predating
  # the runtime column. Dialyzer now proves it dead: `TurnMachine.open/3`
  # passed `conv.runtime` through `ACP.concurrency/1`'s `is_binary` guard, so
  # the row this receives always has one. The fallback stays, as it did
  # before the move; the suppression is function-scoped for the reason
  # `CallbackKey.env/1` gives.
  @dialyzer {:nowarn_function, run_fresh_turn: 7}
  defp run_fresh_turn(state, conv, turn, prompt, agent, images, acp?) do
    turn_number = turn.turn_number

    # Write image temp files to sprite. Only on the legacy path: ACP carries
    # images as content blocks inside `session/prompt`, so writing them into
    # the sandbox first would be a round trip whose product nothing reads.
    image_paths = if acp?, do: [], else: write_image_temp_files(state.handle, turn.id, images)

    {:ok, _} = Conversations.update_conversation(conv, %{status: "running"})

    {mode, runtime_session_id} = TurnMachine.session_plan(conv, state.runtime_session_id)

    {cmd, args, build_opts} =
      TurnMachine.command(acp?, conv, agent, prompt, mode, runtime_session_id,
        handle: state.handle,
        runtime_module: state.runtime_module,
        image_paths: image_paths
      )

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
    turn_span = TurnMachine.open_span(state.user_id, conv, turn, mode, agent)
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

      case Managoat.Sandbox.spawn(state.handle, cmd, args, spawn_opts) do
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
              use_stdin? -> TurnMachine.write_prompt_and_close(command, prompt <> prompt_suffix)
              true -> :ok
            end

          case stdin_result do
            :ok ->
              # Tool-span tracing. Every ACP turn gets it, whatever the runtime
              # — `session/update` carries the id and status the tracer keys on
              # (#637). The legacy path traces nothing: its only tracer was a
              # parser over claude's dialect, deleted with that path.
              stream_tracer = if acp?, do: Managoat.ACP.Tracer.new(turn_span, prefix: "fountain")

              {peer, peer_mon} =
                if acp? do
                  TurnMachine.start_acp_peer(command, prompt, mode, runtime_session_id,
                    cwd: cwd,
                    images: images,
                    mcp_servers:
                      Managoat.Runtimes.ACP.mcp_servers(
                        Egress.with_connection_servers(
                          agent,
                          state.user_id,
                          state.conversation_id,
                          state.callback_token
                        )
                      ) ++
                        McpServers.fountain_served(conv, state.callback_token),
                    model:
                      agent &&
                        Managoat.Runtimes.Model.acp_model(
                          conv.runtime || agent.runtime,
                          agent.model
                        ),
                    permission_policy: TurnMachine.effective_permission_policy(conv, agent)
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
              {exit_code, output} = TurnMachine.drain_exited_command(command.ref)

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

  # A turn that never got as far as running (`TurnMachine.fail_before_start/5`):
  # the spawn failed, or the runtime exited before the prompt reached its
  # stdin (#603). The server's half is the runtime's parting words (#608),
  # persisted through the output path against the turn they explain.
  #
  # Called only from inside kick_turn's try block, which restores the caller's
  # previous current-span in its `after`; the span this ends is the turn span
  # kick_turn opened a few lines above the call.
  defp fail_turn_before_start(state, turn, reason, what, exit_code \\ nil, output \\ []) do
    detail = TurnMachine.failure_detail(reason, exit_code)
    Logger.error("#{what}: #{detail}")

    # current_turn is nil on this path — it is only assigned once the prompt
    # is away — and persist_output reads it for the turn_id, so stand it up
    # for the duration and clear it again before returning.
    state =
      Enum.reduce(output, %{state | current_turn: turn}, fn {stream, data}, acc ->
        log_output(acc, stream, data)
      end)

    TurnMachine.fail_before_start(turn, state.conversation_id, what, detail, exit_code)

    %{state | current_turn: nil}
  end

  # Time to first token (#535), one-shot per turn: `TurnMachine.maybe_emit_first_output/1`.
  defp maybe_emit_first_output(state) do
    TurnMachine.into_state(
      state,
      TurnMachine.maybe_emit_first_output(TurnMachine.from_state(state))
    )
  end

  # The aggregate turn-duration event (#536), from every path that ends a turn
  # which actually ran: `TurnMachine.emit_completed/2`.
  defp emit_turn_completed(state, status),
    do: TurnMachine.emit_completed(TurnMachine.from_state(state), status)

  # Persist + broadcast one chunk of sandbox output, subject to the
  # per-conversation byte budget (#331). log_events is unbounded per row
  # count and lives on the same Postgres volume the app depends on, so a
  # `while true; do base64 /dev/urandom; done` sandbox was an availability
  # risk, not just a storage bill — retention (#217) bounds age, not rate.
  # Once the budget is exceeded, one truncation marker is persisted and
  # every later chunk is dropped. Dropped rather than broadcast-only:
  # consumers key ordering off the DB-assigned event id, and an unbounded
  # broadcast stream would still let a hostile sandbox saturate PubSub.

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
        Managoat.ACP.Tracer.handle_line(new_state.stream_tracer, data)
      else
        new_state.stream_tracer
      end

    %{new_state | stream_tracer: tracer}
  end

  # gemini erases a session in the act of loading it (#659), so its store is
  # consolidated at the end of every turn — before the next turn's
  # `session/load` can collide with it. Best-effort and gemini-only; delete
  # with the workaround when gemini-cli#28775 lands.
  defp consolidate_gemini_session(%{handle: handle} = state) when not is_nil(handle) do
    conv = Conversations._unsafe_get_conversation!(state.conversation_id)

    if conv.runtime == "gemini" do
      Managoat.Runtimes.Gemini.SessionStore.consolidate(handle, conv.runtime_session_id)
    end

    :ok
  end

  defp consolidate_gemini_session(_state), do: :ok

  # Terminal path for an ACP turn. The order matters: stdin closes first so the
  # adapter starts exiting while we do the bookkeeping, and `current_command_ref`
  # is cleared at the end so the `{:exit, …}` that follows finds no match and
  # falls through to the catch-all. A turn ends on the prompt response *or* the
  # process exit, whichever arrives first, and never waits for both.
  #
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
    state = drop_caller_tools(state, "turn_ended")
    state = cancel_autonomous_quiet(state)

    turn = TurnMachine.finish(TurnMachine.from_state(state), status, span_attrs, stage_meta)
    touch_activity(TurnMachine.into_state(state, turn))
  end

  # One peer report through the turn state machine (#1374): the turn the
  # server holds goes in, the next one comes back with the effects to apply,
  # in order. `ctx` is what the machine needs that is not the turn's own.
  defp drive_turn(state, payload, extra \\ []) do
    ctx = TurnMachine.ctx(state, extra)
    {turn, effects} = TurnMachine.handle(TurnMachine.from_state(state), payload, ctx)
    state = TurnMachine.into_state(state, turn)

    Enum.reduce(effects, state, &apply_effect(&2, &1))
  end

  # What the machine hands back: the server's state, processes, timers,
  # output persistence and pending registries, one clause each.
  defp apply_effect(state, {:persist_lines, stream, data}),
    do: persist_acp_lines(state, stream, data)

  defp apply_effect(state, :open_autonomous_turn), do: open_autonomous_turn(state)
  defp apply_effect(state, :arm_autonomous_quiet), do: arm_autonomous_quiet(state)

  defp apply_effect(state, {:session_id, id}) do
    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
    {:ok, _} = Conversations.update_conversation(conv, %{runtime_session_id: id})
    %{state | runtime_session_id: id}
  end

  defp apply_effect(state, {:ask_permission, request_id, tool, options}),
    do: ask_permission(state, request_id, tool, options)

  defp apply_effect(state, {:finish, status, span_attrs, stage_meta}),
    do: finish_acp_turn(state, status, span_attrs, stage_meta)

  defp apply_effect(state, {:drop_connection, why}), do: drop_connection(state, why)

  # `ask`: the agent is blocked and a human has to answer (#940). The request
  # goes on the turn row first, then the stage, then the timeout
  # (`Pending.ask/6`); the server holds the row and the timer.
  defp ask_permission(state, request_id, tool, options) do
    {turn, pending} =
      Pending.ask(
        Pending.from_state(state),
        state.conversation_id,
        state.current_turn,
        request_id,
        tool,
        options
      )

    %{Pending.into_state(state, pending) | current_turn: turn}
  end

  # ── the connection (#817) ─────────────────────────────────────────────────

  # Whether an idle peer from an earlier turn is still driving this machine.
  defp connection_alive?(%{acp_peer: peer}) when is_pid(peer), do: Process.alive?(peer)
  defp connection_alive?(_state), do: false

  defp user_turn_running?(%{current_turn: %{origin: "autonomous"}}), do: false
  defp user_turn_running?(%{current_turn: turn}), do: not is_nil(turn)

  # This turn rides the open connection: no spawn, no handshake. `Peer.prompt/3`
  # reuses the session already open, so a background task keeps running and the
  # runtime's per-session grants survive (#817).
  defp resume_acp_connection(state, conv, turn, prompt, images) do
    turn_span =
      TurnMachine.open_span(state.user_id, conv, turn, :continue, TurnMachine.agent_for(conv))

    previous_span = OpenTelemetry.Tracer.set_current_span(turn_span)

    publish_stage(state.conversation_id, "turn", "started", %{
      turn_id: turn.id,
      turn_number: turn.turn_number,
      mode: "continue",
      connection: "reused"
    })

    started_mono = System.monotonic_time(:millisecond)

    case Managoat.ACP.Peer.prompt(state.acp_peer, prompt, images) do
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
            stream_tracer: Managoat.ACP.Tracer.new(turn_span, prefix: "fountain")
        }

      {:error, reason} ->
        # The idle peer would not take the prompt (it died between the check
        # and the call, or is wedged). Drop it and spawn fresh — the turn row
        # already exists, so run the fresh path against it.
        Logger.warning(
          "conv #{state.conversation_id}: idle peer refused prompt (#{inspect(reason)}); respawning"
        )

        OpenTelemetry.Tracer.set_current_span(previous_span)
        TurnMachine.end_span(turn_span, :error, %{"error" => "peer_refused_reuse"})
        state = drop_connection(state, "peer_refused_reuse")
        run_fresh_turn(state, conv, turn, prompt, TurnMachine.agent_for(conv), images, true)
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
      if TurnMachine.autonomous_turn?(state) do
        finish_acp_turn(state, "completed", %{"origin" => "connection_closed"}, %{
          origin: "autonomous",
          cycle: "connection_closed"
        })
      else
        state
      end

    state = cancel_autonomous_quiet(state)
    if state.current_command, do: Managoat.Sandbox.close_stdin(state.current_command)
    consolidate_gemini_session(state)
    stop_acp_peer(state)
    if state.current_command, do: Managoat.Sandbox.stop_command(state.current_command)

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

    turn_span =
      TurnMachine.open_span(state.user_id, conv, turn, :autonomous, TurnMachine.agent_for(conv))

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
        stream_tracer: Managoat.ACP.Tracer.new(turn_span, prefix: "fountain")
    })
  end

  defp close_autonomous_turn(state, why) do
    if TurnMachine.autonomous_turn?(state) do
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
      Managoat.Sandbox.write_file(handle, path, data)
      {path, mt}
    end)
  end

  defp media_type_to_ext("image/png"), do: "png"
  defp media_type_to_ext("image/jpeg"), do: "jpeg"
  defp media_type_to_ext("image/gif"), do: "gif"
  defp media_type_to_ext("image/webp"), do: "webp"
  defp media_type_to_ext(_), do: "bin"
end
