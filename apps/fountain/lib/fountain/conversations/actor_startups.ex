defmodule Fountain.Conversations.ActorStartups do
  @moduledoc """
  Bound reconnect setup independently of the physical machine's ready status.

  Completion and expiry arbitrate under the actor's original binding locks.
  Expiry revokes access and fences the incarnation before termination; it never
  releases the machine, its provider history or another conversation's turns.
  A fenced incarnation requires reconciliation before another actor can use the
  machine. Neither process death nor normal teardown proves remote completion.
  """
  import Ecto.Query
  require Logger
  alias Fountain.{Conversations, Repo}
  alias Fountain.Conversations.{ActorClaim, ActorStartup, Conversation, PromptDelivery, Sandbox}

  @doc "Save one attempt while its original machine, parent and actor claim are locked."
  def save!(claim, sandbox, launch, {default_ms, recovery_deadline}) do
    if sandbox.status in ~w(ready suspended) do
      configured = Application.get_env(:fountain, :provision_deadline_ms, default_ms)

      unless is_integer(configured) and configured > 0,
        do: raise(ArgumentError, "provision_deadline_ms must be positive")

      deadline =
        if launch && launch.actor_claim_id == claim.id do
          launch.deadline_at
        else
          DateTime.add(DateTime.utc_now(), configured, :millisecond)
        end

      deadline =
        if recovery_deadline && DateTime.compare(recovery_deadline, deadline) == :lt,
          do: recovery_deadline,
          else: deadline

      if Repo.exists?(
           from s in ActorStartup,
             where: s.actor_claim_id == ^claim.id and s.state == "starting"
         ),
         do: Repo.rollback(:startup_in_progress)

      Repo.insert!(%ActorStartup{
        id: if(fetch(claim.id), do: Ecto.UUID.generate(), else: claim.id),
        actor_claim_id: claim.id,
        user_id: claim.user_id,
        conversation_id: claim.conversation_id,
        sandbox_id: claim.sandbox_id,
        deadline_at: deadline
      })
    end
  end

  def fetch(nil), do: nil
  def fetch(id), do: Repo.get(ActorStartup, id)

  @doc "An expired incarnation cannot publish callbacks even while its claim retains ownership."
  def writable?(nil), do: true

  def writable?(id) do
    not Repo.exists?(
      from s in ActorStartup,
        where: s.actor_claim_id == ^id and s.state == "expired"
    )
  end

  @doc "Unfinished reconnect teardown cannot release its ownership as evidence of completion."
  def releasable?(nil), do: true

  def releasable?(id) do
    not Repo.exists?(
      from s in ActorStartup,
        where: s.actor_claim_id == ^id and s.state in ["starting", "expired"]
    )
  end

  def fenced?(sandbox_id),
    do:
      Repo.exists?(
        from s in ActorStartup, where: s.sandbox_id == ^sandbox_id and s.state == "expired"
      )

  def unfinished?(sandbox_id),
    do:
      Repo.exists?(
        from s in ActorStartup,
          where: s.sandbox_id == ^sandbox_id and s.state in ["starting", "expired"]
      )

  def complete(state), do: settle(state, "completed")
  def returned(state), do: settle(state, "returned")

  def after_return(state, continuation) do
    case returned(state) do
      :ok -> continuation.()
      {:error, _} -> {:stop, :normal, state}
    end
  end

  defp settle(state, outcome) do
    case fetch(Map.get(state, :actor_startup_id, Map.get(state, :actor_claim))) do
      nil ->
        if Map.get(state, :actor_startup_id), do: {:error, :startup_missing}, else: :ok

      observed ->
        unless observed.actor_claim_id == Map.get(state, :actor_claim) and
                 observed.user_id == Map.get(state, :user_id) and
                 observed.conversation_id == Map.get(state, :conversation_id) and
                 observed.sandbox_id == Map.get(state, :sandbox_id),
               do: raise(ArgumentError, "startup outcome requires its original actor binding")

        case Repo.transaction(fn ->
               {parent, sandbox, claim, startup} = lock(observed)

               cond do
                 not owned?(parent, sandbox, claim, startup) ->
                   {:error, :ownership_changed}

                 not writable?(startup.actor_claim_id) ->
                   {:error, :startup_expired}

                 startup.state != "starting" ->
                   :ok

                 expired?(startup) ->
                   expire!(parent, startup)
                   {:error, :startup_expired}

                 true ->
                   finish!(startup, outcome)
                   :ok
               end
             end) do
          {:ok, result} -> result
          {:error, _} = error -> error
        end
    end
  end

  @doc "Return :legacy only when no durable reconnect outcome belongs to this incarnation."
  def expire(conversation_id, sandbox_id, actor_id, startup_id \\ nil) do
    case fetch(startup_id || actor_id) do
      nil ->
        if startup_id, do: {:ok, :stale}, else: :legacy

      %ActorStartup{
        actor_claim_id: ^actor_id,
        conversation_id: ^conversation_id,
        sandbox_id: ^sandbox_id
      } = observed ->
        Repo.transaction(fn ->
          {parent, sandbox, claim, startup} = lock(observed)

          cond do
            not owned?(parent, sandbox, claim, startup) ->
              :stale

            startup.state == "expired" ->
              :expired

            startup.state != "starting" ->
              :settled

            not expired?(startup) ->
              Repo.rollback(:deadline_not_reached)

            true ->
              expire!(parent, startup)
              :expired
          end
        end)

      _ ->
        {:ok, :stale}
    end
  rescue
    error ->
      Logger.warning("reconnect expiry decision unavailable: #{inspect(error.__struct__)}")
      {:error, :decision_unavailable}
  end

  defp lock(observed) do
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
      4316,
      :erlang.phash2(observed.sandbox_id)
    ])

    parent =
      Repo.one(
        from c in Conversation, where: c.id == ^observed.conversation_id, lock: "FOR UPDATE"
      )

    sandbox = Repo.one(from s in Sandbox, where: s.id == ^observed.sandbox_id, lock: "FOR UPDATE")

    claim =
      Repo.one(from a in ActorClaim, where: a.id == ^observed.actor_claim_id, lock: "FOR UPDATE")

    startup = Repo.one!(from s in ActorStartup, where: s.id == ^observed.id, lock: "FOR UPDATE")
    {parent, sandbox, claim, startup}
  end

  defp owned?(parent, sandbox, claim, startup),
    do:
      parent && sandbox && claim && claim.state == "active" &&
        parent.user_id == startup.user_id && sandbox.user_id == startup.user_id &&
        claim.user_id == startup.user_id && parent.id == startup.conversation_id &&
        parent.sandbox_id == startup.sandbox_id && claim.conversation_id == parent.id &&
        claim.sandbox_id == sandbox.id

  defp expired?(startup), do: DateTime.compare(DateTime.utc_now(), startup.deadline_at) != :lt

  defp finish!(startup, outcome),
    do:
      startup
      |> Ecto.Changeset.change(state: outcome, settled_at: DateTime.utc_now())
      |> Repo.update!()

  defp expire!(parent, startup) do
    # Ownership: the locked parent and active incarnation still own this exact
    # conversation. No successor can mint credentials until reconciliation.
    if parent.callback_api_key_id do
      case Fountain.Accounts.revoke_api_key(parent.user_id, parent.callback_api_key_id,
             actor: "system:actor_startup_deadline"
           ) do
        {:ok, _} -> :ok
        {:error, :not_found} -> :ok
      end
    end

    :ok = Fountain.Broker.Native.Sessions.release(parent.id)

    if receipt = PromptDelivery.queued(parent.user_id, parent.id) do
      case PromptDelivery.refuse(parent.user_id, parent.id, receipt.id, "provisioning_failed",
             sandbox_id: startup.sandbox_id
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end

    event =
      Conversations.log!(%{
        conversation_id: parent.id,
        kind: "stage",
        stage: "reattach",
        state: "failed",
        data:
          Jason.encode!(%{
            reason: "reconnect deadline exceeded",
            sandbox_id: startup.sandbox_id,
            actor_claim_id: startup.actor_claim_id,
            actor_startup_id: startup.id,
            recovery_required: true
          })
      })

    Fountain.Webhooks.dispatch_stage!(event)

    %{"event_id" => event.id, "conversation_id" => parent.id, "user_id" => parent.user_id}
    |> Fountain.Workers.TurnDeadlineNotification.new()
    |> Oban.insert!()

    finish!(startup, "expired")
  end
end
