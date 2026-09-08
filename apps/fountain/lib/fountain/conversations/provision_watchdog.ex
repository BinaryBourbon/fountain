defmodule Fountain.Conversations.ProvisionWatchdog do
  @moduledoc """
  Bound a blocked provisioning actor without failing its replacement.

  The process watches its original PID. Its timeout decision locks the original
  machine and current parent before updating rows and recording a stage. Provider
  uncertainty retains its journal and capacity. Actor termination follows commit.
  """
  import Ecto.Query
  require Logger

  alias Fountain.{Conversations, Repo}
  alias Fountain.Conversations.{Conversation, ExecutionGuard, Sandbox}

  def start(conversation_id, sandbox_id, default_ms) do
    actor = self()
    timeout = Application.get_env(:fountain, :provision_deadline_ms, default_ms)

    spawn(fn ->
      monitor = Process.monitor(actor)
      wait(actor, monitor, conversation_id, sandbox_id, timeout)
    end)
  end

  defp wait(actor, monitor, conversation_id, sandbox_id, timeout) do
    receive do
      {:DOWN, ^monitor, :process, ^actor, _reason} -> :ok
    after
      timeout ->
        # Ownership: this watchdog was created by the actor for its original binding.
        case _unsafe_expire(conversation_id, sandbox_id) do
          {:ok, :expired} ->
            stop(actor)

            :telemetry.execute([:fountain, :provision, :deadline_exceeded], %{count: 1}, %{
              conversation_id: conversation_id
            })

          {:ok, :stale} ->
            stop(actor)

          {:ok, :settled} ->
            :ok

          {:error, _} ->
            # An unavailable DB cannot authorize a kill followed by a restart
            # against an unchanged pending row. Retry the same decision; do not
            # create another watchdog or restart the provisioning actor.
            Logger.warning("provision deadline decision unavailable; retrying")
            wait(actor, monitor, conversation_id, sandbox_id, 1_000)
        end
    end
  end

  @doc "Commit a timeout only for the actor's still-owned, unfinished provisioning."
  def _unsafe_expire(conversation_id, sandbox_id),
    do: fail_pending(conversation_id, sandbox_id, "provision deadline exceeded")

  @doc "Record an actor-start failure only while its original machine is still pending."
  def _unsafe_fail_start(conversation_id, sandbox_id) do
    with {:ok, :expired} <- fail_pending(conversation_id, sandbox_id, "worker start failed"),
         do: {:ok, :failed}
  end

  defp fail_pending(conversation_id, sandbox_id, reason) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, :erlang.phash2(sandbox_id)])

      parent =
        Repo.one(from c in Conversation, where: c.id == ^conversation_id, lock: "FOR UPDATE")

      sandbox = Repo.one(from s in Sandbox, where: s.id == ^sandbox_id, lock: "FOR UPDATE")

      cond do
        is_nil(parent) or is_nil(sandbox) or parent.sandbox_id != sandbox.id or
            parent.user_id != sandbox.user_id ->
          :stale

        sandbox.status not in ~w(pending starting) ->
          :settled

        # Ownership: the locked parent and original machine still agree on their tenant.
        ExecutionGuard._unsafe_sandbox_open?(sandbox.id) or
            Conversations._unsafe_running_turns_elsewhere(sandbox.id, nil) > 0 ->
          :settled

        true ->
          {:ok, _} = Conversations.update_sandbox(sandbox, %{status: "failed"})

          if parent.status not in ~w(terminated failed) do
            parent |> Conversation.changeset(%{status: "failed"}) |> Repo.update!()
            record_failure(parent, sandbox.id, reason)
          end

          delivery = Fountain.Conversations.PromptDelivery

          if receipt = delivery.queued(parent.user_id, parent.id) do
            case delivery.refuse(parent.user_id, parent.id, receipt.id, "provisioning_failed",
                   sandbox_id: sandbox.id
                 ) do
              {:ok, _} -> :ok
              {:error, reason} -> Repo.rollback(reason)
            end
          end

          :expired
      end
    end)
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, :database_unavailable}
  end

  defp record_failure(parent, sandbox_id, reason) do
    event =
      Conversations.log!(%{
        conversation_id: parent.id,
        kind: "stage",
        stage: "provision",
        state: "failed",
        data: Jason.encode!(%{reason: reason, sandbox_id: sandbox_id})
      })

    Fountain.Webhooks.dispatch_stage!(event)

    %{"event_id" => event.id, "conversation_id" => parent.id, "user_id" => parent.user_id}
    |> Fountain.Workers.TurnDeadlineNotification.new()
    |> Oban.insert!()
  end

  defp stop(actor) do
    case Horde.DynamicSupervisor.terminate_child(Fountain.ConversationSupervisor, actor) do
      :ok -> :ok
      {:error, _} -> Process.exit(actor, :kill)
    end
  end
end
