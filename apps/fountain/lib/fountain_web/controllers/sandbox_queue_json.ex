defmodule FountainWeb.SandboxQueueJSON do
  @moduledoc false
  alias Fountain.SandboxQueue.Request

  def index(%{requests: requests}) do
    # One query's worth of positions: queued requests listed oldest-first ARE
    # position order, so enumerate rather than re-counting per row.
    %{
      data:
        requests
        |> Enum.with_index(1)
        |> Enum.map(fn {request, position} -> data(request, position) end)
    }
  end

  def show(%{request: request, position: position}), do: %{data: data(request, position)}

  def data(%Request{} = r, position) do
    %{
      id: r.id,
      agent_id: r.agent_id,
      kind: r.kind,
      status: r.status,
      source: r.source,
      conversation_id: r.conversation_id,
      error: r.error,
      position: position,
      inserted_at: r.inserted_at
    }
  end
end
