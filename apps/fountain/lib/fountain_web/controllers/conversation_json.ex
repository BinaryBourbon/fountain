defmodule FountainWeb.ConversationJSON do
  @moduledoc false
  alias Fountain.Conversations.{Conversation, LogEvent, Sandbox, Turn}

  def index(%{conversations: convs}), do: %{data: Enum.map(convs, &data/1)}
  def show(%{conversation: conv}), do: %{data: data(conv)}
  def turns(%{turns: turns}), do: %{data: Enum.map(turns, &turn_data/1)}

  def events(%{events: events, has_more: has_more?, limit: limit}) do
    %{
      data: Enum.map(events, &log_event_data/1),
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
      sandbox_id: c.sandbox_id,
      sandbox: sandbox_data(c.sandbox),
      agent_id: c.agent_id,
      vault_id: c.vault_id,
      runtime: c.runtime,
      status: c.status,
      runtime_session_id: c.runtime_session_id,
      source: c.source,
      parent_conversation_id: c.parent_conversation_id,
      turn_count: c.turn_count,
      last_active_at: c.last_active_at,
      last_read_at: c.last_read_at,
      # Served rather than left to each client: the rule has three cases and
      # the nil ones are easy to get backwards.
      unread: Fountain.Conversations.unread?(c),
      inserted_at: c.inserted_at,
      updated_at: c.updated_at
    }
  end

  defp tree_node(%{id: id, source: source, status: status, parent_id: parent_id}) do
    %{id: id, source: source, status: status, parent_id: parent_id}
  end

  defp sandbox_data(%Sandbox{} = s) do
    %{
      id: s.id,
      sprite_name: s.sprite_name,
      status: s.status
    }
  end

  defp sandbox_data(_), do: nil

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
      image_count: length(t.images || [])
    }
  end
end
