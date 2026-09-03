defmodule Fountain.Workers.SandboxQueueDrainer do
  @moduledoc """
  Drains sandbox requests after capacity changes (#1033, ADR 0042).

  Scheduled jobs deduplicate per tenant. A poke during an available,
  executing or completed drain creates a follow-up job, so a later freed slot
  never waits for the five-minute backstop.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [keys: [:user_id], period: 30, states: :scheduled]

  alias Fountain.SandboxQueue

  require Logger

  @doc "Enqueue a drain for one tenant."
  def poke(user_id) when is_binary(user_id) do
    %{user_id: user_id} |> new(schedule_in: 1) |> Oban.insert()
    :ok
  end

  @doc "Enqueue one drain for every tenant with active requests."
  def poke_all do
    SandboxQueue.user_ids_with_active_requests()
    |> Enum.each(&poke/1)

    :ok
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    %{started: started, failed: failed, expired: expired} = SandboxQueue.drain(user_id)

    if started + failed + expired > 0 do
      Logger.info(
        "sandbox queue: user #{user_id} started #{started}, failed #{failed}, expired #{expired}"
      )
    end

    :ok
  end

  def perform(%Oban.Job{args: args}) when map_size(args) == 0, do: poke_all()
end
