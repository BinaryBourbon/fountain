defmodule Fountain.Conversations.Pending do
  @moduledoc """
  What a turn waits on a human or a client for (#1375): a permission
  request the peer asked (#940), and a caller-defined tool call the tool
  bridge parked (#1202).

  A value and the functions that add, answer, deny, expire and drain it.
  The value is the parked calls with their timers and the permission
  timeout; the permission request itself lives on the turn row, which is
  why a request raised before a deploy is still answerable after one.
  `from_state/1` reads the two server fields into a `%Pending{}` and
  `into_state/2` writes them back; the server's state does not change shape.

  Every function takes what it reads (the conversation id, the turn row,
  the peer) and returns what changed: the reply to hand back, the turn row
  and the next value. Timers are armed in the calling process, which is the
  server; the answers reach the peer (`Managoat.ACP.Peer`) and the parked
  caller from here, and the stage events say what happened on the stream.
  `Fountain.CallerTools` owns the wire shapes and stays where it is.
  """

  alias Fountain.Conversations
  alias Fountain.Conversations.Lifecycle

  @type call :: %{
          id: String.t(),
          name: String.t(),
          arguments: map(),
          turn_id: String.t(),
          waiter: pid() | nil,
          timer: reference() | nil,
          result: {:ok, String.t()} | {:error, String.t()} | nil,
          parked_at: integer()
        }

  @type t :: %__MODULE__{
          calls: %{String.t() => call()},
          permission_timer: reference() | nil
        }

  defstruct calls: %{}, permission_timer: nil

  # ── the server boundary ───────────────────────────────────────────────────

  @doc "What the server holds, as one value."
  @spec from_state(map()) :: t()
  def from_state(state),
    do: %__MODULE__{calls: state.caller_calls, permission_timer: state.permission_timer}

  @doc "The value written back into the server's fields."
  @spec into_state(map(), t()) :: map()
  def into_state(state, %__MODULE__{} = pending),
    do: %{state | caller_calls: pending.calls, permission_timer: pending.permission_timer}

  # ── permission requests (#940) ────────────────────────────────────────────

  @doc """
  `ask`: the agent is blocked and a human has to answer (#940).

  Three things happen, and the order matters. The pending request is persisted
  on the turn first, so a deploy landing a millisecond later can still be
  answered; then the stage event goes out; then the timeout is armed.

  The timeout is not optional and it is not a tidiness measure.
  `Lifecycle.check/4` suppresses only the *idle* verdict while a turn is in
  flight, so an unanswered request would sail past the idle bound and be
  resolved by the max-lifetime ceiling — and per 0017 the idle bound suspends
  while the ceiling destroys. Left alone, a prompt nobody answers does not
  hang forever; it burns the whole lifetime and then takes the agent's memory
  with it (#649).

  Returns the turn row with the request on it (unchanged when there is no
  turn) and the value with the timer armed.
  """
  @spec ask(t(), String.t(), Conversations.Turn.t() | nil, term(), String.t(), list()) ::
          {Conversations.Turn.t() | nil, t()}
  def ask(%__MODULE__{} = pending, conversation_id, turn, request_id, tool, options) do
    request = %{
      "request_id" => request_id,
      "tool" => tool,
      "options" => options,
      "asked_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    turn =
      case turn do
        nil ->
          nil

        turn ->
          {:ok, turn} = Conversations._unsafe_update_turn(turn, %{pending_permission: request})
          turn
      end

    publish_stage(conversation_id, "request", "started", %{
      request_id: request_id,
      tool: tool,
      # The agent's own list, verbatim. A client must never offer an option
      # that is not on it.
      options: options,
      timeout_ms: Lifecycle.ask_timeout_ms()
    })

    timer =
      Process.send_after(
        self(),
        {:permission_timeout, request_id},
        Lifecycle.ask_timeout_ms()
      )

    {turn, %{pending | permission_timer: timer}}
  end

  @doc """
  A human answered. First answer wins: the web apps and an editor (#708) are
  peer clients of this door, not fallbacks for one another, so a second
  answer to the same request is "too late" rather than an error in the
  caller. The peer takes the option; the request is then resolved as
  `answered`.
  """
  @spec answer_permission(
          t(),
          String.t(),
          Conversations.Turn.t() | nil,
          pid() | nil,
          term(),
          String.t()
        ) ::
          {:ok | {:error, term()}, Conversations.Turn.t() | nil, t()}
  def answer_permission(
        %__MODULE__{} = pending,
        conversation_id,
        turn,
        peer,
        request_id,
        option_id
      ) do
    case peer do
      nil ->
        {{:error, :no_pending_permission}, turn, pending}

      peer ->
        case Managoat.ACP.Peer.answer_permission(peer, request_id, option_id) do
          :ok ->
            {turn, pending} =
              resolve_permission(
                pending,
                conversation_id,
                turn,
                peer,
                request_id,
                "answered",
                option_id
              )

            {:ok, turn, pending}

          {:error, reason} ->
            {{:error, reason}, turn, pending}
        end
    end
  end

  # `state: "done"` for every outcome, including a deny and a timeout. The stage
  # and its status are the Prometheus counter's only tags and there is an alert
  # on them — a timeout emitting `failed` would page someone for a policy doing
  # exactly what it was told.
  @spec resolve_permission(
          t(),
          String.t(),
          Conversations.Turn.t() | nil,
          pid() | nil,
          term(),
          String.t(),
          String.t() | nil
        ) :: {Conversations.Turn.t() | nil, t()}
  def resolve_permission(
        %__MODULE__{} = pending,
        conversation_id,
        turn,
        peer,
        request_id,
        outcome,
        option_id
      ) do
    if pending.permission_timer, do: Process.cancel_timer(pending.permission_timer)

    # Read before the clear below wipes it.
    tool = pending_tool(turn)

    if outcome != "answered" and peer do
      Managoat.ACP.Peer.deny_permission(peer, request_id)
    end

    turn =
      case turn do
        nil ->
          nil

        turn ->
          {:ok, turn} = Conversations._unsafe_update_turn(turn, %{pending_permission: nil})
          turn
      end

    publish_stage(conversation_id, "request", "done", %{
      request_id: request_id,
      outcome: outcome,
      option_id: option_id
    })

    if outcome != "answered" do
      Conversations.record_permission_denied(conversation_id, tool, outcome)
    end

    {turn, %{pending | permission_timer: nil}}
  end

  @doc "The tool the turn is blocked on, or nil."
  @spec pending_tool(Conversations.Turn.t() | nil) :: String.t() | nil
  def pending_tool(%{pending_permission: %{"tool" => tool}}), do: tool
  def pending_tool(_turn), do: nil

  # Resolve whatever is held, if anything. The turn row is the source of truth
  # rather than the timer, so this is also correct for a request raised by a
  # previous BEAM lifetime and reattached to.
  @spec resolve_pending_permission(
          t(),
          String.t(),
          Conversations.Turn.t() | nil,
          pid() | nil,
          String.t()
        ) ::
          {Conversations.Turn.t() | nil, t()}
  def resolve_pending_permission(%__MODULE__{} = pending, conversation_id, turn, peer, outcome) do
    case turn do
      %{pending_permission: %{"request_id" => request_id}} ->
        resolve_permission(pending, conversation_id, turn, peer, request_id, outcome, nil)

      _ ->
        {turn, pending}
    end
  end

  # ── parked caller-tool calls (#1202) ──────────────────────────────────────

  @doc """
  Park a caller-tool call the agent just made. The call gets an id, a
  `caller_tool`/`started` stage event goes out (which is what closes the
  client's completion with `tool_calls`), and a deadline is armed. `waiter`
  receives `{:caller_tool_result, id, result}` when the call resolves.
  """
  @spec park(t(), String.t(), Conversations.Turn.t(), String.t(), map(), pid()) ::
          {String.t(), t()}
  def park(%__MODULE__{} = pending, conversation_id, turn, name, arguments, waiter) do
    call_id = "call_" <> (Ecto.UUID.generate() |> String.replace("-", ""))

    publish_stage(conversation_id, "caller_tool", "started", %{
      call_id: call_id,
      turn_id: turn.id,
      name: name,
      arguments: arguments,
      timeout_ms: Lifecycle.ask_timeout_ms()
    })

    timer =
      Process.send_after(
        self(),
        {:caller_tool_timeout, call_id},
        Lifecycle.ask_timeout_ms()
      )

    entry = %{
      id: call_id,
      name: name,
      arguments: arguments,
      turn_id: turn.id,
      waiter: waiter,
      timer: timer,
      result: nil,
      parked_at: System.monotonic_time(:millisecond)
    }

    {call_id, put_in(pending.calls[call_id], entry)}
  end

  @doc """
  Re-attach `waiter` to a parked call (the MCP handler's in-request wait ran
  out and the agent is asking again). `{:ok, result}` at once if it resolved
  meanwhile — a result is kept until the turn ends, so an answer that landed
  between two waits is not lost.
  """
  @spec await(t(), String.t(), pid()) ::
          {:pending | {:ok, term()} | {:error, :unknown_call}, t()}
  def await(%__MODULE__{} = pending, call_id, waiter) do
    case pending.calls[call_id] do
      nil -> {{:error, :unknown_call}, pending}
      %{result: nil} -> {:pending, put_in(pending.calls[call_id].waiter, waiter)}
      %{result: result} -> {{:ok, result}, pending}
    end
  end

  @doc "The calls parked and unanswered, oldest first: `%{id, name, arguments, turn_id}`."
  @spec calls(t()) :: [map()]
  def calls(%__MODULE__{} = pending) do
    pending.calls
    |> Map.values()
    |> Enum.filter(&is_nil(&1.result))
    |> Enum.sort_by(& &1.parked_at)
    |> Enum.map(&Map.take(&1, [:id, :name, :arguments, :turn_id]))
  end

  @doc """
  Resolve parked calls with the client's answers, `%{call_id => content}`.
  Ids that match nothing are ignored; if none match, `{:error, :no_pending_calls}`
  and nothing changes. Returns the turn the calls belong to and whatever is
  still parked, so the controller can emit the remainder at once instead of
  waiting for a stage event that is already behind its cursor.
  """
  @spec answer_calls(t(), String.t(), %{String.t() => String.t()}) ::
          {{:ok, %{turn_id: String.t(), remaining: [map()]}} | {:error, :no_pending_calls}, t()}
  def answer_calls(%__MODULE__{} = pending, conversation_id, answers) do
    matched =
      pending.calls
      |> Map.values()
      |> Enum.filter(&(is_nil(&1.result) and Map.has_key?(answers, &1.id)))

    if matched == [] do
      {{:error, :no_pending_calls}, pending}
    else
      pending =
        Enum.reduce(matched, pending, fn call, pending ->
          resolve_call(
            pending,
            conversation_id,
            call.id,
            "answered",
            {:ok, Map.fetch!(answers, call.id)}
          )
        end)

      turn_id = matched |> List.first() |> Map.fetch!(:turn_id)
      {{:ok, %{turn_id: turn_id, remaining: calls(pending)}}, pending}
    end
  end

  # The one place a parked caller-tool call stops being parked (#1202): an
  # answer, the deadline, or the turn ending. Cancels the timer, hands the
  # result to whoever is waiting, keeps it for a waiter that asks later, and
  # says so on the stream. `done` for every outcome, as `request` does.
  @spec resolve_call(t(), String.t(), String.t(), String.t(), {:ok, term()} | {:error, term()}) ::
          t()
  def resolve_call(%__MODULE__{} = pending, conversation_id, call_id, outcome, result) do
    case pending.calls[call_id] do
      %{result: nil} = call ->
        if call.timer, do: Process.cancel_timer(call.timer)
        if is_pid(call.waiter), do: send(call.waiter, {:caller_tool_result, call_id, result})

        publish_stage(conversation_id, "caller_tool", "done", %{
          call_id: call_id,
          turn_id: call.turn_id,
          name: call.name,
          outcome: outcome
        })

        put_in(pending.calls[call_id], %{call | result: result, timer: nil, waiter: nil})

      _ ->
        pending
    end
  end

  # Everything still parked when the turn ends: the agent gave up waiting, or
  # the turn was cut. Resolved as errors, then the whole registry is dropped —
  # a kept result belongs to a turn that is over.
  @spec drop_calls(t(), String.t(), String.t()) :: t()
  def drop_calls(%__MODULE__{} = pending, conversation_id, outcome) do
    pending =
      Enum.reduce(calls(pending), pending, fn call, pending ->
        resolve_call(
          pending,
          conversation_id,
          call.id,
          outcome,
          {:error, "the turn ended before the caller answered"}
        )
      end)

    %{pending | calls: %{}}
  end

  defp publish_stage(conv_id, stage, status, meta) do
    Conversations.publish_stage(conv_id, stage, status, meta)
  end
end
