defmodule FountainWeb.ConversationJSON do
  @moduledoc false
  alias Fountain.Conversations.{Conversation, LogEvent, Sandbox, Turn}

  def index(%{conversations: convs}), do: %{data: Enum.map(convs, &data/1)}

  def show(%{conversation: conv, resumed: resumed?}),
    do: %{data: data(conv), meta: %{resumed: resumed?}}

  def show(%{conversation: conv}), do: %{data: data(conv)}
  def turns(%{turns: turns}), do: %{data: Enum.map(turns, &turn_data/1)}

  def events(%{events: events, has_more: has_more?, limit: limit} = assigns) do
    blocks_runtime = Map.get(assigns, :blocks_runtime)

    %{
      data: Enum.map(events, &(&1 |> log_event_data() |> put_blocks(&1, blocks_runtime))),
      meta: %{
        limit: limit,
        has_more: has_more?,
        # The id to pass back as `after`. nil on an empty page — there is
        # nothing to resume from, and echoing the request's cursor would
        # invite a client to loop on it.
        next_cursor: events |> List.last() |> event_id()
      }
    }
  end

  def tree(%{nodes: nodes}), do: %{data: Enum.map(nodes, &tree_node/1)}

  def data(%Conversation{} = c) do
    %{
      id: c.id,
      title: c.title,
      # The first turn's prompt, for clients that title an untitled
      # conversation the way the console's sidebar did. Only served where the
      # first turn was preloaded (index and show); null elsewhere and for a
      # conversation that has no turn yet.
      first_prompt: first_prompt(c),
      sandbox_id: c.sandbox_id,
      sandbox: sandbox_data(c.sandbox),
      agent_id: c.agent_id,
      vault_id: c.vault_id,
      environment_id: c.environment_id,
      permission_policy: c.permission_policy,
      runtime: c.runtime,
      # Derived, never stored — the same signal as on an agent (#702). A
      # protocol client asks before reopening a conversation, because a
      # legacy-runtime one has no ACP transcript to replay.
      acp: Fountain.Runtimes.ACP.enabled?(c.runtime),
      status: c.status,
      runtime_session_id: c.runtime_session_id,
      source: c.source,
      parent_conversation_id: c.parent_conversation_id,
      channel_id: c.channel_id,
      turn_count: c.turn_count,
      last_active_at: c.last_active_at,
      last_read_at: c.last_read_at,
      # Served rather than left to each client: the rule has three cases and
      # the nil ones are easy to get backwards.
      unread: Fountain.Conversations.unread?(c),
      # Running sums of the turns' usage (#827); zeros until a turn reports one.
      usage_total: %{input: c.usage_input_tokens || 0, output: c.usage_output_tokens || 0},
      inserted_at: c.inserted_at,
      updated_at: c.updated_at
    }
  end

  defp first_prompt(%Conversation{turns: [%Turn{turn_number: 1, prompt: prompt} | _]}), do: prompt
  defp first_prompt(_), do: nil

  defp tree_node(%{id: id, source: source, status: status, parent_id: parent_id}) do
    %{id: id, source: source, status: status, parent_id: parent_id}
  end

  defp sandbox_data(%Sandbox{} = s) do
    %{
      id: s.id,
      sprite_name: s.sprite_name,
      status: s.status,
      provider: s.provider,
      # The sandbox's own HTTP endpoint, for providers that give it one. Read
      # from the row rather than the provider so listing conversations stays a
      # single query; null means the provider has no such concept (or the
      # sandbox predates the field).
      url: s.provider_meta["public_url"],
      # Where a runner-backed sandbox lives (#834): the machine and the
      # directory, so a client says "on mac-mini · ~/…" without parsing the
      # name. Null for hosted providers.
      runner: runner_data(Fountain.Runners.for_sandbox(s))
    }
  end

  defp sandbox_data(_), do: nil

  defp runner_data(nil), do: nil

  defp runner_data(%{runner: runner, online: online, path: path}) do
    %{
      id: runner && runner.id,
      name: runner && runner.name,
      hostname: runner && runner.hostname,
      online: online,
      path: path
    }
  end

  # Field-for-field the SSE payload, plus `id` (the pagination cursor and the
  # SSE `Last-Event-ID`) and `duration_ms`, which stage events carry and the
  # UI's timeline reads.
  defp log_event_data(%LogEvent{} = e) do
    %{
      id: e.id,
      kind: e.kind,
      stream: e.stream,
      data: e.data,
      stage: e.stage,
      state: e.state,
      duration_ms: e.duration_ms,
      turn_id: e.turn_id,
      ts: e.inserted_at
    }
  end

  @doc """
  Add `blocks` — the event's data parsed into the blocks a transcript renders
  — to an event's JSON when a runtime is given; unchanged when nil. Output
  events only: a stage event has no dialect to parse, and gets `[]`.
  """
  def put_blocks(json, _event, nil), do: json

  def put_blocks(json, %LogEvent{kind: "output"} = ev, runtime) do
    blocks =
      ev
      |> Fountain.Conversations.Blocks.for_event(runtime)
      |> Enum.map(&Fountain.Conversations.Blocks.to_json/1)

    Map.put(json, :blocks, blocks)
  end

  def put_blocks(json, _event, _runtime), do: Map.put(json, :blocks, [])

  defp event_id(%LogEvent{id: id}), do: id
  defp event_id(nil), do: nil

  defp turn_data(%Turn{} = t) do
    %{
      id: t.id,
      turn_number: t.turn_number,
      prompt: t.prompt,
      status: t.status,
      exit_code: t.exit_code,
      started_at: t.started_at,
      ended_at: t.ended_at,
      inserted_at: t.inserted_at,
      image_count: length(t.images || []),
      # The end-of-turn figure as the runtime reported it (#827); null when
      # it reported none or the turn predates the column.
      usage: t.usage && usage_data(t.usage)
    }
  end

  @doc "A turn's stored usage as the wire object: `input`, `output`, and the cache fields when present."
  def usage_data(%{} = u) do
    %{input: u["input"] || 0, output: u["output"] || 0}
    |> put_present(:cache_read, u["cache_read"])
    |> put_present(:cache_write, u["cache_write"])
  end

  defp put_present(map, _k, nil), do: map
  defp put_present(map, k, v), do: Map.put(map, k, v)
end
