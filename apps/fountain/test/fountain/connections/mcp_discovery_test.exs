defmodule Fountain.Connections.McpDiscoveryTest do
  use Fountain.DataCase, async: true

  alias Fountain.Connections
  alias Fountain.Connections.{McpDiscovery, OAuth, Provider}

  # A conforming server: 401 with the challenge, the resource document, the
  # AS metadata with registration, and a registration endpoint that issues a
  # confidential client.
  defp conforming_server(req, opts \\ []) do
    registers? = Keyword.get(opts, :register, true)

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
        Req.Test.json(
          req,
          %{
            "issuer" => "https://auth.example",
            "authorization_endpoint" => "https://auth.example/authorize",
            "token_endpoint" => "https://auth.example/token",
            "revocation_endpoint" => "https://auth.example/revoke",
            "code_challenge_methods_supported" => ["S256"],
            "token_endpoint_auth_methods_supported" => ["client_secret_post", "none"]
          }
          |> then(
            &if registers?,
              do: Map.put(&1, "registration_endpoint", "https://auth.example/register"),
              else: &1
          )
        )

      {"POST", "/register"} ->
        {:ok, body, _} = Plug.Conn.read_body(req)
        reg = Jason.decode!(body)
        assert reg["redirect_uris"] |> hd() =~ "/connections/"
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
      Req.Test.stub(OAuth, &conforming_server/1)

      assert {:ok, md} = McpDiscovery.discover("https://mcp.example/mcp")
      assert md["issuer"] == "https://auth.example"
      assert md["authorization_endpoint"] == "https://auth.example/authorize"
      assert md["token_endpoint"] == "https://auth.example/token"
      assert md["revocation_endpoint"] == "https://auth.example/revoke"
      assert md["registration_endpoint"] == "https://auth.example/register"
      assert md["scopes"] == ["mcp:tools"]
      assert md["resource"] == "https://mcp.example/mcp"
    end

    test "falls back to the well-known path when the server names no resource metadata" do
      Req.Test.stub(OAuth, fn req ->
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

      assert {:ok, md} = McpDiscovery.discover("https://mcp.example/mcp")
      assert md["issuer"] == "https://auth.example/tenant"
      assert is_nil(md["registration_endpoint"])
      assert md["scopes"] == []
    end

    test "refuses a non-https server and a metadata chain that points somewhere private" do
      assert {:error, {:unsafe_url, _, :not_https}} =
               McpDiscovery.discover("http://mcp.example/mcp")

      Req.Test.stub(OAuth, fn req ->
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
               McpDiscovery.discover("https://mcp.example/mcp")
    end

    test "says so when the resource names no authorization server or the AS metadata is incomplete" do
      Req.Test.stub(OAuth, fn req ->
        case req.request_path do
          "/mcp" -> Plug.Conn.send_resp(req, 401, "")
          "/.well-known/oauth-protected-resource/mcp" -> Req.Test.json(req, %{"resource" => "x"})
        end
      end)

      assert {:error, :no_authorization_server} = McpDiscovery.discover("https://mcp.example/mcp")
    end
  end

  describe "register/2" do
    test "registers a client and reports the auth method" do
      Req.Test.stub(OAuth, &conforming_server/1)
      {:ok, md} = McpDiscovery.discover("https://mcp.example/mcp")

      assert {:ok, client} = McpDiscovery.register(md, "https://f.example/connections/x/callback")

      assert client == %{
               "client_id" => "dcr-client",
               "client_secret" => "dcr-secret",
               "token_endpoint_auth" => "client_secret_post",
               "client_source" => "dcr"
             }

      assert {:error, :no_registration_endpoint} =
               McpDiscovery.register(%{}, "https://f.example/cb")
    end
  end

  describe "Connections.discover_provider/4" do
    test "builds an mcp provider with a registered client; a second provider registers its own" do
      user = insert_verified_user()
      Req.Test.stub(OAuth, &conforming_server/1)

      assert {:ok, %Provider{} = p} =
               Connections.discover_provider(user.id, "https://mcp.example/mcp")

      assert p.kind == "mcp"
      assert p.slug == "mcp-example"
      assert p.name == "mcp-example"
      assert p.env_key == "MCP_EXAMPLE_ACCESS_TOKEN"
      assert p.issuer == "https://auth.example"
      assert p.authorize_url == "https://auth.example/authorize"
      assert p.token_url == "https://auth.example/token"
      assert p.revoke_url == "https://auth.example/revoke"
      assert p.client_id == "dcr-client"
      assert p.client_source == "dcr"
      assert p.pkce
      assert p.token_hosts == ["mcp.example"]
      assert p.scopes == ["mcp:tools"]
      assert {:ok, %Provider{client_secret: "dcr-secret"}} = Connections.unlock_provider(p)

      # A second provider behind the same issuer registers its own client:
      # a registration names one redirect URI, and this provider's callback
      # is not the first one's.
      test_pid = self()

      Req.Test.stub(OAuth, fn req ->
        if req.method == "POST" and req.request_path == "/register" do
          {:ok, body, _} = Plug.Conn.read_body(req)
          send(test_pid, {:registered, Jason.decode!(body)["redirect_uris"]})

          req
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(%{
            "client_id" => "dcr-client-2",
            "client_secret" => "dcr-secret-2",
            "token_endpoint_auth_method" => "client_secret_post"
          })
        else
          conforming_server(req)
        end
      end)

      assert {:ok, p2} =
               Connections.discover_provider(user.id, "https://mcp.example/mcp", %{
                 "slug" => "second"
               })

      assert p2.client_id == "dcr-client-2"
      assert p2.client_source == "dcr"
      assert p2.env_key == "SECOND_ACCESS_TOKEN"

      assert_received {:registered, [uri]}
      assert uri == Connections.redirect_uri(p2)
      refute uri == Connections.redirect_uri(p)

      # The authorize URL carries PKCE and the resource.
      {:ok, p} = Connections.unlock_provider(p)
      url = OAuth.authorize_url(p, "https://f.example/cb", "st", OAuth.code_verifier())
      q = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert q["resource"] == "https://mcp.example/mcp"
      assert q["code_challenge_method"] == "S256"
    end

    test "a server without registration is saved without a client unless the tenant pastes one" do
      user = insert_verified_user()
      Req.Test.stub(OAuth, &conforming_server(&1, register: false))

      assert {:ok, %Provider{client_id: nil, client_source: nil}} =
               Connections.discover_provider(user.id, "https://mcp.example/mcp")

      assert {:ok, %Provider{client_id: "manual-id", client_source: "manual"} = p} =
               Connections.discover_provider(user.id, "https://mcp.example/mcp", %{
                 "slug" => "manual",
                 "client_id" => "manual-id",
                 "client_secret" => "manual-secret"
               })

      assert {:ok, %Provider{client_secret: "manual-secret"}} = Connections.unlock_provider(p)
    end

    test "rediscover refreshes the endpoints and keeps the client while the issuer is the same" do
      user = insert_verified_user()
      Req.Test.stub(OAuth, &conforming_server/1)
      {:ok, p} = Connections.discover_provider(user.id, "https://mcp.example/mcp")

      Req.Test.stub(OAuth, fn req ->
        if req.request_path == "/register", do: flunk("same issuer, same client")
        conforming_server(req)
      end)

      assert {:ok, p2} = Connections.rediscover_provider(p)
      assert p2.client_id == "dcr-client"
      assert p2.authorize_url == "https://auth.example/authorize"
    end
  end
end
