defmodule Fountain.Workers.SandboxQueueDrainer do
  @moduledoc """
  Drains one tenant's sandbox queue when a slot frees (#1033, ADR 0030).

  Poked from `Conversations.update_sandbox/2` on every slot-freeing
  transition — terminate, fail, suspend, and the reaper's stuck-row release
  all pass through that choke point, so no site can forget. Unique per user
  for a short window: a reaper pass releasing five rows for one tenant is one
  drain, not five.

  The five-minute cron firing (empty args) is the backstop, not the trigger:
  it expires overdue requests and re-pokes every tenant with anything queued,
  so a lost poke costs minutes, never a stall until something unrelated
  moves.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [keys: [:user_id], period: 30]

  alias Fountain.SandboxQueue

  require Logger

  @doc "Enqueue a drain for one tenant. Best-effort: the cron sweep is the backstop."
  def poke(user_id) when is_binary(user_id) do
    %{user_id: user_id} |> new() |> Oban.insert()
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

  # The cron firing: sweep every tenant with anything queued.
  def perform(%Oban.Job{args: args}) when map_size(args) == 0 do
    SandboxQueue.user_ids_with_queued()
    |> Enum.each(&poke/1)

    :ok
  end
end
