defmodule Fountain.Conversations.ProvisionContext do
  @moduledoc """
  Bind provisioning output and outcomes to the original tenant and machine.

  Machine and parent locks serialize publication with holder transfers. Failure,
  queued prompt refusal and session revocation commit before provider cleanup.
  Actor claims also fence callbacks from an earlier process incarnation.
  """
  import Ecto.Query
  require Logger

  alias Fountain.{Conversations, Repo}
  alias Fountain.Conversations.{Conversation, ExecutionGuard, PromptDelivery, Sandbox}

  @enforce_keys [:user_id, :conversation_id, :sandbox_id]
  defstruct [:user_id, :conversation_id, :sandbox_id, :phase, :actor_claim]

  @type t :: %__MODULE__{
          user_id: Ecto.UUID.t(),
          conversation_id: Ecto.UUID.t(),
          sandbox_id: Ecto.UUID.t(),
          phase: :fresh | :reattach,
          actor_claim: Ecto.UUID.t() | nil
        }
  @type target :: t() | String.t()

  def new(conversation, sandbox, actor_claim \\ nil),
    do: %__MODULE__{
      user_id: conversation.user_id,
      conversation_id: conversation.id,
      sandbox_id: sandbox.id,
      actor_claim: actor_claim,
      phase: if(sandbox.status in ~w(pending starting), do: :fresh, else: :reattach)
    }

  def id(%__MODULE__{conversation_id: id}), do: id
  def id(id) when is_binary(id), do: id

  def stage(context, stage, status, meta \\ %{})

  def stage(%__MODULE__{} = context, stage, status, meta) do
    nested? = Repo.in_transaction?()

    case owned(context, fn parent, _sandbox ->
           record_stage!(parent, context, stage, status, meta)
         end) do
      {:ok, event} ->
        # ownership: owned/2 checked both tenant IDs and the original binding under locks.
        if not nested?, do: Conversations._unsafe_notify_stage(event)
        event

      {:error, :ownership_changed} ->
        nil

      {:error, reason} ->
        raise "provision stage was not persisted: #{inspect(reason)}"
    end
  end

  def stage(id, stage, status, meta) when is_binary(id),
    do: Conversations.publish_stage(id, stage, status, meta)

  def output(context, stage, data) when is_binary(data) and data != "" do
    attrs = %{kind: "output", stream: "stdout", stage: stage, data: data}

    result =
      case context do
        %__MODULE__{} ->
          owned(context, fn parent, _ ->
            Conversations.log!(Map.put(attrs, :conversation_id, parent.id))
          end)

        id when is_binary(id) ->
          {:ok, Conversations.log!(Map.put(attrs, :conversation_id, id))}
      end

    case result do
      {:ok, event} ->
        if not Repo.in_transaction?(),
          do:
            Phoenix.PubSub.broadcast(Fountain.PubSub, "conv:#{id(context)}", {:log_event, event})

        event

      {:error, :ownership_changed} ->
        nil

      {:error, reason} ->
        raise "provision output was not persisted: #{inspect(reason)}"
    end
  end

  def output(_, _, _), do: nil

  @doc "Mint the native broker session and its stages under the original binding locks."
  def prepare_broker(%__MODULE__{} = context, brokered, bindings, opts) do
    # The broker's only backend is native: minting writes local encrypted rows,
    # with no provider I/O. A failed stage enqueue must roll back the token too.
    result =
      owned(context, fn parent, _ ->
        record_stage!(parent, context, "broker", "started", %{
          keys: brokered |> Map.keys() |> Enum.sort()
        })

        opts = Keyword.put(opts, :user_id, parent.user_id)

        case Fountain.Broker.prepare(parent.id, brokered, bindings, opts) do
          {:ok, session} = ok ->
            record_stage!(parent, context, "broker", "done", %{
              vault: session.vault,
              expires_at: session.expires_at
            })

            ok

          {:error, reason} = error ->
            record_stage!(parent, context, "broker", "failed", %{reason: inspect(reason)})
            error
        end
      end)

    case result do
      {:ok, outcome} -> outcome
      {:error, _} = error -> error
    end
  end

  @doc "Fail owned provisioning and revoke only its saved session, with no provider calls."
  def fail(%__MODULE__{} = context, reason, session \\ nil) do
    nested? = Repo.in_transaction?()

    result =
      owned(
        context,
        fn parent, sandbox ->
          retired? = sandbox.status in ~w(terminated failed)
          cleanup? = context.phase == :fresh and not retired?

          failed =
            if context.phase == :fresh do
              # ownership: owned/3 holds the original machine and tenant-checked parent locks.
              if ExecutionGuard._unsafe_sandbox_open?(sandbox.id) or
                   Conversations._unsafe_running_turns_elsewhere(sandbox.id, nil) > 0,
                 do: Repo.rollback(:active_execution)

              if retired? do
                sandbox
              else
                if sandbox.status not in ~w(pending starting),
                  do: Repo.rollback(:provision_settled)

                {:ok, failed} = Conversations.update_sandbox(sandbox, %{status: "failed"})
                failed
              end
            else
              if Repo.exists?(
                   from t in Conversations.Turn,
                     where: t.conversation_id == ^parent.id and t.status == "running"
                 ),
                 do: Repo.rollback(:active_execution)

              sandbox
            end

          parent |> Conversation.changeset(%{status: "failed"}) |> Repo.update!()
          event = record_stage!(parent, context, "provision", "failed", reason)

          if receipt = PromptDelivery.queued(parent.user_id, parent.id) do
            case PromptDelivery.refuse(
                   parent.user_id,
                   parent.id,
                   receipt.id,
                   "provisioning_failed",
                   sandbox_id: sandbox.id
                 ) do
              {:ok, _} -> :ok
              {:error, cause} -> Repo.rollback(cause)
            end
          end

          :ok = Conversations.Egress.release_session(parent.user_id, parent.id, session)
          %{sandbox: failed, cleanup?: cleanup?, event: event}
        end,
        allow_retired: true
      )

    case result do
      {:ok, %{event: event} = outcome} ->
        if not nested?, do: notify_committed_stage(event)
        {:ok, Map.delete(outcome, :event)}

      error ->
        error
    end
  rescue
    error ->
      Logger.warning("provision failure decision unavailable: #{inspect(error.__struct__)}")
      {:error, :decision_unavailable}
  end

  defp owned(context, writer, opts \\ []) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
        4316,
        :erlang.phash2(context.sandbox_id)
      ])

      parent =
        Repo.one(
          from c in Conversation, where: c.id == ^context.conversation_id, lock: "FOR UPDATE"
        )

      sandbox =
        Repo.one(from s in Sandbox, where: s.id == ^context.sandbox_id, lock: "FOR UPDATE")

      unless parent && sandbox && parent.user_id == context.user_id &&
               sandbox.user_id == context.user_id && parent.sandbox_id == sandbox.id &&
               parent.status not in ~w(terminated failed) &&
               (sandbox.status not in ~w(terminated failed) or
                  (Keyword.get(opts, :allow_retired, false) and context.phase == :fresh and
                     parent.status == "pending")),
             do: Repo.rollback(:ownership_changed)

      unless Conversations.ActorOwnership.current?(parent.id, sandbox.id, context.actor_claim),
        do: Repo.rollback(:ownership_changed)

      writer.(parent, sandbox)
    end)
  end

  defp notify_committed_stage(event) do
    # ownership: event was committed by owned/3 after both tenant and binding checks.
    Conversations._unsafe_notify_stage(event)
  rescue
    error ->
      # The durable job will retry notification; cleanup keeps its committed grant.
      Logger.warning("provision stage notification unavailable: #{inspect(error.__struct__)}")
      :ok
  end

  defp record_stage!(parent, context, stage, status, meta) do
    event =
      Conversations.log!(%{
        conversation_id: parent.id,
        kind: "stage",
        stage: stage,
        state: status,
        data: Jason.encode!(Map.put(meta, :sandbox_id, context.sandbox_id))
      })

    Fountain.Webhooks.dispatch_stage!(event)

    %{"event_id" => event.id, "conversation_id" => parent.id, "user_id" => parent.user_id}
    |> Fountain.Workers.TurnDeadlineNotification.new()
    |> Oban.insert!()

    event
  end
end
