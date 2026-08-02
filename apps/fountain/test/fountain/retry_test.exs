defmodule Fountain.RetryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Fountain.Retry

  # Returns a fun that fails with `failures` results before succeeding, and
  # counts calls in an Agent.
  defp flaky(counter, failures, success \\ :ok) do
    fn ->
      n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      if n <= length(failures), do: Enum.at(failures, n - 1), else: success
    end
  end

  defp new_counter do
    {:ok, pid} = Agent.start_link(fn -> 0 end)
    pid
  end

  test "passes a first-try success through without retrying" do
    counter = new_counter()
    assert :ok = Retry.with_backoff(flaky(counter, []))
    assert Agent.get(counter, & &1) == 1
  end

  test "retries a transient error and returns the eventual success" do
    counter = new_counter()

    capture_log(fn ->
      assert {:ok, :won} =
               Retry.with_backoff(flaky(counter, [{:error, :timeout}], {:ok, :won}), base_ms: 1)
    end)

    assert Agent.get(counter, & &1) == 2
  end

  test "gives up after the attempt budget and returns the last error" do
    counter = new_counter()
    failures = List.duplicate({:error, :timeout}, 5)

    capture_log(fn ->
      assert {:error, :timeout} =
               Retry.with_backoff(flaky(counter, failures), attempts: 3, base_ms: 1)
    end)

    assert Agent.get(counter, & &1) == 3
  end

  test "does not retry a permanent api_error" do
    counter = new_counter()

    assert {:error, {:api_error, 404, "gone"}} =
             Retry.with_backoff(flaky(counter, [{:error, {:api_error, 404, "gone"}}]),
               base_ms: 1
             )

    assert Agent.get(counter, & &1) == 1
  end

  test "retries a raise and re-raises when exhausted" do
    counter = new_counter()

    fun = fn ->
      Agent.update(counter, &(&1 + 1))
      raise "Failed to start command: :closed"
    end

    capture_log(fn ->
      assert_raise RuntimeError, ~r/Failed to start command/, fn ->
        Retry.with_backoff(fun, attempts: 2, base_ms: 1)
      end
    end)

    assert Agent.get(counter, & &1) == 2
  end

  test "a raise that stops before the budget returns the recovery" do
    counter = new_counter()

    fun = fn ->
      n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      if n == 1, do: raise("Failed to start command: :closed"), else: :ok
    end

    capture_log(fn -> assert :ok = Retry.with_backoff(fun, base_ms: 1) end)
    assert Agent.get(counter, & &1) == 2
  end

  test "honors a custom retriable? classifier" do
    counter = new_counter()

    assert {:error, :special} =
             Retry.with_backoff(flaky(counter, [{:error, :special}, {:error, :special}]),
               base_ms: 1,
               retriable?: fn reason -> reason != :special end
             )

    assert Agent.get(counter, & &1) == 1
  end

  describe "transient?/1" do
    test "5xx and 429 are transient; other 4xx are not" do
      assert Retry.transient?({:api_error, 500, ""})
      assert Retry.transient?({:api_error, 503, ""})
      assert Retry.transient?({:api_error, 429, ""})
      refute Retry.transient?({:api_error, 404, ""})
      refute Retry.transient?({:api_error, 409, ""})
      refute Retry.transient?({:api_error, 422, ""})
    end

    test "unknown shapes default to transient" do
      assert Retry.transient?(:timeout)
      assert Retry.transient?(:closed)
      assert Retry.transient?(%RuntimeError{message: "x"})
    end
  end
end
