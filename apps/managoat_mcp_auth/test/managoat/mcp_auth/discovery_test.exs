defmodule Managoat.McpAuth.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Managoat.McpAuth

  # A conforming server: 401 with the challenge, the resource document, the
  # AS metadata with registration, and a registration endpoint that issues a
  # confidential client.
  defp conforming_server(req) do
    case {req.method, req.request_path} do
      {"GET", "/mcp"} ->
        req
        |> Plug.Conn.put_resp_header(
          "www-authenticate",
          ~s(Bearer resource_metadata="https://mcp.example/.well-known/oauth-protected-resource/mcp")
        )
        |> Plug.Conn.send_resp(401, "")

      {"GET", "/.well-known/oauth-protected-resource/mcp"} ->
        Req.Test.json(req, %{
          "resource" => "https://mcp.example/mcp",
          "authorization_servers" => ["https://auth.example"],
          "scopes_supported" => ["mcp:tools"]
        })

      {"GET", "/.well-known/oauth-authorization-server"} ->
        Req.Test.json(req, %{
          "issuer" => "https://auth.example",
          "authorization_endpoint" => "https://auth.example/authorize",
          "token_endpoint" => "https://auth.example/token",
          "revocation_endpoint" => "https://auth.example/revoke",
          "registration_endpoint" => "https://auth.example/register",
          "code_challenge_methods_supported" => ["S256"],
          "token_endpoint_auth_methods_supported" => ["client_secret_post", "none"]
        })

      {"POST", "/register"} ->
        {:ok, body, _} = Plug.Conn.read_body(req)
        reg = Jason.decode!(body)
        assert reg["client_name"] == "Example client"
        assert reg["client_uri"] == "https://client.example"
        assert reg["redirect_uris"] == ["https://client.example/connections/x/callback"]
        assert reg["token_endpoint_auth_method"] == "client_secret_post"
        assert "refresh_token" in reg["grant_types"]

        req
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{
          "client_id" => "dcr-client",
          "client_secret" => "dcr-secret",
          "token_endpoint_auth_method" => "client_secret_post"
        })
    end
  end

  describe "discover/1" do
    test "follows the 401 challenge to the resource and authorization server metadata" do
      Req.Test.stub(stub_name(), &conforming_server/1)

      assert {:ok, md} = McpAuth.discover("https://mcp.example/mcp")
      assert md["issuer"] == "https://auth.example"
      assert md["authorization_endpoint"] == "https://auth.example/authorize"
      assert md["token_endpoint"] == "https://auth.example/token"
      assert md["revocation_endpoint"] == "https://auth.example/revoke"
      assert md["registration_endpoint"] == "https://auth.example/register"
      assert md["scopes"] == ["mcp:tools"]
      assert md["resource"] == "https://mcp.example/mcp"
    end

    test "falls back to the well-known path when the server names no resource metadata" do
      Req.Test.stub(stub_name(), fn req ->
        case req.request_path do
          "/mcp" ->
            Plug.Conn.send_resp(req, 401, "")

          "/.well-known/oauth-protected-resource/mcp" ->
            Plug.Conn.send_resp(req, 404, "")

          "/.well-known/oauth-protected-resource" ->
            Req.Test.json(req, %{"authorization_servers" => ["https://auth.example/tenant"]})

          "/.well-known/oauth-authorization-server/tenant" ->
            Plug.Conn.send_resp(req, 404, "")

          "/tenant/.well-known/openid-configuration" ->
            Req.Test.json(req, %{
              "issuer" => "https://auth.example/tenant",
              "authorization_endpoint" => "https://auth.example/tenant/authorize",
              "token_endpoint" => "https://auth.example/tenant/token"
            })
        end
      end)

      assert {:ok, md} = McpAuth.discover("https://mcp.example/mcp")
      assert md["issuer"] == "https://auth.example/tenant"
      assert is_nil(md["registration_endpoint"])
      assert md["scopes"] == []
    end

    test "refuses a non-https server and a metadata chain that points somewhere private" do
      assert {:error, {:unsafe_url, _, :not_https}} =
               McpAuth.discover("http://mcp.example/mcp")

      Req.Test.stub(stub_name(), fn req ->
        case req.request_path do
          "/mcp" ->
            req
            |> Plug.Conn.put_resp_header(
              "www-authenticate",
              ~s(Bearer resource_metadata="https://169.254.169.254/latest")
            )
            |> Plug.Conn.send_resp(401, "")
        end
      end)

      assert {:error, {:unsafe_url, "https://169.254.169.254/latest", :ip_literal}} =
               McpAuth.discover("https://mcp.example/mcp")
    end

    test "says so when the resource names no authorization server" do
      Req.Test.stub(stub_name(), fn req ->
        case req.request_path do
          "/mcp" -> Plug.Conn.send_resp(req, 401, "")
          "/.well-known/oauth-protected-resource/mcp" -> Req.Test.json(req, %{"resource" => "x"})
        end
      end)

      assert {:error, :no_authorization_server} =
               McpAuth.discover("https://mcp.example/mcp")
    end
  end

  describe "register/3" do
    test "registers a named client and reports the auth method" do
      Req.Test.stub(stub_name(), &conforming_server/1)
      {:ok, md} = McpAuth.discover("https://mcp.example/mcp")

      assert {:ok, client} =
               McpAuth.register(md, "https://client.example/connections/x/callback",
                 client_name: "Example client",
                 client_uri: "https://client.example"
               )

      assert client == %{
               "client_id" => "dcr-client",
               "client_secret" => "dcr-secret",
               "token_endpoint_auth" => "client_secret_post",
               "client_source" => "dcr"
             }

      assert {:error, :no_registration_endpoint} =
               McpAuth.register(%{}, "https://client.example/cb", [])
    end

    test "requires the client name and URI" do
      md = %{"registration_endpoint" => "https://auth.example/register"}

      assert_raise KeyError, fn ->
        McpAuth.register(md, "https://client.example/cb", client_uri: "https://client.example")
      end

      assert_raise KeyError, fn ->
        McpAuth.register(md, "https://client.example/cb", client_name: "Example client")
      end
    end
  end

  defp stub_name do
    {Req.Test, name} =
      :managoat_mcp_auth
      |> Application.fetch_env!(:req_options)
      |> Keyword.fetch!(:plug)

    name
  end
end
