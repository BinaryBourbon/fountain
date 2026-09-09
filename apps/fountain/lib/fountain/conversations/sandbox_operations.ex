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

  @doc "Bounded recovery of abandoned submissions; no provider call or reservation release."
  def _unsafe_recover_submissions(cutoff, limit \\ 100) when limit in 1..100 do
    from(o in SandboxOperation,
      where: o.state == "submitted" and o.submitted_at < ^cutoff,
      order_by: [asc: o.submitted_at, asc: o.id],
      limit: ^limit,
      select: o.id
    )
    |> Repo.all()
    |> Enum.count(fn id -> match?({:ok, _}, _unsafe_mark_uncertain(id)) end)
  end

  @doc "Read bounded cleanup candidates; the operation claim rechecks authority before I/O."
  def _unsafe_recovery_candidates(cutoff, limit \\ 100) when limit in 1..100 do
    live_holders =
      from p in Conversation,
        where: p.sandbox_id == parent_as(:creation).sandbox_id and p.status not in @terminal

    deletes =
      from d in SandboxOperation,
        where: d.creation_id == parent_as(:creation).id and d.action == "destroy"

    creations =
      from c in SandboxOperation,
        as: :creation,
        left_join: s in Sandbox,
        on: s.id == c.sandbox_id,
        left_join: u in Fountain.Accounts.User,
        on: u.id == c.user_id,
        where: c.action == "create" and c.state == "confirmed" and c.holds_slot,
        where: is_nil(c.recovery_checked_at) or c.recovery_checked_at < ^cutoff,
        where:
          is_nil(s.id) or s.status in @terminal or is_nil(u.id) or
            (s.mode == "ephemeral" and not exists(subquery(live_holders))),
        where: not exists(subquery(deletes)),
        order_by: [asc_nulls_first: c.recovery_checked_at, asc: c.id],
        limit: ^limit,
        select: c.id

    uncertain_deletes =
      from d in SandboxOperation,
        where: d.action == "destroy" and d.state == "uncertain",
        where: is_nil(d.recovery_checked_at) or d.recovery_checked_at < ^cutoff,
        order_by: [asc_nulls_first: d.recovery_checked_at, asc: d.id],
        limit: ^limit,
        select: d.id

    %{cleanup: Repo.all(creations), reconcile: Repo.all(uncertain_deletes)}
  end

  @doc "Clean up a confirmed creation only after its machine or final ephemeral holder retires."
  def _unsafe_recover_creation(id, cutoff) do
    with {:ok, creation} <- claim_recovery(id, "create", "confirmed", cutoff) do
      observed = %Sandbox{
        id: creation.sandbox_id,
        user_id: creation.user_id,
        provider: creation.provider,
        sprite_name: creation.sandbox_name,
        provider_instance_id: creation.provider_instance_id
      }

      _unsafe_destroy(observed, recovery: true)
    end
  end

  @doc "Observe an uncertain deletion without another write; never probe an uncertain create."
  def _unsafe_reconcile_destroy(id, cutoff, probe \\ &Managoat.Sandbox.get/1) do
    with {:ok, operation} <- claim_recovery(id, "destroy", "uncertain", cutoff),
         :ok <- check_recovery_binding(operation) do
      handle = Managoat.Sandbox.build_handle(:sprites, operation.sandbox_name)
      result = probe.(%{handle | instance_id: operation.provider_instance_id})

      # Probe success/presence, a timeout, and provider prose establish nothing.
      if result == {:error, :not_found},
        do: _unsafe_complete_destroy(operation.id, result),
        else: {:error, :provider_operation_uncertain}
    end
  rescue
    _ -> {:error, :provider_operation_uncertain}
  catch
    _, _ -> {:error, :provider_operation_uncertain}
  end

  defp claim_recovery(id, action, state, cutoff) do
    Repo.transaction(fn ->
      operation = lock_operation(id) || Repo.rollback(:not_found)

      unless operation.action == action and operation.state == state,
        do: Repo.rollback(:provider_operation_fenced)

      if operation.recovery_checked_at &&
           DateTime.compare(operation.recovery_checked_at, cutoff) != :lt,
         do: Repo.rollback(:recovery_throttled)

      operation
      |> SandboxOperation.changeset(%{recovery_checked_at: DateTime.utc_now()})
      |> Repo.update!()
    end)
  end

  defp check_recovery_binding(observed) do
    case Repo.transaction(fn ->
           lock_machine(observed.sandbox_id)
           operation = lock_operation(observed.id) || Repo.rollback(:not_found)
           creation = lock_creation(observed.sandbox_id) || Repo.rollback(:not_found)
           sandbox = lock_sandbox(observed.sandbox_id)

           unless operation.state == "uncertain" and operation.provider == "sprites" and
                    deletion_binding?(operation, creation) and creation.holds_slot and
                    (is_nil(sandbox) or retained_binding?(creation, sandbox)),
                  do: Repo.rollback(:ownership_changed)
         end) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc "Query retained create and legacy-resume reservations, including deleted parents."
  def _unsafe_reserved_slots do
    from operation in SandboxOperation,
      where: operation.holds_slot,
      select: %{id: operation.sandbox_id, user_id: operation.user_id}
  end

  @doc "Whether this physical sandbox has entered the durable lifecycle."
  def _unsafe_managed?(sandbox_id) do
    Repo.exists?(
      from operation in SandboxOperation,
        where: operation.sandbox_id == ^sandbox_id and operation.action == "create"
    )
  end

  @doc "Reject ambiguous logical aliases or another machine's permanent physical name claim."
  def _unsafe_name_conflict?(sandbox) do
    Repo.exists?(
      from s in Sandbox,
        where:
          s.id != ^sandbox.id and
            s.provider == ^sandbox.provider and s.sprite_name == ^sandbox.sprite_name
    ) ||
      Repo.exists?(
        from o in SandboxOperation,
          where:
            o.sandbox_id != ^sandbox.id and
              o.provider == ^sandbox.provider and o.sandbox_name == ^sandbox.sprite_name and
              (o.action == "create" or not is_nil(o.delete_deadline_at))
      )
  end

  @doc "Logical retirement cannot release a retained provider reservation."
  def _unsafe_holds_slot?(sandbox_id) do
    Repo.exists?(
      from operation in SandboxOperation,
        where: operation.sandbox_id == ^sandbox_id and operation.holds_slot
    )
  end

  def _unsafe_destroy(%Sandbox{} = sandbox, opts \\ []) do
    case _unsafe_submit_destroy(sandbox, opts) do
      {:ok, operation} -> _unsafe_complete_destroy(operation.id, destroy_once(operation))
      {:error, :provider_already_destroyed} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc "Reclaim at a current lifecycle bound, with provider I/O only after the grant commits."
  def _unsafe_destroy_at_bound(sandbox, reason) when reason in [:idle, :max_lifetime] do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      submission = _unsafe_submit_destroy_at_bound(sandbox, reason)

      with {:ok, operation} <- audit_result(submission, "sandbox.operation_submitted"),
           do: _unsafe_complete_destroy(operation.id, destroy_once(operation))
    end
  end

  @doc "Route owned cleanup through its existing journal; never downgrade a managed claim."
  def _unsafe_destroy_or_legacy(%Sandbox{} = sandbox, handle, opts \\ []) do
    cond do
      Fountain.Conversations.ActorStartups.unfinished?(sandbox.id) ->
        {:error, :startup_unresolved}

      _unsafe_managed?(sandbox.id) ->
        _unsafe_destroy(sandbox, opts)

      # ownership: the cleanup caller supplies its owned sandbox; an unresolved operation blocks it.
      Fountain.Conversations.SandboxTransitions._unsafe_pending?(sandbox.id) ->
        {:error, :provider_operation_fenced}

      true ->
        Fountain.Conversations.LegacyDeletion.destroy(sandbox, handle, opts)
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
  def _unsafe_submit_destroy(observed, opts \\ []) do
    observed
    |> submit_destroy(opts, nil)
    |> audit_result("sandbox.operation_submitted")
  end

  @doc "Reserve bound-driven deletion using current policy, run clock and machine mode."
  def _unsafe_submit_destroy_at_bound(observed, reason) when reason in [:idle, :max_lifetime],
    do: submit_destroy(observed, [], reason)

  defp submit_destroy(%Sandbox{} = observed, opts, reason) do
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

      unless retained_binding?(creation, observed) and
               (is_nil(sandbox) or retained_binding?(creation, sandbox)) and
               Enum.all?(parents, &retained_owner?(creation, &1.user_id)),
             do: Repo.rollback(:ownership_changed)

      if creation.provider != "sprites" or creation.state != "confirmed" or
           is_nil(creation.provider_instance_id),
         do: Repo.rollback(:provider_identity_missing)

      if Keyword.get(opts, :recovery, false) and not cleanup_due?(creation, sandbox, parents),
        do: Repo.rollback(:sandbox_held)

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

      now = DateTime.utc_now()
      if reason, do: assert_destroy_bound!(sandbox, parents, reason, now)

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
          submitted_at: now
        })
        |> insert_operation!()

      if sandbox do
        retire_row(sandbox, nil)
      end

      operation
    end)
  end

  defp assert_destroy_bound!(nil, _parents, _reason, _now),
    do: Repo.rollback(:sandbox_not_ready)

  defp assert_destroy_bound!(sandbox, parents, reason, now) do
    if sandbox.status != "ready", do: Repo.rollback(:sandbox_not_ready)

    # Ownership: submit_destroy locked this machine and its current tenant-owned parents.
    if Fountain.Conversations.SandboxActivity._unsafe_check(sandbox, parents, now) !=
         {:expired, reason},
       do: Repo.rollback(:lifecycle_bound_not_reached)

    if Fountain.Conversations.SandboxActivity.managed_action(sandbox, reason) != :destroy,
      do: Repo.rollback(:lifecycle_action_changed)
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
          sandbox = lock_sandbox(operation.sandbox_id)

          unless deletion_binding?(operation, creation) and
                   (is_nil(sandbox) or retained_binding?(creation, sandbox)),
                 do: Repo.rollback(:ownership_changed)

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
        if retained_binding?(operation, sandbox), do: retire_row(sandbox, at)

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

  # A deleted account's retained identity still owns its cleanup obligation.
  # Nil never matches an extant account, a different tenant, or another machine.
  defp retained_owner?(operation, user_id) do
    user_id == operation.user_id or
      (is_nil(user_id) and
         not Repo.exists?(
           from u in Fountain.Accounts.User,
             where: u.id == ^operation.user_id
         ))
  end

  defp retained_binding?(operation, sandbox) do
    retained_owner?(operation, sandbox.user_id) and operation.provider == sandbox.provider and
      operation.sandbox_name == sandbox.sprite_name and
      sandbox.provider_instance_id in [nil, operation.provider_instance_id]
  end

  defp deletion_binding?(operation, creation) do
    creation.action == "create" and creation.state == "confirmed" and
      operation.creation_id == creation.id and
      operation.sandbox_id == creation.sandbox_id and operation.user_id == creation.user_id and
      operation.provider == creation.provider and operation.sandbox_name == creation.sandbox_name and
      operation.provider_instance_id == creation.provider_instance_id and
      not is_nil(creation.provider_instance_id)
  end

  defp cleanup_due?(creation, sandbox, parents) do
    is_nil(sandbox) or sandbox.status in @terminal or
      not Repo.exists?(from u in Fountain.Accounts.User, where: u.id == ^creation.user_id) or
      (sandbox.mode == "ephemeral" and Enum.all?(parents, &(&1.status in @terminal)))
  end

  defp retire_row(sandbox, at) do
    attrs = %{
      status: if(sandbox.status == "failed", do: "failed", else: "terminated"),
      terminated_at: if(at, do: DateTime.truncate(at, :second))
    }

    if is_nil(sandbox.user_id) do
      # The retained binding above proved account deletion. The general
      # changeset requires a live user; this narrow historical write cannot revive it.
      sandbox |> Ecto.Changeset.change(attrs) |> Repo.update!()
    else
      {:ok, retired} = Fountain.Conversations.update_sandbox(sandbox, attrs)
      retired
    end
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
