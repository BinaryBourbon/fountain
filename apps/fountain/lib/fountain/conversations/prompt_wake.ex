defmodule Fountain.Conversations.PromptWake do
  @moduledoc """
  Hand accepted prompts to a wake independently of their submitting process.

  Acceptance saves the request with its receipt and dispatch job. Either the
  caller or dispatch claims the invocation before calling the existing wake
  path outside the transaction. Registry absence grants no replay: a started
  request survives process death and needs explicit lifecycle reconciliation.
  A returned invocation is not proof that a provider operation completed.

  This covers prompt acceptance, not prompt-free creation or abandoned actor
  recovery. Existing creation/reattach policy still owns provider decisions.
  """
  import Ecto.Query
  alias Fountain.{Conversations, Repo}
  alias Fountain.Conversations.{Conversation, ConversationServer, PromptDelivery, PromptReceipt}
  alias Fountain.Conversations.PromptWakeRequest

  @doc "Save with a newly accepted receipt while its owned parent is locked."
  def save!(parent, receipt) do
    unless Repo.in_transaction?() && receipt.user_id == parent.user_id &&
             receipt.conversation_id == parent.id,
           do: raise(ArgumentError, "wake request requires the owned acceptance transaction")

    Repo.insert!(%PromptWakeRequest{
      id: receipt.id,
      user_id: parent.user_id,
      conversation_id: parent.id,
      sandbox_id: parent.sandbox_id
    })
  end

  def deliver(%PromptReceipt{state: "queued"} = receipt) do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      case ConversationServer.whereis(receipt.conversation_id) do
        pid when is_pid(pid) -> ConversationServer.queue_prompt_receipt(pid, receipt.id)
        nil -> wake(receipt)
      end
    end
  end

  def deliver(_), do: :ok

  defp wake(receipt) do
    with %PromptWakeRequest{} = request <- Repo.get(PromptWakeRequest, receipt.id),
         {:ok, parent} <- claim(request, receipt) do
      # Ownership: claim rechecked this receipt's saved tenant and original machine under locks.
      result = Conversations._unsafe_wake_bound_conversation(parent, receipt.id)

      # This records return only, not provider success. An exception, process
      # death or database failure leaves the invocation fenced as started.
      Repo.transaction(fn ->
        if result == {:error, :no_agent} do
          PromptDelivery.refuse(
            receipt.user_id,
            receipt.conversation_id,
            receipt.id,
            "admission_refused",
            sandbox_id: parent.sandbox_id
          )
        end

        from(w in PromptWakeRequest, where: w.id == ^request.id and w.state == "started")
        |> Repo.update_all(set: [state: "returned", returned_at: DateTime.utc_now()])
      end)

      :ok
    else
      _ -> :ok
    end
  end

  defp claim(request, receipt) do
    Repo.transaction(fn ->
      if request.sandbox_id,
        do:
          Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
            4316,
            :erlang.phash2(request.sandbox_id)
          ])

      parent =
        Repo.one(
          from c in Conversation, where: c.id == ^request.conversation_id, lock: "FOR UPDATE"
        )

      saved = Repo.one(from r in PromptReceipt, where: r.id == ^request.id, lock: "FOR UPDATE")

      current =
        Repo.one(from w in PromptWakeRequest, where: w.id == ^request.id, lock: "FOR UPDATE")

      unless parent && saved && current &&
               parent.user_id == receipt.user_id && request.user_id == receipt.user_id &&
               request.conversation_id == receipt.conversation_id &&
               saved.user_id == receipt.user_id &&
               saved.conversation_id == parent.id && parent.sandbox_id == request.sandbox_id &&
               parent.status not in ~w(terminated failed) && saved.state == "queued" &&
               current.state == "requested" && not PromptDelivery.expired?(saved),
             do: Repo.rollback(:wake_unavailable)

      # A second receipt cannot authorize replay of an interrupted invocation.
      if Repo.exists?(
           from w in PromptWakeRequest,
             where: w.conversation_id == ^parent.id and w.state == "started"
         ),
         do: Repo.rollback(:wake_unresolved)

      current
      |> Ecto.Changeset.change(state: "started", started_at: DateTime.utc_now())
      |> Repo.update!()

      parent
    end)
  end
end
