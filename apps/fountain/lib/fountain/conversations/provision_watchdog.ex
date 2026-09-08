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

  alias Fountain.Conversations.{
    ActorClaim,
    ActorLaunch,
    Conversation,
    ExecutionGuard,
    Sandbox,
    SandboxOperation
  }

  def start(conversation_id, sandbox_id, default_ms, opts \\ []) do
    actor = self()
    configured = Application.get_env(:fountain, :provision_deadline_ms, default_ms)

    timeout =
      case Keyword.get(opts, :deadline_at) do
        %DateTime{} = deadline ->
          min(configured, max(DateTime.diff(deadline, DateTime.utc_now(), :millisecond), 0))

        nil ->
          configured
      end

    spawn(fn ->
      monitor = Process.monitor(actor)
      wait(actor, monitor, conversation_id, sandbox_id, timeout, Keyword.get(opts, :actor_claim))
    end)
  end

  defp wait(actor, monitor, conversation_id, sandbox_id, timeout, actor_claim) do
    receive do
      {:DOWN, ^monitor, :process, ^actor, _reason} -> :ok
    after
      timeout ->
        # Ownership: this watchdog was created by the actor for its original binding.
        case _unsafe_expire(conversation_id, sandbox_id, actor_claim) do
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
            wait(actor, monitor, conversation_id, sandbox_id, 1_000, actor_claim)
        end
    end
  end

  @doc "Commit a timeout only for the actor's still-owned, unfinished provisioning."
  def _unsafe_expire(conversation_id, sandbox_id, actor_claim \\ nil) do
    case Conversations.ActorStartups.expire(conversation_id, sandbox_id, actor_claim) do
      :legacy ->
        fail_pending(conversation_id, sandbox_id, "provision deadline exceeded", actor_claim)

      result ->
        result
    end
  end

  @doc "Record an actor-start failure only while its original machine is still pending."
  def _unsafe_fail_start(conversation_id, sandbox_id) do
    with {:ok, :expired} <- fail_pending(conversation_id, sandbox_id, "worker start failed", nil),
         do: {:ok, :failed}
  end

  @doc "Fail an unacknowledged launch's unused machine while retaining replacement retryability."
  def _unsafe_fail_launch(%ActorLaunch{} = launch) do
    with {:ok, :expired} <-
           fail_pending(
             launch.conversation_id,
             launch.sandbox_id,
             "worker start failed",
             {:launch, launch.id}
           ),
         do: {:ok, :failed}
  end

  defp fail_pending(conversation_id, sandbox_id, reason, actor_claim) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, :erlang.phash2(sandbox_id)])

      parent =
        Repo.one(from c in Conversation, where: c.id == ^conversation_id, lock: "FOR UPDATE")

      sandbox = Repo.one(from s in Sandbox, where: s.id == ^sandbox_id, lock: "FOR UPDATE")

      context = failure_context(parent, sandbox, actor_claim)

      cond do
        is_nil(parent) or is_nil(sandbox) or parent.sandbox_id != sandbox.id or
            parent.user_id != sandbox.user_id ->
          :stale

        context == :stale ->
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
            status = if context == :replacement, do: "idle", else: "failed"
            parent |> Conversation.changeset(%{status: status}) |> Repo.update!()
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

  defp failure_context(nil, _, _), do: :stale
  defp failure_context(_, nil, _), do: :stale

  defp failure_context(parent, sandbox, {:launch, id}) do
    launch =
      Repo.one(
        from l in ActorLaunch,
          where:
            l.id == ^id and l.conversation_id == ^parent.id and
              l.user_id == ^parent.user_id and l.sandbox_id == ^sandbox.id and
              l.runtime == ^parent.runtime and l.state == "requested",
          lock: "FOR UPDATE"
      )

    # An actor on the old binding does not own this unused replacement. Any
    # history on the new machine requires reconciliation rather than retirement.
    unused? =
      not Repo.exists?(from a in ActorClaim, where: a.sandbox_id == ^sandbox.id) and
        not Repo.exists?(from o in SandboxOperation, where: o.sandbox_id == ^sandbox.id)

    cond do
      is_nil(launch) or not unused? -> :stale
      launch.kind == "replace" -> :replacement
      true -> :actor
    end
  end

  defp failure_context(parent, sandbox, actor_claim) do
    if Conversations.ActorOwnership.current?(parent.id, sandbox.id, actor_claim),
      do: :actor,
      else: :stale
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
