defmodule Fountain.Conversations.ActorLaunches do
  @moduledoc """
  Commit actor startup requests before calling Horde.

  Fresh creation and replacement reserve their machines atomically with launch.
  Reconnect requests authorize only an existing ready machine. Each request is
  acknowledged with its actor claim; redelivery cannot grant another provider
  attempt. Original creation ancestry remains immutable across reconnects.
  Suspended-provider wake and abandoned-actor reconciliation remain separate
  integration work. This module never adopts or deletes a provider resource.
  """
  import Ecto.Query
  alias Fountain.{Conversations, Repo}

  alias Fountain.Conversations.{
    ActorLaunch,
    Conversation,
    ConversationServer,
    PromptDelivery,
    PromptReceipt,
    Sandbox
  }

  def create(user_id, sandbox_attrs, parent_attrs, opening_attrs) do
    if sandbox_attrs.user_id != user_id or parent_attrs.user_id != user_id do
      {:error, :ownership_changed}
    else
      Fountain.Quotas.with_sandbox_reservation(user_id, fn ->
        with {:ok, sandbox} <- Conversations.create_sandbox(sandbox_attrs),
             {:ok, parent} <-
               Conversations.create_conversation(Map.put(parent_attrs, :sandbox_id, sandbox.id)),
             {:ok, receipt} <- PromptDelivery.save_initial(user_id, parent.id, opening_attrs) do
          launch = save!(parent, sandbox, receipt)
          {:ok, {sandbox, parent, launch}}
        end
      end)
    end
  end

  @doc "Commit replacement binding and launch before any actor can observe the new machine."
  def replace(observed, source_snapshot, sandbox_attrs, receipt_id \\ nil) do
    result =
      Fountain.Quotas.with_sandbox_reservation(
        observed.user_id,
        [exclude: observed.sandbox_id],
        fn ->
          # Ownership: wake loaded the parent for this tenant; holder arbitration
          # rechecks the original binding and the source snapshot under locks.
          with {:ok, {sandbox, parent}} <-
                 Conversations.SandboxHolders._unsafe_create_replacement(
                   observed,
                   source_snapshot,
                   sandbox_attrs
                 ) do
            receipt = opening_receipt!(parent, receipt_id)
            launch = save!(parent, sandbox, receipt, observed.sandbox_id, "replace")
            {:ok, {sandbox, parent, launch}}
          end
        end
      )

    case result do
      {:error, _} = error -> replacement_winner(observed) || error
      success -> success
    end
  end

  @doc "Save a reconnect request for the observed ready machine, without reserving compute."
  def reconnect(observed, machine, receipt_id \\ nil) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, :erlang.phash2(machine.id)])

      parent = Repo.one(from c in Conversation, where: c.id == ^observed.id, lock: "FOR UPDATE")
      sandbox = Repo.one(from s in Sandbox, where: s.id == ^machine.id, lock: "FOR UPDATE")

      unless parent && sandbox && parent.user_id == observed.user_id &&
               parent.runtime == observed.runtime && parent.sandbox_id == observed.sandbox_id &&
               parent.sandbox_id == sandbox.id && sandbox.user_id == parent.user_id &&
               parent.status not in ~w(terminated failed) && sandbox.status == "ready" &&
               sandbox.provider == machine.provider && sandbox.sprite_name == machine.sprite_name &&
               sandbox.provider_instance_id == machine.provider_instance_id &&
               sandbox.provider_meta == machine.provider_meta,
             do: Repo.rollback(:ownership_changed)

      # Ownership: the locked parent and machine belong to the observed tenant.
      if Conversations.SandboxTransitions._unsafe_pending?(sandbox.id),
        do: Repo.rollback(:provider_operation_fenced)

      receipt = opening_receipt!(parent, receipt_id)

      pending =
        Repo.one(
          from l in ActorLaunch,
            where: l.conversation_id == ^parent.id and l.state == "requested",
            lock: "FOR UPDATE"
        )

      launch =
        if pending do
          assert_binding!(pending, parent, sandbox)
          unless pending.kind == "reconnect", do: Repo.rollback(:launch_unavailable)
          pending
        else
          save!(parent, sandbox, receipt, nil, "reconnect")
        end

      {parent, launch}
    end)
  end

  # A losing caller may hit the quota gate after the winner consumes the last
  # slot. Reuse only a launch that explicitly names this same original binding.
  defp replacement_winner(observed) do
    from(l in ActorLaunch,
      join: c in Conversation,
      on: c.id == l.conversation_id and c.sandbox_id == l.sandbox_id,
      join: s in Sandbox,
      on: s.id == l.sandbox_id,
      where:
        c.id == ^observed.id and c.user_id == ^observed.user_id and
          l.user_id == ^observed.user_id and s.user_id == ^observed.user_id and
          fragment(
            "? IS NOT DISTINCT FROM ?",
            l.source_sandbox_id,
            type(^observed.sandbox_id, :binary_id)
          ) and l.kind == "replace" and l.runtime == ^observed.runtime and
          c.runtime == ^observed.runtime and l.state in ["requested", "acknowledged"] and
          c.status not in ["terminated", "failed"] and
          s.status in ["pending", "starting", "ready", "suspended"],
      select: {s, c, l}
    )
    |> Repo.one()
    |> case do
      nil -> nil
      winner -> {:ok, winner}
    end
  end

  defp opening_receipt!(parent, nil), do: PromptDelivery.queued(parent.user_id, parent.id)

  defp opening_receipt!(parent, receipt_id) do
    receipt =
      Repo.one(
        from r in PromptReceipt,
          where:
            r.id == ^receipt_id and r.user_id == ^parent.user_id and
              r.conversation_id == ^parent.id,
          lock: "FOR UPDATE"
      )

    unless receipt && receipt.state == "queued", do: Repo.rollback(:opening_cancelled)
    receipt
  end

  defp save!(parent, sandbox, receipt, source_id \\ nil, kind \\ "create") do
    # All callers hold the parent lock. A previous unresolved request needs its
    # own outcome, not an exception from the unique index or a second launch.
    if Repo.exists?(
         from l in ActorLaunch,
           where: l.conversation_id == ^parent.id and l.state == "requested"
       ),
       do: Repo.rollback(:launch_unavailable)

    deadline = DateTime.add(DateTime.utc_now(), launch_timeout_ms(), :millisecond)

    deadline =
      if receipt && DateTime.compare(receipt.delivery_deadline_at, deadline) == :lt,
        do: receipt.delivery_deadline_at,
        else: deadline

    if receipt && (receipt.state != "queued" or PromptDelivery.expired?(receipt)),
      do: Repo.rollback(:delivery_expired)

    launch =
      Repo.insert!(%ActorLaunch{
        user_id: parent.user_id,
        conversation_id: parent.id,
        sandbox_id: sandbox.id,
        source_sandbox_id: source_id,
        kind: kind,
        reconnect_identity: if(kind == "reconnect", do: reconnect_identity(sandbox)),
        runtime: parent.runtime,
        opening_receipt_id: receipt && receipt.id,
        deadline_at: deadline
      })

    enqueue(launch)
    launch
  end

  def enqueue(launch) do
    %{
      "launch_id" => launch.id,
      "conversation_id" => launch.conversation_id,
      "user_id" => launch.user_id
    }
    |> Fountain.Workers.ActorLaunchDispatch.new()
    |> Oban.insert!()
  end

  def fetch(user_id, conversation_id, launch_id),
    do:
      Repo.get_by(ActorLaunch, id: launch_id, user_id: user_id, conversation_id: conversation_id)

  def deliver(user_id, conversation_id, launch_id),
    do: deliver(user_id, conversation_id, launch_id, false)

  @doc "Start after acceptance, preserving a synchronous startup refusal for API callers."
  def start(user_id, conversation_id, launch_id),
    do: deliver(user_id, conversation_id, launch_id, true)

  defp deliver(user_id, conversation_id, launch_id, return_failure?) do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      case fetch(user_id, conversation_id, launch_id) do
        %ActorLaunch{state: "requested"} = launch -> deliver_requested(launch, return_failure?)
        _ -> :ok
      end
    end
  end

  defp deliver_requested(launch, return_failure?) do
    result =
      case eligible(launch) do
        {:ok, parent} ->
          with :ok <- admission(parent),
               {:ok, runtime} <- Fountain.RuntimeDispatch.for_agent(parent) do
            case Horde.DynamicSupervisor.start_child(
                   Fountain.ConversationSupervisor,
                   {ConversationServer,
                    [
                      conversation_id: parent.id,
                      sandbox_id: launch.sandbox_id,
                      runtime_module: runtime,
                      launch_id: launch.id
                    ]}
                 ) do
              {:ok, pid} ->
                PromptDelivery.notify_pending(parent.user_id, parent.id, pid)

              {:error, {:already_started, pid}} ->
                PromptDelivery.notify_pending(parent.user_id, parent.id, pid)

              {:error, reason} ->
                refuse_start(launch, "start_failed", reason)
            end
          else
            {:error, reason} -> refuse_start(launch, "admission_refused", reason)
          end

        {:error, :launch_expired} ->
          refuse_start(launch, "launch_expired", :launch_expired)

        {:error, :opening_cancelled} ->
          refuse_start(launch, "opening_cancelled", :opening_cancelled)

        {:error, :ownership_changed} ->
          refuse_start(launch, "binding_changed", :ownership_changed)

        {:error, :launch_settled} ->
          :ok
      end

    case Repo.get(ActorLaunch, launch.id) do
      %{state: "requested"} -> {:snooze, 15}
      %{state: "refused"} when return_failure? -> result
      _ -> :ok
    end
  end

  defp refuse_start(launch, reason, error) do
    refuse(launch, reason)
    {:error, error}
  end

  defp eligible(observed) do
    Repo.transaction(fn ->
      {parent, sandbox, launch} = lock_binding(observed)
      assert_binding!(launch, parent, sandbox)
      requested!(launch, parent, sandbox)
      parent
    end)
  end

  @doc "Acknowledge while ActorOwnership holds the original machine, parent and sandbox locks."
  def acknowledge!(parent, sandbox, actor_id, supplied_id) do
    pending =
      Repo.one(
        from l in ActorLaunch,
          where: l.conversation_id == ^parent.id and l.state == "requested",
          lock: "FOR UPDATE"
      )

    # A stored child spec must not bypass a newer request's cancellation or
    # deadline. Legacy actors may retain only the original creation ancestry.
    if pending && pending.id != supplied_id, do: Repo.rollback(:launch_unavailable)

    launch =
      if supplied_id do
        Repo.one(from l in ActorLaunch, where: l.id == ^supplied_id, lock: "FOR UPDATE")
      else
        Repo.one(
          from l in ActorLaunch,
            where: l.sandbox_id == ^sandbox.id and l.kind in ["create", "replace"],
            lock: "FOR UPDATE"
        )
      end

    cond do
      is_nil(launch) and is_nil(supplied_id) ->
        nil

      is_nil(launch) ->
        Repo.rollback(:launch_unavailable)

      launch.state == "acknowledged" and sandbox.status in ~w(ready suspended) and
        launch.conversation_id != parent.id and is_nil(supplied_id) ->
        # ActorOwnership already locked and verified the attaching parent and
        # machine. Another owned parent may use a ready shared machine, but it
        # cannot claim or rewrite the original parent's launch identity.
        unless launch.user_id == parent.user_id and launch.user_id == sandbox.user_id,
          do: Repo.rollback(:ownership_changed)

        nil

      true ->
        assert_binding!(launch, parent, sandbox)
        acknowledge_owned!(launch, parent, sandbox, actor_id, supplied_id)
    end
  end

  defp acknowledge_owned!(launch, parent, sandbox, actor_id, supplied_id) do
    cond do
      launch.state == "requested" and supplied_id == launch.id ->
        requested!(launch, parent, sandbox)

        case admission(parent) do
          :ok -> :ok
          {:error, _} -> Repo.rollback(:launch_admission_refused)
        end

        # Admission can wait on other database locks. Queue time and those waits
        # belong to the accepted deadline, not a fresh provisioning allowance.
        if expired?(launch), do: Repo.rollback(:launch_expired)

        launch
        |> Ecto.Changeset.change(
          state: "acknowledged",
          actor_claim_id: actor_id,
          acknowledged_at: DateTime.utc_now()
        )
        |> Repo.update!()

      launch.state == "acknowledged" and sandbox.status in ~w(ready suspended) and
          supplied_id in [nil, launch.id] ->
        # A reconnect's old child specification is not permission to resume a
        # parked machine or bypass provider work submitted after its first actor.
        # Ownership: assert_binding! verified the saved physical identity above.
        if launch.kind == "reconnect" and
             (sandbox.status != "ready" or
                Conversations.SandboxTransitions._unsafe_pending?(sandbox.id)),
           do: Repo.rollback(:launch_unavailable)

        launch

      true ->
        Repo.rollback(:launch_unavailable)
    end
  end

  def refuse(observed, reason)
      when reason in ~w(start_failed admission_refused launch_expired opening_cancelled binding_changed) do
    Repo.transaction(fn ->
      {parent, sandbox, launch} = lock_binding(observed)
      if launch.state != "requested", do: Repo.rollback(:launch_settled)

      if reason == "launch_expired" and not expired?(launch),
        do: Repo.rollback(:launch_not_expired)

      # Ownership: this launch retains its accepted parent and original machine.
      # The watchdog rechecks that binding and current actor before any failure.
      if launch.kind != "reconnect" and same_binding?(launch, parent, sandbox) do
        Conversations.ProvisionWatchdog._unsafe_fail_launch(launch)
      end

      launch
      |> Ecto.Changeset.change(
        state: "refused",
        failure_reason: reason,
        refused_at: DateTime.utc_now()
      )
      |> Repo.update!()
    end)
  end

  defp lock_binding(observed) do
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
      4316,
      :erlang.phash2(observed.sandbox_id)
    ])

    parent =
      Repo.one(
        from c in Conversation, where: c.id == ^observed.conversation_id, lock: "FOR UPDATE"
      )

    sandbox = Repo.one(from s in Sandbox, where: s.id == ^observed.sandbox_id, lock: "FOR UPDATE")

    launch =
      Repo.one!(
        from l in ActorLaunch,
          where:
            l.id == ^observed.id and
              l.user_id == ^observed.user_id and l.conversation_id == ^observed.conversation_id and
              l.sandbox_id == ^observed.sandbox_id,
          lock: "FOR UPDATE"
      )

    {parent, sandbox, launch}
  end

  defp assert_binding!(launch, parent, sandbox) do
    unless same_binding?(launch, parent, sandbox), do: Repo.rollback(:ownership_changed)
  end

  defp same_binding?(launch, parent, sandbox) do
    parent && sandbox && parent.user_id == launch.user_id && sandbox.user_id == launch.user_id &&
      parent.id == launch.conversation_id && parent.sandbox_id == launch.sandbox_id &&
      sandbox.id == launch.sandbox_id && parent.runtime == launch.runtime &&
      (launch.kind != "reconnect" or launch.reconnect_identity == reconnect_identity(sandbox))
  end

  defp reconnect_identity(sandbox) do
    %{
      "provider" => sandbox.provider,
      "name" => sandbox.sprite_name,
      "instance_id" => sandbox.provider_instance_id,
      "lifecycle_operation_id" => (sandbox.provider_meta || %{})["lifecycle_operation_id"]
    }
  end

  defp requested!(launch, parent, sandbox) do
    if launch.state != "requested", do: Repo.rollback(:launch_settled)

    expected_status = if launch.kind == "reconnect", do: "ready", else: "pending"

    if parent.status in ~w(terminated failed) or sandbox.status != expected_status,
      do: Repo.rollback(:ownership_changed)

    # Ownership: assert_binding! checked this launch's original tenant and machine.
    if launch.kind == "reconnect" and
         Conversations.SandboxTransitions._unsafe_pending?(sandbox.id),
       do: Repo.rollback(:ownership_changed)

    if launch.opening_receipt_id do
      receipt =
        Repo.one(
          from r in PromptReceipt,
            where:
              r.id == ^launch.opening_receipt_id and
                r.user_id == ^launch.user_id and r.conversation_id == ^parent.id,
            lock: "FOR UPDATE"
        )

      unless receipt && receipt.state == "queued", do: Repo.rollback(:opening_cancelled)
    end

    # Read the clock after all admission row locks, including the opening receipt.
    if expired?(launch), do: Repo.rollback(:launch_expired)
  end

  defp admission(parent) do
    with :ok <- Fountain.Accounts.check_not_suspended(parent.user_id),
         :ok <- Fountain.Billing.check_spend(parent.user_id),
         # Ownership: the launch/claim locked and checked this parent's tenant.
         :ok <- Conversations._unsafe_execution_limits_gate(parent),
         agent when not is_nil(agent) <-
           parent.agent_id && Fountain.Agents.get_agent(parent.agent_id, parent.user_id) do
      Fountain.PlatformInference.gate(parent.user_id, agent.model)
    else
      nil -> {:error, :no_agent}
      {:error, _} = error -> error
    end
  end

  defp expired?(launch), do: DateTime.compare(DateTime.utc_now(), launch.deadline_at) != :lt

  defp launch_timeout_ms do
    case Application.get_env(:fountain, :provision_deadline_ms, :timer.minutes(30)) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> raise ArgumentError, "provision_deadline_ms must be positive"
    end
  end
end
