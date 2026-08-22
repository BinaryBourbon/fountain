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

  **The response is not the end of the replay, and we do not treat it as one.**
  Gemini answers `session/load` before replaying — its `streamHistory` is a
  floating promise — so a window closed on the response misses the replay
  entirely (#657, live: one assistant message rendered twice). The window
  closes instead on a bounded quiet period: keep discarding until the stream
  has been silent for `@replay_quiet_ms`, then prompt, giving up after
  `@replay_max_ms` because a turn held open disarms idle reclaim (#413).

  We prefer `resume` whenever the adapter advertises it, which the pinned Claude
  adapter does. `load` is kept because the capability is per-adapter and per
  version, and discovering at runtime that this build cannot resume is better
  handled by taking the expensive path than by failing the turn.

  ## Reattaching after a restart

  A deploy restarts every `ConversationServer`, and with it every peer — but
  the adapter in the sprite is a detachable session that keeps running,
  mid-turn, with a `session/prompt` still outstanding. `attach: prompt_id`
  starts a peer for that turn without a handshake: it joins the stream already
  in flight, answers the agent's requests (a `session/request_permission`
  nobody answers is a turn that never ends), and closes the turn on the
  response to `prompt_id`. Everything else in the replayed prefix — the
  handshake responses, a model rejection the previous peer already reported —
  is history and is dropped rather than re-acted-on.

  The prompt id has to come from the caller because it is the only way to
  tell the prompt's answer from a replayed handshake response; the peer
  reports `{:prompt_sent, id}` the moment it writes the prompt so the server
  can persist it for exactly this purpose. Without it a reattached turn cannot
  be resumed at all, and the caller orphans it instead.

  Sprites replays the **tail** of the session buffer (measured: one 16 KiB
  chunk, starting mid-line — not from the beginning), so an attached peer
  drops the partial first line and the server de-duplicates the replayed
  lines it already holds by content, not by byte count.

  ## What it sends back

  Everything goes to the owner as `{:acp, ref, payload}` so the server can keep
  its existing invariants — the log budget, the redaction pass and the replay
  skip all live on the server's persistence path, and a peer writing rows
  directly would bypass all three.
  """

  use GenServer

  require Logger

  alias Fountain.Runtimes.ACP
  alias Fountain.Runtimes.ACP.{Protocol, Usage}

  # How long the replay has to stay quiet before we believe it is over, and how
  # long we will wait for that in total. See `handle_response(:load_session, …)`.
  @replay_quiet_ms 250
  @replay_max_ms 10_000

  @typedoc "What the peer reports upward. `ref` is the sprite command's ref."
  @type payload ::
          {:lines, stream :: String.t(), data :: String.t()}
          | {:session, String.t()}
          | {:prompt_sent, pos_integer()}
          | {:model_rejected, requested :: String.t(), detail :: String.t()}
          | {:handshake_ms, non_neg_integer(), method :: String.t()}
          | {:done, stop_reason :: String.t(), usage :: map() | nil}
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
      model: nil,
      # The effective per-tool permission policy for this turn (#939). Already
      # merged and clamped by `Permissions.effective/2` before it gets here —
      # the peer applies it, it does not resolve it.
      permission_policy: %{},
      buffer: "",
      next_id: 1,
      pending: %{},
      phase: :initializing,
      replay_discard?: false,
      # Both set from opts in `init/1`; the defaults live on the outer module.
      replay_quiet_ms: nil,
      replay_max_ms: nil,
      replay_result: nil,
      replay_last_ms: nil,
      replay_until_ms: nil,
      capabilities: %{},
      auth_methods: [],
      authenticated?: false,
      # `attach: prompt_id` mode: joined a turn already in flight, so replayed
      # responses to ids we never sent are expected, and the first chunk may
      # start mid-line.
      attached?: false,
      drop_partial_line?: false
    ]
  end

  # ── public api ────────────────────────────────────────────────────────────

  @doc """
  Start a peer for one turn.

  Required opts: `:owner`, `:command`, `:ref`, `:prompt`, `:mode`,
  `:session_id`, `:cwd`.

  `attach: prompt_id` skips the handshake and resumes a turn whose
  `session/prompt` (with that JSON-RPC id) is already outstanding on the
  attached command — see the moduledoc. `:session_id` must be the live
  session's id so `cancel/1` still works.
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
      permission_policy: Keyword.get(opts, :permission_policy) || %{},
      model: Keyword.get(opts, :model),
      replay_quiet_ms: Keyword.get(opts, :replay_quiet_ms, @replay_quiet_ms),
      replay_max_ms: Keyword.get(opts, :replay_max_ms, @replay_max_ms),
      started_mono: System.monotonic_time(:millisecond)
    }

    case Keyword.get(opts, :attach) do
      nil ->
        {:ok, state, {:continue, :initialize}}

      prompt_id when is_integer(prompt_id) ->
        {:ok,
         %{
           state
           | phase: :prompting,
             pending: %{prompt_id => :prompt},
             next_id: prompt_id + 1,
             attached?: true,
             drop_partial_line?: true
         }}
    end
  end

  @impl true
  def handle_continue(:initialize, state) do
    send_request(state, :initialize, "initialize", ACP.initialize_params())
    |> noreply()
  end

  @impl true
  def handle_cast({:stdout, data}, %State{drop_partial_line?: true} = state) do
    # The replay starts wherever the sprite's buffer happens to start, which is
    # mid-line unless we are lucky. A fragment that does not open a JSON object
    # can only be the tail of a line we cannot parse: drop through its newline.
    # A chunk with no newline yet is the same fragment still arriving.
    cond do
      String.starts_with?(data, "{") ->
        handle_cast({:stdout, data}, %{state | drop_partial_line?: false})

      String.contains?(data, "\n") ->
        [_partial, rest] = String.split(data, "\n", parts: 2)
        handle_cast({:stdout, rest}, %{state | drop_partial_line?: false})

      true ->
        {:noreply, state}
    end
  end

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

  def handle_info(:replay_check, %State{phase: :draining_replay} = state) do
    quiet_for = now_ms() - state.replay_last_ms

    if quiet_for >= state.replay_quiet_ms or now_ms() >= state.replay_until_ms do
      %{state | replay_discard?: false}
      |> pin_model_then_prompt(state.replay_result)
      |> noreply()
    else
      state |> schedule_replay_check(state.replay_quiet_ms - quiet_for) |> noreply()
    end
  end

  # A turn that failed or was answered while a check was in flight.
  def handle_info(:replay_check, state), do: {:noreply, state}

  def handle_info(msg, state) do
    Logger.debug("acp peer: unexpected message #{inspect(msg)}")
    {:noreply, state}
  end

  # ── message dispatch ──────────────────────────────────────────────────────

  defp handle_message({:notification, "session/update", params}, state) do
    if state.replay_discard? do
      # Replay of history we already hold. Dropped, not persisted — see the
      # moduledoc. The timestamp is what the quiet period below measures.
      %{state | replay_last_ms: now_ms()}
    else
      persist(state, "acp", Protocol.notification("session/update", params))
    end
  end

  defp handle_message({:notification, _method, _params}, state), do: state

  defp handle_message({:response, id, result}, state) do
    case pop_pending(state, id) do
      {nil, %State{attached?: true} = state} ->
        # A replayed answer to the previous peer's handshake. Expected.
        state

      {nil, state} ->
        Logger.warning("acp peer: response to unknown request #{inspect(id)}")
        state

      {tag, state} ->
        handle_response(tag, result, state)
    end
  end

  # A model we could not pin is not worth failing a turn over — but it is worth
  # the tenant seeing, because the alternative is their agent quietly running a
  # model they did not choose.
  #
  # Reported upward rather than written to `stderr` (#724). stderr is the one
  # stream every protocol client filters out: `?streams=acp,stage` drops it,
  # and `fountain acp` treats it as the adapter's own noise. So the warning was
  # invisible to exactly the surfaces that had no other way to know — the
  # server turns this into a stage event, which every surface renders.
  defp handle_message({:error_response, _id, error}, %State{phase: :setting_model} = state) do
    state
    |> report_model_rejected(error)
    |> send_prompt()
  end

  # Attached mid-turn: an error for an id we never sent is a replay of one the
  # previous peer already handled — a `session/set_config_option` refusal is the
  # common one, and it was reported as a stage event at the time. Only the
  # prompt's own error can fail this turn.
  defp handle_message({:error_response, id, _error}, %State{attached?: true} = state)
       when not is_map_key(state.pending, id),
       do: state

  # Backstop for an agent that advertises no auth method at `initialize` and
  # then refuses anyway. The eager path above covers everything measured; this
  # covers being wrong about that, once, rather than failing the turn outright.
  defp handle_message({:error_response, id, error}, state) do
    {tag, state} = pop_pending(state, id)

    cond do
      session_setup?(tag) and auth_error?(error) and not state.authenticated? and
          auth_method(state) ->
        method = auth_method(state)
        Logger.info("acp peer: #{tag} needs authentication; retrying with #{method}")

        send_request(
          %{state | authenticated?: true},
          :authenticate,
          "authenticate",
          %{methodId: method}
        )

      # Claude's own error kind for "the Anthropic org owning this OAuth token
      # has disabled subscription (Claude Code) access" (#655). It arrives
      # over ACP as a generic JSON-RPC -32603 "Internal error" — nothing in
      # `code` marks it, so the kind has to be found in the error body's text
      # rather than read off a field. Scoped to the `:prompt` call: session
      # setup can fail for unrelated reasons, and the auth-retry clause above
      # already owns those.
      tag == :prompt and oauth_org_not_allowed?(error) ->
        fail(state, {:oauth_org_not_allowed, error_detail(error)})

      true ->
        fail(state, {:acp_error, tag, error})
    end
  end

  # `session/request_permission` is the channel gate 3 exists to use. Gate 2
  # answered it with a constant auto-allow, which was parity with the legacy
  # path's `--dangerously-skip-permissions` and friends. #939 made that a
  # policy: `Fountain.Permissions` decides per tool, and `auto_allow` — still
  # the default — keeps the old ladder verbatim, so this is parity until
  # someone writes a policy.
  #
  # Answering *something* is not optional: the agent blocks on this request, and
  # a blocked agent is a turn in flight, which disarms idle reclaim and bills
  # the sprite to the ceiling.
  #
  # The verdict is reported to the owner so a denial reaches the audit trail
  # (0013 — in the context, tool and verdict, never values). Allows are not
  # recorded: a turn makes dozens of tool calls, and a row each would make the
  # trail a transcript.
  defp handle_message({:request, id, "session/request_permission", params}, state) do
    outcome = Fountain.Permissions.outcome(state.permission_policy, params)
    tool = Fountain.Permissions.tool_name(params)
    verdict = Fountain.Permissions.verdict_for(state.permission_policy, tool)

    if verdict != "auto_allow", do: report(state, {:permission_denied, tool, verdict})

    write(state, Protocol.response(id, %{outcome: outcome}))
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
    state = %{state | capabilities: caps, auth_methods: Map.get(result, "authMethods") || []}

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

    # Authenticate *before* opening a session, when the agent offers a method.
    #
    # This was reactive at first — authenticate only when a call is refused —
    # and that is too late to be useful. Gemini will happily open a session
    # from ambient credentials without being told which auth method to use, but
    # it does not *persist* one: the next turn's `session/load` answers "No
    # previous sessions found for this project", so the retry authenticates
    # correctly and then finds nothing to load. The session has to be created
    # under a chosen method to exist at all.
    #
    # Safe to do eagerly because an agent that needs nothing advertises
    # nothing: claude's adapter returns `authMethods: []` (measured), so
    # `auth_method/1` is nil and this is skipped entirely for it.
    case auth_method(state) do
      nil ->
        start_session(state)

      chosen ->
        send_request(%{state | authenticated?: true}, :authenticate, "authenticate", %{
          methodId: chosen
        })
    end
  end

  defp handle_response(:new_session, result, state) do
    case Map.get(result, "sessionId") do
      id when is_binary(id) ->
        report(state, {:session, id})
        pin_model_then_prompt(%{state | session_id: id}, result)

      _ ->
        fail(state, {:acp_no_session_id, result})
    end
  end

  defp handle_response(:resume_session, result, state),
    do: pin_model_then_prompt(state, result)

  # ACP says the agent MUST replay the conversation as `session/update`
  # notifications *before* responding to `session/load`, which would make this
  # response the end of the replay. Gemini does not: it calls its
  # `streamHistory` as a floating promise and answers first, so the replay
  # arrives after this point and would land in `log_events` — duplicating the
  # transcript on every turn after the first (#657, measured against a live
  # agent: two `:text` blocks reading `"ECHO-5ECHO-5"`).
  #
  # So the response is not the signal. We keep discarding until the stream has
  # been quiet for `replay_quiet_ms`, then prompt. Timing is the only thing
  # separating replay from answer here — both arrive as `session/update` on the
  # same session, and the fresh answer cannot begin before we send
  # `session/prompt`, which the quiet period gates. Do not "fix" this by
  # widening the discard past the prompt; that drops the answer.
  #
  # The wait is capped: an agent that never goes quiet must not hold a turn
  # open, because a turn in flight disarms idle reclaim (#413). The cost is
  # cheap next to gemini's ~2.8s handshake, and it comes off entirely when the
  # upstream `await` lands.
  defp handle_response(:load_session, result, state) do
    schedule_replay_check(%{
      state
      | phase: :draining_replay,
        replay_result: result,
        replay_last_ms: now_ms(),
        replay_until_ms: now_ms() + state.replay_max_ms
    })
  end

  # The model was pinned (or refused); either way the turn goes ahead.
  defp handle_response(:set_model, _result, state), do: send_prompt(state)

  # Authenticated; open (or reopen) the session.
  defp handle_response(:authenticate, _result, state), do: start_session(state)

  # The turn's usage rides along with the stop reason (#827): it is the one
  # end-of-turn figure the runtime reports, and the response is the only place
  # it appears. nil when the runtime reports none.
  defp handle_response(:prompt, result, state) do
    stop = Map.get(result, "stopReason") || "end_turn"
    report(state, {:done, stop, Usage.from_prompt_result(result)})
    %{state | phase: :done}
  end

  # ── authentication ────────────────────────────────────────────────────────

  defp session_setup?(tag), do: tag in [:new_session, :resume_session, :load_session]

  defp auth_error?(%{"code" => -32_000}), do: true

  defp auth_error?(%{"message" => message}) when is_binary(message),
    do: String.contains?(String.downcase(message), "auth")

  defp auth_error?(_), do: false

  # inspect/1 rather than pattern-matching a specific key: the adapter's exact
  # placement of the kind (top-level, `data.details`, `data.kind`, ...) has
  # not been pinned down against a live org-disallowed account, and a
  # substring search over the whole payload is total — it cannot raise on a
  # shape we did not anticipate, unlike a `get_in` chain would.
  defp oauth_org_not_allowed?(error),
    do: error |> inspect() |> String.contains?("oauth_org_not_allowed")

  # Prefer a method naming an API key in its `_meta`: that is what an agent
  # offers for "there is a key in the environment, use it", as against an
  # interactive OAuth flow a headless sandbox can never complete.
  defp auth_method(state) do
    case Enum.find(state.auth_methods, &api_key_method?/1) do
      %{"id" => id} when is_binary(id) -> id
      _ -> nil
    end
  end

  # An api-key method only — never "whatever it listed first".
  #
  # Measured 2026-08-10: opencode advertises exactly `["opencode-login"]`, and
  # a first-in-the-list fallback picked it. It happened to return ok, but the
  # name is an interactive login and a headless sandbox cannot complete one; an
  # agent that *blocked* on it would leave a turn in flight forever, which
  # disarms idle reclaim and bills the sprite to its ceiling. Getting away with
  # it once is not evidence.
  #
  # Nothing needs the fallback. Of the four runtimes, only gemini requires
  # authentication at all, and it advertises an api-key method; claude
  # advertises none, and codex and opencode were both driven through a full
  # turn without ever authenticating.
  defp api_key_method?(method) do
    meta = Map.get(method, "_meta")
    is_map(meta) and Map.has_key?(meta, "api-key")
  end

  # ── session setup ─────────────────────────────────────────────────────────

  defp start_session(%State{mode: :run} = state), do: start_new_session(state)
  defp start_session(%State{mode: :continue} = state), do: resume_session(state)

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

  # ACP carries no model in `session/new`. The runtime's own default therefore
  # wins unless the client says otherwise, which would silently ignore
  # `agent.model` — the field the tenant actually configured, and for a
  # multi-provider runtime the entire configuration.
  #
  # The mechanism is `session/set_config_option` with `configId: "model"`, and
  # the session response advertises which options exist. We only send it when
  # the agent said it has one, so a runtime with no model concept is left alone
  # rather than being handed a method it never offered.
  defp pin_model_then_prompt(state, result) do
    cond do
      is_nil(state.model) or state.model == "" ->
        send_prompt(state)

      model_configurable?(result) ->
        send_request(%{state | phase: :setting_model}, :set_model, "session/set_config_option", %{
          sessionId: state.session_id,
          configId: "model",
          value: state.model
        })

      Map.has_key?(result, "models") ->
        send_request(%{state | phase: :setting_model}, :set_model, "session/set_model", %{
          sessionId: state.session_id,
          modelId: state.model
        })

      true ->
        state
        |> persist("stderr", [
          "fountain: this runtime does not expose model selection over ACP; ",
          "#{state.model} was not applied and its default is in use\n"
        ])
        |> send_prompt()
    end
  end

  # Two shapes in the wild, both measured against live agents on 2026-08-10.
  # Claude's adapter advertises `configOptions` and takes
  # `session/set_config_option` with `configId: "model"`; gemini advertises
  # `models` and implements ACP's own `session/set_model` with a `modelId`.
  # Neither is a superset of the other, so the session response decides.
  defp model_configurable?(result) do
    case Map.get(result, "configOptions") do
      options when is_list(options) -> Enum.any?(options, &(Map.get(&1, "id") == "model"))
      _ -> false
    end
  end

  defp send_prompt(state) do
    params = %{
      sessionId: state.session_id,
      prompt: [%{type: "text", text: state.prompt} | image_blocks(state.images)]
    }

    id = state.next_id
    state = send_request(%{state | phase: :prompting}, :prompt, "session/prompt", params)

    # Reported after the write so the server never persists an id for a prompt
    # that did not go out. Reattach reads it back — see the moduledoc.
    if state.phase == :failed, do: state, else: tap(state, &report(&1, {:prompt_sent, id}))
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

  # `Fountain.Sandbox.write_stdin/2` is total by contract: a runtime that has
  # already gone yields {:error, :command_exited} rather than exiting this
  # process — #603, and being mid-turn is exactly the condition that made
  # that an orphaned turn rather than an error.
  defp write(%State{phase: :failed} = state, _iodata), do: state

  defp write(state, iodata) do
    case Fountain.Sandbox.write_stdin(state.command, iodata) do
      :ok -> state
      {:error, reason} -> fail(state, {:acp_write_failed, reason})
    end
  end

  defp report_model_rejected(state, error) do
    report(state, {:model_rejected, state.model, error_detail(error)})
    state
  end

  # Adapters put the useful sentence in different places: claude's is under
  # `data.details` ("Invalid value for config option model: …"), while the
  # top-level `message` is a generic "Internal error". Prefer the specific one.
  defp error_detail(%{"data" => %{"details" => details}}) when is_binary(details), do: details
  defp error_detail(%{"message" => message}) when is_binary(message), do: message
  defp error_detail(other), do: inspect(other)

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

  defp schedule_replay_check(state, after_ms \\ nil) do
    Process.send_after(self(), :replay_check, after_ms || state.replay_quiet_ms)
    state
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp supports?(state, path) do
    case get_in(state.capabilities, path) do
      nil -> false
      false -> false
      _ -> true
    end
  end

  # Prefer an option the agent itself marked as an allow. `optionId` is opaque
  # and adapter-defined, so picking by `kind` is the only portable choice.
  defp noreply(state), do: {:noreply, state}
end
