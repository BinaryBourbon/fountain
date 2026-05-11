defmodule FountainWeb.ConversationJSON do
  @moduledoc false
  alias Fountain.Conversations.{Conversation, Sandbox, Turn}

  def index(%{conversations: convs}), do: %{data: Enum.map(convs, &data/1)}
  def show(%{conversation: conv}), do: %{data: data(conv)}
  def turns(%{turns: turns}), do: %{data: Enum.map(turns, &turn_data/1)}

  def data(%Conversation{} = c) do
    %{
      id: c.id,
      sandbox_id: c.sandbox_id,
      sandbox: sandbox_data(c.sandbox),
      agent_id: c.agent_id,
      vault_id: c.vault_id,
      runtime: c.runtime,
      status: c.status,
      runtime_session_id: c.runtime_session_id,
      source: c.source,
      parent_conversation_id: c.parent_conversation_id,
      inserted_at: c.inserted_at,
      updated_at: c.updated_at
    }
  end

  defp sandbox_data(%Sandbox{} = s) do
    %{
      id: s.id,
      sprite_name: s.sprite_name,
      status: s.status
    }
  end

  defp sandbox_data(_), do: nil

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
