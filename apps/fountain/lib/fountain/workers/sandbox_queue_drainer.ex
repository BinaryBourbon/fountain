defmodule Fountain.Workers.SandboxQueueDrainer do
  @moduledoc """
  Drains sandbox requests after capacity changes (#1033, ADR 0042).

  Scheduled jobs deduplicate per tenant. A poke during an available,
  executing or completed drain creates a follow-up job, so a later freed slot
  never waits for the five-minute backstop.

  `:scope` joins `:user_id` in the uniqueness key so a fan-out job and a
  tenant job are never mistaken for each other. Oban's own state groups are
  the only alternative to `:scheduled` here, and every one of them includes
  `executing` — a poke reporting capacity a running drain has already read
  past must create a follow-up, not vanish.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [keys: [:user_id, :scope], period: 30, states: :scheduled]

  alias Fountain.SandboxQueue

  require Logger

  @doc "Enqueue a drain for one tenant."
  def poke(user_id) when is_binary(user_id) do
    %{user_id: user_id} |> new(schedule_in: 1) |> Oban.insert()
    :ok
  end

  @doc """
  Enqueue one job that fans out to every tenant with active requests.

  One insert, not one per waiting tenant: the caller is
  `Conversations.update_sandbox/2`, the choke point every sandbox status
  change goes through, and the scan that finds those tenants belongs in a job
  rather than on the path that wrote the row.
  """
  def poke_all_later do
    %{scope: "all"} |> new(schedule_in: 1) |> Oban.insert()
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

  def perform(%Oban.Job{args: %{"scope" => "all"}}), do: poke_all()

  def perform(%Oban.Job{args: args}) when map_size(args) == 0, do: poke_all()
end
