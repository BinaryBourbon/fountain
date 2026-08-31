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

  describe "device authorization (#1305)" do
    alias Fountain.OAuth.DeviceGrant

    test "the happy path: start → approve in the console → poll mints a key, once" do
      user = insert_verified_user()

      assert {:ok, %{device_code: device_code, user_code: user_code} = grant} =
               OAuth.start_device_grant()

      assert grant.expires_in == 900
      assert grant.interval == OAuth.device_interval_seconds()
      # The display shape a human types back in, dash and all.
      assert user_code =~ ~r/^[BCDFGHJKLMNPQRSTVWXZ]{4}-[BCDFGHJKLMNPQRSTVWXZ]{4}$/

      # Nobody has decided yet.
      assert {:error, :authorization_pending} = OAuth.poll_device_grant(device_code)

      # The approval page finds it however the human typed it.
      assert {:ok, _} = OAuth.get_device_grant_for_approval(String.downcase(user_code))
      assert :ok = OAuth.approve_device_grant(user_code, user.id, actor: "ui")

      assert {:ok, %{access_token: token, api_key: key}} =
               OAuth.poll_device_grant(device_code, actor: "api")

      assert key.name =~ "CLI login"
      assert key.scopes == ["full"]
      assert is_nil(key.expires_at)
      assert {:ok, %{id: uid}, _} = Accounts.authenticate_api_key(token)
      assert uid == user.id

      # Single use: the grant is consumed with the mint.
      assert {:error, :invalid_grant} = OAuth.poll_device_grant(device_code)

      actions = user.id |> Audit.list_recent_for_user(20) |> Enum.map(& &1.action)
      assert "oauth.device_approved" in actions
      assert "api_key.created" in actions
    end

    test "polling faster than the interval gets slow_down" do
      {:ok, %{device_code: device_code}} = OAuth.start_device_grant()

      assert {:error, :authorization_pending} = OAuth.poll_device_grant(device_code)
      assert {:error, :slow_down} = OAuth.poll_device_grant(device_code)
    end

    test "a denial reaches the polling CLI as access_denied and audits" do
      user = insert_verified_user()
      {:ok, %{device_code: device_code, user_code: user_code}} = OAuth.start_device_grant()

      assert :ok = OAuth.deny_device_grant(user_code, user.id, actor: "ui")
      assert {:error, :access_denied} = OAuth.poll_device_grant(device_code)

      # Decided is decided: no second opinion, in either direction.
      assert {:error, :not_found} = OAuth.approve_device_grant(user_code, user.id)
      assert {:error, :not_found} = OAuth.get_device_grant_for_approval(user_code)

      actions = user.id |> Audit.list_recent_for_user(20) |> Enum.map(& &1.action)
      assert "oauth.device_denied" in actions
    end

    test "an expired grant is expired_token to the poll, invisible to approval, and pruned" do
      user = insert_verified_user()
      {:ok, %{device_code: device_code, user_code: user_code}} = OAuth.start_device_grant()

      Repo.update_all(DeviceGrant,
        set: [
          expires_at: DateTime.add(DateTime.utc_now(), -1, :second) |> DateTime.truncate(:second)
        ]
      )

      assert {:error, :expired_token} = OAuth.poll_device_grant(device_code)
      assert {:error, :not_found} = OAuth.get_device_grant_for_approval(user_code)
      assert {:error, :not_found} = OAuth.approve_device_grant(user_code, user.id)
      assert OAuth.prune_expired() >= 1
    end

    test "an unknown device code is invalid_grant" do
      assert {:error, :invalid_grant} = OAuth.poll_device_grant("not-a-code")
    end

    test "a suspended approver cannot collect a key" do
      user = insert_verified_user()
      {:ok, %{device_code: device_code, user_code: user_code}} = OAuth.start_device_grant()
      assert :ok = OAuth.approve_device_grant(user_code, user.id)

      {:ok, _, _} = Accounts.suspend_user(user, actor: "admin")

      assert {:error, :access_denied} = OAuth.poll_device_grant(device_code)
    end

    test "normalize_user_code strips the display shape" do
      assert OAuth.normalize_user_code(" bcdf-ghjk ") == "BCDFGHJK"
      assert OAuth.format_user_code("BCDFGHJK") == "BCDF-GHJK"
    end
  end

  test "pkce_verify is S256 and constant-shape" do
    {v, c} = pkce()
    assert OAuth.pkce_verify(v, c)
    refute OAuth.pkce_verify(v <> "a", c)
    refute OAuth.pkce_verify(nil, c)
  end
end
