defmodule Fountain.BrokerTest do
  # The Agent Vault client and the placeholder rule (ADR 0019 gate 1a). The
  # HTTP calls are stubbed at `Req`, the repo's one client; the request
  # shapes asserted here are the ones verified against agent-vault 0.39.1.
  use ExUnit.Case, async: false
  use Mimic

  alias Fountain.Broker

  @conv "0b0f6e1a-4d4c-4c1a-9a2b-3c4d5e6f7a8b"

  setup do
    previous =
      for key <- [:broker_url, :broker_token, :broker_proxy_url, :broker_tenants],
          do: {key, Application.get_env(:fountain, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:fountain, key),
          else: Application.put_env(:fountain, key, value)
      end
    end)

    :ok
  end

  defp configure(tenants \\ []) do
    Application.put_env(:fountain, :broker_url, "http://broker.test:14321")
    Application.put_env(:fountain, :broker_token, "av_sess_owner")
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")
    Application.put_env(:fountain, :broker_tenants, tenants)
  end

  describe "the switch" do
    test "blank BROKER_URL means off, for every tenant" do
      Application.delete_env(:fountain, :broker_url)
      Application.put_env(:fountain, :broker_tenants, ["u1"])

      refute Broker.configured?()
      refute Broker.enabled_for?("u1")
    end

    test "configured, only the tenants on the ratchet are brokered" do
      configure(["u1"])

      assert Broker.enabled_for?("u1")
      refute Broker.enabled_for?("u2")
      refute Broker.enabled_for?(nil)
    end

    test "the proxy host is the one host a brokered sandbox may reach" do
      configure()
      assert Broker.proxy_host() == "broker.test"
    end
  end

  describe "split/1" do
    test "catalog keys become placeholders; the values move to the broker side" do
      secrets = %{
        "GITHUB_TOKEN" => "ghp_real",
        "GH_TOKEN" => "ghp_other",
        "DATABASE_URL" => "postgres://x",
        "EMPTY" => ""
      }

      assert {sandbox, brokered} = Broker.split(secrets)

      assert sandbox == %{
               "GITHUB_TOKEN" => "__github_token__",
               "GH_TOKEN" => "__gh_token__",
               "DATABASE_URL" => "postgres://x",
               "EMPTY" => ""
             }

      assert brokered == %{"GITHUB_TOKEN" => "ghp_real", "GH_TOKEN" => "ghp_other"}
    end

    test "an empty catalog value is not brokered: there is nothing to attach" do
      assert {%{"GITHUB_TOKEN" => ""}, %{}} = Broker.split(%{"GITHUB_TOKEN" => ""})
    end

    test "no catalog key, nothing changes" do
      assert {%{"A" => "1"}, %{}} = Broker.split(%{"A" => "1"})
    end
  end

  describe "the sandbox side" do
    test "the vault name is the conversation id in the broker's alphabet" do
      assert Broker.vault_name(@conv) == "c-0b0f6e1a4d4c4c1a9a2b3c4d5e6f7a8b"
      assert String.length(Broker.vault_name(@conv)) <= 64
    end

    test "sandbox_env carries the token inside the proxy address, and the CA path" do
      configure()
      env = Broker.sandbox_env(%{vault: "c-x", token: "av_sess_t", expires_at: nil})

      assert {"HTTPS_PROXY", "http://av_sess_t@broker.test:14322"} in env
      assert {"HTTP_PROXY", "http://av_sess_t@broker.test:14322"} in env
      assert {"https_proxy", "http://av_sess_t@broker.test:14322"} in env
      assert {"http_proxy", "http://av_sess_t@broker.test:14322"} in env
      assert {"NODE_EXTRA_CA_CERTS", Broker.ca_path()} in env
      assert Enum.map(env, &elem(&1, 0)) -- Broker.env_keys() == []
    end

    test "every token-carrying variable is process-only" do
      for key <- Broker.process_only_keys(), do: assert(key in Broker.env_keys())
      assert "HTTPS_PROXY" in Broker.process_only_keys()
    end

    test "expiring? is true near the end, and when the end is unknown" do
      soon = DateTime.add(DateTime.utc_now(), 60, :second)
      later = DateTime.add(DateTime.utc_now(), 3_600, :second)

      assert Broker.expiring?(%{expires_at: soon})
      refute Broker.expiring?(%{expires_at: later})
      assert Broker.expiring?(%{expires_at: nil})
    end
  end

  describe "prepare/2" do
    setup do
      configure(["u1"])
      :ok
    end

    test "creates the vault, sets the policy, loads credentials and services, mints a session" do
      test = self()

      stub(Req, :post, fn req, opts ->
        url = Keyword.fetch!(opts, :url)
        send(test, {:post, url, Keyword.get(opts, :json), req.options[:auth]})

        case url do
          "/v1/vaults" -> {:ok, %{status: 201, body: %{"name" => "c-x"}}}
          "/v1/credentials" -> {:ok, %{status: 200, body: %{"set" => ["GITHUB_TOKEN"]}}}
          "/v1/sessions" -> {:ok, %{status: 201, body: %{"token" => "av_sess_conv", "expires_at" => "2030-01-01T00:00:00Z"}}}
        end
      end)

      stub(Req, :patch, fn _req, opts ->
        send(test, {:patch, Keyword.fetch!(opts, :url), Keyword.get(opts, :json)})
        {:ok, %{status: 200, body: %{"unmatched_host_policy" => "passthrough"}}}
      end)

      stub(Req, :put, fn _req, opts ->
        send(test, {:put, Keyword.fetch!(opts, :url), Keyword.get(opts, :json)})
        {:ok, %{status: 200, body: %{"services_count" => 2}}}
      end)

      assert {:ok, session} = Broker.prepare(@conv, %{"GITHUB_TOKEN" => "ghp_real"})
      vault = Broker.vault_name(@conv)

      assert session.vault == vault
      assert session.token == "av_sess_conv"
      assert %DateTime{year: 2030} = session.expires_at

      assert_received {:post, "/v1/vaults", %{name: ^vault}, {:bearer, "av_sess_owner"}}
      assert_received {:patch, "/v1/vaults/" <> _, %{unmatched_host_policy: "passthrough"}}

      # The tenant's value plus the constant git username, in one upsert.
      assert_received {:post, "/v1/credentials", %{vault: ^vault, credentials: creds}, _}
      assert creds == %{"GITHUB_TOKEN" => "ghp_real", "GITHUB_BASIC_USER" => "x-access-token"}

      # api.github.com takes a bearer; git over HTTPS on github.com sends basic.
      assert_received {:put, "/v1/vaults/" <> _, %{services: services}}

      assert [
               %{name: "github-api", host: "api.github.com", auth: %{type: "bearer", token: "GITHUB_TOKEN"}},
               %{
                 name: "github-git",
                 host: "github.com",
                 auth: %{type: "basic", username: "GITHUB_BASIC_USER", password: "GITHUB_TOKEN"}
               }
             ] = services

      assert_received {:post, "/v1/sessions", %{vault: ^vault, vault_role: "proxy", ttl_seconds: ttl}, _}
      assert ttl == Application.get_env(:fountain, :broker_session_ttl_seconds, 21_600)
    end

    test "a vault that already exists is fine" do
      stub(Req, :post, fn _req, opts ->
        case Keyword.fetch!(opts, :url) do
          "/v1/vaults" -> {:ok, %{status: 409, body: %{"error" => "exists"}}}
          "/v1/credentials" -> {:ok, %{status: 200, body: %{}}}
          "/v1/sessions" -> {:ok, %{status: 201, body: %{"token" => "t", "expires_at" => "x"}}}
        end
      end)

      stub(Req, :patch, fn _r, _o -> {:ok, %{status: 200, body: %{}}} end)
      stub(Req, :put, fn _r, _o -> {:ok, %{status: 200, body: %{}}} end)

      assert {:ok, %{token: "t", expires_at: nil}} = Broker.prepare(@conv, %{"GH_TOKEN" => "g"})
    end

    test "GH_TOKEN alone binds the github services to GH_TOKEN" do
      test = self()

      stub(Req, :post, fn _req, opts ->
        case Keyword.fetch!(opts, :url) do
          "/v1/sessions" -> {:ok, %{status: 201, body: %{"token" => "t"}}}
          _ -> {:ok, %{status: 200, body: %{}}}
        end
      end)

      stub(Req, :patch, fn _r, _o -> {:ok, %{status: 200, body: %{}}} end)

      stub(Req, :put, fn _r, opts ->
        send(test, {:services, opts[:json].services})
        {:ok, %{status: 200, body: %{}}}
      end)

      assert {:ok, _} = Broker.prepare(@conv, %{"GH_TOKEN" => "g"})
      assert_received {:services, [%{auth: %{token: "GH_TOKEN"}}, %{auth: %{password: "GH_TOKEN"}}]}
    end

    test "a broker error stops the chain and names the step" do
      stub(Req, :post, fn _r, _o -> {:ok, %{status: 500, body: "boom"}} end)
      assert {:error, {:broker, :vault, {:api_error, 500, "boom"}}} = Broker.prepare(@conv, %{})
    end

    test "a transport error surfaces as-is" do
      stub(Req, :post, fn _r, _o -> {:error, :econnrefused} end)
      assert {:error, {:broker, :vault, :econnrefused}} = Broker.prepare(@conv, %{})
    end
  end

  describe "the other calls" do
    setup do
      configure()
      :ok
    end

    test "preflight is /health, unauthenticated" do
      stub(Req, :get, fn req, opts ->
        assert opts[:url] == "/health"
        assert is_nil(req.options[:auth])
        {:ok, %{status: 200, body: %{"status" => "ok"}}}
      end)

      assert :ok = Broker.preflight()
    end

    test "preflight reports the broker as unreachable, with the detail" do
      stub(Req, :get, fn _r, _o -> {:error, :econnrefused} end)
      assert {:error, {:broker, :unreachable, :econnrefused}} = Broker.preflight()

      stub(Req, :get, fn _r, _o -> {:ok, %{status: 503, body: "down"}} end)
      assert {:error, {:broker, :unreachable, {503, "down"}}} = Broker.preflight()
    end

    test "ca_pem fetches the root CA" do
      stub(Req, :get, fn _r, opts ->
        assert opts[:url] == "/v1/mitm/ca.pem"
        {:ok, %{status: 200, body: "-----BEGIN CERTIFICATE-----\n"}}
      end)

      assert {:ok, "-----BEGIN CERTIFICATE-----\n"} = Broker.ca_pem()
    end

    test "release deletes the conversation's vault, and a missing one is already released" do
      stub(Req, :delete, fn _r, opts ->
        assert opts[:url] == "/v1/vaults/" <> Broker.vault_name(@conv)
        {:ok, %{status: 200, body: %{"deleted" => true}}}
      end)

      assert :ok = Broker.release(@conv)

      stub(Req, :delete, fn _r, _o -> {:ok, %{status: 404, body: %{}}} end)
      assert :ok = Broker.release(@conv)

      stub(Req, :delete, fn _r, _o -> {:error, :timeout} end)
      assert {:error, {:broker, :release, :timeout}} = Broker.release(@conv)
    end
  end
end
