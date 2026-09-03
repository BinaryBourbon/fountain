defmodule Fountain.Workers.CreditRentCollector do
  @moduledoc "Daily shell over `Fountain.Credits.Rent.collect/1`."

  use Oban.Worker, queue: :credits, max_attempts: 3, unique: [period: 60]

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    counts = Fountain.Credits.Rent.collect()
    Fountain.Credits.Telemetry.emit_run("rent", counts)

    case counts do
      %{charged: 0, reminded: 0, released: 0} ->
        :ok

      c ->
        Logger.info(
          "credit rent: charged #{c.charged}, reminded #{c.reminded}, released #{c.released}"
        )
    end

    :ok
  end
end
