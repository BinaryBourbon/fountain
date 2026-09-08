defmodule Fountain.Workers.ActorLaunchDispatch do
  @moduledoc "Retry an explicit unacknowledged launch; only its actor claim can grant provisioning."
  use Oban.Worker,
    queue: :schedules,
    max_attempts: 20,
    unique: [
      period: :infinity,
      keys: [:launch_id],
      states: :incomplete
    ]

  @impl Oban.Worker
  def timeout(_job), do: 30_000

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"launch_id" => id, "conversation_id" => conversation_id, "user_id" => user_id}
      }),
      do: Fountain.Conversations.ActorLaunches.deliver(user_id, conversation_id, id)
end
