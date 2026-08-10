defmodule Fountain.Runtimes.ACP.Peer do
  @moduledoc """
  One ACP connection, for exactly one turn.

  Gate 2 of [0014](decisions/0014-agent-client-protocol.md). The peer drives
  `initialize` → (`session/new` | `session/resume` | `session/load`) →
  `session/prompt` over the sprite's stdio, translates nothing itself, and
  ends when the prompt is answered.

  ## Why this is not in `ConversationServer`

  0014 says it outright: "This is a new GenServer sitting beside a
  `ConversationServer` that is already 2,088 lines. If the peer lands inside
  that module, this ADR has been implemented wrongly." The server owns the
  sprite, the turn row and the log budget; the peer owns a protocol
  conversation with states and a correlation table. They fail differently and
  should not share a mailbox.

  ## Lifetime is the turn, and that is the economics

  0014's *Session lifetime* section is the load-bearing constraint: the ACP
  connection is scoped to the turn, never to the session, so nothing is
  attached between turns and `Lifecycle`/`SandboxReaper` keep reclaiming idle
  sprites on exactly today's terms. The durable identity is
  `conversation.runtime_session_id`, which we hand to `session/resume`.

  The peer is deliberately unlinked from its owner in both directions and
  monitored instead. A protocol bug here must fail a *turn*; linking would make
  it take down a `ConversationServer` that is also holding a sprite handle and
  a tenant's secrets.

  ## Resumption, and why `session/load` is the unhappy path

  `session/resume` restores context and returns. `session/load` "**MUST** replay
  the entire conversation to the Client in the form of `session/update`
  notifications" before responding — and we already hold that history as
  `log_events` rows, so persisting the replay would duplicate the whole
  transcript into the database and onto the SSE stream on every turn after the
  first. While a `session/load` is outstanding the peer runs in replay-discard
  mode and drops updates on the floor.

  We prefer `resume` whenever the adapter advertises it, which the pinned Claude
  adapter does. `load` is kept because the capability is per-adapter and per
  version, and discovering at runtime that this build cannot resume is better
  handled by taking the expensive path than by failing the turn.

  ## What it sends back

  Everything goes to the owner as `{:acp, ref, payload}` so the server can keep
  its existing invariants — the log budget, the redaction pass and the replay
  skip all live on the server's persistence path, and a peer writing rows
  directly would bypass all three.
  """

  use GenServer

  require Logger

  alias Fountain.Runtimes.ACP
  alias Fountain.Runtimes.ACP.Protocol
  alias Fountain.SpriteStdin

  @typedoc "What the peer reports upward. `ref` is the sprite command's ref."
  @type payload ::
          {:lines, stream :: String.t(), data :: String.t()}
          | {:session, String.t()}
          | {:handshake_ms, non_neg_integer(), method :: String.t()}
          | {:done, stop_reason :: String.t()}
          | {:failed, term()}

  defmodule State do
    @moduledoc false
    defstruct [
      :owner,
      :owner_mon,
      :command,
      :ref,
      :prompt,
      :mode,
      :session_id,
      :cwd,
      :started_mono,
      images: [],
      mcp_servers: [],
      buffer: "",
      next_id: 1,
      pending: %{},
      phase: :initializing,
      replay_discard?: false,
      capabilities: %{}
    ]
  end

  # ── public api ────────────────────────────────────────────────────────────

  @doc """
  Start a peer for one turn.

  Required opts: `:owner`, `:command`, `:ref`, `:prompt`, `:mode`,
  `:session_id`, `:cwd`.
  """
  def start(opts), do: GenServer.start(__MODULE__, opts)

  @doc "Feed a stdout chunk from the sprite. Chunks respect no message boundary."
  def stdout(pid, data), do: GenServer.cast(pid, {:stdout, data})

  @doc """
  Ask the agent to stop the current turn.

  `session/cancel` is a notification with no reply; the agent answers the
  original `session/prompt` with a `cancelled` stop reason, which is what
  actually ends the turn.
  """
  def cancel(pid), do: GenServer.cast(pid, :cancel)

  # ── callbacks ─────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)

    state = %State{
      owner: owner,
      owner_mon: Process.monitor(owner),
      command: Keyword.fetch!(opts, :command),
      ref: Keyword.fetch!(opts, :ref),
      prompt: Keyword.fetch!(opts, :prompt),
      mode: Keyword.fetch!(opts, :mode),
      session_id: Keyword.fetch!(opts, :session_id),
      cwd: Keyword.get(opts, :cwd, "/home/sprite"),
      images: Keyword.get(opts, :images, []),
      mcp_servers: Keyword.get(opts, :mcp_servers, []),
      started_mono: System.monotonic_time(:millisecond)
    }

    {:ok, state, {:continue, :initialize}}
  end

  @impl true
  def handle_continue(:initialize, state) do
    send_request(state, :initialize, "initialize", ACP.initialize_params())
    |> noreply()
  end

  @impl true
  def handle_cast({:stdout, data}, state) do
    {messages, buffer} = Protocol.feed(state.buffer, data)

    messages
    |> Enum.reduce(%{state | buffer: buffer}, &handle_message/2)
    |> noreply()
  end

  def handle_cast(:cancel, %State{session_id: id} = state) when is_binary(id) do
    state
    |> write(Protocol.notification("session/cancel", %{sessionId: id}))
    |> noreply()
  end

  def handle_cast(:cancel, state), do: {:noreply, state}

  @impl true
  def handle_info({:DOWN, mon, :process, _pid, _reason}, %State{owner_mon: mon} = state) do
    # The server is gone; there is nobody to report to and the sprite command
    # is its property, not ours.
    {:stop, :normal, state}
  end

  def handle_info(msg, state) do
    Logger.debug("acp peer: unexpected message #{inspect(msg)}")
    {:noreply, state}
  end

  # ── message dispatch ──────────────────────────────────────────────────────

  defp handle_message({:notification, "session/update", params}, state) do
    if state.replay_discard? do
      # Replay of history we already hold. Dropped, not persisted — see the
      # moduledoc.
      state
    else
      persist(state, "acp", Protocol.notification("session/update", params))
    end
  end

  defp handle_message({:notification, _method, _params}, state), do: state

  defp handle_message({:response, id, result}, state) do
    case pop_pending(state, id) do
      {nil, state} ->
        Logger.warning("acp peer: response to unknown request #{inspect(id)}")
        state

      {tag, state} ->
        handle_response(tag, result, state)
    end
  end

  defp handle_message({:error_response, id, error}, state) do
    {tag, state} = pop_pending(state, id)
    fail(state, {:acp_error, tag, error})
  end

  # `session/request_permission` is the channel gate 3 exists to use. Gate 2
  # answers it the way the legacy path already behaves — every runtime today
  # runs with its rail removed (`--dangerously-skip-permissions` and friends),
  # so auto-allowing is parity, not a new exposure. Answering *something* is not
  # optional: the agent blocks on this request, and a blocked agent is a turn in
  # flight, which disarms idle reclaim and bills the sprite to the ceiling.
  defp handle_message({:request, id, "session/request_permission", params}, state) do
    write(state, Protocol.response(id, %{outcome: permission_outcome(params)}))
  end

  # We declared no filesystem or terminal capabilities, so nothing should ask.
  # If something does, it gets a JSON-RPC error rather than silence.
  defp handle_message({:request, id, method, _params}, state) do
    Logger.warning("acp peer: refusing unsupported client method #{method}")
    write(state, Protocol.error(id, Protocol.method_not_found(), "#{method} is not supported"))
  end

  # Adapters and the Node runtime under them write warnings and stack traces to
  # stdout. Those are output, not protocol, and the transcript is more useful
  # with them in it.
  defp handle_message({:invalid, line}, state), do: persist(state, "stdout", [line, "\n"])

  # ── responses ─────────────────────────────────────────────────────────────

  defp handle_response(:initialize, result, state) do
    caps = Map.get(result, "agentCapabilities") || %{}
    state = %{state | capabilities: caps}

    # Labelled with the session-setup call we are about to make, not with the
    # server's idea of the mode: `kick_turn` persists a generated session id
    # before the first turn spawns, so by the time this lands the server cannot
    # tell a `session/new` from a resume. A resume and a new session pay
    # different prices, and averaging them hides whichever is the problem.
    method = if state.mode == :run, do: "session/new", else: resume_method(state)

    report(
      state,
      {:handshake_ms, System.monotonic_time(:millisecond) - state.started_mono, method}
    )

    case state.mode do
      :run -> start_new_session(state)
      :continue -> resume_session(state)
    end
  end

  defp handle_response(:new_session, result, state) do
    case Map.get(result, "sessionId") do
      id when is_binary(id) ->
        report(state, {:session, id})
        send_prompt(%{state | session_id: id})

      _ ->
        fail(state, {:acp_no_session_id, result})
    end
  end

  defp handle_response(:resume_session, _result, state), do: send_prompt(state)

  defp handle_response(:load_session, _result, state) do
    # The replay is over; everything from here is this turn's.
    send_prompt(%{state | replay_discard?: false})
  end

  defp handle_response(:prompt, result, state) do
    stop = Map.get(result, "stopReason") || "end_turn"
    report(state, {:done, stop})
    %{state | phase: :done}
  end

  # ── session setup ─────────────────────────────────────────────────────────

  # No client-proposed `sessionId`. The spec is explicit that the *agent*
  # "MUST respond with a unique Session ID", and we overwrite whatever we sent
  # with what comes back anyway — so proposing one was decoration that a
  # stricter agent could reject on schema grounds.
  defp start_new_session(state) do
    send_request(
      %{state | phase: :starting_session},
      :new_session,
      "session/new",
      %{cwd: state.cwd, mcpServers: state.mcp_servers}
    )
  end

  defp resume_session(%State{session_id: nil} = state) do
    # `mode == :continue` with no id is a contradiction the caller should not be
    # able to produce; failing loudly beats silently starting a second session
    # that renders as the same conversation.
    fail(state, :acp_resume_without_session_id)
  end

  defp resume_session(state) do
    # Resumption re-sends the servers rather than assuming the agent kept them.
    # The adapter snapshots `{cwd, mcpServers}` per session and tears the
    # session down when they change, so omitting them here would read as
    # "the client removed every MCP server".
    params = %{sessionId: state.session_id, cwd: state.cwd, mcpServers: state.mcp_servers}

    case resume_method(state) do
      "session/resume" ->
        send_request(
          %{state | phase: :starting_session},
          :resume_session,
          "session/resume",
          params
        )

      "session/load" ->
        # The expensive path: everything until the response is history we
        # already have.
        %{state | phase: :starting_session, replay_discard?: true}
        |> send_request(:load_session, "session/load", params)

      _ ->
        fail(state, :acp_agent_cannot_resume)
    end
  end

  # Which resumption the agent's advertised capabilities allow, preferring the
  # one that does not replay. Consulted twice — once to label the handshake
  # measurement, once to make the call — so the number and the behaviour cannot
  # disagree.
  defp resume_method(state) do
    cond do
      supports?(state, ["sessionCapabilities", "resume"]) -> "session/resume"
      Map.get(state.capabilities, "loadSession") == true -> "session/load"
      true -> "none"
    end
  end

  defp send_prompt(state) do
    params = %{
      sessionId: state.session_id,
      prompt: [%{type: "text", text: state.prompt} | image_blocks(state.images)]
    }

    send_request(%{state | phase: :prompting}, :prompt, "session/prompt", params)
  end

  # ACP carries images in the prompt itself, so the legacy dance — write the
  # bytes to a temp file in the sandbox, then append the paths to the prompt and
  # hope the model reaches for its Read tool — is not needed. `data` here is raw
  # binary (already decoded by `FountainWeb.PromptImages`), and the protocol
  # wants base64.
  #
  # The adapter advertises `promptCapabilities.image`; we send images
  # unconditionally because the alternative is dropping a user's attachment
  # silently, and an agent that cannot read one will say so.
  defp image_blocks(images) do
    Enum.map(images, fn %{media_type: media_type, data: data} ->
      %{type: "image", mimeType: media_type, data: Base.encode64(data)}
    end)
  end

  # ── plumbing ──────────────────────────────────────────────────────────────

  defp send_request(state, tag, method, params) do
    id = state.next_id

    %{state | next_id: id + 1, pending: Map.put(state.pending, id, tag)}
    |> write(Protocol.request(id, method, params))
  end

  defp pop_pending(state, id) do
    {tag, pending} = Map.pop(state.pending, id)
    {tag, %{state | pending: pending}}
  end

  # Every write goes through `SpriteStdin` rather than `Sprites.write/2`,
  # because the latter exits its caller when the runtime has already gone —
  # #603, and being mid-turn is exactly the condition that made it an orphaned
  # turn rather than an error.
  defp write(%State{phase: :failed} = state, _iodata), do: state

  defp write(state, iodata) do
    case SpriteStdin.write(state.command, iodata) do
      :ok -> state
      {:error, reason} -> fail(state, {:acp_write_failed, reason})
    end
  end

  defp persist(state, stream, iodata) do
    report(state, {:lines, stream, IO.iodata_to_binary(iodata)})
    state
  end

  defp fail(%State{phase: :failed} = state, _reason), do: state

  defp fail(state, reason) do
    report(state, {:failed, reason})
    %{state | phase: :failed}
  end

  defp report(state, payload), do: send(state.owner, {:acp, state.ref, payload})

  defp supports?(state, path) do
    case get_in(state.capabilities, path) do
      nil -> false
      false -> false
      _ -> true
    end
  end

  # Prefer an option the agent itself marked as an allow. `optionId` is opaque
  # and adapter-defined, so picking by `kind` is the only portable choice.
  defp permission_outcome(params) do
    options = Map.get(params, "options") || []

    chosen =
      Enum.find(options, &(&1["kind"] == "allow_always")) ||
        Enum.find(options, &(&1["kind"] == "allow_once")) ||
        List.first(options)

    case chosen do
      %{"optionId" => id} -> %{outcome: "selected", optionId: id}
      _ -> %{outcome: "cancelled"}
    end
  end

  defp noreply(state), do: {:noreply, state}
end
