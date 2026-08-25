defmodule Fountain.BrokerTest do
  # The seam the app talks to (ADR 0019): the switch, the placeholder rule,
  # the sandbox-side env, and the session lifecycle over the native store.
  use Fountain.DataCase, async: false

  alias Fountain.Broker
  alias Fountain.Broker.Sessions

  @conv "0b0f6e1a-4d4c-4c1a-9a2b-3c4d5e6f7a8b"

  setup do
    previous =
      for key <- [:broker_listen_port, :broker_proxy_url, :broker_tenants],
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
    Application.put_env(:fountain, :broker_listen_port, 14_322)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")
    Application.put_env(:fountain, :broker_tenants, tenants)
  end

  defp bound(attrs) do
    struct(
      Fountain.SecretBindings.Binding,
      Map.merge(
        %{auth_type: "bearer", header: nil, prefix: nil, username: nil, headers: %{}, enabled: true},
        attrs
      )
    )
  end

  # Mint a session and read back what the proxy would see for it.
  defp prepared(conv, user, brokered, bindings \\ %{}) do
    {:ok, %{token: token, vault: vault}} = Broker.prepare(conv.id, user.id, brokered, bindings)
    {:ok, binding} = Sessions.lookup(token, vault)
    binding
  end

  describe "the switch" do
    test "blank BROKER_LISTEN_PORT means off, for every tenant" do
      Application.delete_env(:fountain, :broker_listen_port)
      Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")
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

    test "preflight is whether the listener is up on this node" do
      assert {:error, {:broker, :unreachable, :listener_down}} = Broker.preflight()

      start_supervised!({Fountain.Broker.Supervisor, port: 0})
      assert :ok = Broker.preflight()
    end
  end

  describe "split/2" do
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

    test "a key with a binding is brokered; an unbound non-catalog key is not" do
      bindings = %{
        "STRIPE_SECRET_KEY" => [bound(%{key: "STRIPE_SECRET_KEY", host: "api.stripe.com"})]
      }

      assert {sandbox, brokered} =
               Broker.split(
                 %{"STRIPE_SECRET_KEY" => "sk", "DATABASE_URL" => "pg://", "GITHUB_TOKEN" => "gh"},
                 bindings
               )

      assert sandbox == %{
               "STRIPE_SECRET_KEY" => "__stripe_secret_key__",
               "DATABASE_URL" => "pg://",
               "GITHUB_TOKEN" => "__github_token__"
             }

      assert brokered == %{"STRIPE_SECRET_KEY" => "sk", "GITHUB_TOKEN" => "gh"}
    end
  end

  describe "the sandbox side" do
    test "the vault name is the conversation id in the proxy URL's alphabet" do
      assert Broker.vault_name(@conv) == "c-0b0f6e1a4d4c4c1a9a2b3c4d5e6f7a8b"
      assert String.length(Broker.vault_name(@conv)) <= 64
    end

    test "sandbox_env carries token and vault inside the proxy address, and the CA path" do
      configure()
      env = Broker.sandbox_env(%{vault: "c-x", token: "fb_t", expires_at: nil})

      assert {"HTTPS_PROXY", "http://fb_t:c-x@broker.test:14322"} in env
      assert {"HTTP_PROXY", "http://fb_t:c-x@broker.test:14322"} in env
      assert {"https_proxy", "http://fb_t:c-x@broker.test:14322"} in env
      assert {"http_proxy", "http://fb_t:c-x@broker.test:14322"} in env
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

    test "ca_pem is the root the proxy signs with" do
      assert {:ok, pem} = Broker.ca_pem()
      assert pem == Fountain.Broker.CA.pem()
      assert String.starts_with?(pem, "-----BEGIN CERTIFICATE-----")
    end

    test "service_name/2 is a stable slug" do
      assert Broker.service_name("STRIPE_SECRET_KEY", "api.stripe.com:443/v1/*") ==
               "stripe-secret-key-api-stripe-com-443-v1"

      assert String.length(Broker.service_name(String.duplicate("K", 80), "a.b.c")) <= 64
    end
  end

  describe "prepare/4 and release/1" do
    setup do
      configure()
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))
      {:ok, user: user, conv: conv}
    end

    test "mints a session the proxy resolves to the github catalog pair", %{
      user: user,
      conv: conv
    } do
      assert {:ok, %{token: "fb_" <> _ = token, vault: vault, expires_at: %DateTime{} = at}} =
               Broker.prepare(conv.id, user.id, %{"GITHUB_TOKEN" => "ghp_real"})

      assert vault == Broker.vault_name(conv.id)
      assert DateTime.diff(at, DateTime.utc_now(), :second) in 21_000..21_600

      assert {:ok, binding} = Sessions.lookup(token, vault)
      assert binding.conversation_id == conv.id
      assert binding.user_id == user.id

      assert binding.credentials == %{
               "GITHUB_TOKEN" => "ghp_real",
               "GITHUB_TOKEN_BASIC_USER" => "x-access-token"
             }

      assert [
               %{
                 "name" => "github-api",
                 "host" => "api.github.com",
                 "auth" => %{"type" => "bearer", "token" => "GITHUB_TOKEN"}
               },
               %{
                 "name" => "github-git",
                 "host" => "github.com",
                 "auth" => %{
                   "type" => "basic",
                   "username" => "GITHUB_TOKEN_BASIC_USER",
                   "password" => "GITHUB_TOKEN"
                 }
               }
             ] = binding.services

      assert binding.unmatched_host_policy == "passthrough"
    end

    test "GH_TOKEN alone binds the github services to GH_TOKEN", %{user: user, conv: conv} do
      binding = prepared(conv, user, %{"GH_TOKEN" => "ghp_alt"})
      assert [%{"auth" => %{"token" => "GH_TOKEN"}}, _] = binding.services
      assert binding.credentials["GH_TOKEN"] == "ghp_alt"
    end

    test "one service per binding, only the fields of its type", %{user: user, conv: conv} do
      bindings = %{
        "STRIPE_SECRET_KEY" => [
          bound(%{key: "STRIPE_SECRET_KEY", host: "api.stripe.com"}),
          bound(%{
            key: "STRIPE_SECRET_KEY",
            host: "files.stripe.com",
            auth_type: "api_key",
            header: "x-api-key",
            prefix: "Token "
          })
        ],
        "JIRA_TOKEN" => [
          bound(%{
            key: "JIRA_TOKEN",
            host: "acme.atlassian.net",
            auth_type: "basic",
            username: "me@acme.com"
          })
        ],
        "CUSTOM_KEY" => [
          bound(%{
            key: "CUSTOM_KEY",
            host: "api.custom.example",
            auth_type: "custom",
            headers: %{"X-Key" => "{{ CUSTOM_KEY }}"}
          })
        ]
      }

      brokered = %{"STRIPE_SECRET_KEY" => "sk", "JIRA_TOKEN" => "jt", "CUSTOM_KEY" => "ck"}
      binding = prepared(conv, user, brokered, bindings)
      by_host = Map.new(binding.services, &{&1["host"], &1})

      assert %{
               "name" => "stripe-secret-key-api-stripe-com",
               "auth" => %{"type" => "bearer", "token" => "STRIPE_SECRET_KEY"}
             } = by_host["api.stripe.com"]

      assert %{
               "auth" => %{
                 "type" => "api-key",
                 "key" => "STRIPE_SECRET_KEY",
                 "header" => "x-api-key",
                 "prefix" => "Token "
               }
             } = by_host["files.stripe.com"]

      assert %{
               "auth" => %{
                 "type" => "basic",
                 "username" => "JIRA_TOKEN_BASIC_USER",
                 "password" => "JIRA_TOKEN"
               }
             } = by_host["acme.atlassian.net"]

      assert %{"auth" => %{"type" => "custom", "headers" => %{"X-Key" => "{{ CUSTOM_KEY }}"}}} =
               by_host["api.custom.example"]

      refute Map.has_key?(by_host["api.stripe.com"]["auth"], "header")

      # The basic username rides beside the password as a credential.
      assert binding.credentials["JIRA_TOKEN_BASIC_USER"] == "me@acme.com"
      assert binding.credentials["JIRA_TOKEN"] == "jt"
    end

    test "a GitHub key with its own binding drops the catalog pair", %{user: user, conv: conv} do
      bindings = %{"GITHUB_TOKEN" => [bound(%{key: "GITHUB_TOKEN", host: "api.github.com"})]}
      binding = prepared(conv, user, %{"GITHUB_TOKEN" => "gh"}, bindings)

      assert [%{"host" => "api.github.com", "name" => "github-token-api-github-com"}] =
               binding.services

      refute Map.has_key?(binding.credentials, "GITHUB_TOKEN_BASIC_USER")
    end

    test "the credentials are ciphertext at rest, under the tenant DEK", %{user: user, conv: conv} do
      {:ok, _} = Broker.prepare(conv.id, user.id, %{"GITHUB_TOKEN" => "ghp_real"})
      [row] = Repo.all(Fountain.Broker.Session)

      refute row.credentials_ciphertext =~ "ghp_real"
      assert byte_size(row.token_hash) == 32
    end

    test "the binding is on the token: another vault name is refused", %{user: user, conv: conv} do
      {:ok, %{token: token}} = Broker.prepare(conv.id, user.id, %{"GITHUB_TOKEN" => "ghp_real"})
      assert {:error, :vault_mismatch} = Sessions.lookup(token, "c-someone-else")
      assert {:error, :unknown} = Sessions.lookup("fb_nope", "c-x")
    end

    test "release drops every session of the conversation, and only those", %{
      user: user,
      conv: conv
    } do
      other = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))
      {:ok, %{token: t1, vault: v1}} = Broker.prepare(conv.id, user.id, %{"GITHUB_TOKEN" => "a"})
      {:ok, %{token: t2, vault: v2}} = Broker.prepare(conv.id, user.id, %{"GITHUB_TOKEN" => "b"})
      {:ok, %{token: t3, vault: v3}} = Broker.prepare(other.id, user.id, %{"GITHUB_TOKEN" => "c"})

      assert :ok = Broker.release(conv.id)
      assert {:error, :unknown} = Sessions.lookup(t1, v1)
      assert {:error, :unknown} = Sessions.lookup(t2, v2)
      assert {:ok, _} = Sessions.lookup(t3, v3)
    end

    test "an expired session is refused, and swept on the next mint", %{user: user, conv: conv} do
      {:ok, %{token: token, vault: vault}} =
        Broker.prepare(conv.id, user.id, %{"GITHUB_TOKEN" => "a"})

      past = DateTime.add(DateTime.utc_now(), -1, :second)
      Repo.update_all(Fountain.Broker.Session, set: [expires_at: past])

      assert {:error, :expired} = Sessions.lookup(token, vault)
      {:ok, _} = Broker.prepare(conv.id, user.id, %{"GITHUB_TOKEN" => "a"})
      assert Repo.aggregate(Fountain.Broker.Session, :count) == 1
    end
  end
end
