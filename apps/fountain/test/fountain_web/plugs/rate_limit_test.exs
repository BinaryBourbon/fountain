defmodule FountainWeb.Plugs.RateLimitTest do
  use FountainWeb.ConnCase, async: false

  alias FountainWeb.Plugs.RateLimit

  # All tests use a unique bucket so they don't share ETS state with other tests.
  defp unique_bucket, do: "test-#{System.unique_integer([:positive, :monotonic])}"

  setup do
    RateLimit.ensure_table()
    :ok
  end

  describe "ensure_table/0" do
    test "is idempotent — safe to call multiple times" do
      assert RateLimit.ensure_table() != :error
      assert RateLimit.ensure_table() != :error
    end
  end

  describe "init/1" do
    test "returns a map with bucket, max, and default window_ms" do
      opts = RateLimit.init(bucket: "test", max: 10)
      assert opts.bucket == "test"
      assert opts.max == 10
      assert opts.window_ms == 60_000
    end

    test "accepts a custom window_ms" do
      opts = RateLimit.init(bucket: "test", max: 5, window_ms: 1_000)
      assert opts.window_ms == 1_000
    end

    test "raises when :bucket is missing" do
      assert_raise KeyError, fn -> RateLimit.init(max: 10) end
    end

    test "raises when :max is missing" do
      assert_raise KeyError, fn -> RateLimit.init(bucket: "test") end
    end
  end

  describe "bump/2" do
    test "returns :ok on the first request" do
      opts = %{bucket: unique_bucket(), max: 5, window_ms: 60_000}
      key = {opts.bucket, self()}
      assert RateLimit.bump(key, opts) == :ok
    end

    test "returns :ok while under the limit" do
      opts = %{bucket: unique_bucket(), max: 3, window_ms: 60_000}
      key = {opts.bucket, self()}

      assert RateLimit.bump(key, opts) == :ok
      assert RateLimit.bump(key, opts) == :ok
      assert RateLimit.bump(key, opts) == :ok
    end

    test "returns {:limited, retry_after} when the limit is exceeded" do
      opts = %{bucket: unique_bucket(), max: 2, window_ms: 60_000}
      key = {opts.bucket, self()}

      RateLimit.bump(key, opts)
      RateLimit.bump(key, opts)

      assert {:limited, retry_secs} = RateLimit.bump(key, opts)
      assert retry_secs >= 1
    end

    test "resets the window after the window_ms has elapsed" do
      # Use a very short window (1 ms) so we can expire it immediately.
      opts = %{bucket: unique_bucket(), max: 1, window_ms: 1}
      key = {opts.bucket, self()}

      RateLimit.bump(key, opts)
      # Exhaust the single slot
      assert {:limited, _} = RateLimit.bump(key, opts)

      # Wait long enough for the window to expire
      Process.sleep(5)

      # New window — should be :ok again
      assert :ok = RateLimit.bump(key, opts)
    end
  end

  describe "call/2 — pass-through" do
    test "allows requests under the limit and does not halt the conn", %{conn: conn} do
      opts = RateLimit.init(bucket: unique_bucket(), max: 10)

      result = RateLimit.call(conn, opts)

      refute result.halted
    end
  end

  describe "call/2 — IP-based keying (isolation disabled)" do
    # These tests temporarily disable test isolation to exercise format_ip branches.
    # They restore isolation to `true` (not delete) so subsequent tests are unaffected.
    setup do
      Application.put_env(:fountain, :rate_limit_test_isolation, false)
      on_exit(fn -> Application.put_env(:fountain, :rate_limit_test_isolation, true) end)
    end

    test "uses IP tuple as key when isolation is off", %{conn: conn} do
      conn = %{conn | remote_ip: {10, 0, 0, 1}}
      opts = RateLimit.init(bucket: unique_bucket(), max: 10)
      result = RateLimit.call(conn, opts)
      refute result.halted
    end

    test "uses 'unknown' as key when remote_ip is nil", %{conn: conn} do
      conn = %{conn | remote_ip: nil}
      opts = RateLimit.init(bucket: unique_bucket(), max: 10)
      result = RateLimit.call(conn, opts)
      refute result.halted
    end
  end

  describe "call/2 — rate limited" do
    test "halts the conn with 429 when limit is exceeded", %{conn: conn} do
      opts = RateLimit.init(bucket: unique_bucket(), max: 1, window_ms: 60_000)

      # First request passes
      conn1 = RateLimit.call(conn, opts)
      refute conn1.halted

      # Second request is rate-limited (same process = same key in test isolation mode)
      conn2 = RateLimit.call(conn, opts)
      assert conn2.halted
      assert conn2.status == 429

      body = Jason.decode!(conn2.resp_body)
      assert body["error"] == "rate_limited"
      assert is_integer(body["retry_after_seconds"])
      assert body["retry_after_seconds"] >= 1

      [retry_after] = Plug.Conn.get_resp_header(conn2, "retry-after")
      assert String.to_integer(retry_after) >= 1
    end
  end
end
