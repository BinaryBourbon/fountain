defmodule Fountain.Conversations.LegacyDeletion do
  @moduledoc "Durable deletion intent for an existing legacy machine; never a managed creation claim."
  import Ecto.Query
  alias Fountain.{Conversations, Repo}

  alias Fountain.Conversations.{
    Conversation,
    Sandbox,
    SandboxOperation,
    SandboxOperations,
    WakeContext
  }

  alias Managoat.Sandbox.Handle

  @terminal ~w(terminated failed)
  @generation "lifecycle_operation_id"

  def destroy(observed, handle, opts \\ []) do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      with {:ok, operation} <- submit(observed, handle, opts) do
        dispatch(operation.id)
      else
        {:error, :provider_already_destroyed} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  @doc "Claim the saved intent once after commit; redelivery cannot grant a second provider call."
  def dispatch(id) do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      with {:ok, operation} <- claim(id) do
        result =
          WakeContext.run(%{deadline_at: operation.delete_deadline_at}, fn ->
            original =
              Managoat.Sandbox.build_handle(
                String.to_existing_atom(operation.provider),
                operation.sandbox_name
              )

            original = %{original | instance_id: operation.provider_instance_id}
            Managoat.Sandbox.destroy_once(original, timeout_ms: 30_000)
          end)

        complete(operation.id, result)
      end
    end
  end

  @doc "Persist the dispatch boundary before any provider request."
  def claim(id) do
    observed = Repo.get!(SandboxOperation, id)

    Repo.transaction(fn ->
      lock_machine(observed.sandbox_id)
      lock_parents(observed.sandbox_id)
      sandbox = lock_sandbox(observed.sandbox_id)
      operation = Repo.one!(from o in SandboxOperation, where: o.id == ^id, lock: "FOR UPDATE")

      unless operation.action == "destroy" && is_nil(operation.creation_id) &&
               operation.delete_deadline_at && operation.state == "submitted" &&
               is_nil(operation.delete_started_at),
             do: Repo.rollback(:provider_operation_fenced)

      unless owned?(operation, sandbox), do: Repo.rollback(:ownership_changed)
      # ownership: the saved deletion intent still owns this exact retired machine.
      if Conversations._unsafe_running_turns_elsewhere(operation.sandbox_id, nil) > 0 ||
           Conversations.ExecutionGuard._unsafe_sandbox_open?(operation.sandbox_id),
         do: Repo.rollback(:sandbox_mid_turn)

      now = DateTime.utc_now()

      if DateTime.compare(now, operation.delete_deadline_at) != :lt do
        operation |> SandboxOperation.changeset(%{state: "refused"}) |> Repo.update!()
        {:error, :provider_operation_fenced}
      else
        {:ok,
         operation |> SandboxOperation.changeset(%{delete_started_at: now}) |> Repo.update!()}
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, _} = error -> error
    end
  end

  @doc "Serialize deletion with resume and admission, retaining capacity before provider I/O."
  def submit(observed, handle, opts \\ []) do
    Repo.transaction(fn ->
      lock_machine(observed.id)
      parents = lock_parents(observed.id)
      sandbox = lock_sandbox(observed.id) || Repo.rollback(:ownership_changed)
      assert_binding!(observed, sandbox, handle)
      # ownership: the locked current machine matches the cleanup caller's original snapshot.
      if SandboxOperations._unsafe_managed?(sandbox.id) ||
           Conversations.SandboxTransitions._unsafe_pending?(sandbox.id),
         do: Repo.rollback(:provider_operation_fenced)

      existing =
        Repo.one(
          from o in SandboxOperation,
            where:
              o.sandbox_id == ^sandbox.id and
                o.action == "destroy" and not is_nil(o.delete_deadline_at)
        )

      if existing do
        Repo.rollback(
          if existing.state == "confirmed",
            do: :provider_already_destroyed,
            else: :provider_operation_fenced
        )
      end

      unless Enum.all?(parents, &(&1.user_id == sandbox.user_id)),
        do: Repo.rollback(:ownership_changed)

      # ownership: all locked parents and the original physical snapshot agree on this tenant.
      if Conversations._unsafe_running_turns_elsewhere(sandbox.id, nil) > 0 ||
           Conversations.ExecutionGuard._unsafe_sandbox_open?(sandbox.id),
         do: Repo.rollback(:sandbox_mid_turn)

      holder = Keyword.get(opts, :holder)

      if holder && Enum.any?(parents, &(&1.id != holder && &1.status not in @terminal)),
        do: Repo.rollback(:sandbox_held)

      unless Managoat.Sandbox.supports?(handle, :destroy_once), do: Repo.rollback(:not_supported)
      timeout = Keyword.get(opts, :timeout_ms, 35_000)

      unless is_integer(timeout) && timeout in 1..35_000,
        do: Repo.rollback(:invalid_delete_timeout)

      now = DateTime.utc_now()

      if reason = Keyword.get(opts, :bound) do
        unless reason in [:idle, :max_lifetime] && sandbox.status == "ready",
          do: Repo.rollback(:sandbox_not_ready)

        # ownership: current tenant-owned parents are locked with this exact machine.
        unless Conversations.SandboxActivity._unsafe_check(sandbox, parents, now) ==
                 {:expired, reason},
               do: Repo.rollback(:lifecycle_bound_not_reached)
      end

      operation =
        %SandboxOperation{}
        |> SandboxOperation.changeset(%{
          sandbox_id: sandbox.id,
          user_id: sandbox.user_id,
          provider: sandbox.provider,
          sandbox_name: sandbox.sprite_name,
          provider_instance_id: sandbox.provider_instance_id,
          action: "destroy",
          state: "submitted",
          holds_slot: true,
          submitted_at: now,
          delete_deadline_at: DateTime.add(now, timeout, :millisecond)
        })
        |> Repo.insert()
        |> case do
          {:ok, operation} -> operation
          {:error, _} -> Repo.rollback(:provider_operation_fenced)
        end

      {:ok, _} =
        Conversations.update_sandbox(sandbox, %{
          status: if(sandbox.status == "failed", do: "failed", else: "terminated"),
          terminated_at: nil,
          provider_meta: Map.put(sandbox.provider_meta || %{}, @generation, operation.id)
        })

      operation
    end)
  end

  @doc "Only this attempt's confirmed absence releases capacity; no lookup grants replay."
  def complete(id, result) do
    observed = Repo.get!(SandboxOperation, id)

    Repo.transaction(fn ->
      lock_machine(observed.sandbox_id)
      lock_parents(observed.sandbox_id)
      sandbox = lock_sandbox(observed.sandbox_id)
      operation = Repo.one!(from o in SandboxOperation, where: o.id == ^id, lock: "FOR UPDATE")

      unless operation.action == "destroy" && is_nil(operation.creation_id) &&
               operation.delete_deadline_at && operation.delete_started_at &&
               operation.state in ~w(submitted uncertain),
             do: Repo.rollback(:provider_operation_fenced)

      cond do
        match?({:not_started, _}, result) ->
          # The machine still exists even when this attempt certainly made no call.
          operation |> SandboxOperation.changeset(%{state: "refused"}) |> Repo.update!()
          {:error, :provider_operation_fenced}

        result == {:returned, :ok} && owned?(operation, sandbox) ->
          at = DateTime.utc_now()

          operation
          |> SandboxOperation.changeset(%{
            state: "confirmed",
            holds_slot: false,
            confirmed_at: at
          })
          |> Repo.update!()

          if sandbox do
            sandbox
            |> Ecto.Changeset.change(terminated_at: DateTime.truncate(at, :second))
            |> Repo.update!()
          end

          :ok

        true ->
          operation |> SandboxOperation.changeset(%{state: "uncertain"}) |> Repo.update!()
          {:error, :provider_operation_uncertain}
      end
    end)
    |> case do
      {:ok, result} -> result
      {:error, _} = error -> error
    end
  end

  defp assert_binding!(observed, sandbox, %Handle{} = handle) do
    unless is_binary(sandbox.user_id) && sandbox.user_id == observed.user_id &&
             sandbox.provider == observed.provider && sandbox.sprite_name == observed.sprite_name &&
             sandbox.provider_instance_id == observed.provider_instance_id &&
             sandbox.provider_meta == observed.provider_meta && sandbox.status == observed.status &&
             sandbox.mode == observed.mode && Atom.to_string(handle.provider) == sandbox.provider &&
             handle.name == sandbox.sprite_name &&
             handle.instance_id == sandbox.provider_instance_id,
           do: Repo.rollback(:ownership_changed)

    # ownership: the locked snapshot matches the caller; physical aliases cannot grant cleanup.
    if SandboxOperations._unsafe_name_conflict?(sandbox), do: Repo.rollback(:ownership_changed)
  end

  defp assert_binding!(_, _, _), do: Repo.rollback(:provider_identity_missing)

  defp name_conflict?(operation) do
    # ownership: this immutable operation carries its original machine and provider name.
    SandboxOperations._unsafe_name_conflict?(%{
      id: operation.sandbox_id,
      provider: operation.provider,
      sprite_name: operation.sandbox_name
    })
  end

  defp owned?(operation, nil), do: not name_conflict?(operation)

  defp owned?(operation, sandbox) do
    owner_matches =
      sandbox.user_id == operation.user_id ||
        (is_nil(sandbox.user_id) &&
           not Repo.exists?(from u in Fountain.Accounts.User, where: u.id == ^operation.user_id))

    owner_matches && not name_conflict?(operation) && sandbox.id == operation.sandbox_id &&
      sandbox.provider == operation.provider &&
      sandbox.sprite_name == operation.sandbox_name &&
      sandbox.provider_instance_id == operation.provider_instance_id &&
      sandbox.provider_meta[@generation] == operation.id && sandbox.status in @terminal
  end

  defp lock_machine(id),
    do: Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, :erlang.phash2(id)])

  defp lock_parents(id),
    do:
      Repo.all(
        from c in Conversation, where: c.sandbox_id == ^id, order_by: c.id, lock: "FOR UPDATE"
      )

  defp lock_sandbox(id), do: Repo.one(from s in Sandbox, where: s.id == ^id, lock: "FOR UPDATE")
end
