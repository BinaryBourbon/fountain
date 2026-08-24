defmodule FountainWeb.SandboxJSON do
  @moduledoc false
  alias Fountain.Conversations.{Conversation, Sandbox}
  alias FountainWeb.ConversationJSON

  def index(%{sandboxes: sandboxes}), do: %{data: Enum.map(sandboxes, &data/1)}
  def show(%{sandbox: sandbox}), do: %{data: data(sandbox)}

  # The same shape a conversation embeds, plus the machine's own history and
  # the conversations on it.
  def data(%Sandbox{} = s) do
    s
    |> ConversationJSON.sandbox_data()
    |> Map.merge(%{
      inserted_at: s.inserted_at,
      last_resumed_at: s.last_resumed_at,
      conversations: Enum.map(s.conversations || [], &conversation_data/1)
    })
  end

  defp conversation_data(%Conversation{} = c) do
    %{
      id: c.id,
      status: c.status,
      title: c.title,
      runtime: c.runtime,
      # `running` is set for exactly the span of a turn (kick_turn → finish),
      # so it is the honest "is this one using the machine right now".
      mid_turn: c.status == "running",
      inserted_at: c.inserted_at
    }
  end
end
