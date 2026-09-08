defmodule Fountain.Conversations.DeadlineEvents do
  @moduledoc """
  Records deadline outcomes in the same transaction as the failed turn.

  Webhook jobs and a retryable local notification share that transaction. The
  persisted log id is the deduplication identity for both streams and callbacks.
  Notifications may repeat; the terminal log event is inserted only once under
  the execution journal lock. No actor or provider call participates.
  """

  alias Fountain.{Conversations, Repo, Webhooks}
  alias Fountain.Conversations.Conversation
  alias Fountain.Workers.TurnDeadlineNotification

  @doc "System journal writer; requires its parent, execution and turn locks."
  def _unsafe_record!(execution, turn) do
    # ownership: recheck the journal's original tenant on the locked parent.
    owner = Repo.get_by(Conversation, id: execution.conversation_id, user_id: execution.user_id)

    if owner && turn.conversation_id == owner.id do
      event =
        Conversations.log!(%{
          conversation_id: owner.id,
          turn_id: turn.id,
          kind: "stage",
          stage: "turn",
          state: "failed",
          data:
            Jason.encode!(%{
              turn_id: turn.id,
              turn_number: turn.turn_number,
              limit_reason: "wall_time_limit",
              stop_reason: "wall_time_limit"
            })
        })

      Webhooks.dispatch_stage!(event)

      %{"event_id" => event.id, "conversation_id" => owner.id, "user_id" => owner.user_id}
      |> TurnDeadlineNotification.new()
      |> Oban.insert!()

      event.id
    end
  end
end
