defmodule Fountain.Workers.ActorLaunchSweep do
  @moduledoc "Restore dispatch for requested launches in bounded pages; never replay acknowledged actors."
  use Oban.Worker, queue: :maintenance, max_attempts: 3
  import Ecto.Query
  alias Fountain.Repo
  alias Fountain.Conversations.{ActorLaunch, ActorLaunches}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    query = from l in ActorLaunch, where: l.state == "requested", order_by: l.id, limit: 100
    query = if args["after_id"], do: where(query, [l], l.id > ^args["after_id"]), else: query
    launches = Repo.all(query)

    Repo.transaction(fn ->
      if length(launches) == 100,
        do: %{"after_id" => List.last(launches).id} |> new() |> Oban.insert!()

      Enum.each(launches, &ActorLaunches.enqueue/1)
    end)

    :ok
  end
end
