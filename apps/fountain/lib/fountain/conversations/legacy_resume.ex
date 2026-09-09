defmodule Fountain.Conversations.LegacyResume do
  @moduledoc "Journal an existing legacy machine's resume without adopting it as a managed create."
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

  def resume(context, observed) do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      with {:ok, operation} <- submit(context, observed) do
        handle =
          Managoat.Sandbox.build_handle(
            Conversations.sandbox_provider_atom(observed),
            operation.sandbox_name
          )

        handle = %{handle | instance_id: operation.provider_instance_id}
        complete(operation, WakeContext.run(context, fn -> Managoat.Sandbox.resume(handle) end))
      end
    end
  end

  def submit(context, observed) do
    Fountain.Quotas.with_sandbox_reservation(context.user_id, [exclude: observed.id], fn ->
      lock_machine(observed.id)
      WakeContext.assert_locked!(context)
      sandbox = Repo.one(from s in Sandbox, where: s.id == ^observed.id, lock: "FOR UPDATE")
      WakeContext.assert_machine!(context, observed, sandbox)
      unless sandbox.status == "suspended", do: Repo.rollback(:sandbox_not_ready)
      # ownership: wake authority and the locked physical snapshot retain this user's machine.
      if SandboxOperations._unsafe_managed?(sandbox.id) ||
           Conversations.SandboxTransitions._unsafe_pending?(sandbox.id),
         do: Repo.rollback(:provider_operation_fenced)

      # ownership: the locked parent and machine still match the original wake.
      if Conversations.ExecutionGuard._unsafe_sandbox_open?(sandbox.id),
        do: Repo.rollback(:sandbox_mid_turn)

      with :ok <- Fountain.Accounts.check_not_suspended(context.user_id),
           :ok <- Fountain.Billing.check_spend(context.user_id) do
        WakeContext.assert_locked!(context)

        attrs =
          Map.merge(WakeContext.operation_attrs(context), %{
            sandbox_id: sandbox.id,
            user_id: context.user_id,
            provider: sandbox.provider,
            sandbox_name: sandbox.sprite_name,
            provider_instance_id: sandbox.provider_instance_id,
            action: "resume",
            state: "submitted",
            holds_slot: true,
            submitted_at: DateTime.utc_now()
          })

        case Repo.insert(SandboxOperation.changeset(%SandboxOperation{}, attrs)) do
          {:ok, operation} ->
            {:ok, _} =
              Conversations.update_sandbox(sandbox, %{
                provider_meta:
                  Map.put(sandbox.provider_meta || %{}, "lifecycle_operation_id", operation.id)
              })

            {:ok, operation}

          {:error, _} ->
            {:error, :provider_operation_fenced}
        end
      end
    end)
  end

  @doc "A causal return can record readiness; uncertainty retains its slot and blocks another resume."
  def complete(supplied, result) do
    observed = Repo.get!(SandboxOperation, supplied.id)

    Repo.transaction(fn ->
      lock_machine(observed.sandbox_id)

      parent =
        Repo.one(
          from c in Conversation, where: c.id == ^observed.conversation_id, lock: "FOR UPDATE"
        )

      sandbox =
        Repo.one(from s in Sandbox, where: s.id == ^observed.sandbox_id, lock: "FOR UPDATE")

      operation =
        Repo.one!(from o in SandboxOperation, where: o.id == ^observed.id, lock: "FOR UPDATE")

      unless operation.action == "resume" && is_nil(operation.creation_id) &&
               operation.state in ~w(submitted uncertain),
             do: Repo.rollback(:provider_operation_fenced)

      cond do
        match?({:not_started, _}, result) ->
          operation
          |> SandboxOperation.changeset(%{state: "refused", holds_slot: false})
          |> Repo.update!()

          {:error, elem(result, 1)}

        successful?(operation, result) && owned?(parent, sandbox, operation) ->
          {:ok, ready} =
            Conversations.update_sandbox(sandbox, %{
              status: "ready",
              last_resumed_at: DateTime.truncate(DateTime.utc_now(), :second)
            })

          operation
          |> SandboxOperation.changeset(%{
            state: "confirmed",
            holds_slot: false,
            confirmed_at: DateTime.utc_now()
          })
          |> Repo.update!()

          {:ok, ready}

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

  defp successful?(operation, {:returned, {:ok, %Handle{} = handle}}),
    do:
      Atom.to_string(handle.provider) == operation.provider &&
        handle.name == operation.sandbox_name &&
        (is_nil(operation.provider_instance_id) ||
           handle.instance_id == operation.provider_instance_id)

  defp successful?(_, _), do: false

  defp owned?(parent, sandbox, operation),
    do:
      parent && sandbox &&
        parent.id == operation.conversation_id && sandbox.id == operation.sandbox_id &&
        parent.user_id == operation.user_id && parent.sandbox_id == sandbox.id &&
        parent.status not in ~w(terminated failed) && sandbox.user_id == operation.user_id &&
        sandbox.provider == operation.provider && sandbox.sprite_name == operation.sandbox_name &&
        sandbox.provider_instance_id == operation.provider_instance_id &&
        sandbox.status == "suspended" &&
        sandbox.provider_meta["lifecycle_operation_id"] == operation.id

  defp lock_machine(id),
    do: Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, :erlang.phash2(id)])
end
