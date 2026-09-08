defmodule Fountain.Conversations.SandboxOperations do
  @moduledoc """
  Fixed provider-operation intents, with permanent physical-name claims.

  A submitted create retains capacity even if its parent disappears. A timeout
  does not authorize another request or adoption by name. Only the successful
  fresh-create response establishes the provider instance identity.

  Internal callers must already own the supplied conversation and sandbox.
  Provider calls run outside transactions; operation rows survive parent deletion.
  Lifecycle call-site integration is in progress and execution controls stay off.
  """
  import Ecto.Query

  alias Fountain.{Audit, Repo}
  alias Fountain.Conversations.{Conversation, Sandbox, SandboxOperation}
  alias Managoat.Sandbox.Handle

  @terminal ~w(terminated failed)

  def _unsafe_create(%Sandbox{} = sandbox, %Conversation{} = conversation) do
    with {:ok, operation} <- _unsafe_submit_create(sandbox, conversation) do
      if operation.state == "submitted" do
        result = fresh_create(operation)
        _unsafe_complete_create(operation.id, result)
      else
        {:error, :provider_operation_uncertain}
      end
    end
  end

  @doc "Commit one create intent; an interrupted pre-journal attempt stays uncertain."
  def _unsafe_submit_create(%Sandbox{} = observed, %Conversation{} = parent) do
    result =
      Repo.transaction(fn ->
        lock_machine(observed.id)
        current_parent = lock_parent(parent.id) || Repo.rollback(:not_found)
        sandbox = lock_sandbox(observed.id) || Repo.rollback(:not_found)

        unless same_binding?(sandbox, observed) and parent.user_id == sandbox.user_id and
                 current_parent.user_id == sandbox.user_id and
                 current_parent.sandbox_id == sandbox.id,
               do: Repo.rollback(:ownership_changed)

        if current_parent.status in @terminal or sandbox.status not in ~w(pending starting),
          do: Repo.rollback(:sandbox_retired)

        if sandbox.provider != "sprites", do: Repo.rollback(:provider_not_supported)

        # Existing names are never adopted. Even after parents are pruned this
        # unique claim remains, so a successor cannot reuse the physical name.
        attrs = %{
          sandbox_id: sandbox.id,
          conversation_id: current_parent.id,
          user_id: sandbox.user_id,
          provider: sandbox.provider,
          sandbox_name: sandbox.sprite_name,
          action: "create",
          sandbox_started_at: sandbox.inserted_at,
          state: if(observed.status == "pending", do: "submitted", else: "uncertain"),
          submitted_at: if(observed.status == "pending", do: DateTime.utc_now()),
          holds_slot: true
        }

        case Repo.insert(SandboxOperation.changeset(%SandboxOperation{}, attrs)) do
          {:ok, operation} -> operation
          {:error, _} -> Repo.rollback(:provider_operation_fenced)
        end
      end)

    audit_result(result, "sandbox.operation_submitted")
  end

  @doc "Record the fresh-create response without reviving a retired or deleted parent."
  def _unsafe_complete_create(operation_id, provider_result) do
    observed = Repo.get(SandboxOperation, operation_id)

    if observed && observed.action == "create" do
      result =
        Repo.transaction(fn ->
          lock_machine(observed.sandbox_id)
          parent = lock_parent(observed.conversation_id)
          operation = lock_operation(operation_id) || Repo.rollback(:not_found)

          if operation.state not in ~w(submitted uncertain) or is_nil(operation.submitted_at),
            do: Repo.rollback(:provider_operation_fenced)

          attrs = creation_outcome(operation, provider_result)

          case Repo.update(SandboxOperation.changeset(operation, attrs)) do
            {:ok, recorded} ->
              sandbox = lock_sandbox(operation.sandbox_id)
              {recorded, usable_parent?(parent, sandbox, operation)}

            {:error, _} ->
              Repo.rollback(:provider_identity_conflict)
          end
        end)

      case result do
        {:ok, {recorded, usable?}} ->
          audit(recorded, "sandbox.operation_result")
          creation_reply(recorded, provider_result, usable?)

        {:error, :provider_identity_conflict} ->
          # The successful response was not safe to bind. Preserve its intent
          # as uncertain; a duplicate provider ID never authorizes adoption.
          _unsafe_mark_uncertain(operation_id)
          {:error, :provider_operation_uncertain}

        {:error, _} = error ->
          error
      end
    else
      {:error, :not_found}
    end
  end

  @doc "A failed observer retains its intent and slot; it grants no provider retry."
  def _unsafe_mark_uncertain(operation_id) do
    result =
      Repo.transaction(fn ->
        operation = lock_operation(operation_id) || Repo.rollback(:not_found)

        if operation.state == "submitted" do
          operation |> SandboxOperation.changeset(%{state: "uncertain"}) |> Repo.update!()
        else
          Repo.rollback(:provider_operation_fenced)
        end
      end)

    audit_result(result, "sandbox.operation_result")
  end

  @doc "Query retained create reservations, including ones whose parents were deleted."
  def _unsafe_reserved_slots do
    from operation in SandboxOperation,
      where: operation.action == "create" and operation.holds_slot,
      select: %{id: operation.sandbox_id, user_id: operation.user_id}
  end

  @doc "Whether this physical sandbox has entered the durable lifecycle."
  def _unsafe_managed?(sandbox_id) do
    Repo.exists?(
      from operation in SandboxOperation,
        where: operation.sandbox_id == ^sandbox_id and operation.action == "create"
    )
  end

  @doc "Logical retirement cannot release a retained provider reservation."
  def _unsafe_holds_slot?(sandbox_id) do
    Repo.exists?(
      from operation in SandboxOperation,
        where:
          operation.sandbox_id == ^sandbox_id and operation.action == "create" and
            operation.holds_slot
    )
  end

  def _unsafe_destroy(%Sandbox{} = sandbox, opts \\ []) do
    case _unsafe_submit_destroy(sandbox, opts) do
      {:ok, operation} -> _unsafe_complete_destroy(operation.id, destroy_once(operation))
      {:error, :provider_already_destroyed} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc "Route owned cleanup through its existing journal; never downgrade a managed claim."
  def _unsafe_destroy_or_legacy(%Sandbox{} = sandbox, handle, opts \\ []) do
    if _unsafe_managed?(sandbox.id) do
      _unsafe_destroy(sandbox, opts)
    else
      if handle, do: Managoat.Sandbox.destroy(handle), else: :ok
    end
  end

  @doc "Publish readiness only for a live parent and its confirmed fresh creation."
  def _unsafe_finish_provision(%Sandbox{} = observed, %Conversation{} = parent) do
    Repo.transaction(fn ->
      lock_machine(observed.id)
      current_parent = lock_parent(parent.id)
      sandbox = lock_sandbox(observed.id) || Repo.rollback(:not_found)
      creation = lock_creation(observed.id) || Repo.rollback(:provider_identity_missing)

      unless same_binding?(sandbox, observed) and creation_binding?(creation, sandbox) and
               parent.user_id == creation.user_id,
             do: Repo.rollback(:ownership_changed)

      unless usable_parent?(current_parent, sandbox, creation),
        do: Repo.rollback(:sandbox_retired)

      unless creation.state == "confirmed" and creation.holds_slot and
               is_binary(creation.provider_instance_id),
             do: Repo.rollback(:provider_identity_missing)

      if sandbox.provider_instance_id not in [nil, creation.provider_instance_id],
        do: Repo.rollback(:provider_identity_changed)

      changeset =
        sandbox
        |> Ecto.Changeset.change(provider_instance_id: creation.provider_instance_id)
        |> Ecto.Changeset.unique_constraint([:provider, :provider_instance_id])

      case Repo.update(changeset) do
        {:ok, bound} ->
          {:ok, ready} = Fountain.Conversations.update_sandbox(bound, %{status: "ready"})
          ready

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  @doc "Retire the logical machine and commit one deletion grant while admission is excluded."
  def _unsafe_submit_destroy(%Sandbox{} = observed, opts \\ []) do
    result =
      Repo.transaction(fn ->
        lock_machine(observed.id)

        parents =
          Repo.all(
            from c in Conversation,
              where: c.sandbox_id == ^observed.id,
              order_by: c.id,
              lock: "FOR UPDATE"
          )

        sandbox = lock_sandbox(observed.id)
        creation = lock_creation(observed.id) || Repo.rollback(:provider_identity_missing)

        unless creation_binding?(creation, observed) and
                 (is_nil(sandbox) or same_binding?(sandbox, observed)) and
                 Enum.all?(parents, &(&1.user_id == creation.user_id)),
               do: Repo.rollback(:ownership_changed)

        if creation.provider != "sprites" or creation.state != "confirmed" or
             is_nil(creation.provider_instance_id),
           do: Repo.rollback(:provider_identity_missing)

        existing =
          Repo.one(
            from o in SandboxOperation,
              where: o.sandbox_id == ^observed.id and o.action == "destroy",
              lock: "FOR UPDATE"
          )

        if existing do
          Repo.rollback(
            if(existing.state == "confirmed",
              do: :provider_already_destroyed,
              else: :provider_operation_fenced
            )
          )
        end

        # Ownership: locked parents and the creation claim above agree on this sandbox owner.
        if Fountain.Conversations._unsafe_running_turns_elsewhere(observed.id, nil) > 0 or
             Fountain.Conversations.ExecutionGuard._unsafe_sandbox_open?(observed.id),
           do: Repo.rollback(:sandbox_mid_turn)

        holder = Keyword.get(opts, :holder)

        if holder && Enum.any?(parents, &(&1.id != holder and &1.status not in @terminal)),
          do: Repo.rollback(:sandbox_held)

        operation =
          %SandboxOperation{}
          |> SandboxOperation.changeset(%{
            sandbox_id: creation.sandbox_id,
            user_id: creation.user_id,
            provider: creation.provider,
            sandbox_name: creation.sandbox_name,
            provider_instance_id: creation.provider_instance_id,
            creation_id: creation.id,
            action: "destroy",
            state: "submitted",
            submitted_at: DateTime.utc_now()
          })
          |> insert_operation!()

        if sandbox do
          {:ok, _} = Fountain.Conversations.update_sandbox(sandbox, %{status: "terminated"})
        end

        operation
      end)

    audit_result(result, "sandbox.operation_submitted")
  end

  @doc "Only a confirmed delete/absence result releases the physical reservation."
  def _unsafe_complete_destroy(operation_id, provider_result) do
    observed = Repo.get(SandboxOperation, operation_id)

    if observed && observed.action == "destroy" do
      result =
        Repo.transaction(fn ->
          lock_machine(observed.sandbox_id)
          operation = lock_operation(operation_id) || Repo.rollback(:not_found)
          creation = lock_operation(operation.creation_id) || Repo.rollback(:not_found)

          if operation.state not in ~w(submitted uncertain),
            do: Repo.rollback(:provider_operation_fenced)

          confirmed? = provider_result in [:ok, {:error, :not_found}]
          at = DateTime.utc_now()

          attrs =
            if confirmed?,
              do: %{state: "confirmed", confirmed_at: at},
              else: %{state: "uncertain"}

          recorded = operation |> SandboxOperation.changeset(attrs) |> Repo.update!()

          if confirmed? do
            creation |> SandboxOperation.changeset(%{holds_slot: false}) |> Repo.update!()
            record_destroyed_row(operation, at)
          end

          recorded
        end)

      case audit_result(result, "sandbox.operation_result") do
        {:ok, %{state: "confirmed"}} -> :ok
        {:ok, _} -> {:error, :provider_operation_uncertain}
        {:error, _} = error -> error
      end
    else
      {:error, :not_found}
    end
  end

  defp record_destroyed_row(operation, at) do
    case lock_sandbox(operation.sandbox_id) do
      %Sandbox{} = sandbox ->
        if creation_binding?(operation, sandbox) do
          status = if sandbox.status == "failed", do: "failed", else: "terminated"

          {:ok, _} =
            Fountain.Conversations.update_sandbox(sandbox, %{
              status: status,
              terminated_at: DateTime.truncate(at, :second)
            })
        end

      nil ->
        :ok
    end
  end

  defp destroy_once(operation) do
    handle = Managoat.Sandbox.build_handle(:sprites, operation.sandbox_name)
    # Instance ID records the creation claim; the provider still deletes by
    # name. The permanent name claim forbids another service create at this name.
    Managoat.Sandbox.destroy_once(%{handle | instance_id: operation.provider_instance_id})
  rescue
    _ -> {:error, :provider_operation_uncertain}
  catch
    :exit, _ -> {:error, :provider_operation_uncertain}
  end

  defp creation_binding?(operation, sandbox) do
    operation.user_id == sandbox.user_id and operation.provider == sandbox.provider and
      operation.sandbox_name == sandbox.sprite_name
  end

  defp insert_operation!(changeset) do
    case Repo.insert(changeset) do
      {:ok, operation} -> operation
      {:error, _} -> Repo.rollback(:provider_operation_fenced)
    end
  end

  defp lock_creation(sandbox_id) do
    Repo.one(
      from o in SandboxOperation,
        where: o.sandbox_id == ^sandbox_id and o.action == "create",
        lock: "FOR UPDATE"
    )
  end

  defp fresh_create(operation) do
    Managoat.Sandbox.create_new(:sprites, operation.sandbox_name)
  rescue
    _ -> {:error, :provider_operation_uncertain}
  catch
    :exit, _ -> {:error, :provider_operation_uncertain}
  end

  defp creation_outcome(operation, {:ok, %Handle{} = handle}) do
    if handle.provider == :sprites and handle.name == operation.sandbox_name and
         is_binary(handle.instance_id) and byte_size(handle.instance_id) in 1..256 do
      %{
        state: "confirmed",
        provider_instance_id: handle.instance_id,
        confirmed_at: DateTime.utc_now()
      }
    else
      %{state: "uncertain"}
    end
  end

  defp creation_outcome(_operation, {:error, :already_exists}),
    do: %{state: "refused", holds_slot: false}

  defp creation_outcome(_operation, {:error, {:invalid, _}}),
    do: %{state: "refused", holds_slot: false}

  defp creation_outcome(_operation, _result), do: %{state: "uncertain"}

  defp creation_reply(%{state: "confirmed"}, {:ok, handle}, true), do: {:ok, handle}
  defp creation_reply(%{state: "confirmed"}, _result, false), do: {:error, :sandbox_retired}

  defp creation_reply(%{state: "refused"}, _result, _usable),
    do: {:error, :provider_create_refused}

  defp creation_reply(_operation, _result, _usable), do: {:error, :provider_operation_uncertain}

  defp usable_parent?(%Conversation{} = parent, %Sandbox{} = sandbox, operation) do
    parent.user_id == operation.user_id and parent.sandbox_id == operation.sandbox_id and
      parent.status not in @terminal and sandbox.status in ~w(pending starting) and
      sandbox.user_id == operation.user_id and sandbox.provider == operation.provider and
      sandbox.sprite_name == operation.sandbox_name
  end

  defp usable_parent?(_, _, _), do: false

  defp same_binding?(current, observed) do
    current.user_id == observed.user_id and current.provider == observed.provider and
      current.sprite_name == observed.sprite_name
  end

  defp lock_machine(id),
    do: Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, :erlang.phash2(id)])

  defp lock_parent(id),
    do: Repo.one(from c in Conversation, where: c.id == ^id, lock: "FOR UPDATE")

  defp lock_sandbox(id),
    do: Repo.one(from s in Sandbox, where: s.id == ^id, lock: "FOR UPDATE")

  defp lock_operation(id),
    do: Repo.one(from o in SandboxOperation, where: o.id == ^id, lock: "FOR UPDATE")

  defp audit_result({:ok, operation} = result, action) do
    audit(operation, action)
    result
  end

  defp audit_result(error, _action), do: error

  defp audit(operation, action) do
    Audit.record(%{
      user_id: operation.user_id,
      resource_type: "sandbox",
      resource_id: operation.sandbox_id,
      actor: "system:sandbox_operations",
      action: action,
      metadata: %{"action" => operation.action, "state" => operation.state}
    })
  end
end
