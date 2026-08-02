defmodule Fountain.Workers.AccountExport do
  @moduledoc """
  Builds a requested account data export (#288).

  Runs async because an export reads every row the account owns — log output
  dominates, and a heavy account is tens of megabytes of it — which has no
  business happening inside a LiveView event.

  The JSON document is gzipped before storage: sprite log output compresses
  roughly 20x, which is the difference between a multi-megabyte row and a
  hundreds-of-kilobytes one. Each run starts by purging expired exports, so
  the table never accumulates dead payloads between requests.

  A final failed attempt marks the export row `failed` so the account page
  shows an honest status instead of "generating…" forever.
  """

  use Oban.Worker, queue: :exports, max_attempts: 3

  require Logger

  alias Fountain.Exports
  alias Fountain.Exports.Export

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"export_id" => export_id, "user_id" => user_id}} = job) do
    Exports.purge_expired()

    case Exports.get_export(export_id, user_id) do
      nil ->
        # Superseded by a newer request or the account is gone. Nothing to
        # build, and retrying will not bring the row back.
        :ok

      %Export{status: "completed"} ->
        :ok

      %Export{} = export ->
        build(export, job)
    end
  end

  defp build(%Export{user_id: user_id} = export, job) do
    json = user_id |> Exports.build() |> Jason.encode!()
    payload = :zlib.gzip(json)

    with {:ok, _} <- Exports.complete_export(export, payload, byte_size(json)) do
      :ok
    end
  rescue
    e ->
      if job.attempt >= job.max_attempts do
        Logger.error("account_export: giving up on #{export.id}: #{Exception.message(e)}")
        Exports.fail_export(export, e)
      end

      reraise e, __STACKTRACE__
  end

  @doc "Enqueue the build job for `export`."
  @spec enqueue(Export.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(%Export{id: id, user_id: user_id}) do
    %{export_id: id, user_id: user_id}
    |> new()
    |> Oban.insert()
  end
end
