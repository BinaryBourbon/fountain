defmodule Fountain.Conversations.ActorOwnership do
  @moduledoc """
  Arbitrate actor startup before credentials, interruption or provider calls.

  A claim identifies one process incarnation. Registry absence and elapsed time
  never release it: an untrappable process or node loss requires recovery to
  account for its outstanding operations before another actor can take over.
  Normal termination retires only this incarnation; it does not establish remote
  completion. A new actor cannot claim a starting machine or a previously claimed
  pending machine. A committed holder transfer supersedes the old claim; its
  scoped callbacks then lose authority.
  """
  import Ecto.Query
  alias Fountain.Repo
  alias Fountain.Conversations.{ActorClaim, Conversation, Sandbox}

  def start(state, conversation, sandbox, provision_deadline_ms) do
    id = Map.get(state, :actor_claim) || Ecto.UUID.generate()

    with {:ok, {_claim, current, machine, launch}} <-
           claim_binding(
             conversation.user_id,
             conversation.id,
             sandbox.id,
             id,
             Map.get(state, :launch_id)
           ) do
      if is_nil(Map.get(state, :actor_claim)) do
        Fountain.Conversations.ProvisionWatchdog.start(
          conversation.id,
          sandbox.id,
          provision_deadline_ms,
          actor_claim: id,
          deadline_at: if(launch && machine.status == "pending", do: launch.deadline_at)
        )
      end

      {:ok, state |> Map.put(:actor_claim, id) |> Map.put(:user_id, current.user_id), current,
       machine}
    end
  end

  def claim(user_id, conversation_id, sandbox_id, id) do
    with {:ok, {claim, _parent, _sandbox, _launch}} <-
           claim_binding(user_id, conversation_id, sandbox_id, id, nil),
         do: {:ok, claim}
  end

  defp claim_binding(user_id, conversation_id, sandbox_id, id, launch_id) do
    Repo.transaction(fn ->
      lock_machine(sandbox_id)

      parent =
        Repo.one(from c in Conversation, where: c.id == ^conversation_id, lock: "FOR UPDATE")

      sandbox = Repo.one(from s in Sandbox, where: s.id == ^sandbox_id, lock: "FOR UPDATE")

      unless parent && sandbox && parent.user_id == user_id && sandbox.user_id == user_id &&
               parent.sandbox_id == sandbox.id && parent.status not in ~w(terminated failed) &&
               sandbox.status not in ~w(terminated failed),
             do: Repo.rollback(:ownership_changed)

      existing =
        Repo.one(
          from a in ActorClaim,
            where: a.conversation_id == ^parent.id and a.state == "active",
            lock: "FOR UPDATE"
        )

      {claim, launch} =
        cond do
          existing && existing.user_id != user_id ->
            Repo.rollback(:ownership_changed)

          existing && existing.id == id && existing.sandbox_id == sandbox_id ->
            {existing, nil}

          existing && existing.sandbox_id == sandbox_id ->
            Repo.rollback(:actor_owned)

          true ->
            if Repo.get(ActorClaim, id), do: Repo.rollback(:actor_retired)
            assert_new_start!(sandbox)

            launch =
              Fountain.Conversations.ActorLaunches.acknowledge!(parent, sandbox, id, launch_id)

            if existing do
              existing |> Ecto.Changeset.change(state: "superseded") |> Repo.update!()
            end

            claim =
              Repo.insert!(%ActorClaim{
                id: id,
                user_id: user_id,
                conversation_id: conversation_id,
                sandbox_id: sandbox_id,
                launch_id: launch && launch.id
              })

            {claim, launch}
        end

      {claim, parent, sandbox, launch}
    end)
  end

  # Machine locking serializes claims across every conversation on this sandbox.
  # A stopped/superseded process can have left a provider operation behind; its
  # history cannot be discarded to authorize another fresh provisioning attempt.
  defp assert_new_start!(%Sandbox{status: "starting"}),
    do: Repo.rollback(:provisioning_unresolved)

  defp assert_new_start!(%Sandbox{status: "pending", id: id}) do
    if Repo.exists?(from a in ActorClaim, where: a.sandbox_id == ^id),
      do: Repo.rollback(:provisioning_unresolved)
  end

  defp assert_new_start!(_sandbox), do: :ok

  @doc "Check while holding the original machine/parent locks; nil supports non-actor writers only."
  def current?(conversation_id, sandbox_id, id) do
    case Repo.one(
           from a in ActorClaim,
             where: a.conversation_id == ^conversation_id and a.state == "active",
             lock: "FOR UPDATE"
         ) do
      nil -> is_nil(id)
      claim -> claim.id == id && claim.sandbox_id == sandbox_id
    end
  end

  def current?(state),
    do: current?(state.conversation_id, state.sandbox_id, Map.get(state, :actor_claim))

  @doc "Serialize local teardown and release with successor claims on the parent lock."
  def finish(state, teardown) do
    Repo.transaction(fn ->
      lock_machine(state.sandbox_id)

      parent =
        Repo.one(
          from c in Conversation, where: c.id == ^state.conversation_id, lock: "FOR UPDATE"
        )

      if parent && parent.user_id == state.user_id && parent.sandbox_id == state.sandbox_id &&
           current?(state) do
        teardown.()
      end

      release(state)
    end)

    :ok
  end

  # An exiting actor retires its own claim without changing a successor's claim.
  defp release(state) do
    if id = Map.get(state, :actor_claim) do
      from(a in ActorClaim,
        where:
          a.id == ^id and a.user_id == ^state.user_id and
            a.conversation_id == ^state.conversation_id and a.sandbox_id == ^state.sandbox_id and
            a.state == "active"
      )
      |> Repo.update_all(set: [state: "stopped", updated_at: DateTime.utc_now()])
    end

    :ok
  end

  defp lock_machine(id),
    do: Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, :erlang.phash2(id)])
end
