defmodule Fountain.OAuthTest do
  use Fountain.DataCase, async: true

  alias Fountain.{Accounts, Audit, OAuth}

  @client "test-app"
  @redirect "https://app.test/callback"

  defp pkce do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {verifier, Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)}
  end

  defp request(challenge, over \\ %{}) do
    Map.merge(
      %{
        "client_id" => @client,
        "redirect_uri" => @redirect,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256"
      },
      over
    )
  end

  describe "validate_request/1" do
    test "accepts a registered client, exact redirect and S256 challenge" do
      {_v, c} = pkce()
      assert {:ok, %{id: @client}} = OAuth.validate_request(request(c))
    end

    test "refuses what must never redirect" do
      {_v, c} = pkce()

      assert {:error, :unknown_client} =
               OAuth.validate_request(request(c, %{"client_id" => "nope"}))

      assert {:error, :redirect_uri_mismatch} =
               OAuth.validate_request(
                 request(c, %{"redirect_uri" => "https://app.test/callback?x=1"})
               )

      assert {:error, :redirect_uri_mismatch} =
               OAuth.validate_request(request(c, %{"redirect_uri" => "https://evil.test/"}))

      assert {:error, :unsupported_code_challenge_method} =
               OAuth.validate_request(request(c, %{"code_challenge_method" => "plain"}))

      assert {:error, :invalid_code_challenge} = OAuth.validate_request(request("short"))
      assert {:error, :invalid_code_challenge} = OAuth.validate_request(request(nil))
    end
  end

  describe "authorize/3 + exchange/2" do
    test "the happy path mints a 30-day oauth:<client> API key that authenticates, once" do
      user = insert_verified_user()
      {verifier, challenge} = pkce()

      assert {:ok, code} = OAuth.authorize(user.id, request(challenge), actor: "ui")

      assert {:ok, %{access_token: token, expires_in: ttl, api_key: key}} =
               OAuth.exchange(%{
                 "code" => code,
                 "code_verifier" => verifier,
                 "client_id" => @client,
                 "redirect_uri" => @redirect
               })

      assert ttl == OAuth.token_ttl_seconds()
      assert key.name == "oauth:test-app"
      assert key.scopes == ["full"]
      assert DateTime.diff(key.expires_at, DateTime.utc_now()) > 29 * 24 * 3600
      assert {:ok, %{id: uid}, _} = Accounts.authenticate_api_key(token)
      assert uid == user.id

      # single use
      assert {:error, :invalid_grant} =
               OAuth.exchange(%{
                 "code" => code,
                 "code_verifier" => verifier,
                 "client_id" => @client,
                 "redirect_uri" => @redirect
               })

      actions = user.id |> Audit.list_recent_for_user(20) |> Enum.map(& &1.action)
      assert "oauth.authorized" in actions
      assert "api_key.created" in actions
    end

    test "every wrong grant is one answer" do
      user = insert_verified_user()
      {verifier, challenge} = pkce()
      {:ok, code} = OAuth.authorize(user.id, request(challenge))

      base = %{
        "code" => code,
        "code_verifier" => verifier,
        "client_id" => @client,
        "redirect_uri" => @redirect
      }

      assert {:error, :invalid_grant} =
               OAuth.exchange(%{base | "code_verifier" => verifier <> "x"})

      assert {:error, :invalid_grant} = OAuth.exchange(%{base | "client_id" => "other"})

      assert {:error, :invalid_grant} =
               OAuth.exchange(%{base | "redirect_uri" => "http://localhost:5173/"})

      assert {:error, :invalid_grant} = OAuth.exchange(%{base | "code" => "not-a-code"})
      assert {:error, :invalid_grant} = OAuth.exchange(Map.delete(base, "code_verifier"))
      # None of those consumed the code.
      assert {:ok, _} = OAuth.exchange(base)
    end

    test "an expired code is refused and pruned" do
      user = insert_verified_user()
      {verifier, challenge} = pkce()
      {:ok, code} = OAuth.authorize(user.id, request(challenge))

      Repo.update_all(Fountain.OAuth.AuthorizationCode,
        set: [
          expires_at: DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)
        ]
      )

      assert {:error, :invalid_grant} =
               OAuth.exchange(%{
                 "code" => code,
                 "code_verifier" => verifier,
                 "client_id" => @client,
                 "redirect_uri" => @redirect
               })

      assert OAuth.prune_expired() >= 1
    end
  end

  test "pkce_verify is S256 and constant-shape" do
    {v, c} = pkce()
    assert OAuth.pkce_verify(v, c)
    refute OAuth.pkce_verify(v <> "a", c)
    refute OAuth.pkce_verify(nil, c)
  end
end
