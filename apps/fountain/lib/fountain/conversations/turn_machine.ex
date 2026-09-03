defmodule Fountain.Conversations.TurnMachine do
  @moduledoc """
  A conversation's turn as a state machine (#1374): the running turn row,
  its OTel span, its metrics and its stream tracer as one value, and one
  function per peer report that returns the next value and a list of
  effects for `ConversationServer` to apply.

  ## The shape

  `from_state/1` reads the server's four turn fields (and the reattach
  dedup set the `:lines` report consults) into a `%Turn{}`; `into_state/2`
  writes them back. The server's state does not change shape.

  `handle/3` is the machine. It reads rows and writes the turn row (the
  prompt's JSON-RPC id, the usage), and records what is the turn's own to
  record (the `model` stage, the handshake telemetry and span stamp, the
  permission-denied audit). Everything that is the server's — its other
  state, its processes, its timers, output persistence, the pending
  registries — comes back as an effect, applied in list order:

    * `{:persist_lines, stream, data}` — the log budget, redaction, replay
      skip and tracer feed (the output family, #1377);
    * `:open_autonomous_turn`, `:arm_autonomous_quiet` — the background
      cycle a peer narrates out of turn (#817, the connection family);
    * `{:session_id, id}` — persist the runtime's session id on the row and
      in state;
    * `{:ask_permission, request_id, tool, options}` — the held request:
      its row, its stage, its timeout (the pending family, #1375);
    * `{:finish, status, span_attrs, stage_meta}` — end the turn: the
      server resolves what is pending, cancels the quiet timer, then calls
      `finish/4`;
    * `{:drop_connection, why}` — a failed peer is not reusable.

  `finish/4` and the interrupt pair are the turn's own bookkeeping, called
  by the server at the right point of its sequence so nothing reorders.
  The functions after them are what starting a turn decides before the
  spawn, which stays a server callback because it spawns.
  """

  require Logger
  require OpenTelemetry.Tracer

  alias Fountain.{Agents, Conversations}
  alias Fountain.Conversations.Conversation

  @typedoc "What the peer reports about a turn, with the command ref already matched."
  @type payload :: tuple()

  @typedoc """
  What the machine needs that is not the turn's own: `:autonomous?` (the
  connection family's predicate, read by the server), `:runtime_module`
  (the OAuth clause is Claude-only), `:oauth_switched?` (the server
  swaps the env before the call; the machine words the message), and the
  pair the usage stamp needs — `:inference` (`:own` | `:platform`, whose key
  ran this turn, #1388) and `:model` (what it ran).
  """
  @type ctx :: %{
          optional(:autonomous?) => boolean(),
          optional(:runtime_module) => module(),
          optional(:oauth_switched?) => boolean(),
          optional(:inference) => :own | :platform | nil,
          optional(:model) => String.t() | nil
        }

  @type effect ::
          {:persist_lines, String.t(), binary()}
          | :open_autonomous_turn
          | :arm_autonomous_quiet
          | {:session_id, String.t()}
          | {:ask_permission, term(), String.t(), list()}
          | {:finish, String.t(), map(), map()}
          | {:drop_connection, String.t()}

  @type t :: %__MODULE__{
          conversation_id: String.t() | nil,
          row: Conversations.Turn.t() | nil,
          span: term() | nil,
          metrics: map() | nil,
          tracer: term() | nil,
          replay_dedup: MapSet.t()
        }

  defstruct conversation_id: nil,
            row: nil,
            span: nil,
            metrics: nil,
            tracer: nil,
            replay_dedup: MapSet.new()

  # ── the server boundary ───────────────────────────────────────────────────

  @doc "The turn the server holds, as one value."
  @spec from_state(map()) :: t()
  def from_state(state) do
    %__MODULE__{
      conversation_id: state.conversation_id,
      row: state.current_turn,
      span: state.current_turn_span,
      metrics: state.turn_metrics,
      tracer: state.stream_tracer,
      replay_dedup: state.replay_dedup
    }
  end

  @doc "The turn written back into the server's fields."
  @spec into_state(map(), t()) :: map()
  def into_state(state, %__MODULE__{} = turn) do
    %{
      state
      | current_turn: turn.row,
        current_turn_span: turn.span,
        turn_metrics: turn.metrics,
        stream_tracer: turn.tracer,
        replay_dedup: turn.replay_dedup
    }
  end

  # ── the machine ───────────────────────────────────────────────────────────

  @doc """
  The `ctx/0` for a report, from the server's state plus whatever the call
  site adds (`:oauth_switched?` is the only one).

  Here rather than at the call site because every key of it is the machine's
  own vocabulary, and the server's job is to hold the state, not to know
  which parts of it the machine reads.
  """
  @spec ctx(map(), keyword()) :: ctx()
  def ctx(state, extra \\ []) do
    Map.new(
      [
        autonomous?: autonomous_turn?(state),
        runtime_module: state.runtime_module,
        inference: state.inference_source,
        model: state.inference_model
      ] ++ extra
    )
  end

  @doc """
  Whether the running turn is a background cycle the agent narrated out of
  turn (#817) rather than a prompt somebody sent. Over the server's state,
  which is where the running turn lives.
  """
  @spec autonomous_turn?(map()) :: boolean()
  def autonomous_turn?(%{current_turn: %{origin: "autonomous"}}), do: true
  def autonomous_turn?(_state), do: false

  @doc "One peer report: the next turn and the effects the server applies."
  @spec handle(t(), payload(), ctx()) :: {t(), [effect()]}
  def handle(turn, payload, ctx \\ %{})

  # A `session/update` the peer relayed. Under ACP every line here is
  # protocol, so it lands on the "acp" stream with the tracer reading it
  # (`persist_lines`). A line with no turn open (#817) means the agent is
  # narrating a background cycle: that opens an autonomous turn — a real
  # row, so the log budget, redaction and the stage events apply unchanged —
  # and every further line re-arms the quiet timer that closes it if no
  # `cycle_end` ever does.
  #
  # Session *metadata* is the exception (#1300). The claude adapter writes its
  # `session_info_update` (the generated title) about a second after every
  # prompt response — out of turn — and reading that as a background follow-up
  # opened a phantom autonomous turn after nearly every turn, held open for
  # the full quiet window: `running` status, deferred idle park, billed turn
  # time. Metadata is nothing the agent did, so it opens no turn and re-arms
  # no quiet timer; with a turn in flight it still lands on the transcript.
  def handle(%__MODULE__{} = turn, {:lines, stream, data}, ctx) do
    cond do
      stream == "acp" and MapSet.member?(turn.replay_dedup, data) ->
        # A replayed line we already hold (ACP reattach). Each persisted line
        # suppresses at most one arrival, so a legitimate later repeat survives.
        {%{turn | replay_dedup: MapSet.delete(turn.replay_dedup, data)}, []}

      stream == "acp" and Managoat.ACP.Protocol.session_metadata?(data) ->
        if is_nil(turn.row) do
          # No turn to attach it to, and not worth opening one: dropped.
          {turn, []}
        else
          {turn, [{:persist_lines, stream, data}]}
        end

      stream == "acp" and is_nil(turn.row) ->
        {turn, [:open_autonomous_turn, {:persist_lines, stream, data}]}

      stream == "acp" and Map.get(ctx, :autonomous?, false) ->
        {turn, [:arm_autonomous_quiet, {:persist_lines, stream, data}]}

      true ->
        {turn, [{:persist_lines, stream, data}]}
    end
  end

  # The adapter marked the end of a background cycle (#817). The turn it
  # opened closes here; a `cycle_end` with no autonomous turn open (its
  # updates never reached us) is nothing to close.
  def handle(%__MODULE__{} = turn, {:cycle_end, kind}, ctx) do
    if Map.get(ctx, :autonomous?, false) do
      {turn,
       [
         {:finish, "completed", %{"origin" => kind}, %{origin: "autonomous", cycle: kind}}
       ]}
    else
      {turn, []}
    end
  end

  # The runtime refused the agent's model. Published as a stage event so it
  # reaches every surface — the conversation view, the API, the CLI and an
  # editor's log — rather than only the `stderr` stream, which is the one
  # thing a protocol client filters out (#724). The turn continues on the
  # runtime's default, which is the peer's call and the right one mid-turn;
  # what changes here is that nobody has to guess which model answered.
  def handle(%__MODULE__{} = turn, {:model_rejected, requested, detail}, _ctx) do
    Logger.warning("conv #{turn.conversation_id}: runtime refused model #{requested}: #{detail}")

    publish_stage(turn.conversation_id, "model", "failed", %{
      requested: requested,
      detail: detail,
      using: "the runtime's default for this turn"
    })

    {turn, []}
  end

  # `session/new` chose an id. Persisted immediately, exactly as the legacy path
  # persists one before spawning: it is what the next turn resumes by, and a
  # server restart between here and the end of the turn must not lose it.
  def handle(%__MODULE__{} = turn, {:session, id}, _ctx), do: {turn, [{:session_id, id}]}

  # The peer wrote `session/prompt` under this JSON-RPC id. Persisted at once:
  # it is what a reattach after a restart needs to tell the prompt's answer
  # from the replayed handshake, and a turn without it cannot be resumed at
  # all — see `reattach_acp_peer/3`.
  def handle(%__MODULE__{} = turn, {:prompt_sent, id}, _ctx) do
    {:ok, row} = Conversations._unsafe_update_turn(turn.row, %{acp_prompt_id: id})
    {%{turn | row: row}, []}
  end

  # `ask`: the agent is blocked and a human has to answer (#940). An agent
  # blocked mid-cycle asks out of turn (#817): the request needs a turn row
  # to live on, exactly as an out-of-turn update does. The request itself —
  # persisted on the turn first, then announced, then timed — is the
  # server's `ask_permission` effect.
  def handle(%__MODULE__{} = turn, {:permission_ask, request_id, tool, options}, _ctx) do
    open = if is_nil(turn.row), do: [:open_autonomous_turn], else: []
    {turn, open ++ [{:ask_permission, request_id, tool, options}]}
  end

  # A tool the policy withheld (#939). Recorded in the context, per 0013: the
  # tool and the verdict, never the tool's input. Only refusals reach here —
  # the peer stays silent on `auto_allow`, because a turn makes dozens of tool
  # calls and a row each would turn the trail into a transcript.
  def handle(%__MODULE__{} = turn, {:permission_denied, tool, verdict}, _ctx) do
    Conversations.record_permission_denied(turn.conversation_id, tool, verdict)
    {turn, []}
  end

  # The number gate 2 exists to produce: what a turn pays for `initialize` plus
  # resumption, which the legacy path does not pay at all. Emitted per turn so
  # the cost of a disposable sandbox is measurable rather than argued about.
  #
  # Also stamped on the turn's OTel span, because the comparison that decides
  # the gate is against *this same turn's* total — a handshake figure in an
  # unrelated metrics stream tells you the cost but not the share.
  def handle(%__MODULE__{} = turn, {:handshake_ms, ms, method}, _ctx) do
    :telemetry.execute([:fountain, :acp, :handshake], %{duration_ms: ms}, %{
      conversation_id: turn.conversation_id,
      turn_id: turn.row && turn.row.id,
      method: method
    })

    stamp_span(turn.span, %{
      "acp.handshake_ms" => ms,
      "acp.session_method" => method
    })

    {turn, []}
  end

  # The turn's first terminator: `session/prompt` answered with a stop reason.
  # Closing stdin here is what makes the adapter exit, and clearing the command
  # ref is what makes that exit a no-op instead of a second ending.
  #
  # `usage` is the turn's end-of-turn token figure (#827), recorded once here
  # — the response is the only place the runtime reports it — before the turn
  # row is closed. nil records nothing.
  def handle(%__MODULE__{} = turn, {:done, stop_reason, usage}, ctx) do
    status = if stop_reason in ["refusal", "cancelled"], do: "failed", else: "completed"
    record_usage(turn, with_inference(usage, ctx))

    {turn,
     [
       {:finish, status, %{"stop_reason" => stop_reason}, %{stop_reason: stop_reason}}
     ]}
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
  #
  # The swap itself is the server's (it logs the refusal and rewrites the
  # sprite env and the broker session before this is called);
  # `:oauth_switched?` says whether a key was there to swap in, which is what
  # the message turns on.
  def handle(
        %__MODULE__{} = turn,
        {:failed, {:oauth_org_not_allowed, _detail}},
        %{runtime_module: Managoat.Runtimes.Claude} = ctx
      ) do
    message =
      if Map.get(ctx, :oauth_switched?, false) do
        "Your organization has disabled Claude subscription (OAuth) access for Claude Code. " <>
          "Switched to the Anthropic API key on this account for the rest of this " <>
          "conversation — send your prompt again."
      else
        "Your organization has disabled Claude subscription (OAuth) access for Claude Code, " <>
          "and no Anthropic API key is on file for this account. Add one in Settings, then " <>
          "try again."
      end

    {turn,
     [
       {:finish, "failed", %{"error" => message, "acp.oauth_org_not_allowed" => true},
        %{reason: message}},
       {:drop_connection, "failed"}
     ]}
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
  def handle(%__MODULE__{} = turn, {:failed, {:model_unavailable, requested, detail}}, _ctx) do
    Logger.warning(
      "conv #{turn.conversation_id}: provider refused model #{requested || "(unset)"}: #{detail}"
    )

    publish_stage(turn.conversation_id, "model", "failed", %{
      requested: requested,
      detail: detail,
      using: "none, the turn failed"
    })

    message = model_unavailable_message(requested, detail)

    {turn,
     [
       {:finish, "failed", %{"error" => message, "acp.model_unavailable" => true},
        %{reason: message}},
       {:drop_connection, "failed"}
     ]}
  end

  # A failed peer is not reusable: end the turn it was driving (if any) and
  # drop the connection, so the next prompt spawns a fresh adapter.
  def handle(%__MODULE__{} = turn, {:failed, reason}, _ctx) do
    Logger.error("conv #{turn.conversation_id}: acp peer failed: #{inspect(reason)}")

    finish =
      if turn.row do
        [{:finish, "failed", %{"error" => inspect(reason)}, %{reason: "acp: #{inspect(reason)}"}}]
      else
        []
      end

    {turn, finish ++ [{:drop_connection, "failed"}]}
  end

  # ── ending a turn ─────────────────────────────────────────────────────────

  @doc """
  End a turn, and only a turn (#817): the row, the `turn` stage, the span,
  the completion metric and the conversation back to idle. What the server
  resolves first (a held permission, parked caller tools, the quiet timer)
  is the server's; what it clears after (activity) is too. Returns the turn
  with its bookkeeping cleared.
  """
  @spec finish(t(), String.t(), map(), map()) :: t()
  def finish(%__MODULE__{} = turn, status, span_attrs, stage_meta) do
    # Before the turn span ends: totals land on it, abandoned tool spans close.
    finalize_tracer(turn.tracer)

    {:ok, row} =
      Conversations._unsafe_update_turn(turn.row, %{
        status: status,
        ended_at: now()
      })

    publish_stage(
      turn.conversation_id,
      "turn",
      if(status == "completed", do: "done", else: "failed"),
      Map.merge(%{turn_id: row.id, turn_number: row.turn_number}, stage_meta)
    )

    end_span(
      turn.span,
      if(status == "completed", do: :ok, else: :error),
      span_attrs
    )

    emit_completed(turn, row.status)

    conv = Conversations._unsafe_get_conversation!(turn.conversation_id)
    {:ok, _} = Conversations.update_conversation(conv, %{status: "idle"})

    %{turn | row: nil, span: nil, metrics: nil, tracer: nil}
  end

  @doc """
  The interrupt's first half: the row `interrupted`, the stage, the tracer
  closed. The server stops the peer between the halves, as it always did,
  then `close_interrupted/1` ends the span, emits the metric and sets the
  conversation idle.
  """
  @spec mark_interrupted(t()) :: t()
  def mark_interrupted(%__MODULE__{} = turn) do
    {:ok, _turn} =
      Conversations._unsafe_update_turn(turn.row, %{
        status: "interrupted",
        ended_at: now()
      })

    publish_stage(turn.conversation_id, "turn", "interrupted", %{
      turn_id: turn.row.id,
      turn_number: turn.row.turn_number
    })

    # Finalize stream tracer: close any tool spans still open (abandoned calls).
    finalize_tracer(turn.tracer)
    turn
  end

  @spec close_interrupted(t()) :: t()
  def close_interrupted(%__MODULE__{} = turn) do
    end_span(turn.span, :error, %{"outcome" => "interrupted"})

    emit_completed(turn, "interrupted")

    conv = Conversations._unsafe_get_conversation!(turn.conversation_id)
    {:ok, _} = Conversations.update_conversation(conv, %{status: "idle"})

    %{turn | row: nil, span: nil, metrics: nil, tracer: nil}
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
  @spec emit_completed(t(), String.t()) :: :ok
  def emit_completed(%__MODULE__{metrics: nil}, _status), do: :ok

  def emit_completed(%__MODULE__{metrics: metrics} = turn, status) do
    Fountain.Telemetry.event(
      [:turn, :completed],
      %{runtime: metrics.runtime, status: status, conv_id: turn.conversation_id},
      %{duration_ms: System.monotonic_time(:millisecond) - metrics.started_mono}
    )
  end

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
  @spec maybe_emit_first_output(t()) :: t()
  def maybe_emit_first_output(%__MODULE__{metrics: %{first_output?: false} = metrics} = turn) do
    Fountain.Telemetry.event(
      [:turn, :first_output],
      %{runtime: metrics.runtime, conv_id: turn.conversation_id},
      %{elapsed_ms: System.monotonic_time(:millisecond) - metrics.started_mono}
    )

    %{turn | metrics: %{metrics | first_output?: true}}
  end

  # No turn running, or this turn already reported. Also the reattach case:
  # turn_metrics is nil there, so the replayed output a resumed session
  # opens with can't be mistaken for a first token (its real one arrived in
  # a previous BEAM lifetime).
  def maybe_emit_first_output(%__MODULE__{} = turn), do: turn

  @doc """
  The usage figure with the turn's inference source on it (#1388).

  Two keys beside the token counts: `"inference"` — `"platform"` when
  Fountain's key ran the turn, `"own"` when the tenant's did — and, on a
  platform turn, `"model"`, which is what `Workers.CreditPricer` prices
  against the rate card.

  **Only stamped on a deployment that holds a platform key at all.** With
  none configured there is no question to answer, and an unstamped map is
  byte-for-byte the map every turn has always carried, which is what keeps a
  self-hosted install (and the tests that assert on it) unchanged.

  The `"model"` key is deliberately absent on an `"own"` turn: nothing prices
  it, so recording it would put a configuration detail in a column that
  exists to hold token counts.
  """
  @spec with_inference(map() | nil, ctx()) :: map() | nil
  def with_inference(usage, ctx) when is_map(usage) do
    case Map.get(ctx, :inference) do
      source when source in [:own, :platform] ->
        if Fountain.PlatformInference.enabled?() do
          usage
          |> Map.put("inference", Atom.to_string(source))
          |> put_model(source, Map.get(ctx, :model))
        else
          usage
        end

      _ ->
        usage
    end
  end

  def with_inference(usage, _ctx), do: usage

  defp put_model(usage, :platform, model) when is_binary(model),
    do: Map.put(usage, "model", model)

  defp put_model(usage, _source, _model), do: usage

  @spec record_usage(t(), map() | nil) :: :ok
  def record_usage(%__MODULE__{row: %{} = row}, %{} = usage) do
    case Conversations._unsafe_record_turn_usage(row, usage) do
      {:ok, _} ->
        :ok

      other ->
        Logger.warning(
          "conv #{row.conversation_id}: turn #{row.id} usage not recorded: #{inspect(other)}"
        )
    end
  end

  def record_usage(_turn, _usage), do: :ok

  # ── the span and the tracer ───────────────────────────────────────────────

  # The turn's OTel span. Opened explicitly (not via Telemetry.span) because a
  # turn finishes asynchronously, in a later handler; the context is carried in
  # state and closed there. `mode` is `:run` | `:continue` | `:autonomous`.
  @spec open_span(String.t() | nil, Conversation.t(), Conversations.Turn.t(), atom(), map() | nil) ::
          term()
  def open_span(user_id, conv, turn, mode, agent) do
    OpenTelemetry.Tracer.start_span("fountain.turn", %{
      attributes: %{
        "conv_id" => conv.id,
        "turn_id" => turn.id,
        "turn_number" => turn.turn_number,
        "mode" => Atom.to_string(mode),
        "runtime" => to_string(conv.runtime),
        "model" => agent && agent.model,
        "agent_id" => agent && agent.id,
        "user_id" => user_id,
        "prompt_length" => byte_size(turn.prompt),
        "image_count" => 0
      }
    })
  end

  # Attributes on a turn's span from outside `kick_turn`, which restores the
  # caller's current span in its `after` block — so by the time a peer report
  # arrives the turn span is no longer current and a bare `set_attribute` would
  # land on whatever is.
  @spec stamp_span(term() | nil, map()) :: :ok
  def stamp_span(nil, _attrs), do: :ok

  def stamp_span(span_ctx, attrs) do
    previous = OpenTelemetry.Tracer.set_current_span(span_ctx)
    Enum.each(attrs, fn {k, v} -> OpenTelemetry.Tracer.set_attribute(to_string(k), v) end)
    OpenTelemetry.Tracer.set_current_span(previous)
    :ok
  end

  # End the OTel turn span (if any) with a status reflecting the
  # outcome. Called from the :exit and :interrupt handlers.
  @spec end_span(term() | nil, :ok | :error, map()) :: :ok | term()
  def end_span(nil, _outcome, _attrs), do: :ok

  def end_span(span_ctx, outcome, attrs) do
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

  # Called on every way a turn can end; ACP turns are the only ones that
  # trace, so nil is the legacy case.
  @spec finalize_tracer(term() | nil) :: :ok | term()
  def finalize_tracer(nil), do: :ok
  def finalize_tracer(tracer), do: Managoat.ACP.Tracer.finalize(tracer)

  # ── starting a turn ───────────────────────────────────────────────────────

  # Every turn passes through here, whichever door it came in by — the
  # controller/LiveView call above, or the queued initial prompt a wake
  # delivers as a cast. The provisioning gates cover fresh sprites only; a
  # live server (or the reuse arm of a wake) outlives the balance it was
  # started under, and each turn resets the idle clock, so a balance spent to
  # zero otherwise bought up to the 24h max lifetime of continued service per
  # live sandbox (#313). Suspension is the same shape.
  #
  # `inference` is the conversation's inference source (#1388). On a turn
  # running on a platform key the deployment's daily ceiling is the third
  # gate: a live server outlives the ceiling it started under exactly as it
  # outlives the balance, so the same backstop shape applies. A turn on the
  # tenant's own key is never touched by it.
  @spec gate(String.t(), :own | :platform | nil) :: :ok | {:error, term()}
  def gate(user_id, inference \\ nil) do
    with :ok <- Fountain.Accounts.check_not_suspended(user_id),
         :ok <- Fountain.Billing.check_spend(user_id) do
      if inference == :platform,
        do: Fountain.PlatformInference.check_ceiling(),
        else: :ok
    end
  end

  # Whether this machine can take a turn from this conversation right now. An
  # unlocked read — the locked check is inside the turn insert
  # (`_unsafe_create_turn_on_sandbox/3`); this one exists so the API door gets
  # a refusal to render rather than an `:ok` followed by a refused stage.
  @spec capacity_gate(String.t(), Conversation.t()) :: :ok | {:error, :sandbox_at_capacity}
  def capacity_gate(sandbox_id, conv) do
    capacity = Managoat.Runtimes.ACP.concurrency(conv.runtime)

    if Conversations._unsafe_sandbox_at_capacity?(sandbox_id, conv.id, capacity),
      do: {:error, :sandbox_at_capacity},
      else: :ok
  end

  @doc """
  The turn row, or the refusal. The machine may be shared (ADR 0023). For a
  runtime that takes one turn at a time the insert is checked under the
  sandbox's lock, so two conversations prompting the same machine at once
  cannot both start. Refused, not queued: nothing is written, the
  conversation stays idle and the caller sends again when the other turn
  ends.
  """
  @spec open(String.t(), String.t(), String.t()) ::
          {:ok, Conversation.t(), Conversations.Turn.t()} | :at_capacity
  def open(conversation_id, sandbox_id, prompt) do
    conv = Conversations._unsafe_get_conversation!(conversation_id)
    turn_number = Conversations._unsafe_next_turn_number(conversation_id)

    attrs = %{
      conversation_id: conv.id,
      turn_number: turn_number,
      prompt: prompt,
      status: "running",
      started_at: now()
    }

    capacity = Managoat.Runtimes.ACP.concurrency(conv.runtime)

    case Conversations._unsafe_create_turn_on_sandbox(attrs, sandbox_id, capacity) do
      {:ok, turn} ->
        {:ok, conv, turn}

      {:error, :sandbox_at_capacity} ->
        publish_stage(conversation_id, "sandbox", "done", %{
          event: "at_capacity",
          reason: "sandbox_at_capacity",
          runtime: conv.runtime,
          message:
            "Another conversation is running a turn on this sandbox, and #{conv.runtime} " <>
              "takes one turn at a time. Wait for it to finish, or interrupt it, then send again."
        })

        :at_capacity
    end
  end

  # Store images. A rejected image must not take the turn down with it: this
  # used to hard-match {:ok, _}, which is why validation could not be added to
  # the insert path without crashing the server mid-turn.
  @spec store_images(Conversations.Turn.t(), list()) :: :ok
  def store_images(turn, images) do
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
  end

  # On the first turn, asynchronously generate a short title for the sidebar.
  # Not for a teammate's conversation: there the title is the name the user
  # gave the teammate when adding it (or nothing, and the agent's name
  # shows), and a generated summary would rename the teammate on the team
  # page after its first message (#807).
  @spec generate_title(Conversation.t(), Conversations.Turn.t(), String.t(), map()) :: :ok
  def generate_title(conv, turn, prompt, creds) do
    if turn.turn_number == 1 and conv.channel_id != Fountain.Team.channel() do
      conv_id = conv.id

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

    :ok
  end

  @doc """
  The mode and the runtime session id a fresh turn runs with. A persisted id
  means "a turn has happened", which is what picks `session/resume` or
  `session/load` over `session/new`; with none, one is generated and
  persisted immediately so a server restart can resume.
  """
  @spec session_plan(Conversation.t(), String.t() | nil) :: {:run | :continue, String.t()}
  def session_plan(conv, runtime_session_id) do
    mode =
      cond do
        is_nil(runtime_session_id) -> :run
        true -> :continue
      end

    runtime_session_id =
      case runtime_session_id do
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

    {mode, runtime_session_id}
  end

  @doc """
  What to spawn. 0014: a supported runtime spawns an ACP adapter instead of
  the CLI, and everything about the turn — the prompt, the images, the
  session id, the mode — travels over the protocol rather than in argv, so
  `build_command/5` is not consulted at all on this path. There is no opt-in
  left to check: gate 4 deleted the legacy spawn path for claude, codex and
  opencode along with the per-agent flag, so `acp?` is a property of
  `conv.runtime` alone.

  The `else` branch is now **unreachable in production**. It survived for
  gemini until #659 put it on ACP and #941 deleted its `build_command/5`;
  no runtime module implements that callback any more, and `for_runtime/1`
  refuses a name that has no module, so a conversation whose runtime lacks
  an ACP adapter cannot start in the first place. It is kept because the
  turn machinery it leads to — the log budget, stdin handling, exit codes —
  is shared, and `Managoat.Runtimes.Testing.FakeRuntime` still drives it here.

  Returns `{cmd, args, build_opts}`; `build_opts` may carry `stdin?`
  (codex embeds the prompt in argv and returns false), `tty?` (codex wants
  a PTY so `isatty(0)` is true), `dir` (a workspace with a local .git) and
  `prompt_suffix` (image references for a runtime that cannot take images
  as flags).
  """
  @spec command(
          boolean(),
          Conversation.t(),
          map() | nil,
          String.t(),
          atom(),
          String.t(),
          keyword()
        ) :: {String.t(), [String.t()], keyword()}
  def command(acp?, conv, agent, prompt, mode, runtime_session_id, opts) do
    if acp? do
      {c, a} = Managoat.Runtimes.ACP.command(conv.runtime)
      # The ACP `cwd` is validated in band by the agent CLI against the real
      # filesystem, so it must be the path a process inside the sandbox sees
      # — identity on hosted providers, the mapped directory on a runner
      # (ADR 0022).
      acp_cwd =
        Managoat.Sandbox.host_path(
          Keyword.fetch!(opts, :handle),
          Managoat.Runtimes.ACP.cwd(conv.runtime)
        )

      {c, a, stdin?: true, dir: acp_cwd}
    else
      Keyword.fetch!(opts, :runtime_module).build_command(agent, prompt, mode, runtime_session_id,
        images: Keyword.get(opts, :image_paths, [])
      )
    end
  end

  # The legacy stdin dance, unchanged and lifted out so the ACP branch above
  # reads as one condition rather than a nested `if`.
  @spec write_prompt_and_close(Managoat.Sandbox.Command.t(), String.t()) :: :ok | {:error, term()}
  def write_prompt_and_close(command, payload) do
    case Managoat.Sandbox.write_stdin(command, payload) do
      :ok -> Managoat.Sandbox.close_stdin(command)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Start the peer for a fresh ACP turn, owned by the caller; returns it with its monitor."
  @spec start_acp_peer(Managoat.Sandbox.Command.t(), String.t(), atom(), String.t(), keyword()) ::
          {pid(), reference()}
  def start_acp_peer(command, prompt, mode, runtime_session_id, opts) do
    {:ok, peer} =
      Managoat.ACP.Peer.start(
        owner: self(),
        # See reattach_acp_peer/3 for the writer's contract.
        writer: fn iodata -> Managoat.Sandbox.write_stdin(command, iodata) end,
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

  # The permission policy in force for this turn (#939): the agent's own,
  # clamped by whatever narrowing the launch asked for. Resolved per turn from
  # the agent rather than read off a policy frozen on the conversation row, so
  # tightening an agent tightens the conversations already running under it.
  @spec effective_permission_policy(Conversation.t(), map() | nil) :: term()
  def effective_permission_policy(conv, agent) do
    Managoat.ACP.Permissions.effective(agent && agent.permission_policy, conv.permission_policy)
  end

  # Ownership is already established: this server exists for this conversation.
  # See the `_unsafe_` rules in CLAUDE.md — a GenServer holding the conversation
  # is one of the legitimate callers.
  @spec agent_for(Conversation.t()) :: map() | nil
  def agent_for(conv), do: conv.agent_id && Agents._unsafe_get_agent(conv.agent_id)

  @doc """
  A turn that never got as far as running: either the spawn itself failed,
  or the runtime exited before the prompt reached its stdin (#603). Both
  leave nothing running, so both end the same way — the turn `failed` with
  the reason, a `turn`/`failed` stage event, and the conversation back to
  "idle".

  `exit_code` is what the runtime managed to say before it went (#608); the
  spawn-failure path has none, since there was never a process. `detail` is
  `failure_detail/2`'s sentence, which the server logs first and then
  persists the runtime's parting words against the turn they explain,
  before calling this.

  Called only from inside the server's spawn `try` block, which restores the
  caller's previous current-span in its `after`; the span this ends is the
  turn span opened a few lines above the call.
  """
  @spec fail_before_start(
          Conversations.Turn.t(),
          String.t(),
          String.t(),
          String.t(),
          integer() | nil
        ) ::
          :ok
  def fail_before_start(turn, conversation_id, what, detail, exit_code) do
    {:ok, _} =
      Conversations._unsafe_update_turn(turn, %{
        status: "failed",
        exit_code: exit_code,
        ended_at: now()
      })

    publish_stage(conversation_id, "turn", "failed", %{
      turn_id: turn.id,
      reason: detail,
      exit_code: exit_code
    })

    # The conversation was set to "running" just before the spawn attempt;
    # without this it stays "running" in the API and UI until some later turn
    # completes, even though nothing is executing. The :exit and :interrupt
    # handlers both do the same reset.
    failed_conv = Conversations._unsafe_get_conversation!(conversation_id)

    if failed_conv.status == "running" do
      {:ok, _} = Conversations.update_conversation(failed_conv, %{status: "idle"})
    end

    # The turn never started; close the span we just opened so it doesn't leak.
    if exit_code, do: OpenTelemetry.Tracer.set_attribute("exit_code", exit_code)
    OpenTelemetry.Tracer.set_status(OpenTelemetry.status(:error, "#{what}: #{detail}"))

    # No-arg: end_span/1 takes a timestamp, not a span. turn_span is the
    # current span here (kick_turn made it current), which is what no-arg ends.
    OpenTelemetry.Tracer.end_span()
    :ok
  end

  @doc "The reason as it is reported everywhere: inspected, with the exit code appended when there is one."
  @spec failure_detail(term(), integer() | nil) :: String.t()
  def failure_detail(reason, exit_code), do: "#{inspect(reason)}#{exit_detail(exit_code)}"

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
  #
  # The other terminal frame ends the drain too, with a nil code. Since
  # `managoat_sandbox` 0.2.0 a transport that closes with no exit frame
  # arrives as `{:error, ref, :closed_before_exit}` rather than a fabricated
  # `{:exit, ref, 0}`, and that frame is just as stranded as the output
  # around it: `current_command_ref` is unset on this path, so leaving it in
  # the mailbox costs the full deadline and then drops it (#608 again). The
  # code stays nil because nobody measured one — a nil reads as "no exit
  # code" everywhere it is reported, which is exactly the truth here.
  @spec drain_exited_command(reference()) :: {integer() | nil, [{String.t(), binary()}]}
  def drain_exited_command(ref) do
    drain_exited_command(ref, System.monotonic_time(:millisecond) + @drain_timeout_ms, [])
  end

  defp drain_exited_command(ref, deadline, output) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:exit, %{ref: ^ref}, code} ->
        {code, Enum.reverse(output)}

      {:error, %{ref: ^ref}, _reason} ->
        {nil, Enum.reverse(output)}

      {:stdout, %{ref: ^ref}, data} ->
        drain_exited_command(ref, deadline, [{"stdout", data} | output])

      {:stderr, %{ref: ^ref}, data} ->
        drain_exited_command(ref, deadline, [{"stderr", data} | output])
    after
      timeout -> {nil, Enum.reverse(output)}
    end
  end

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
  @spec reset_runtime_session(Conversation.t(), String.t()) :: :ok
  def reset_runtime_session(conv, conversation_id) do
    {:ok, _} = Conversations.update_conversation(conv, %{runtime_session_id: nil})

    publish_stage(conversation_id, "session", "done", %{
      event: "reset",
      reason: "fresh_sandbox",
      detail: "the previous runtime session lived on a sandbox that no longer exists"
    })

    :ok
  end

  # The provider's own sentence is the useful half, and it usually names the
  # replacement, so it is quoted rather than summarised. Fountain adds only
  # what the provider cannot know: which field holds the model, and that no
  # retry helps until that field changes.
  @spec model_unavailable_message(String.t() | nil, String.t()) :: String.t()
  def model_unavailable_message(requested, detail) do
    named = if is_binary(requested) and requested != "", do: " (#{requested})", else: ""

    "The provider refused this agent's model#{named}: #{String.trim(detail)} " <>
      "Change the agent's model, then send your prompt again. " <>
      "Every turn fails the same way until it changes."
  end

  defp publish_stage(conv_id, stage, status, meta) do
    Conversations.publish_stage(conv_id, stage, status, meta)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
