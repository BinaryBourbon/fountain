defmodule FountainWeb.SandboxQueueJSON do
  @moduledoc false
  alias Fountain.SandboxQueue.Request

  @doc """
  A tenant's waiting requests. The list is already in FIFO order, so position
  is the index rather than a count query per row.
  """
  def index(%{requests: requests}) do
    %{
      data:
        requests
        |> Enum.with_index(1)
        |> Enum.map(fn {request, position} -> data(request, position) end)
    }
  end

  def show(%{request: request, position: position}), do: %{data: data(request, position)}

  def data(%Request{} = request, position) do
    %{
      id: request.id,
      agent_id: request.agent_id,
      kind: request.kind,
      status: request.status,
      source: request.source,
      conversation_id: request.conversation_id,
      error: request.error,
      position: position,
      inserted_at: request.inserted_at
    }
  end
end
