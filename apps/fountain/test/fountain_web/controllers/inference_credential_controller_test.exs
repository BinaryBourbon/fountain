defmodule FountainWeb.InferenceCredentialControllerTest do
  @moduledoc """
  BYO inference credentials over the API (#518).

  A conversation cannot run without one of these, and they could only be set in
  a browser — so an API-only consumer could register, create an agent, and then
  fail at the one step that matters. These tests pin the headless path, the
  provider-ping outcomes it has to distinguish, and the scope gate that keeps a
  sandbox from replacing the tenant's keys.
  """

  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.{Crypto, InferenceCredentials}

  setup do
    user = insert_verified_user()
    {_rec, key} = insert_api_key(user)
    {:ok, user: user, key: key}
  end

  defp ping_ok, do: stub(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 200}} end)

  defp stored_value(user, provider) do
    {:ok, dek} = Crypto.load_tenant_key(user.id)
    {:ok, creds} = InferenceCredentials.decrypted_for_user(user.id, dek)
    Map.get(creds, provider)
  end

  defp audit_actions(user_id) do
    user_id |> Fountain.Audit.list_recent_for_user(100) |> Enum.map(& &1.action)
  end

  describe "GET /api/account/inference-credentials" do
    test "reports every provider, unset", %{conn: conn, key: key} do
      body =
        conn
        |> authed_with_key(key)
        |> get("/api/account/inference-credentials")
        |> json_response(200)

      providers = Enum.map(body["data"], & &1["provider"])

      assert Enum.sort(providers) ==
               ~w(anthropic_api_key claude_code_oauth_token gemini_api_key openai_api_key)

      refute Enum.any?(body["data"], & &1["set"])
    end

    test "reports a set provider without ever returning the value", %{
      conn: conn,
      user: user,
      key: key
    } do
      {:ok, dek} = Crypto.load_tenant_key(user.id)
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "sk-live-xyz")

      conn = conn |> authed_with_key(key) |> get("/api/account/inference-credentials")
      body = json_response(conn, 200)

      assert Enum.find(body["data"], &(&1["provider"] == "openai_api_key"))["set"]
      refute conn.resp_body =~ "sk-live-xyz"
    end
  end

  describe "PUT /api/account/inference-credentials/:provider" do
    test "validates against the provider, then stores encrypted", %{
      conn: conn,
      user: user,
      key: key
    } do
      ping_ok()

      body =
        conn
        |> authed_with_key(key)
        |> put_json("/api/account/inference-credentials/anthropic_api_key", %{
          "value" => "sk-ant-real"
        })
        |> json_response(200)

      assert body["data"] == %{"provider" => "anthropic_api_key", "set" => true}
      assert stored_value(user, :anthropic_api_key) == "sk-ant-real"
      assert "inference_credential.write" in audit_actions(user.id)
    end

    test "the credential is never echoed back", %{conn: conn, key: key} do
      ping_ok()

      conn =
        conn
        |> authed_with_key(key)
        |> put_json("/api/account/inference-credentials/openai_api_key", %{
          "value" => "sk-openai-secret"
        })

      assert json_response(conn, 200)
      refute conn.resp_body =~ "sk-openai-secret"
    end

    test "the credential never reaches the audit log", %{conn: conn, user: user, key: key} do
      ping_ok()

      conn
      |> authed_with_key(key)
      |> put_json("/api/account/inference-credentials/openai_api_key", %{
        "value" => "sk-openai-secret"
      })
      |> json_response(200)

      events = Fountain.Audit.list_recent_for_user(user.id, 100)

      # Guard the guard (#406): an empty trail would make the refute vacuous.
      assert Enum.any?(events, &(&1.action == "inference_credential.write"))

      for event <- events, do: refute(inspect(event.metadata) =~ "sk-openai-secret")
    end

    test "a provider rejection is 422 and stores nothing", %{conn: conn, user: user, key: key} do
      stub(Req, :get, fn _url, _opts -> {:ok, %Req.Response{status: 401}} end)

      body =
        conn
        |> authed_with_key(key)
        |> put_json("/api/account/inference-credentials/anthropic_api_key", %{"value" => "typo"})
        |> json_response(422)

      assert body["reason"] == "invalid"
      assert body["provider_status"] == 401
      refute stored_value(user, :anthropic_api_key)
    end

    test "a timeout is 504, not 422 — the caller should retry, not re-type", %{
      conn: conn,
      user: user,
      key: key
    } do
      stub(Req, :get, fn _url, _opts -> {:error, %{reason: :timeout}} end)

      body =
        conn
        |> authed_with_key(key)
        |> put_json("/api/account/inference-credentials/gemini_api_key", %{"value" => "g-key"})
        |> json_response(504)

      assert body["reason"] == "timeout"
      refute stored_value(user, :gemini_api_key)
    end

    test "an unreachable provider is 502", %{conn: conn, key: key} do
      stub(Req, :get, fn _url, _opts -> {:error, %{reason: :nxdomain}} end)

      body =
        conn
        |> authed_with_key(key)
        |> put_json("/api/account/inference-credentials/openai_api_key", %{"value" => "sk-x"})
        |> json_response(502)

      assert body["reason"] == "network"
    end

    test "validate: false stores without pinging the provider", %{
      conn: conn,
      user: user,
      key: key
    } do
      # The settings page tells users they can "save anyway from the API" when
      # validation fails; that has to be true.
      reject(Req, :get, 2)

      conn
      |> authed_with_key(key)
      |> put_json("/api/account/inference-credentials/openai_api_key", %{
        "value" => "sk-unchecked",
        "validate" => false
      })
      |> json_response(200)

      assert stored_value(user, :openai_api_key) == "sk-unchecked"
    end

    test "a blank value is refused before any provider call", %{conn: conn, key: key} do
      reject(Req, :get, 2)

      body =
        conn
        |> authed_with_key(key)
        |> put_json("/api/account/inference-credentials/openai_api_key", %{"value" => "   "})
        |> json_response(422)

      assert body["reason"] == "empty_value"
    end

    test "an unknown provider is refused by the spec, before any provider call", %{
      conn: conn,
      key: key
    } do
      # The provider list is an enum in the OpenAPI path parameter, so
      # CastAndValidate refuses it (422) before the action runs.
      reject(Req, :get, 2)

      conn
      |> authed_with_key(key)
      |> put_json("/api/account/inference-credentials/nope", %{"value" => "x"})
      |> json_response(422)
    end
  end

  describe "DELETE /api/account/inference-credentials/:provider" do
    test "clears the credential", %{conn: conn, user: user, key: key} do
      {:ok, dek} = Crypto.load_tenant_key(user.id)
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :gemini_api_key, "g-key")

      conn
      |> authed_with_key(key)
      |> delete("/api/account/inference-credentials/gemini_api_key")
      |> response(204)

      refute stored_value(user, :gemini_api_key)
      assert "inference_credential.delete" in audit_actions(user.id)
    end

    test "clearing one provider leaves the others alone", %{conn: conn, user: user, key: key} do
      {:ok, dek} = Crypto.load_tenant_key(user.id)
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :gemini_api_key, "g-key")
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "o-key")

      conn
      |> authed_with_key(key)
      |> delete("/api/account/inference-credentials/gemini_api_key")
      |> response(204)

      assert stored_value(user, :openai_api_key) == "o-key"
    end
  end

  describe "the full-scope gate" do
    setup %{user: user} do
      {_rec, sprite_key} = insert_sprite_api_key(user)
      {:ok, sprite_key: sprite_key}
    end

    test "a sprite token cannot replace the tenant's credentials", %{
      conn: conn,
      user: user,
      sprite_key: sprite_key
    } do
      # The escalation that matters: code inside a sandbox swapping the keys the
      # account runs on, or reading which providers are configured.
      reject(Req, :get, 2)

      body =
        conn
        |> authed_with_key(sprite_key)
        |> put_json("/api/account/inference-credentials/anthropic_api_key", %{"value" => "sk-evil"})
        |> json_response(403)

      assert body["reason"] == "insufficient_scope"
      assert body["required_scope"] == "full"
      refute stored_value(user, :anthropic_api_key)
    end

    test "a sprite token cannot clear a credential", %{conn: conn, user: user, sprite_key: key} do
      {:ok, dek} = Crypto.load_tenant_key(user.id)
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "o-key")

      conn
      |> authed_with_key(key)
      |> delete("/api/account/inference-credentials/openai_api_key")
      |> json_response(403)

      assert stored_value(user, :openai_api_key) == "o-key"
    end

    test "a sprite token cannot list credential status", %{conn: conn, sprite_key: key} do
      conn
      |> authed_with_key(key)
      |> get("/api/account/inference-credentials")
      |> json_response(403)
    end

    test "an ordinary full key is allowed", %{conn: conn, key: key} do
      conn
      |> authed_with_key(key)
      |> get("/api/account/inference-credentials")
      |> json_response(200)
    end
  end

  describe "authentication" do
    test "no bearer token is 401", %{conn: conn} do
      conn
      |> put_req_header("accept", "application/json")
      |> get("/api/account/inference-credentials")
      |> json_response(401)
    end

    test "one tenant cannot see another's status", %{conn: conn, key: key} do
      other = insert_verified_user()
      {:ok, dek} = Crypto.load_tenant_key(other.id)
      {:ok, _} = InferenceCredentials.put_credential(other.id, dek, :openai_api_key, "not-yours")

      body =
        conn
        |> authed_with_key(key)
        |> get("/api/account/inference-credentials")
        |> json_response(200)

      refute Enum.any?(body["data"], & &1["set"])
    end
  end
end
