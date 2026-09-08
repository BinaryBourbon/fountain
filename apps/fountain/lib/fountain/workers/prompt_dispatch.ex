defmodule Fountain.Workers.PromptDispatch do
  @moduledoc """
  Retry receipt notifications independently of the submitting process.

  A cast is not an acknowledgement. Keep the job until the receipt is claimed,
  refused or past its saved deadline. An accepted prompt also has a durable
  wake request: caller and job compete for its one invocation. Never infer
  provider absence from a registry miss or replay an interrupted wake or a
  claimed turn. Existing lifecycle policy owns provider decisions.
  """
  use Oban.Worker, queue: :schedules, max_attempts: 20

  alias Fountain.Conversations.{PromptDelivery, PromptReceipt, PromptWake}

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"receipt_id" => id, "conversation_id" => conversation_id, "user_id" => user_id}
      }) do
    case PromptDelivery.fetch(user_id, conversation_id, id) do
      %PromptReceipt{state: "queued"} = receipt -> dispatch(receipt)
      _ -> :ok
    end
  end

  defp dispatch(receipt) do
    if PromptDelivery.expired?(receipt) do
      case PromptDelivery.refuse(
             receipt.user_id,
             receipt.conversation_id,
             receipt.id,
             "delivery_expired"
           ) do
        {:ok, _} -> :ok
        {:error, reason} when reason in [:delivery_claimed, :not_found] -> :ok
        {:error, :delivery_not_expired} -> {:snooze, 15}
        {:error, _} = error -> error
      end
    else
      PromptWake.deliver(receipt)

      {:snooze, 15}
    end
  end
end
