defmodule FountainWeb.OAuthControllerTest do
  @moduledoc "The consent page, the token endpoint and revoke — Fountain as an OAuth server (#817)."
  use FountainWeb.ConnCase, async: true

  alias Fountain.{Accounts, OAuth}

  @client "test-app"
  @redirect "https://app.test/callback"

  defp pkce do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {verifier, Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)}
  end

  defp authorize_qs(challenge, over \\ %{}) do
    %{
      "client_id" => @client,
      "redirect_uri" => @redirect,
      "code_challenge" => challenge,
      "code_challenge_method" => "S256",
      "state" => "xyz"
    }
    |> Map.merge(over)
    |> URI.encode_query()
  end

  describe "GET /oauth/authorize" do
    test "signed out: stashes the request and goes to login; login returns to it", %{conn: conn} do
      {_v, c} = pkce()
      conn = get(conn, "/oauth/authorize?" <> authorize_qs(c))
      assert redirected_to(conn) == "/auth/login"
      assert get_session(conn, :return_to) == "/oauth/authorize?" <> authorize_qs(c)

      # Log in with the same session: the login lands back on the consent page.
      user = insert_verified_user(password: "correct horse battery")

      conn =
        conn
        |> recycle()
        |> Plug.Test.init_test_session(%{return_to: "/oauth/authorize?" <> authorize_qs(c)})
        |> post("/auth/login", %{"email" => user.email, "password" => "correct horse battery"})

      assert redirected_to(conn) == "/oauth/authorize?" <> authorize_qs(c)
    end

    test "signed in: shows the consent page naming the client", %{conn: conn} do
      user = insert_verified_user()
      {_v, c} = pkce()

      html =
        conn
        |> login_user(user)
        |> get("/oauth/authorize?" <> authorize_qs(c))
        |> html_response(200)

      assert html =~ "Sign in to Test App?"
      assert html =~ user.email
      assert html =~ ~s(name="decision" value="allow")
    end

    test "the consent page's form-action CSP allows the client's redirect origin", %{conn: conn} do
      user = insert_verified_user()
      {_v, c} = pkce()
      conn = conn |> login_user(user) |> get("/oauth/authorize?" <> authorize_qs(c))
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "form-action 'self' https://app.test"
    end

    test "an unregistered client or redirect renders, never redirects", %{conn: conn} do
      user = insert_verified_user()
      {_v, c} = pkce()

      html =
        conn
        |> login_user(user)
        |> get("/oauth/authorize?" <> authorize_qs(c, %{"client_id" => "nope"}))
        |> html_response(400)

      assert html =~ "not registered"

      html =
        conn
        |> login_user(user)
        |> get("/oauth/authorize?" <> authorize_qs(c, %{"redirect_uri" => "https://evil.test/"}))
        |> html_response(400)

      assert html =~ "redirect_uri"
    end
  end

  describe "POST /oauth/authorize" do
    test "allow → redirect to the app with a code and the state; deny → access_denied", %{
      conn: conn
    } do
      user = insert_verified_user()
      {_v, c} = pkce()

      params = %{
        "client_id" => @client,
        "redirect_uri" => @redirect,
        "code_challenge" => c,
        "code_challenge_method" => "S256",
        "state" => "xyz"
      }

      conn1 =
        conn |> login_user(user) |> post("/oauth/authorize", Map.put(params, "decision", "allow"))

      loc = redirected_to(conn1)
      assert String.starts_with?(loc, @redirect <> "?")
      q = loc |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      assert q["state"] == "xyz"
      assert is_binary(q["code"]) and byte_size(q["code"]) > 20

      conn2 =
        conn |> login_user(user) |> post("/oauth/authorize", Map.put(params, "decision", "deny"))

      q2 = conn2 |> redirected_to() |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      assert q2 == %{"error" => "access_denied", "state" => "xyz"}
    end

    test "a bad request on POST renders too", %{conn: conn} do
      user = insert_verified_user()
      {_v, c} = pkce()

      resp =
        conn
        |> login_user(user)
        |> post("/oauth/authorize", %{
          "client_id" => "nope",
          "redirect_uri" => @redirect,
          "code_challenge" => c,
          "decision" => "allow"
        })

      assert html_response(resp, 400) =~ "not registered"
    end
  end

  describe "POST /api/oauth/token" do
    test "exchanges the code + verifier for a bearer key that works, no-store", %{conn: conn} do
      user = insert_verified_user()
      {v, c} = pkce()

      {:ok, code} =
        OAuth.authorize(user.id, %{
          "client_id" => @client,
          "redirect_uri" => @redirect,
          "code_challenge" => c
        })

      resp =
        post_json(conn, "/api/oauth/token", %{
          grant_type: "authorization_code",
          code: code,
          code_verifier: v,
          client_id: @client,
          redirect_uri: @redirect
        })

      body = json_response(resp, 200)
      assert body["token_type"] == "bearer"
      assert body["expires_in"] == OAuth.token_ttl_seconds()
      assert get_resp_header(resp, "cache-control") == ["no-store"]

      me =
        conn |> authed_with_key(body["access_token"]) |> get("/api/auth/me") |> json_response(200)

      assert me["id"] == user.id
    end

    test "invalid_grant for a wrong verifier; unsupported_grant_type otherwise", %{conn: conn} do
      user = insert_verified_user()
      {v, c} = pkce()

      {:ok, code} =
        OAuth.authorize(user.id, %{
          "client_id" => @client,
          "redirect_uri" => @redirect,
          "code_challenge" => c
        })

      assert %{"error" => "invalid_grant"} =
               conn
               |> post_json("/api/oauth/token", %{
                 grant_type: "authorization_code",
                 code: code,
                 code_verifier: v <> "x",
                 client_id: @client,
                 redirect_uri: @redirect
               })
               |> json_response(400)

      assert %{"error" => "unsupported_grant_type"} =
               conn
               |> post_json("/api/oauth/token", %{
                 grant_type: "password",
                 code: "x",
                 code_verifier: "y",
                 client_id: @client,
                 redirect_uri: @redirect
               })
               |> json_response(400)
    end
  end

  test "POST /api/oauth/revoke revokes the presented key", %{conn: conn} do
    user = insert_verified_user()
    {_rec, raw} = insert_api_key(user)
    assert conn |> authed_with_key(raw) |> post("/api/oauth/revoke") |> response(204)
    assert {:error, :revoked} = Accounts.authenticate_api_key(raw)
  end
end
