defmodule Fountain.Conversations.BoundedTurn do
  @moduledoc """
  The conversation actor's side of a bounded turn: may it act, and how it stops.

  Extracted from `ConversationServer` because that module's line count only
  ratchets down (`conversation_server_size_test.exs`) and because none of this
  is actor logic — it is journal logic the actor happens to call. `finish_turn`
  is passed in rather than reached for: ending a turn writes through the actor's
  own transcript and owns its `current_turn`.

  The division of labour with `ExecutionGuard` is the point. `gate/1` is one
  unlocked read, because it runs per inbound message. `retire/3` takes the locks,
  because that is where a terminal outcome is actually decided.
  """
  require Logger

  alias Fountain.Conversations.{Connection, ExecutionGuard}

  @doc """
  May this actor handle its own next message?

  `:ok` for a journal that is still active, still bound to this connection and
  still inside its deadline; `:retire` for anything else, including no journal
  at all. Unlocked on purpose — see `ExecutionGuard._unsafe_actor_gate/3`.
  """
  @spec gate(map()) :: :ok | :retire
  def gate(%{turn_execution: %{id: id, connection_id: connection_id}}) do
    # ownership: this is the journal committed for this actor's current turn.
    ExecutionGuard._unsafe_actor_gate(id, connection_id)
  end

  @doc """
  Stop this actor's bounded turn and close its connection.

  `finish_turn` is the actor's own terminal writer, called as
  `finish_turn.(state, status, result, meta)`.
  """
  @spec retire(map(), (map(), String.t(), map(), map() -> map())) :: map()
  def retire(%{turn_execution: execution} = state, finish_turn) do
    # ownership: retirement targets this actor's immutable original journal.
    case ExecutionGuard._unsafe_complete(execution.id, "interrupted") do
      {:ok, decision} -> finish(state, decision, finish_turn)
      {:error, reason} -> abandon(state, reason, finish_turn)
    end
  end

  defp finish(state, decision, finish_turn) do
    if state.current_turn && decision.turn do
      finish_turn.(state, decision.turn.status, %{"outcome" => "retired"}, %{
        reason: "execution_retired"
      })
    else
      state
    end
    |> Connection.close_bounded()
  end

  # The journal deliberately carries no foreign key to its parent, so an
  # uncertain termination survives a deleted conversation
  # (20260907214000_add_turn_execution_guards.exs says why). That is exactly
  # when an actor is still draining its mailbox, so `:not_found` is reachable
  # here — and a hard match would take the actor down rather than let it put
  # itself away.
  #
  # The journal was also the thing that would have ended this turn, so with it
  # gone the actor has to. Failing locally is the honest outcome: the durable
  # record of what the remote command was doing is gone, so the turn cannot be
  # called complete. Clearing `turn_execution` drops this server back onto the
  # unbounded path for whatever is left in its mailbox, rather than re-entering
  # the gate against a row that is not there.
  defp abandon(state, reason, finish_turn) do
    Logger.warning(
      "conv #{state.conversation_id}: bounded retirement found no journal (#{inspect(reason)})"
    )

    # `turn_execution` stays set through this. `Connection.close_bounded/1`
    # returns untouched on `%{turn_execution: nil}`, so clearing it first made
    # the close below a no-op — and that close is the only thing on this path
    # that retires the transport, stops the peer and drops `current_command_ref`.
    # Leaving them set is worse than the crash this clause replaced: the next
    # prompt would take the unbounded path, find the connection alive and
    # resume onto a turn this function already failed.
    #
    # Both exits are covered. With a turn, `finish_turn` ends with its own
    # `if state.turn_execution, do: close_bounded_connection(state)` and does
    # the work, exactly as the success path above relies on. Without one, the
    # pipeline's own call does it. `close_bounded/1` clears the field either
    # way; nothing here needs it nil early.
    if state.current_turn do
      finish_turn.(state, "failed", %{"outcome" => "journal_missing"}, %{
        reason: "execution_journal_missing"
      })
    else
      state
    end
    |> Connection.close_bounded()
  end
end
