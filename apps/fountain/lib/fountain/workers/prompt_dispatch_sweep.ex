defmodule Fountain.Workers.PromptDispatchSweep do
  @moduledoc """
  Redeliver queued receipt notifications independently of their original jobs.

  A crashed or discarded dispatch job cannot strand accepted intent. Each minute,
  bounded pages revisit owned queued receipts through the same idempotent dispatch
  boundary. No job is reset and no provider operation is retried. Pagination is
  committed before dispatch so a blocked page cannot starve the following page.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  import Ecto.Query
  require Logger

  alias Fountain.Repo
  alias Fountain.Conversations.{Conversation, PromptReceipt}
  alias Fountain.Workers.PromptDispatch

  @page_size 100

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(30)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    receipts = queued_page(args["after_receipt_id"])

    if length(receipts) == @page_size do
      %{"after_receipt_id" => List.last(receipts).id}
      |> new()
      |> Oban.insert!()
    end

    failures = Enum.count(receipts, &(dispatch(&1) == :error))
    if failures == 0, do: :ok, else: {:error, {:prompt_dispatch_failed, failures}}
  end

  defp queued_page(cursor) do
    # Ownership: only candidates whose current parent retains the saved tenant
    # are listed. PromptDispatch fetches that scope again before any notification.
    query =
      from r in PromptReceipt,
        join: c in Conversation,
        on: c.id == r.conversation_id and c.user_id == r.user_id,
        where: r.state == "queued",
        order_by: r.id,
        limit: @page_size,
        select: %{id: r.id, conversation_id: r.conversation_id, user_id: r.user_id}

    query = if cursor, do: where(query, [r], r.id > ^cursor), else: query
    Repo.all(query)
  end

  defp dispatch(receipt) do
    case PromptDispatch.perform(%Oban.Job{
           args: %{
             "receipt_id" => receipt.id,
             "conversation_id" => receipt.conversation_id,
             "user_id" => receipt.user_id
           }
         }) do
      :ok -> :ok
      {:snooze, _} -> :ok
      {:error, _} -> :error
    end
  rescue
    error ->
      Logger.warning(
        "prompt dispatch receipt #{receipt.id} failed (#{inspect(error.__struct__)})"
      )

      :error
  end
end
