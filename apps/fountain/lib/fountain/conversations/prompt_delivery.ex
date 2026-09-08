defmodule Fountain.Conversations.PromptDelivery do
  @moduledoc """
  Persist an owned prompt and images, then claim its existing turn once.

  The receipt survives transcript retention, so a repeated key cannot recreate
  deleted work. Claim and bounded execution admission commit together before the
  caller may start provider work. Prompt submission, creation, attach and wake
  save intent before delivery. Committed dispatch jobs retry notifications until
  claim or expiry; they never start or replace a provider resource.
  """
  import Ecto.Query

  alias Fountain.{Conversations, Repo}

  alias Fountain.Conversations.{
    Conversation,
    ExecutionGuard,
    PromptReceipt,
    Turn,
    TurnImage,
    TurnMachine
  }

  @refusals ~w(cancelled provisioning_failed binding_changed admission_refused delivery_unavailable delivery_expired)

  @doc "Validate an optional opening prompt before reserving a sandbox."
  def validate_initial(attrs) do
    case {attrs["prompt"], attrs["images"] || []} do
      {prompt, []} when prompt in [nil, ""] -> :ok
      {prompt, images} -> validate_payload(prompt, images)
    end
  end

  @doc "Save opening intent before its actor can start; an absent prompt creates no receipt."
  def save_initial(user_id, conversation_id, attrs) do
    with :ok <- validate_initial(attrs) do
      case attrs["prompt"] do
        prompt when prompt in [nil, ""] -> {:ok, nil}
        prompt -> submit(user_id, conversation_id, prompt, attrs["images"] || [])
      end
    end
  end

  @doc "Notify a known actor about its currently owned saved intent."
  def notify_pending(user_id, conversation_id, pid) do
    if receipt = queued(user_id, conversation_id),
      do: Conversations.ConversationServer.queue_prompt_receipt(pid, receipt.id)

    :ok
  end

  def submit(user_id, conversation_id, prompt, images, opts \\ []) do
    with {:ok, {receipt, _new?}} <- submit_result(user_id, conversation_id, prompt, images, opts),
         do: {:ok, receipt}
  end

  @doc "Accept before delivery; retries with the same key never repeat a wake."
  def accept(user_id, conversation_id, prompt, images, opts \\ []) do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      with {:ok, {receipt, new?}} <- submit_result(user_id, conversation_id, prompt, images, opts) do
        begin_delivery(receipt, new?)
        {:ok, fetch(user_id, conversation_id, receipt.id) || receipt}
      end
    end
  end

  defp begin_delivery(%PromptReceipt{state: "queued"} = receipt, new?) do
    case Conversations.ConversationServer.whereis(receipt.conversation_id) do
      nil when new? ->
        # Ownership: submit locked this parent for the receipt's saved tenant.
        # Prompt data is already durable; wake never receives replayable text.
        case Conversations.wake_conversation(receipt.conversation_id) do
          {:error, :no_agent} ->
            refuse(receipt.user_id, receipt.conversation_id, receipt.id, "admission_refused")

          _ ->
            :ok
        end

      pid when is_pid(pid) ->
        Conversations.ConversationServer.queue_prompt_receipt(pid, receipt.id)

      _ ->
        :ok
    end
  end

  defp begin_delivery(_, _), do: :ok

  defp submit_result(user_id, conversation_id, prompt, images, opts) do
    with :ok <- validate_payload(prompt, images),
         {:ok, key_hash} <- key_hash(Keyword.get(opts, :idempotency_key)) do
      payload_hash = payload_hash(prompt, images)

      Repo.transaction(fn ->
        parent = lock_parent(user_id, conversation_id)

        case Repo.get_by(PromptReceipt, conversation_id: parent.id, key_hash: key_hash) do
          nil ->
            admit_submission!(parent)
            {insert!(parent, prompt, images, key_hash, payload_hash), true}

          receipt ->
            if receipt.user_id != parent.user_id, do: Repo.rollback(:ownership_changed)
            if receipt.payload_hash != payload_hash, do: Repo.rollback(:idempotency_conflict)
            {receipt, false}
        end
      end)
    end
  end

  def fetch(user_id, conversation_id, receipt_id) do
    Repo.one(
      from r in PromptReceipt,
        join: c in Conversation,
        on: c.id == r.conversation_id,
        where:
          r.id == ^receipt_id and c.id == ^conversation_id and
            c.user_id == ^user_id and r.user_id == ^user_id
    )
  end

  def queued(user_id, conversation_id) do
    Repo.one(
      from r in PromptReceipt,
        join: c in Conversation,
        on: c.id == r.conversation_id,
        where:
          c.id == ^conversation_id and c.user_id == ^user_id and
            r.user_id == ^user_id and r.state == "queued"
    )
  end

  def payload(user_id, conversation_id, receipt_id) do
    with %PromptReceipt{} = receipt <- fetch(user_id, conversation_id, receipt_id),
         %Turn{} = turn <-
           Repo.one(
             from t in Turn,
               where: t.id == ^receipt.turn_id and t.conversation_id == ^conversation_id
           ) do
      images = Repo.all(from i in TurnImage, where: i.turn_id == ^turn.id, order_by: i.position)

      {:ok,
       %{
         receipt: receipt,
         turn: turn,
         images: Enum.map(images, &Map.take(&1, [:media_type, :data]))
       }}
    else
      _ -> {:error, :delivery_unavailable}
    end
  end

  @doc "Claim the saved turn on the actor's current machine; repeated claims grant no work."
  def _unsafe_activate(conversation_id, receipt_id, sandbox_id, opts \\ []) do
    # Ownership: this actor supplies its parent and original machine; admission
    # rechecks that binding, and the writer checks the receipt's saved tenant.
    ExecutionGuard._unsafe_admit_turn(
      %{conversation_id: conversation_id},
      sandbox_id,
      :current_runtime,
      fn ->
        current = Repo.get!(Conversation, conversation_id)
        receipt = lock_receipt!(current, receipt_id)
        if receipt.state != "queued", do: Repo.rollback(:delivery_claimed)
        if running_user_turn?(current.id), do: Repo.rollback(:busy)

        case TurnMachine.gate(current, Keyword.get(opts, :inference_source)) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        turn = lock_turn!(receipt)
        if turn.status != "pending", do: Repo.rollback(:delivery_unavailable)
        # The final turn lock can wait past the deadline even after the receipt
        # lock was acquired. Read the clock only after all admission row locks.
        now = DateTime.utc_now()

        if DateTime.compare(now, receipt.delivery_deadline_at) != :lt,
          do: Repo.rollback(:delivery_expired)

        {:ok, updated} =
          turn
          |> Turn.changeset(%{status: "running", started_at: DateTime.truncate(now, :second)})
          |> Repo.update()

        receipt
        |> PromptReceipt.changeset(%{
          state: "claimed",
          sandbox_id: sandbox_id,
          claimed_at: now
        })
        |> Repo.update!()

        {:ok, updated}
      end
    )
  end

  @doc "Refuse only unclaimed work; the failed turn and delivery intents commit together."
  def refuse(user_id, conversation_id, receipt_id, reason, opts \\ [])

  def refuse(user_id, conversation_id, receipt_id, reason, opts) when reason in @refusals do
    Repo.transaction(fn ->
      parent = lock_parent(user_id, conversation_id)
      expected_sandbox = Keyword.get(opts, :sandbox_id)

      if expected_sandbox && parent.sandbox_id != expected_sandbox,
        do: Repo.rollback(:ownership_changed)

      receipt = lock_receipt!(parent, receipt_id)

      if receipt.state == "claimed", do: Repo.rollback(:delivery_claimed)

      if receipt.state == "queued" do
        if reason == "delivery_expired" and not expired?(receipt),
          do: Repo.rollback(:delivery_not_expired)

        turn = Repo.one(from t in Turn, where: t.id == ^receipt.turn_id, lock: "FOR UPDATE")

        if turn do
          if turn.conversation_id != parent.id or turn.status != "pending",
            do: Repo.rollback(:delivery_unavailable)

          turn
          |> Turn.changeset(%{
            status: "failed",
            ended_at: DateTime.truncate(DateTime.utc_now(), :second)
          })
          |> Repo.update!()

          record_refusal(parent, turn, receipt.id, reason)
        end

        receipt
        |> PromptReceipt.changeset(%{state: "refused", failure_reason: reason})
        |> Repo.update!()
      else
        receipt
      end
    end)
  end

  def refuse(_, _, _, _, _), do: {:error, :invalid_reason}

  defp admit_submission!(parent) do
    if parent.status in ~w(terminated failed), do: Repo.rollback(:gone)
    if running_user_turn?(parent.id), do: Repo.rollback(:busy)

    if Repo.exists?(
         from r in PromptReceipt, where: r.conversation_id == ^parent.id and r.state == "queued"
       ),
       do: Repo.rollback(:busy)

    # Ownership: submission locked the scoped parent before checking its current policy.
    with :ok <- Fountain.Accounts.check_not_suspended(parent.user_id),
         :ok <- Fountain.Billing.check_spend(parent.user_id),
         :ok <- Conversations._unsafe_execution_limits_gate(parent) do
      :ok
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp insert!(parent, prompt, images, key_hash, payload_hash) do
    # Ownership: all rows belong to the scoped parent locked by submit/5.
    turn =
      %Turn{}
      |> Turn.changeset(%{
        conversation_id: parent.id,
        turn_number: Conversations._unsafe_next_turn_number(parent.id),
        prompt: prompt,
        status: "pending"
      })
      |> Repo.insert!()

    # Ownership: this turn was inserted above for the locked, tenant-scoped parent.
    case Conversations._unsafe_insert_turn_images(turn.id, images) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    receipt =
      %PromptReceipt{}
      |> PromptReceipt.changeset(%{
        conversation_id: parent.id,
        user_id: parent.user_id,
        turn_id: turn.id,
        key_hash: key_hash,
        payload_hash: payload_hash,
        delivery_deadline_at:
          DateTime.add(DateTime.utc_now(), delivery_timeout_ms(), :millisecond)
      })
      |> Repo.insert!()

    %{"receipt_id" => receipt.id, "conversation_id" => parent.id, "user_id" => parent.user_id}
    |> Fountain.Workers.PromptDispatch.new()
    |> Oban.insert!()

    receipt
  end

  @doc "Whether the persisted acceptance deadline has passed; activation checks it under lock."
  def expired?(%PromptReceipt{delivery_deadline_at: deadline}),
    do: DateTime.compare(DateTime.utc_now(), deadline) != :lt

  # Allow the ordinary 30-minute provisioning budget plus dispatch time. Snapshot
  # at acceptance: changing configuration cannot extend an existing request.
  defp delivery_timeout_ms do
    case Application.get_env(:fountain, :prompt_delivery_timeout_ms, :timer.minutes(35)) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> raise ArgumentError, "prompt_delivery_timeout_ms must be a positive integer"
    end
  end

  defp lock_parent(user_id, conversation_id) do
    Repo.one(
      from c in Conversation,
        where: c.id == ^conversation_id and c.user_id == ^user_id,
        lock: "FOR UPDATE"
    ) ||
      Repo.rollback(:not_found)
  end

  defp lock_receipt!(parent, receipt_id) do
    Repo.one(
      from r in PromptReceipt,
        where:
          r.id == ^receipt_id and r.conversation_id == ^parent.id and r.user_id == ^parent.user_id,
        lock: "FOR UPDATE"
    ) || Repo.rollback(:not_found)
  end

  defp lock_turn!(receipt) do
    Repo.one(
      from t in Turn,
        where: t.id == ^receipt.turn_id and t.conversation_id == ^receipt.conversation_id,
        lock: "FOR UPDATE"
    ) || Repo.rollback(:delivery_unavailable)
  end

  defp running_user_turn?(conversation_id),
    do:
      Repo.exists?(
        from t in Turn,
          where:
            t.conversation_id == ^conversation_id and t.status == "running" and t.origin == "user"
      )

  defp record_refusal(parent, turn, receipt_id, reason) do
    event =
      Conversations.log!(%{
        conversation_id: parent.id,
        turn_id: turn.id,
        kind: "stage",
        stage: "turn",
        state: "failed",
        data: Jason.encode!(%{turn_id: turn.id, receipt_id: receipt_id, reason: reason})
      })

    Fountain.Webhooks.dispatch_stage!(event)

    %{"event_id" => event.id, "conversation_id" => parent.id, "user_id" => parent.user_id}
    |> Fountain.Workers.TurnDeadlineNotification.new()
    |> Oban.insert!()
  end

  defp key_hash(nil), do: {:ok, :crypto.hash(:sha256, Ecto.UUID.generate())}

  defp key_hash(key) when is_binary(key) and byte_size(key) in 1..200,
    do: {:ok, :crypto.hash(:sha256, key)}

  defp key_hash(_), do: {:error, :invalid_idempotency_key}

  defp payload_hash(prompt, images),
    do:
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({prompt, Enum.map(images, &{&1.media_type, &1.data})})
      )

  defp validate_payload(prompt, images) when is_binary(prompt) and is_list(images) do
    cond do
      String.trim(prompt) == "" -> {:error, :invalid_prompt}
      Enum.any?(images, &(not valid_image?(&1))) -> {:error, :invalid_images}
      true -> :ok
    end
  end

  defp validate_payload(_, _), do: {:error, :invalid_prompt}

  defp valid_image?(%{media_type: media_type, data: data}) when is_binary(data),
    do:
      Fountain.Images.valid_media_type?(media_type) and byte_size(data) > 0 and
        byte_size(data) <= Fountain.Images.max_prompt_image_bytes()

  defp valid_image?(_), do: false
end
