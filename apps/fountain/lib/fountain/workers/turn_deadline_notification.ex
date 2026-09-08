defmodule Fountain.Workers.TurnDeadlineNotification do
  @moduledoc """
  Delivers a persisted deadline stage independently of the conversation actor.

  Webhook jobs were already committed with the event. This job only notifies
  local subscribers and telemetry; retries reuse the same event id. Deleted
  transcripts or changed ownership suppress notification without touching the
  remote execution journal.
  """
  use Oban.Worker, queue: :webhooks, max_attempts: 20

  import Ecto.Query

  alias Fountain.{Conversations, Repo}
  alias Fountain.Conversations.{Conversation, LogEvent}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"event_id" => id, "conversation_id" => conv_id, "user_id" => user_id}
      }) do
    event =
      Repo.one(
        from e in LogEvent,
          join: c in Conversation,
          on: e.conversation_id == c.id,
          where: e.id == ^id and c.id == ^conv_id and c.user_id == ^user_id
      )

    if event do
      # ownership: the event query above scopes its conversation to the saved tenant.
      Conversations._unsafe_notify_stage(event)
    end

    :ok
  end
end
