defmodule FountainWeb.CSPTest do
  use FountainWeb.ConnCase, async: true

  # #323: the browser pipeline had no Content-Security-Policy at all. The
  # policy is deliberately loose on script-src (the root layout runs CDN
  # scripts and inline handlers) — what must hold is that a policy exists and
  # pins the high-value directives.
  test "browser responses carry a Content-Security-Policy", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "default-src 'self'"
    assert csp =~ "frame-ancestors 'self'"
    assert csp =~ "object-src 'none'"
    assert csp =~ "base-uri 'self'"
  end

  test "API responses are not affected", %{conn: conn} do
    conn = get(conn, ~p"/health")
    assert get_resp_header(conn, "content-security-policy") == []
  end
end
