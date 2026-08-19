defmodule FountainWeb.TeamScheduleJSON do
  @moduledoc false

  alias Fountain.Team.Schedule

  def index(%{schedules: schedules}), do: %{data: Enum.map(schedules, &data/1)}
  def show(%{schedule: schedule}), do: %{data: data(schedule)}

  @doc "One schedule, every column the page shows; the prompt is the tenant's and is returned in full."
  def data(%Schedule{} = s) do
    %{
      id: s.id,
      agent_id: s.agent_id,
      name: s.name,
      cron: s.cron,
      prompt: s.prompt,
      one_off: s.one_off,
      enabled: s.enabled,
      next_run_at: s.next_run_at,
      last_run_at: s.last_run_at,
      last_conversation_id: s.last_conversation_id,
      last_error: s.last_error,
      inserted_at: s.inserted_at,
      updated_at: s.updated_at
    }
  end
end
