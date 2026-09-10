defmodule Fountain.Conversations.Pending do
  @moduledoc """
  What a turn waits on a human or a client for (#1375): a permission
  request the peer asked (#940), and a caller-defined tool call the tool
  bridge parked (#1202).

  A value and the functions that add, answer, deny, expire, detach and drain
  it.
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
  alias Fountain.Conversations.DetachedRequest
  alias Fountain.Conversations.Lifecycle
  alias Fountain.Conversations.TurnMachine

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

  @doc """
  The server's whole pending family, over the server's state (#1369).

  Each of these is `from_state/1`, the operation, then `into_state/2` and the
  turn row written back. They lived in the `ConversationServer` as a private
  adapter apiece, which is one round trip of boilerplate per call site in a
  file that only shrinks. `ask/4` reads the request params the server kept
  (`DetachedRequest.request_line/2`); the rest take what they need from state.
  """
  @spec ask(map(), term(), String.t(), list()) :: map()
  def ask(state, request_id, tool, options) do
    params = DetachedRequest.params_for(state.acp_request_params, request_id)

    # Consumed, so dropped. Those params are the agent's whole request,
    # `rawInput` included, and that is tenant data with no reason to sit in a
    # server's state for the life of a connection.
    state = %{state | acp_request_params: nil}

    over(state, fn pending, turn ->
      ask(pending, state.conversation_id, turn, request_id, tool, options, params)
    end)
  end

  @doc "The turn is ending and its request outlives it (#1635)."
  @spec detach(map()) :: map()
  def detach(state), do: over(state, &detach(&1, &2))

  @doc "One request's end, whichever way."
  @spec resolve(map(), term(), String.t(), String.t() | nil) :: map()
  def resolve(state, request_id, outcome, option_id) do
    over(state, fn pending, turn ->
      resolve_permission(
        pending,
        state.conversation_id,
        turn,
        state.acp_peer,
        request_id,
        outcome,
        option_id
      )
    end)
  end

  @doc """
  `resolve/4`, but only while the current turn is still holding the request.

  The in-turn permission timer is the one caller that can arrive too late
  (#1635). `detach/1` cancels it, and `Process.cancel_timer/1` does not recall
  a message that is already in the mailbox, so a timer that fired just before
  the `waiting` frame lands against a turn that has detached. Resolving it then
  would publish a `done` stage denying a request that is still open and still
  answerable, and record a `conversation.permission_denied` row for something
  that did not happen, which ADR 0013 forbids. A detached request's deadline is
  read off the row by the sweep, not by this timer.
  """
  @spec resolve_if_held(map(), term(), String.t(), String.t() | nil) :: map()
  def resolve_if_held(state, request_id, outcome, option_id) do
    if holds?(state.current_turn, request_id) do
      resolve(state, request_id, outcome, option_id)
    else
      state
    end
  end

  @doc "Whatever is held, if anything, as the turn ends."
  @spec resolve_held(map(), String.t()) :: map()
  def resolve_held(state, outcome) do
    over(state, fn pending, turn ->
      resolve_pending_permission(pending, state.conversation_id, turn, state.acp_peer, outcome)
    end)
  end

  @doc "Everything still parked when the turn ends."
  @spec drop(map(), String.t()) :: map()
  def drop(state, outcome) do
    into_state(state, drop_calls(from_state(state), state.conversation_id, outcome))
  end

  @doc "A human's answer, with the reply to hand back to them."
  @spec answer(map(), term(), String.t()) :: {:ok | {:error, term()}, map()}
  def answer(state, request_id, option_id) do
    {reply, turn, pending} =
      answer_permission(
        from_state(state),
        state.conversation_id,
        state.current_turn,
        state.acp_peer,
        request_id,
        option_id
      )

    {reply, %{into_state(state, pending) | current_turn: turn}}
  end

  defp over(state, fun) do
    {turn, pending} = fun.(from_state(state), state.current_turn)
    %{into_state(state, pending) | current_turn: turn}
  end

  # ── permission requests (#940) ────────────────────────────────────────────

  @doc """
  Re-arm a persisted request using its original ask time after transport
  recovery.

  A request that outlived its turn (#1635) is skipped. Its deadline is on the
  row and its own, and the sweep owns it; arming the in-turn timer over it
  would deny it at the five-minute ceiling the detach exists to escape. The
  reattach path only ever passes a `running` turn, and a detached one is
  `completed`, so this is the belt to that braces.
  """
  def restore_permission_timer(%__MODULE__{} = pending, turn) do
    if pending.permission_timer, do: Process.cancel_timer(pending.permission_timer)

    timer =
      case turn do
        %{waiting: true} ->
          nil

        %{pending_permission: %{"request_id" => id} = request} ->
          remaining =
            case DateTime.from_iso8601(request["asked_at"] || "") do
              {:ok, asked_at, _} ->
                elapsed = max(DateTime.diff(DateTime.utc_now(), asked_at, :millisecond), 0)
                max(Lifecycle.ask_timeout_ms() - elapsed, 0)

              _ ->
                0
            end

          Process.send_after(self(), {:permission_timeout, id}, remaining)

        _ ->
          nil
      end

    %{pending | permission_timer: timer}
  end

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

  That reasoning stops at the turn's end, which is what `detach/2` exists for
  (#1635): an agent that ends the turn waiting holds nothing open, so its
  request keeps `detached_timeout_ms` instead and the sweep fires it.

  Returns the turn row with the request on it (unchanged when there is no
  turn) and the value with the timer armed.
  """
  @spec ask(
          t(),
          String.t(),
          Conversations.Turn.t() | nil,
          term(),
          String.t(),
          list(),
          map() | nil
        ) :: {Conversations.Turn.t() | nil, t()}
  def ask(%__MODULE__{} = pending, conversation_id, turn, request_id, tool, options, params) do
    detached_timeout_ms =
      DetachedRequest.timeout_ms(params, effective_ask_timeout_seconds(conversation_id))

    request = %{
      "request_id" => request_id,
      "tool" => tool,
      "options" => options,
      "asked_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      # Decided here, spent only if the turn ends waiting (#1635). Announced
      # now so a card can say how long it has once it detaches, rather than
      # learning it from a second event.
      "detached_timeout_ms" => detached_timeout_ms
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
      timeout_ms: Lifecycle.ask_timeout_ms(),
      # What the request gets instead if the agent ends the turn waiting on it
      # (#1635). The two differ only where a per-request or policy-level
      # `ask_timeout` is set.
      detached_timeout_ms: detached_timeout_ms
    })

    timer =
      Process.send_after(
        self(),
        {:permission_timeout, request_id},
        Lifecycle.ask_timeout_ms()
      )

    {turn, %{pending | permission_timer: timer}}
  end

  # The conversation's own `ask_timeout`, agent and launch merged
  # (`Fountain.PermissionPolicy`). Ownership: the caller is the server for this
  # conversation, established at its `init/1`.
  defp effective_ask_timeout_seconds(conversation_id) do
    conv = Conversations._unsafe_get_conversation!(conversation_id)
    TurnMachine.effective_ask_timeout_seconds(conv, TurnMachine.agent_for(conv))
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

  @doc """
  The turn is ending and the agent asked to keep its request (#1635).

  The agent answered `session/prompt` with the `waiting` stop reason while a
  request was still held, so instead of denying it as the turn's end normally
  does, the request outlives the turn: the row is marked `waiting`, the
  deadline decided at ask time is written onto it, and the in-process timer is
  dropped. From here the request is the sweep's
  (`Fountain.Workers.DetachedRequestSweeper`), because the sandbox is about to
  park and this process is about to have nothing left to do.

  Returns the turn row with the flag on it and the value with no timer.
  """
  @spec detach(t(), Conversations.Turn.t() | nil) :: {Conversations.Turn.t() | nil, t()}
  def detach(%__MODULE__{} = pending, %{pending_permission: request} = turn)
      when is_map(request) do
    if pending.permission_timer, do: Process.cancel_timer(pending.permission_timer)

    deadline =
      request
      |> Map.get("detached_timeout_ms")
      |> case do
        ms when is_integer(ms) and ms > 0 -> ms
        _ -> Lifecycle.ask_timeout_ms()
      end
      |> DetachedRequest.deadline()

    {:ok, turn} =
      Conversations._unsafe_update_turn(turn, %{
        waiting: true,
        permission_deadline: deadline,
        pending_permission: Map.put(request, "deadline", DateTime.to_iso8601(deadline))
      })

    {turn, %{pending | permission_timer: nil}}
  end

  def detach(%__MODULE__{} = pending, turn), do: {turn, pending}

  @doc """
  Whether this turn is holding `request_id` open inside itself.

  False for a turn that ended `waiting` (#1635): its request is on the row,
  but the peer that raised it is driving nothing, so an answer relayed down
  that connection would be reported as landed and reach nobody.
  """
  @spec holds?(Conversations.Turn.t() | nil, term()) :: boolean()
  def holds?(%{pending_permission: %{"request_id" => id}, waiting: waiting}, request_id),
    do: id == request_id and waiting != true

  def holds?(_turn, _request_id), do: false

  @doc "Whether this turn ended holding a request that outlived it (#1635)."
  @spec detached?(Conversations.Turn.t() | nil) :: boolean()
  def detached?(%{waiting: true, pending_permission: request}) when is_map(request), do: true
  def detached?(_turn), do: false

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
