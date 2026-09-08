defmodule Fountain.Conversations.SandboxHolders do
  @moduledoc """
  Serialize conversation attachment and transfer with machine lifecycle grants.

  Machine advisory locks precede parent rows. Transfers lock both machine keys
  in numeric order, re-read ownership and reject unresolved provider operations
  or execution. No provider calls or actor messages run inside these transactions.
  """
  import Ecto.Query
  import Ecto.Changeset, only: [apply_changes: 1, get_field: 2]

  alias Fountain.{Conversations, Repo}
  alias Fountain.Conversations.{Conversation, Sandbox, SandboxOperation, Turn, TurnExecution}

  @terminal ~w(terminated failed)
  @binding [:sandbox_id, :user_id, :agent_id, :environment_id, :vault_id, :runtime]

  def _unsafe_insert(%Ecto.Changeset{valid?: false} = changeset), do: {:error, changeset}

  def _unsafe_insert(changeset) do
    Repo.transaction(fn ->
      candidate = apply_changes(changeset)
      lock_machines([candidate.sandbox_id])
      parents = lock_parents([candidate.sandbox_id])
      sandbox = lock_sandbox(candidate.sandbox_id)
      assert_destination!(sandbox, candidate, parents)
      inserted = write!(Repo.insert(changeset))
      touch_attachment!(sandbox)
      inserted
    end)
  end

  def _unsafe_update(observed, attrs) do
    initial = Conversation.changeset(observed, attrs)

    if initial.valid? do
      Repo.transaction(fn ->
        destination = get_field(initial, :sandbox_id)
        lock_machines([observed.sandbox_id, destination])
        parents = lock_parents([observed.sandbox_id, destination])
        current = Enum.find(parents, &(&1.id == observed.id)) || Repo.rollback(:ownership_changed)

        if current.sandbox_id != observed.sandbox_id or current.user_id != observed.user_id,
          do: Repo.rollback(:ownership_changed)

        changeset = Conversation.changeset(current, attrs)
        candidate = apply_changes(changeset)
        if candidate.user_id != current.user_id, do: Repo.rollback(:ownership_changed)
        moving? = Enum.any?(@binding, &(Map.get(candidate, &1) != Map.get(current, &1)))
        reviving? = current.status in @terminal and candidate.status not in @terminal

        if moving? or reviving? do
          source = lock_optional_sandbox(current.sandbox_id)
          if source && source.user_id != current.user_id, do: Repo.rollback(:ownership_changed)
          assert_idle!([current.id])
          assert_unfenced!(current.sandbox_id)
          sandbox = lock_sandbox(destination)
          peers = Enum.reject(parents, &(&1.id == current.id))
          assert_destination!(sandbox, candidate, peers)
          touch_attachment!(sandbox)
        end

        updated = write!(Repo.update(changeset))

        loaded =
          Enum.filter(
            Conversation.__schema__(:associations),
            &Ecto.assoc_loaded?(Map.get(observed, &1))
          )

        Repo.preload(updated, loaded)
      end)
    else
      {:error, initial}
    end
  end

  @doc "Create a replacement and move its holders under the original machine locks."
  def _unsafe_create_replacement(observed, source_snapshot, sandbox_attrs) do
    destination_id = Ecto.UUID.generate()

    Repo.transaction(fn ->
      lock_machines([observed.sandbox_id, destination_id])
      parents = lock_replacement_parents(observed.sandbox_id, destination_id, observed.id)
      current = Enum.find(parents, &(&1.id == observed.id)) || Repo.rollback(:ownership_changed)

      unless Enum.all?(@binding, &(Map.get(current, &1) == Map.get(observed, &1))) and
               current.status not in @terminal and sandbox_attrs.user_id == current.user_id,
             do: Repo.rollback(:ownership_changed)

      source = lock_optional_sandbox(observed.sandbox_id)
      assert_source_snapshot!(source, source_snapshot, current.user_id)
      assert_unfenced!(observed.sandbox_id)
      assert_idle!(Enum.map(parents, & &1.id))
      mode = if source, do: source.mode, else: "ephemeral"
      if sandbox_attrs.mode != mode, do: Repo.rollback(:ownership_changed)

      if source && source.status not in @terminal do
        write!(Conversations.update_sandbox(source, %{status: "terminated"}))
      end

      destination =
        %Sandbox{id: destination_id}
        |> Sandbox.changeset(sandbox_attrs)
        |> Repo.insert()
        |> write!()

      # Ownership: the locked source and current parent retain this tenant.
      moved = write!(_unsafe_replace(current, destination.id))
      {destination, moved}
    end)
  end

  defp assert_source_snapshot!(nil, nil, _user_id), do: :ok

  defp assert_source_snapshot!(%Sandbox{} = current, %Sandbox{} = observed, user_id) do
    fields = [
      :id,
      :user_id,
      :status,
      :provider,
      :sprite_name,
      :provider_instance_id,
      :provider_meta,
      :mode,
      :agent_id,
      :environment_id,
      :vault_id,
      :updated_at,
      :last_resumed_at,
      :last_attached_at
    ]

    unless current.user_id == user_id and Map.take(current, fields) == Map.take(observed, fields),
      do: Repo.rollback(:ownership_changed)
  end

  defp assert_source_snapshot!(_, _, _), do: Repo.rollback(:ownership_changed)

  @doc "Replace all current live holders in one transaction, including the winning initiator."
  def _unsafe_replace(observed, destination_id) do
    Repo.transaction(fn ->
      source_id = observed.sandbox_id
      lock_machines([source_id, destination_id])
      parents = lock_replacement_parents(source_id, destination_id, observed.id)
      initiator = Enum.find(parents, &(&1.id == observed.id)) || Repo.rollback(:ownership_changed)

      if initiator.sandbox_id != source_id or initiator.user_id != observed.user_id,
        do: Repo.rollback(:ownership_changed)

      if source_id == destination_id, do: Repo.rollback(:ownership_changed)
      source = lock_optional_sandbox(source_id)
      if source && source.user_id != initiator.user_id, do: Repo.rollback(:ownership_changed)
      if source && source.status not in @terminal, do: Repo.rollback(:sandbox_not_retired)
      assert_unfenced!(source_id)
      destination = lock_sandbox(destination_id)

      holders =
        Enum.filter(
          parents,
          &(&1.sandbox_id == source_id and (not is_nil(source_id) or &1.id == initiator.id) and
              (&1.status not in @terminal or &1.id == initiator.id))
        )

      assert_idle!(Enum.map(holders, & &1.id))

      if length(holders) > 1 and Enum.any?(holders, &(&1.sandbox_api_access == "none")),
        do: Repo.rollback(:invalid_sandbox_api_access)

      moved =
        Enum.map(holders, fn holder ->
          candidate = %{holder | sandbox_id: destination_id, runtime_session_id: nil}
          assert_destination!(destination, candidate, parents)
          attrs = %{sandbox_id: destination_id, runtime_session_id: nil}

          attrs =
            if holder.id == initiator.id, do: Map.put(attrs, :status, "pending"), else: attrs

          updated = holder |> Conversation.changeset(attrs) |> Repo.update!()
          if holder.id != initiator.id, do: record_replacement(holder, source_id, destination_id)
          updated
        end)

      touch_attachment!(destination)
      Enum.find(moved, &(&1.id == initiator.id))
    end)
  end

  defp assert_destination!(sandbox, candidate, parents) do
    if sandbox.user_id != candidate.user_id, do: Repo.rollback(:ownership_changed)
    peers = Enum.filter(parents, &(&1.sandbox_id == sandbox.id and &1.id != candidate.id))
    assert_unfenced!(sandbox.id)

    unless sandbox.status in ~w(pending ready suspended) and
             (sandbox.status != "pending" or peers == []),
           do: Repo.rollback({:sandbox_not_attachable, sandbox.status})

    # A none conversation can only enter its own fresh machine. Historical
    # holders count too: ending a conversation does not scrub its credentials.
    if (candidate.sandbox_api_access == "none" and
          (sandbox.mode != "ephemeral" or sandbox.status != "pending" or peers != [])) or
         Enum.any?(peers, &(&1.sandbox_api_access == "none")),
       do: Repo.rollback(:invalid_sandbox_api_access)

    for {field, schema} <- [
          agent_id: Fountain.Agents.Agent,
          environment_id: Fountain.Environments.Environment,
          vault_id: Fountain.Vaults.Vault
        ],
        id = Map.get(candidate, field),
        not is_nil(id) do
      unless Repo.exists?(
               from r in schema, where: r.id == ^id and r.user_id == ^candidate.user_id
             ),
             do: Repo.rollback(:ownership_changed)
    end

    unless identity_matches?(sandbox, candidate, peers),
      do: Repo.rollback(:sandbox_identity_mismatch)

    if Enum.any?(peers, &(&1.user_id != candidate.user_id)),
      do: Repo.rollback(:ownership_changed)

    if Enum.any?(peers, &(&1.runtime != candidate.runtime)),
      do: Repo.rollback(:sandbox_runtime_mismatch)
  end

  defp identity_matches?(sandbox, candidate, peers) do
    exact? =
      sandbox.agent_id == candidate.agent_id and sandbox.vault_id == candidate.vault_id and
        sandbox.environment_id == environment_id(candidate)

    # Older Team machines have no disk-identity columns. Preserve their existing
    # lineage only when every locked historical holder agrees. Managed creations
    # cannot use this fallback, including unresolved or retired incarnations.
    legacy? =
      is_nil(sandbox.agent_id) and is_nil(sandbox.environment_id) and is_nil(sandbox.vault_id) and
        peers != [] and
        not Repo.exists?(from o in SandboxOperation, where: o.sandbox_id == ^sandbox.id)

    if legacy? do
      Enum.all?(peers, fn peer ->
        peer.agent_id == candidate.agent_id and peer.vault_id == candidate.vault_id and
          peer.environment_id == candidate.environment_id and peer.runtime == candidate.runtime
      end)
    else
      exact?
    end
  end

  defp environment_id(%{environment_id: id}) when is_binary(id), do: id
  defp environment_id(%{agent_id: nil}), do: nil

  defp environment_id(candidate) do
    case Repo.get(Fountain.Agents.Agent, candidate.agent_id) do
      %{user_id: owner, environment_id: id} when owner == candidate.user_id -> id
      _ -> Repo.rollback(:ownership_changed)
    end
  end

  defp assert_unfenced!(nil), do: :ok

  defp assert_unfenced!(sandbox_id) do
    if Conversations.ActorStartups.unfinished?(sandbox_id), do: Repo.rollback(:startup_unresolved)

    if Repo.exists?(
         from o in SandboxOperation,
           where: o.sandbox_id == ^sandbox_id and o.state in ~w(submitted uncertain)
       ),
       do: Repo.rollback(:provider_operation_fenced)

    creation = Repo.get_by(SandboxOperation, sandbox_id: sandbox_id, action: "create")
    sandbox = Repo.get(Sandbox, sandbox_id)

    if creation &&
         (creation.state != "confirmed" or not creation.holds_slot or
            not is_binary(creation.provider_instance_id) or creation.provider_instance_id == "" or
            is_nil(sandbox) or creation.user_id != sandbox.user_id or
            creation.sandbox_name != sandbox.sprite_name or creation.provider != sandbox.provider or
            creation.provider_instance_id != sandbox.provider_instance_id),
       do: Repo.rollback(:provider_operation_fenced)
  end

  defp assert_idle!([]), do: :ok

  defp assert_idle!(ids) do
    if Repo.exists?(from t in Turn, where: t.conversation_id in ^ids and t.status == "running") or
         Repo.exists?(
           from e in TurnExecution,
             where: e.conversation_id in ^ids and e.state not in ~w(completed stopped)
         ),
       do: Repo.rollback(:sandbox_mid_turn)
  end

  defp lock_machines(ids) do
    ids
    |> Enum.map(&:erlang.phash2/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(&Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, &1]))
  end

  defp lock_parents(ids),
    do:
      Repo.all(
        from c in Conversation, where: c.sandbox_id in ^ids, order_by: c.id, lock: "FOR UPDATE"
      )

  defp lock_replacement_parents(source_id, destination_id, initiator_id) do
    ids = Enum.reject([source_id, destination_id], &is_nil/1)

    Repo.all(
      from c in Conversation,
        where: c.id == ^initiator_id or c.sandbox_id in ^ids,
        order_by: c.id,
        lock: "FOR UPDATE"
    )
  end

  defp lock_optional_sandbox(nil), do: nil

  defp lock_optional_sandbox(id),
    do: Repo.one(from s in Sandbox, where: s.id == ^id, lock: "FOR UPDATE")

  defp lock_sandbox(id),
    do: lock_optional_sandbox(id) || Repo.rollback(:sandbox_not_found)

  defp touch_attachment!(sandbox) do
    sandbox
    |> Ecto.Changeset.change(last_attached_at: DateTime.utc_now())
    |> Repo.update!()
  end

  defp write!({:ok, row}), do: row
  defp write!({:error, error}), do: Repo.rollback(error)

  defp record_replacement(holder, source_id, destination_id) do
    event =
      Conversations.log!(%{
        conversation_id: holder.id,
        kind: "stage",
        stage: "sandbox",
        state: "done",
        data:
          Jason.encode!(%{
            event: "replaced",
            reason: "sprite_gone",
            source_sandbox_id: source_id,
            sandbox_id: destination_id,
            message:
              "Sandbox replaced; the transcript is kept, but the runtime session starts fresh."
          })
      })

    Fountain.Webhooks.dispatch_stage!(event)

    %{"event_id" => event.id, "conversation_id" => holder.id, "user_id" => holder.user_id}
    |> Fountain.Workers.TurnDeadlineNotification.new()
    |> Oban.insert!()
  end
end
