defmodule Fountain.Broker.Native.RequestLog do
  @moduledoc """
  The native broker's egress request log (ADR 0019 gate 4, #1486): a buffered
  writer in front of `broker_requests`, and the query the `/egress` endpoint
  reads back.

  ## Why a buffer

  The proxy emits `[:managoat, :broker, :request]` from the connection
  process that is relaying a sandbox's bytes. Two things follow. A synchronous
  insert there puts the database on the hot path of every proxied request,
  and a raising telemetry handler is *detached* by `:telemetry` — the log
  would stop for the life of the node and nothing would fail (#1427). So
  `record/1` is a `cast` into this process, which batches rows and writes
  them with one `insert_all`, and every write is guarded.

  A chatty conversation makes a lot of rows. The buffer flushes on whichever
  comes first, 200 rows or two seconds, and refuses to grow past 5,000: past
  that, rows are dropped and counted rather than held, so a runaway
  conversation costs a gap in one tenant's log instead of the node's memory.
  `fountain.broker.request_log.dropped` is the series that says so.

  ## What is stored

  Method, host, path, outcome, the rule that matched and the names of the
  environment variables whose values were attached. Never a header, a body or
  a credential. Response status and latency stay `nil` until the proxy frames
  responses; the columns exist so this backend answers with the same shape as
  the Agent Vault one.
  """

  use GenServer

  import Ecto.Query

  alias Fountain.Broker.Native.Request
  alias Fountain.Repo

  require Logger

  @batch 200
  @flush_ms 2_000
  @max_buffered 5_000

  # ---------------------------------------------------------------------------
  # Writing

  @doc "Start the writer. `Fountain.Application` does this on the native backend only."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Buffer one proxied request. Asynchronous and never raises: the caller is
  the proxy relaying a sandbox's bytes, and a telemetry handler that raises
  is detached for the life of the node.
  """
  @spec record(map(), GenServer.server()) :: :ok
  def record(row, server \\ __MODULE__) when is_map(row) do
    GenServer.cast(server, {:record, row})
  catch
    # No writer on this node (brokerage off, or a boot race). Losing the row
    # is the correct outcome; losing the request is not.
    kind, reason ->
      Logger.debug("broker request log: dropped a row: #{inspect({kind, reason})}")
      :ok
  end

  @doc "Write anything buffered, now. Synchronous, so a test can assert on rows."
  @spec flush(GenServer.server()) :: :ok
  def flush(server \\ __MODULE__), do: GenServer.call(server, :flush)

  # ---------------------------------------------------------------------------
  # Reading

  @doc """
  One page of a conversation's log, newest first. `:limit` caps the page and
  `:before` is the id from a previous page's `next`, so paging walks
  backwards through the ids the way the Agent Vault cursor did.

  `next` is the oldest id on a full page and `nil` on the last one.
  """
  @spec page(String.t(), keyword()) ::
          {:ok, %{events: [Fountain.Broker.egress_event()], next: integer() | nil}}
  def page(conversation_id, opts \\ []) when is_binary(conversation_id) do
    limit = Keyword.get(opts, :limit, 100)

    query =
      from(r in Request,
        where: r.conversation_id == ^conversation_id,
        order_by: [desc: r.id],
        limit: ^limit
      )

    query =
      case Keyword.get(opts, :before) do
        nil -> query
        before -> from(r in query, where: r.id < ^before)
      end

    rows = Repo.all(query)

    next = if length(rows) == limit, do: rows |> List.last() |> Map.fetch!(:id)

    {:ok, %{events: Enum.map(rows, &event/1), next: next}}
  end

  @doc "Delete rows older than the cutoff. Returns how many."
  @spec sweep(DateTime.t()) :: non_neg_integer()
  def sweep(%DateTime{} = cutoff) do
    {n, _} = Repo.delete_all(from(r in Request, where: r.inserted_at < ^cutoff))
    n
  end

  defp event(%Request{} = r) do
    %{
      id: r.id,
      at: r.inserted_at,
      method: r.method,
      host: r.host,
      path: r.path,
      service: r.service,
      credential_keys: r.credential_keys || [],
      status: r.status,
      latency_ms: r.latency_ms,
      error: r.error
    }
  end

  # ---------------------------------------------------------------------------
  # The server

  @impl GenServer
  def init(_opts), do: {:ok, %{buffer: [], size: 0, timer: nil}}

  @impl GenServer
  def handle_cast({:record, _row}, %{size: size} = state) when size >= @max_buffered do
    :telemetry.execute([:fountain, :broker, :request_log_dropped], %{count: 1}, %{})
    {:noreply, state}
  end

  def handle_cast({:record, row}, state) do
    state = %{state | buffer: [row | state.buffer], size: state.size + 1}

    if state.size >= @batch do
      {:noreply, write(state)}
    else
      {:noreply, arm(state)}
    end
  end

  @impl GenServer
  def handle_call(:flush, _from, state), do: {:reply, :ok, write(state)}

  @impl GenServer
  def handle_info(:flush, state), do: {:noreply, write(state)}

  @impl GenServer
  def terminate(_reason, state) do
    write(state)
    :ok
  end

  defp arm(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :flush, @flush_ms)}

  defp arm(state), do: state

  defp write(%{buffer: []} = state), do: disarm(state)

  defp write(state) do
    rows = Enum.reverse(state.buffer)

    try do
      Repo.insert_all(Request, rows)
    rescue
      error ->
        Logger.warning(
          "broker request log: #{length(rows)} row(s) lost: #{Exception.message(error)}"
        )
    catch
      kind, reason ->
        Logger.warning(
          "broker request log: #{length(rows)} row(s) lost: #{inspect({kind, reason})}"
        )
    end

    disarm(%{state | buffer: [], size: 0})
  end

  defp disarm(%{timer: nil} = state), do: state

  defp disarm(state) do
    Process.cancel_timer(state.timer)
    %{state | timer: nil}
  end
end
