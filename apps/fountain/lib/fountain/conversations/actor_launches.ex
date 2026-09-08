defmodule Fountain.Conversations.ActorLaunches do
  @moduledoc """
  Commit fresh creation and its launch outbox before starting a local actor.

  Retrying Horde startup does not acknowledge a launch or grant another provider
  attempt. The first actor claim acknowledges under the same machine/parent locks;
  later actors cannot recreate unfinished provisioning. Acknowledged launches are
  never redelivered by the outbox. Ready-machine maintenance can retain ancestry.
  Fresh wake/attach and abandoned-actor/provider reconciliation remain separate
  integration work; this module never adopts or deletes a provider resource.
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
          launch =
            Repo.insert!(%ActorLaunch{
              user_id: user_id,
              conversation_id: parent.id,
              sandbox_id: sandbox.id,
              runtime: parent.runtime,
              opening_receipt_id: receipt && receipt.id,
              deadline_at: DateTime.add(DateTime.utc_now(), launch_timeout_ms(), :millisecond)
            })

          enqueue(launch)
          {:ok, {sandbox, parent, launch}}
        end
      end)
    end
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

  def deliver(user_id, conversation_id, launch_id) do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      case fetch(user_id, conversation_id, launch_id) do
        %ActorLaunch{state: "requested"} = launch -> deliver_requested(launch)
        _ -> :ok
      end
    end
  end

  defp deliver_requested(launch) do
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

            {:error, _} ->
              refuse(launch, "start_failed")
          end
        else
          {:error, _} -> refuse(launch, "admission_refused")
        end

      {:error, :launch_expired} ->
        refuse(launch, "launch_expired")

      {:error, :opening_cancelled} ->
        refuse(launch, "opening_cancelled")

      {:error, :ownership_changed} ->
        refuse(launch, "binding_changed")

      {:error, :launch_settled} ->
        :ok
    end

    case Repo.get(ActorLaunch, launch.id) do
      %{state: "requested"} -> {:snooze, 15}
      _ -> :ok
    end
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
    launch =
      Repo.one(from l in ActorLaunch, where: l.sandbox_id == ^sandbox.id, lock: "FOR UPDATE")

    cond do
      is_nil(launch) and is_nil(supplied_id) ->
        nil

      is_nil(launch) ->
        Repo.rollback(:ownership_changed)

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
      if same_binding?(launch, parent, sandbox) do
        Conversations.ProvisionWatchdog._unsafe_fail_start(
          launch.conversation_id,
          launch.sandbox_id
        )
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
      sandbox.id == launch.sandbox_id && parent.runtime == launch.runtime
  end

  defp requested!(launch, parent, sandbox) do
    if launch.state != "requested", do: Repo.rollback(:launch_settled)

    if parent.status in ~w(terminated failed) or sandbox.status != "pending",
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
