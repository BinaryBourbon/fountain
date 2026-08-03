defmodule FountainWeb.PreAuthRateLimitTest do
  # #316: TenantAPIAuth halts 401 before RateLimit ever ran, so failed API
  # auth was unmetered — anonymous callers got unlimited attempts, each
  # costing a SHA-256 plus an indexed api_keys lookup. The limiter must run
  # first. These go through the real router pipeline; the bucket is keyed to
  # this test process (rate_limit_test_isolation), so filling it only
  # affects requests dispatched here.
  use FountainWeb.ConnCase, async: true

  alias FountainWeb.Plugs.RateLimit

  defp fill_api_bucket do
    RateLimit.ensure_table()
    now = System.system_time(:millisecond)
    :ets.insert(RateLimit.table(), {{"api", self()}, now, 600})
  end

  test "unauthenticated requests are metered — 429 wins over 401 when the bucket is full",
       %{conn: conn} do
    fill_api_bucket()

    conn =
      conn
      |> put_req_header("authorization", "Bearer not-a-real-key")
      |> get(~p"/api/agents")

    # With the pre-#316 plug order this was a 401: auth halted first and the
    # limiter never saw the request.
    assert conn.status == 429
  end

  test "a missing Authorization header is metered too", %{conn: conn} do
    fill_api_bucket()
    assert get(conn, ~p"/api/agents").status == 429
  end

  test "under the limit, unauthenticated requests still 401", %{conn: conn} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer not-a-real-key")
      |> get(~p"/api/agents")

    assert conn.status == 401
  end

  test "under the limit, authenticated requests still work", %{conn: conn} do
    user = insert_verified_user()
    {:ok, {_key, raw_key}} = Fountain.Accounts.create_api_key(user.id, "t")

    conn =
      conn
      |> authed_with_key(raw_key)
      |> get(~p"/api/agents")

    assert conn.status == 200
  end
end
