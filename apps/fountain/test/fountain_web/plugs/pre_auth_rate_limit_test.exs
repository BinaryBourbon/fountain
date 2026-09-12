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
    :ets.insert(RateLimit.table(), {{"api", self()}, now, 6_000})
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

  test "a noisy key cannot consume a quiet key's quota through their shared address" do
    user = insert_verified_user()
    {noisy, noisy_key} = insert_api_key(user)
    {quiet, quiet_key} = insert_api_key(user)
    now = System.system_time(:millisecond)
    RateLimit.ensure_table()

    :ets.insert(RateLimit.table(), [
      {{"api", self()}, now, 600},
      {{"api-key", noisy.id, self()}, now, 600}
    ])

    assert get(authed_with_key(build_conn(), noisy_key), ~p"/api/agents").status == 429
    assert get(authed_with_key(build_conn(), quiet_key), ~p"/api/agents").status == 200

    :ets.insert(RateLimit.table(), {{"api-key", quiet.id, self()}, now, 599})
    assert get(authed_with_key(build_conn(), quiet_key), ~p"/api/agents").status == 200
    assert get(authed_with_key(build_conn(), quiet_key), ~p"/api/agents").status == 429
  end

  test "failed authentication retains 600 attempts without blocking a valid key" do
    user = insert_verified_user()
    {_key, raw_key} = insert_api_key(user)
    RateLimit.ensure_table()

    :ets.insert(
      RateLimit.table(),
      {{"api-auth-failure", self()}, System.system_time(:millisecond), 599}
    )

    assert get(build_conn(), ~p"/api/agents").status == 401
    refused = get(build_conn(), ~p"/api/agents")
    assert refused.status == 429
    assert get_resp_header(refused, "retry-after") != []
    assert get(authed_with_key(build_conn(), raw_key), ~p"/api/agents").status == 200
  end

  test "unverified keys share the authentication-refusal budget" do
    user = insert_user()
    {_key, raw_key} = insert_api_key(user)
    RateLimit.ensure_table()

    :ets.insert(
      RateLimit.table(),
      {{"api-auth-failure", self()}, System.system_time(:millisecond), 599}
    )

    assert get(authed_with_key(build_conn(), raw_key), ~p"/api/agents").status == 403
    assert get(authed_with_key(build_conn(), raw_key), ~p"/api/agents").status == 429
  end

  test "the intentional aggregate ceiling also bounds authenticated traffic" do
    user = insert_verified_user()
    {_key, raw_key} = insert_api_key(user)
    fill_api_bucket()
    assert get(authed_with_key(build_conn(), raw_key), ~p"/api/agents").status == 429
  end

  test "the pipeline accepts forwarding only from a trusted proxy" do
    direct = %{build_conn() | remote_ip: {198, 51, 100, 9}}
    direct = direct |> put_req_header("x-forwarded-for", "203.0.113.7") |> get(~p"/api/agents")
    assert direct.status == 401
    assert direct.remote_ip == {198, 51, 100, 9}

    proxied = %{build_conn() | remote_ip: {10, 42, 0, 1}}
    proxied = proxied |> put_req_header("x-forwarded-for", "203.0.113.7") |> get(~p"/api/agents")
    assert proxied.status == 401
    assert proxied.remote_ip == {203, 0, 113, 7}
  end
end
