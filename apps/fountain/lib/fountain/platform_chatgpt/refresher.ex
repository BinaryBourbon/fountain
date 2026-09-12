defmodule Fountain.PlatformChatGPT.Refresher do
  @moduledoc """
  The one process on this node that talks to `auth.openai.com` for the
  deployment's ChatGPT grant (ADR 0047 decision 3).

  A refresh is an HTTP round-trip, and every conversation on the deployment
  shares the one grant, so when it goes stale every turn and every launch
  wants to refresh it at the same moment. Holding a database lock across
  that round-trip, the way `Fountain.Connections` does per connection, would
  park every waiter on a checked-out connection and drain the pool. So the
  waiters queue here instead, holding nothing: the first call refreshes,
  the rest find the row fresh when their turn comes.

  Across nodes, generation/version checks prevent stale success and failure
  writes. A loser can serve a winner from the same grant generation; it
  cannot serve or revoke a replacement account. This still permits duplicate
  upstream calls: deployment-wide refresh coordination is follow-up work
  under ADR 0052, not a guarantee of this local queue.
  """

  use GenServer

  @call_timeout 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Refresh the grant on this node's queue. `:if_stale` serves the row when it
  is still fresh; `:force` refreshes regardless (the keepalive). A refresher
  that is down or slow answers `{:error, {:refresher, reason}}` rather than
  taking the caller with it.
  """
  @spec refresh(:if_stale | :force) :: {:ok, String.t()} | {:error, term()}
  def refresh(mode) when mode in [:if_stale, :force] do
    GenServer.call(__MODULE__, {:refresh, mode}, @call_timeout)
  catch
    :exit, reason -> {:error, {:refresher, reason}}
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:refresh, mode}, _from, state) do
    {:reply, Fountain.PlatformChatGPT.refresh_serialized(mode), state}
  end
end
