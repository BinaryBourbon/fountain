defmodule Fountain.Conversations.WakeContext do
  @moduledoc "Original wake binding and deadline, checked at each provider grant."
  import Ecto.Query
  alias Fountain.{Conversations, Repo}

  alias Fountain.Conversations.{
    Conversation,
    PromptDelivery,
    PromptReceipt,
    PromptWakeRequest,
    Sandbox
  }

  @enforce_keys [:user_id, :conversation_id, :runtime, :deadline_at]
  defstruct [
    :user_id,
    :conversation_id,
    :sandbox_id,
    :runtime,
    :agent_id,
    :receipt_id,
    :request_id,
    :deadline_at
  ]

  def new(original, receipt_id) do
    Repo.transaction(fn ->
      if original.sandbox_id, do: lock_machine(original.sandbox_id)
      parent = Repo.one(from c in Conversation, where: c.id == ^original.id, lock: "FOR UPDATE")

      unless parent && parent.user_id == original.user_id &&
               parent.sandbox_id == original.sandbox_id &&
               parent.runtime == original.runtime && parent.agent_id == original.agent_id &&
               parent.status not in ~w(terminated failed),
             do: Repo.rollback(:ownership_changed)

      receipt = receipt!(parent, receipt_id)
      request = receipt && Repo.get(PromptWakeRequest, receipt.id)
      timeout = Application.get_env(:fountain, :provision_deadline_ms, :timer.minutes(30))

      unless is_integer(timeout) and timeout > 0,
        do: raise(ArgumentError, "provision_deadline_ms must be positive")

      deadline = DateTime.add(DateTime.utc_now(), timeout, :millisecond)

      deadline =
        if receipt && DateTime.compare(receipt.delivery_deadline_at, deadline) == :lt,
          do: receipt.delivery_deadline_at,
          else: deadline

      context = %__MODULE__{
        user_id: parent.user_id,
        conversation_id: parent.id,
        sandbox_id: parent.sandbox_id,
        runtime: parent.runtime,
        agent_id: parent.agent_id,
        receipt_id: receipt && receipt.id,
        request_id: request && request.id,
        deadline_at: deadline
      }

      assert_locked!(context)
      context
    end)
  end

  @doc "Called inside the provider grant transaction after its machine and parent locks."
  def assert_locked!(nil), do: :ok

  def assert_locked!(%__MODULE__{} = context) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "wake authority requires a transaction")

    parent =
      Repo.one(
        from c in Conversation, where: c.id == ^context.conversation_id, lock: "FOR UPDATE"
      )

    unless parent && parent.user_id == context.user_id && parent.sandbox_id == context.sandbox_id &&
             parent.runtime == context.runtime && parent.agent_id == context.agent_id &&
             parent.status not in ~w(terminated failed),
           do: Repo.rollback(:ownership_changed)

    receipt = if context.receipt_id, do: receipt!(parent, context.receipt_id)

    if context.request_id do
      request =
        Repo.one(
          from w in PromptWakeRequest, where: w.id == ^context.request_id, lock: "FOR UPDATE"
        )

      unless request && request.user_id == context.user_id && request.conversation_id == parent.id &&
               request.sandbox_id == context.sandbox_id && request.state == "started",
             do: Repo.rollback(:wake_unavailable)
    end

    # Read time after all authority locks: waiting cannot renew the accepted wake.
    if DateTime.compare(DateTime.utc_now(), context.deadline_at) != :lt ||
         (receipt && PromptDelivery.expired?(receipt)),
       do: Repo.rollback(:wake_expired)

    :ok
  end

  @doc "Recheck the observed physical binding before a read-only provider probe."
  def probe(context, observed, fun) do
    with {:ok, :ok} <-
           Repo.transaction(fn ->
             lock_machine(observed.id)
             assert_locked!(context)

             sandbox =
               Repo.one(from s in Sandbox, where: s.id == ^observed.id, lock: "FOR UPDATE")

             assert_machine!(context, observed, sandbox)

             # ownership: the locked original parent and physical snapshot bind this sandbox.
             if Conversations.SandboxTransitions._unsafe_pending?(sandbox.id),
               do: Repo.rollback(:provider_operation_fenced)

             :ok
           end),
         do: provider_result(context, fun)
  end

  def assert_machine!(context, observed, sandbox) do
    unless sandbox && sandbox.user_id == context.user_id && sandbox.id == context.sandbox_id &&
             sandbox.provider == observed.provider && sandbox.sprite_name == observed.sprite_name &&
             sandbox.provider_instance_id == observed.provider_instance_id &&
             sandbox.provider_meta == observed.provider_meta && sandbox.status == observed.status,
           do: Repo.rollback(:ownership_changed)

    if Conversations.ActorStartups.fenced?(sandbox.id), do: Repo.rollback(:startup_unresolved)
  end

  def operation_attrs(nil), do: %{}

  def operation_attrs(context),
    do: %{
      conversation_id: context.conversation_id,
      wake_receipt_id: context.receipt_id,
      wake_request_id: context.request_id,
      wake_deadline_at: context.deadline_at
    }

  @doc "Keep a provider return distinct from a call that never started or timed out."
  def run(context, fun, maximum \\ 35_000) do
    if Repo.in_transaction?() do
      {:not_started, :provider_transaction_open}
    else
      remaining = remaining(context, maximum)

      if remaining <= 0 do
        {:not_started, :wake_expired}
      else
        task =
          Task.Supervisor.async_nolink(Fountain.TaskSupervisor, fn ->
            # The task may have waited for scheduling after its grant committed.
            timeout = remaining(context, maximum)

            if timeout <= 0 do
              {:not_started, :wake_expired}
            else
              {:ok, timer} = :timer.kill_after(timeout)

              try do
                {:returned, fun.()}
              rescue
                _ -> {:uncertain, :provider_operation_uncertain}
              catch
                _, _ -> {:uncertain, :provider_operation_uncertain}
              after
                :timer.cancel(timer)
              end
            end
          end)

        case Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          _ -> {:uncertain, :provider_operation_uncertain}
        end
      end
    end
  catch
    _, _ -> {:uncertain, :provider_operation_uncertain}
  end

  def provider_result(context, fun, maximum \\ 35_000) do
    case run(context, fun, maximum) do
      {:returned, result} -> result
      {_, reason} -> {:error, reason}
    end
  end

  defp remaining(nil, maximum), do: maximum

  defp remaining(context, maximum),
    do: min(maximum, DateTime.diff(context.deadline_at, DateTime.utc_now(), :millisecond))

  defp receipt!(parent, nil) do
    Repo.one(
      from r in PromptReceipt,
        where:
          r.conversation_id == ^parent.id and
            r.user_id == ^parent.user_id and r.state == "queued",
        lock: "FOR UPDATE"
    )
  end

  defp receipt!(parent, id) do
    receipt =
      Repo.one(
        from r in PromptReceipt,
          where:
            r.id == ^id and
              r.conversation_id == ^parent.id and r.user_id == ^parent.user_id,
          lock: "FOR UPDATE"
      )

    unless receipt && receipt.state == "queued", do: Repo.rollback(:opening_cancelled)
    receipt
  end

  defp lock_machine(id),
    do: Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, :erlang.phash2(id)])
end
