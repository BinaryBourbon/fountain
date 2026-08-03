defmodule FountainWeb.Plugs.RateLimit.SweeperTest do
  # #326: the rate-limit ETS table never evicted — one row per distinct
  # {bucket, ip} since boot, unbounded. The sweeper deletes rows whose
  # window is long over; those are behaviorally identical to absent rows
  # (bump/2 resets them on the next hit).
  use ExUnit.Case, async: true

  alias FountainWeb.Plugs.RateLimit

  defp unique_bucket, do: "sweep-#{System.unique_integer([:positive, :monotonic])}"

  test "evict_expired deletes only rows older than max_age" do
    RateLimit.ensure_table()
    now = System.system_time(:millisecond)
    stale = {unique_bucket(), "203.0.113.7"}
    fresh = {unique_bucket(), "203.0.113.8"}
    :ets.insert(RateLimit.table(), {stale, now - :timer.hours(3), 5})
    :ets.insert(RateLimit.table(), {fresh, now, 5})

    assert RateLimit.evict_expired(:timer.hours(2)) >= 1

    assert :ets.lookup(RateLimit.table(), stale) == []
    assert [{^fresh, _, 5}] = :ets.lookup(RateLimit.table(), fresh)
  end

  test "eviction is invisible to limiting: a swept row behaves like a reset one" do
    RateLimit.ensure_table()
    opts = %{bucket: unique_bucket(), max: 2, window_ms: 60_000}
    key = {opts.bucket, "203.0.113.9"}

    # Full bucket whose window is long over.
    :ets.insert(RateLimit.table(), {key, System.system_time(:millisecond) - :timer.hours(3), 2})
    RateLimit.evict_expired(:timer.hours(2))

    # Same outcome an expired-but-present row gets: the window restarts.
    assert RateLimit.bump(key, opts) == :ok
  end

  test "the sweeper process is in the supervision tree and sweeps on tick" do
    pid = Process.whereis(FountainWeb.Plugs.RateLimit.Sweeper)
    assert is_pid(pid)

    now = System.system_time(:millisecond)
    stale = {unique_bucket(), "203.0.113.10"}
    :ets.insert(RateLimit.table(), {stale, now - :timer.hours(3), 1})

    send(pid, :sweep)
    # Synchronize on the GenServer having processed the message.
    _ = :sys.get_state(pid)

    assert :ets.lookup(RateLimit.table(), stale) == []
  end
end
