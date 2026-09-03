defmodule Fountain.Conversations.Connection do
  @moduledoc """
  The ACP connection, which outlives the turn (#817).

  A value — the peer, its monitor, the sandbox command underneath it, and the
  quiet timer that closes a background cycle — and the functions that reuse
  it, close it, lose it, and open the autonomous turn an out-of-turn protocol
  line starts.

  The distinction the module exists for: a turn ends when the agent answers,
  the connection ends when the sandbox stops being this server's. Between the
  two, an idle adapter sits on the machine and the next prompt rides it — no
  spawn, no handshake, no `session/resume`, no model pin — so a background
  task it left running keeps running and the runtime's per-session grants
  survive. `Fountain.Conversations.TurnMachine` owns the turn itself and
  answers `autonomous_turn?/1`; what a turn ends with is the server's, because
  ending one resolves what is pending and stamps the row.

  `from_state/1` reads the five server fields into a `%Connection{}` and
  `into_state/2` writes them back; the server's state does not change shape.
  Timers are armed in the calling process, which is the server.
  """

  require Logger
  require OpenTelemetry.Tracer

  alias Fountain.Conversations
  alias Fountain.Conversations.{Output, TurnMachine}

  @type t :: %__MODULE__{
          peer: pid() | nil,
          peer_mon: reference() | nil,
          command: term() | nil,
          command_ref: term() | nil,
          quiet_timer: reference() | nil
        }

  defstruct peer: nil, peer_mon: nil, command: nil, command_ref: nil, quiet_timer: nil

  # An autonomous turn with no `cycle_end` closes after this long a silence.
  @autonomous_quiet_ms :timer.minutes(10)

  # ── the server boundary ───────────────────────────────────────────────────

  @doc "What the server holds, as one value."
  @spec from_state(map()) :: t()
  def from_state(state) do
    %__MODULE__{
      peer: state.acp_peer,
      peer_mon: state.acp_peer_mon,
      command: state.current_command,
      command_ref: state.current_command_ref,
      quiet_timer: state.autonomous_quiet
    }
  end

  @doc "The value written back into the server's fields."
  @spec into_state(map(), t()) :: map()
  def into_state(state, %__MODULE__{} = conn) do
    %{
      state
      | acp_peer: conn.peer,
        acp_peer_mon: conn.peer_mon,
        current_command: conn.command,
        current_command_ref: conn.command_ref,
        autonomous_quiet: conn.quiet_timer
    }
  end

  # ── what is open, and what is busy ────────────────────────────────────────

  @doc "Whether an idle peer from an earlier turn is still driving this machine."
  @spec alive?(t()) :: boolean()
  def alive?(%__MODULE__{peer: peer}) when is_pid(peer), do: Process.alive?(peer)
  def alive?(%__MODULE__{}), do: false

  @doc """
  Busy means a turn, not a connection (#817).

  An autonomous turn does not make the conversation busy: a human prompt
  supersedes the background cycle rather than queueing behind it.
  """
  @spec user_turn_running?(map() | nil) :: boolean()
  def user_turn_running?(%{origin: "autonomous"}), do: false
  def user_turn_running?(turn), do: not is_nil(turn)

  # ── riding the open connection ────────────────────────────────────────────

  @doc """
  This turn rides the open connection: no spawn, no handshake.

  `Peer.prompt/3` reuses the session already open, so a background task keeps
  running and the runtime's per-session grants survive (#817). Returns the
  turn span, the tracer over it and the monotonic stamp the turn's metrics
  start from; `{:error, reason}` when the idle peer would not take the prompt
  (it died between the check and the call, or is wedged), with the span
  already closed — the caller drops the connection and spawns fresh.
  """
  @spec resume(
          t(),
          String.t(),
          String.t(),
          Conversations.Conversation.t(),
          map(),
          String.t(),
          list()
        ) ::
          {:ok, term(), term(), integer()} | {:error, term()}
  def resume(%__MODULE__{} = conn, conversation_id, user_id, conv, turn, prompt, images) do
    turn_span = TurnMachine.open_span(user_id, conv, turn, :continue, TurnMachine.agent_for(conv))

    previous_span = OpenTelemetry.Tracer.set_current_span(turn_span)

    Output.publish_stage(conversation_id, "turn", "started", %{
      turn_id: turn.id,
      turn_number: turn.turn_number,
      mode: "continue",
      connection: "reused"
    })

    started_mono = System.monotonic_time(:millisecond)

    case Managoat.ACP.Peer.prompt(conn.peer, prompt, images) do
      :ok ->
        OpenTelemetry.Tracer.set_current_span(previous_span)
        {:ok, turn_span, Managoat.ACP.Tracer.new(turn_span, prefix: "fountain"), started_mono}

      {:error, reason} ->
        Logger.warning(
          "conv #{conversation_id}: idle peer refused prompt (#{inspect(reason)}); respawning"
        )

        OpenTelemetry.Tracer.set_current_span(previous_span)
        TurnMachine.end_span(turn_span, :error, %{"error" => "peer_refused_reuse"})
        {:error, reason}
    end
  end

  # ── letting it go ─────────────────────────────────────────────────────────

  @doc """
  Close the ACP connection.

  EOF the adapter so it exits — a detachable session outlives its client, so
  closing the socket alone leaves it and any background task running —
  consolidate gemini's store before the next `session/load` can collide with
  it, stop the peer, and clear the connection fields. Safe on a value with no
  peer and no command; an autonomous turn still open is the caller's to
  finish first, because ending a turn is the server's.
  """
  @spec close(t(), String.t(), term()) :: t()
  def close(%__MODULE__{} = conn, conversation_id, handle) do
    conn = cancel_quiet(conn)
    if conn.command, do: Managoat.Sandbox.close_stdin(conn.command)
    consolidate_gemini_session(handle, conversation_id)
    stop_peer(conn)
    if conn.command, do: Managoat.Sandbox.stop_command(conn.command)

    cleared(conn)
  end

  @doc """
  The adapter went away between turns with no turn to fail (#817). Record it
  on the transcript and clear the connection; the next prompt spawns fresh.
  """
  @spec lost(t(), String.t(), term(), String.t(), map()) :: t()
  def lost(%__MODULE__{} = conn, conversation_id, handle, reason, meta) do
    Output.publish_stage(
      conversation_id,
      "sandbox",
      "done",
      Map.merge(%{event: "connection_lost", reason: reason}, meta)
    )

    conn = cancel_quiet(conn)
    consolidate_gemini_session(handle, conversation_id)

    cleared(conn)
  end

  @doc """
  Stop the peer, if there is one.

  Demonitor before stopping so the peer's own exit does not arrive as a
  `:DOWN` that fails the turn we just finished.
  """
  @spec stop_peer(t()) :: :ok
  def stop_peer(%__MODULE__{peer: nil}), do: :ok

  def stop_peer(%__MODULE__{peer: peer, peer_mon: mon}) do
    if mon, do: Process.demonitor(mon, [:flush])
    if Process.alive?(peer), do: GenServer.stop(peer, :normal, 1_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp cleared(%__MODULE__{} = conn),
    do: %{conn | peer: nil, peer_mon: nil, command: nil, command_ref: nil}

  # gemini erases a session in the act of loading it (#659), so its store is
  # consolidated at the end of every turn — before the next turn's
  # `session/load` can collide with it. Best-effort and gemini-only; delete
  # with the workaround when gemini-cli#28775 lands.
  defp consolidate_gemini_session(handle, conversation_id) when not is_nil(handle) do
    # ownership: a server's own conversation, established at init.
    conv = Conversations._unsafe_get_conversation!(conversation_id)

    if conv.runtime == "gemini" do
      Managoat.Runtimes.Gemini.SessionStore.consolidate(handle, conv.runtime_session_id)
    end

    :ok
  end

  defp consolidate_gemini_session(_handle, _conversation_id), do: :ok

  # ── the autonomous turn (#817, #1301) ─────────────────────────────────────

  @doc """
  An out-of-turn protocol line opened a background cycle (#817).

  A real turn row, so the log budget, redaction and stage events all apply;
  `origin: "autonomous"` and a marker prompt tell it from a user turn.
  Returns the row, the span opened over it and the tracer reading it; the
  caller holds them and arms the quiet timer.
  """
  @spec open_autonomous_turn(String.t(), String.t()) :: {map(), term(), term()}
  def open_autonomous_turn(conversation_id, user_id) do
    # ownership: a server's own conversation, established at init.
    conv = Conversations._unsafe_get_conversation!(conversation_id)
    turn_number = Conversations._unsafe_next_turn_number(conversation_id)

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
      TurnMachine.open_span(user_id, conv, turn, :autonomous, TurnMachine.agent_for(conv))

    Output.publish_stage(conversation_id, "turn", "started", %{
      turn_id: turn.id,
      turn_number: turn_number,
      origin: "autonomous"
    })

    {:ok, _} = Conversations.update_conversation(conv, %{status: "running"})

    {turn, turn_span, Managoat.ACP.Tracer.new(turn_span, prefix: "fountain")}
  end

  @doc """
  Arm the timer that closes an autonomous turn gone quiet without a
  `cycle_end` (#1301): an adapter too old to mark its origin must not hold a
  turn open forever. No turn, no timer.
  """
  @spec arm_quiet(t(), map() | nil) :: t()
  def arm_quiet(%__MODULE__{} = conn, turn) do
    conn = cancel_quiet(conn)
    turn_id = turn && turn.id

    timer =
      if turn_id do
        Process.send_after(self(), {:autonomous_quiet, turn_id}, quiet_ms())
      end

    %{conn | quiet_timer: timer}
  end

  @doc "Disarm the quiet timer."
  @spec cancel_quiet(t()) :: t()
  def cancel_quiet(%__MODULE__{quiet_timer: nil} = conn), do: conn

  def cancel_quiet(%__MODULE__{quiet_timer: timer} = conn) do
    Process.cancel_timer(timer)
    %{conn | quiet_timer: nil}
  end

  @doc "How long a silence closes an autonomous turn."
  @spec quiet_ms() :: non_neg_integer()
  def quiet_ms do
    Application.get_env(:fountain, :autonomous_turn_quiet_ms, @autonomous_quiet_ms)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
