defmodule Fountain.Conversations.MachineEvents do
  @moduledoc false

  import Ecto.Query

  alias Fountain.Conversations
  alias Fountain.Conversations.Output
  alias Fountain.Repo

  # A reset fence admitted no running turn, and forbids another on that
  # machine. A notification must never interrupt a later turn. The conditional
  # write also rechecks the persisted binding if a wake races this mailbox.
  def reset(
        %{sandbox_id: sandbox_id, current_turn: nil, turn_execution: nil} = state,
        sandbox_id,
        reason,
        by,
        message,
        drop
      ) do
    {matched, _} =
      Repo.update_all(
        from(c in Conversations.Conversation,
          join: s in Conversations.Sandbox,
          on: s.id == c.sandbox_id,
          where:
            c.id == ^state.conversation_id and c.user_id == ^state.user_id and
              c.sandbox_id == ^sandbox_id and c.status in ["idle", "running"] and
              s.status == "terminated" and not is_nil(s.reset_requested_at)
        ),
        set: [status: "idle", updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

    if matched == 1 do
      Phoenix.PubSub.broadcast(
        Fountain.PubSub,
        "sidebar:#{state.user_id}",
        {:sidebar_update, state.user_id}
      )

      # No provider/connection operation occurs while the row is locked.
      state = drop.(state, "reset")

      Output.publish_stage(state.conversation_id, "sandbox", "done", %{
        event: "reset",
        reason: reason,
        by: by,
        message: message
      })

      {:stop, :normal, %{state | handle: nil}}
    else
      {:noreply, state}
    end
  end

  def reset(state, _sandbox_id, _reason, _by, _message, _drop), do: {:noreply, state}

  # The server supplies its connection/turn teardown callbacks. Keeping the
  # transcript handling here leaves the actor's mailbox clauses small.
  def gone(state, {event, reason, message}, interrupt, drop) do
    state = if state.current_turn, do: interrupt.(state), else: state
    state = drop.(state, event)

    # ownership: the calling ConversationServer established this holder at init.
    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
    if conv.status == "running", do: Conversations.update_conversation(conv, %{status: "idle"})

    Output.publish_stage(state.conversation_id, "sandbox", "done", %{
      event: event,
      reason: reason,
      by: "another_conversation",
      message: message
    })

    {:stop, :normal, %{state | handle: nil}}
  end
end
