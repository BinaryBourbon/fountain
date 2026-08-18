defmodule Fountain.Workers.TeamScheduler do
  @moduledoc """
  The minute tick for team schedules (`Fountain.Team.Schedules`).

  Runs from Oban's Cron plugin every minute — once across the cluster, since
  the plugin elects a leader — claims what is due and enqueues one
  `Fountain.Workers.TeamScheduleRun` per claim. The claim advances
  `next_run_at` first, so a tick that dies after claiming loses at most the
  runs it had claimed but not enqueued; it never fires one twice. The runs
  are separate jobs so one slow or failing schedule cannot hold the others,
  and so a busy teammate can be retried with a snooze.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger

  alias Fountain.Team.Schedules
  alias Fountain.Workers.TeamScheduleRun

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    now = job.scheduled_at || DateTime.utc_now()
    fired_at = now |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    due = Schedules._unsafe_claim_due(now)

    Enum.each(due, fn schedule ->
      %{"schedule_id" => schedule.id, "fired_at" => fired_at}
      |> TeamScheduleRun.new()
      |> Oban.insert()
    end)

    if due != [], do: Logger.info("team_scheduler: fired #{length(due)} schedule(s)")
    :ok
  end
end
