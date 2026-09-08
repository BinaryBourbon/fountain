defmodule Fountain.Conversations.PromptDeliveryActor do
  @moduledoc """
  Deliver a saved prompt through the actor's existing turn runner.

  Notifications contain only a receipt ID. Startup rediscovers queued work;
  duplicate notifications cannot create another turn or provider submission.
  Prompt submission, creation, attach and wake use receipts. Durable dispatch
  retries ID notifications.
  """
  alias Fountain.{Agents, Conversations}
  alias Fountain.Conversations.{Connection, PromptDelivery}

  def schedule(state) do
    if receipt = PromptDelivery.queued(state.user_id, state.conversation_id),
      do: Conversations.ConversationServer.queue_prompt_receipt(self(), receipt.id)

    :ok
  end

  def deliver(state, receipt_id, close_autonomous, run) do
    case PromptDelivery.payload(state.user_id, state.conversation_id, receipt_id) do
      {:ok, %{receipt: %{state: "queued"}, images: images}} ->
        if Connection.user_turn_running?(state.current_turn) do
          refuse(state, receipt_id)
          {:noreply, state}
        else
          state = close_autonomous.(state)

          # Ownership: payload was fetched for this actor's tenant and parent;
          # activation checks the original machine again under its admission locks.
          case Conversations._unsafe_activate_prompt_receipt(
                 state.conversation_id,
                 receipt_id,
                 state.sandbox_id,
                 inference_source: state.inference_source
               ) do
            {:ok, turn} ->
              case Conversations.get_conversation(state.conversation_id, state.user_id) do
                nil ->
                  {:stop, :normal, state}

                conv ->
                  agent = conv.agent_id && Agents.get_agent(conv.agent_id, state.user_id)
                  {:noreply, run.(state, conv, turn, agent, images)}
              end

            {:error, reason} when reason in [:ownership_changed, :delivery_claimed, :not_found] ->
              {:noreply, state}

            {:error, :delivery_expired} ->
              PromptDelivery.refuse(
                state.user_id,
                state.conversation_id,
                receipt_id,
                "delivery_expired",
                sandbox_id: state.sandbox_id
              )

              {:noreply, state}

            {:error, _} ->
              refuse(state, receipt_id)
              {:noreply, state}
          end
        end

      {:ok, _claimed_or_refused} ->
        {:noreply, state}

      {:error, :delivery_unavailable} ->
        PromptDelivery.refuse(
          state.user_id,
          state.conversation_id,
          receipt_id,
          "delivery_unavailable",
          sandbox_id: state.sandbox_id
        )

        {:noreply, state}
    end
  end

  defp refuse(state, receipt_id),
    do:
      PromptDelivery.refuse(state.user_id, state.conversation_id, receipt_id, "admission_refused",
        sandbox_id: state.sandbox_id
      )
end
