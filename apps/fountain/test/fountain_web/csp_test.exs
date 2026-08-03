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

  # The CSP plug lives in the :browser pipeline only, so today nothing on an
  # API path *could* set the header — this cannot catch #323 regressing.
  # What it pins is scope: if the policy ever migrates to the Endpoint or an
  # API pipeline, where it would ride along on every JSON/SSE response, this
  # is the test that notices.
  test "the policy stays scoped to browser responses — API paths carry none", %{conn: conn} do
    conn = get(conn, ~p"/health")
    assert get_resp_header(conn, "content-security-policy") == []
  end
end
