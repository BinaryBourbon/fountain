defmodule FountainWeb.Plugs.RateLimit.Sweeper do
  @moduledoc """
  Periodic eviction for the rate-limit ETS table (#326).

  `bump/2` only ever overwrites a row when its own key comes back, so the
  table grew by one row per distinct `{bucket, ip}` seen since boot —
  unbounded in proportion to source IPs, and invisible until an instance
  stayed up long enough or someone walked a v6 range.

  Sweeps every 10 minutes, deleting rows whose window started more than
  `@max_age_ms` ago. That bound must exceed the longest window configured
  on any plug — currently 1h (the auth buckets) — so expired-but-swept
  rows can never differ from expired-and-reset rows in behavior. 2h keeps
  a comfortable margin for future windows.
  """

  use GenServer

  require Logger

  @sweep_interval_ms :timer.minutes(10)
  @max_age_ms :timer.hours(2)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(nil) do
    FountainWeb.Plugs.RateLimit.ensure_table()
    :timer.send_interval(@sweep_interval_ms, :sweep)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    deleted = FountainWeb.Plugs.RateLimit.evict_expired(@max_age_ms)

    if deleted > 0 do
      Logger.debug("rate_limit sweeper: evicted #{deleted} expired buckets")
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
