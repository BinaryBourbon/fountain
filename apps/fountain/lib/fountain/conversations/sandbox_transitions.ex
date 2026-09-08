defmodule Fountain.Conversations.SandboxTransitions do
  @moduledoc """
  Managed park/resume grants, serialized with turn admission and cleanup.

  The provider phase runs after the grant commits. Uncertainty retains the
  fence and capacity; no restart grants another attempt. Sprites parking is
  logical only and does not prove stopped compute or billing.
  """
  import Ecto.Query

  alias Fountain.{Audit, Conversations, Repo}
  alias Fountain.Conversations.{Conversation, ExecutionGuard, Sandbox, SandboxOperation}
  alias Fountain.Conversations.{HomeCheckpoint, SandboxOperations}

  @terminal ~w(terminated failed)
  @generation "lifecycle_operation_id"

  def _unsafe_park_current?(sandbox_id, operation_id) do
    case Repo.get(Sandbox, sandbox_id) do
      %Sandbox{status: "suspended", provider_meta: %{@generation => ^operation_id}} -> true
      _ -> false
    end
  end

  def _unsafe_pending?(sandbox_id) do
    Repo.exists?(
      from o in SandboxOperation,
        where: o.sandbox_id == ^sandbox_id and o.state in ~w(submitted uncertain)
    )
  end

  def _unsafe_park(sandbox, reason, timeout \\ 35_000) when timeout in 1..35_000 do
    with :ok <- outside_transaction(),
         {:ok, operation} <- _unsafe_submit(sandbox, "park") do
      result = provider_phase(fn -> park_provider(sandbox, operation) end, timeout)
      _unsafe_complete(operation.id, result, reason)
    end
  end

  @doc "A managed ready row must still name the same physical instance before reuse."
  def _unsafe_verify_ready(sandbox) do
    with :ok <- outside_transaction(),
         {:ok, creation} <- verify_ready_binding(sandbox),
         result <- provider_phase(fn -> resume_provider(creation) end),
         true <-
           successful?(
             %{action: "resume", provider_instance_id: creation.provider_instance_id},
             result
           ),
         {:ok, _} <- verify_ready_binding(sandbox) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :sprite_probe_failed}
    end
  end

  defp verify_ready_binding(observed) do
    Repo.transaction(fn ->
      lock_machine(observed.id)
      creation = lock_creation(observed.id) || Repo.rollback(:provider_identity_missing)
      sandbox = lock_sandbox(observed.id) || Repo.rollback(:not_found)
      assert_binding!(creation, sandbox)

      if sandbox.status != "ready" or sandbox.user_id != observed.user_id or
           sandbox.provider_instance_id != observed.provider_instance_id or
           sandbox.provider_meta[@generation] != observed.provider_meta[@generation] or
           _unsafe_pending?(sandbox.id),
         do: Repo.rollback(:provider_operation_fenced)

      creation
    end)
  end

  def _unsafe_resume(sandbox) do
    with :ok <- outside_transaction(),
         {:ok, operation} <- _unsafe_submit(sandbox, "resume") do
      result = provider_phase(fn -> resume_provider(operation) end)
      _unsafe_complete(operation.id, result, :wake)
    end
  end

  @doc "Reserve a transition and close admission before any provider request."
  def _unsafe_submit(%Sandbox{} = observed, action) when action in ~w(park resume) do
    Repo.transaction(fn ->
      lock_machine(observed.id)
      parents = lock_parents(observed.id)
      creation = lock_creation(observed.id) || Repo.rollback(:provider_identity_missing)
      sandbox = lock_sandbox(observed.id) || Repo.rollback(:not_found)
      assert_binding!(creation, sandbox)

      if observed.user_id != sandbox.user_id or observed.sprite_name != sandbox.sprite_name or
           observed.provider != sandbox.provider or
           observed.provider_instance_id != sandbox.provider_instance_id,
         do: Repo.rollback(:ownership_changed)

      expected = if action == "park", do: "ready", else: "suspended"
      if sandbox.status != expected, do: Repo.rollback(:sandbox_not_ready)
      assert_idle!(sandbox.id, parents, sandbox.user_id)
      if _unsafe_pending?(sandbox.id), do: Repo.rollback(:provider_operation_fenced)

      attrs = %{
        sandbox_id: sandbox.id,
        user_id: sandbox.user_id,
        provider: sandbox.provider,
        sandbox_name: sandbox.sprite_name,
        provider_instance_id: creation.provider_instance_id,
        creation_id: creation.id,
        action: action,
        state: "submitted",
        submitted_at: DateTime.utc_now()
      }

      operation =
        case Repo.insert(SandboxOperation.changeset(%SandboxOperation{}, attrs)) do
          {:ok, operation} -> operation
          {:error, _} -> Repo.rollback(:provider_operation_fenced)
        end

      {:ok, _} =
        Conversations.update_sandbox(sandbox, %{
          status: "suspended",
          provider_meta: Map.put(sandbox.provider_meta || %{}, @generation, operation.id)
        })

      audit(operation)
      operation
    end)
  end

  @doc "Apply only the causal result of the still-owned, unretired transition."
  def _unsafe_complete(operation_id, result, reason) do
    observed = Repo.get(SandboxOperation, operation_id)

    if observed && observed.action in ~w(park resume) do
      complete(observed, result, reason)
    else
      {:error, :not_found}
    end
  end

  defp complete(observed, result, reason) do
    if successful?(observed, result) do
      Repo.transaction(fn ->
        lock_machine(observed.sandbox_id)
        parents = lock_parents(observed.sandbox_id)

        operation =
          Repo.one(from o in SandboxOperation, where: o.id == ^observed.id, lock: "FOR UPDATE")

        creation = lock_creation(observed.sandbox_id) || Repo.rollback(:not_found)
        sandbox = lock_sandbox(observed.sandbox_id) || Repo.rollback(:not_found)
        assert_binding!(creation, sandbox)
        assert_idle!(sandbox.id, parents, sandbox.user_id)

        unless (operation && operation.state in ~w(submitted uncertain)) and
                 operation.creation_id == creation.id and
                 operation.user_id == creation.user_id and
                 operation.provider == creation.provider and
                 operation.sandbox_name == creation.sandbox_name and
                 operation.provider_instance_id == creation.provider_instance_id and
                 sandbox.status == "suspended" and
                 sandbox.provider_meta[@generation] == operation.id,
               do: Repo.rollback(:provider_operation_fenced)

        {:ok, sandbox} =
          Conversations.update_sandbox(sandbox, completion_attrs(operation, sandbox, result))

        operation
        |> SandboxOperation.changeset(%{state: "confirmed", confirmed_at: DateTime.utc_now()})
        |> Repo.update!()

        if operation.action == "park", do: record_park(parents, operation, reason)
        audit(%{operation | state: "confirmed"})
        sandbox
      end)
    else
      # ownership: this is the durable operation read above, never a request-supplied owner.
      SandboxOperations._unsafe_mark_uncertain(observed.id)
      {:error, :provider_operation_uncertain}
    end
  end

  defp successful?(%{action: "park"}, {:ok, checkpoint}),
    do: checkpoint == :skipped or is_binary(checkpoint)

  defp successful?(%{action: "resume", provider_instance_id: id}, {:ok, %{raw: %{"id" => id}}}),
    do: true

  defp successful?(_, _), do: false

  defp completion_attrs(%{action: "resume"}, _sandbox, _result),
    do: %{status: "ready", last_resumed_at: DateTime.truncate(DateTime.utc_now(), :second)}

  defp completion_attrs(_operation, sandbox, {:ok, checkpoint}) do
    meta =
      if is_binary(checkpoint),
        do:
          Map.merge(sandbox.provider_meta, %{
            "checkpoint_id" => checkpoint,
            "checkpoint_at" => DateTime.to_iso8601(DateTime.utc_now())
          }),
        else: sandbox.provider_meta

    %{status: "suspended", provider_meta: meta}
  end

  defp park_provider(sandbox, operation) do
    # Sprites suspend is a no-op. A home checkpoint still needs its one grant;
    # it cannot publish metadata before the transition's ownership recheck.
    checkpoint = HomeCheckpoint.capture_once(sandbox, handle(operation), operation.id)

    case Managoat.Sandbox.suspend(handle(operation)) do
      :ok -> {:ok, checkpoint}
      _ -> {:error, :provider_operation_uncertain}
    end
  end

  defp resume_provider(operation), do: Managoat.Sandbox.get(handle(operation))

  defp handle(operation) do
    handle = Managoat.Sandbox.build_handle(:sprites, operation.sandbox_name)
    %{handle | instance_id: operation.provider_instance_id}
  end

  defp outside_transaction do
    if Repo.in_transaction?(), do: {:error, :provider_transaction_open}, else: :ok
  end

  defp provider_phase(fun, timeout \\ 35_000) do
    task =
      Task.Supervisor.async_nolink(Fountain.TaskSupervisor, fn ->
        {:ok, timer} = :timer.kill_after(timeout)

        try do
          fun.()
        rescue
          _ -> {:error, :provider_operation_uncertain}
        catch
          _, _ -> {:error, :provider_operation_uncertain}
        after
          :timer.cancel(timer)
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :provider_operation_uncertain}
    end
  catch
    _, _ -> {:error, :provider_operation_uncertain}
  end

  defp assert_binding!(creation, sandbox) do
    unless creation.state == "confirmed" and creation.holds_slot and
             sandbox.user_id == creation.user_id and sandbox.provider == "sprites" and
             sandbox.sprite_name == creation.sandbox_name and
             is_binary(creation.provider_instance_id) and
             sandbox.provider_instance_id == creation.provider_instance_id and
             Repo.exists?(from u in Fountain.Accounts.User, where: u.id == ^creation.user_id),
           do: Repo.rollback(:ownership_changed)
  end

  defp assert_idle!(sandbox_id, parents, user_id) do
    unless Enum.all?(parents, &(&1.user_id == user_id)), do: Repo.rollback(:ownership_changed)

    # ownership: locked parents and the confirmed creation bind this machine to user_id.
    if Conversations._unsafe_running_turns_elsewhere(sandbox_id, nil) > 0 or
         ExecutionGuard._unsafe_sandbox_open?(sandbox_id),
       do: Repo.rollback(:sandbox_mid_turn)
  end

  defp record_park(parents, operation, reason) do
    Enum.each(parents, fn parent ->
      if parent.status not in @terminal do
        if parent.status == "running",
          do: parent |> Conversation.changeset(%{status: "idle"}) |> Repo.update!()

        event =
          Conversations.log!(%{
            conversation_id: parent.id,
            kind: "stage",
            stage: "sandbox",
            state: "done",
            data:
              Jason.encode!(%{
                event: "suspended",
                reason: to_string(reason),
                operation_id: operation.id,
                message: "Sandbox parked; its disk is retained."
              })
          })

        Fountain.Webhooks.dispatch_stage!(event)
        # This existing stage-delivery worker accepts any persisted stage and
        # rechecks its historical owner. Both jobs commit with the event.
        %{"event_id" => event.id, "conversation_id" => parent.id, "user_id" => parent.user_id}
        |> Fountain.Workers.TurnDeadlineNotification.new()
        |> Oban.insert!()
      end
    end)
  end

  defp lock_machine(id),
    do: Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, :erlang.phash2(id)])

  defp lock_parents(id),
    do:
      Repo.all(
        from c in Conversation, where: c.sandbox_id == ^id, order_by: c.id, lock: "FOR UPDATE"
      )

  defp lock_creation(id),
    do:
      Repo.one(
        from o in SandboxOperation,
          where: o.sandbox_id == ^id and o.action == "create",
          lock: "FOR UPDATE"
      )

  defp lock_sandbox(id),
    do: Repo.one(from s in Sandbox, where: s.id == ^id, lock: "FOR UPDATE")

  defp audit(operation) do
    Audit.record(%{
      user_id: operation.user_id,
      resource_type: "sandbox",
      resource_id: operation.sandbox_id,
      actor: "system:sandbox_transitions",
      action: "sandbox.operation_result",
      metadata: %{"action" => operation.action, "state" => operation.state}
    })
  end
end
