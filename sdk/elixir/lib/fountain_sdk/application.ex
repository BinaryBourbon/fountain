defmodule FountainSdk.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [{Finch, name: FountainSdk.Finch, pools: %{default: [protocols: [:http1]]}}],
      strategy: :one_for_one,
      name: FountainSdk.Supervisor
    )
  end
end
