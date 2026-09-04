defmodule Fountain.SandboxQueueConfigTest do
  @moduledoc """
  The queue settings that keep the sandbox's one connection from dropping
  waiters (#1524, #1568).

  Under `Ecto.Adapters.SQL.Sandbox` a test has a single connection, shared by
  every process it fans work out to — including Ecto's own parallel preloader,
  which nobody wrote and which is in the stack of most of these failures. Those
  processes queue rather than run in parallel, and at DBConnection's defaults a
  loaded run drops them with a `ConnectionError` that names the test's own
  connection. Neither the pool size nor the code under test has anything to do
  with it, which is why both issues cost an investigation before they cost a
  fix.

  Asserted here rather than left as a comment in `config/test.exs` because the
  cost of losing these two lines is not a failing test: it is the same
  intermittent red, rediscovered from scratch.
  """

  use ExUnit.Case, async: true

  @config Application.compile_env(:fountain, Fountain.Repo)

  # The real failures waited 121-263 ms. A waiter is dropped only once it has
  # waited past `queue_target` and the queue has been slow for a whole
  # `queue_interval`, so these leave roughly an order of magnitude over what
  # was observed.
  #
  # `is_integer/1` first, and not for tidiness: a missing key reads as `nil`,
  # and `nil >= 200` is `true` under Elixir's term ordering, so the obvious
  # form of this assertion passes on exactly the config it exists to reject.
  test "the sandbox connection tolerates a queue" do
    assert is_integer(@config[:queue_target]) and @config[:queue_target] >= 200
    assert is_integer(@config[:queue_interval]) and @config[:queue_interval] >= 5_000
  end

  # CLAUDE.md's rule, and the reason it is not in tension with the two above:
  # the pool is what concurrent *tests* draw from, the queue settings are about
  # contention inside one test on one connection.
  test "the pool still holds 20" do
    assert @config[:pool_size] == 20
    assert @config[:pool] == Ecto.Adapters.SQL.Sandbox
  end
end
