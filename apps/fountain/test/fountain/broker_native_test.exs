defmodule Fountain.BrokerNativeTest do
  # The native backend of Fountain.Broker (#1340): prepare mints a session
  # row the Managoat.Broker store can look up, bindings and the catalog map
  # to rules, release deletes, the sweep expires, and the listener refuses a
  # token it does not know. Global app env, so async: false.
  use Fountain.DataCase, async: false

  import ExUnit.CaptureLog

  alias Fountain.Broker
  alias Fountain.Broker.Native
  alias Fountain.Broker.Native.Sessions
  alias Fountain.SecretBindings.Binding
  alias Managoat.Broker.Rule

  @keys [:broker_url, :broker_token, :broker_listen_port, :broker_proxy_url, :broker_tenants]

  setup do
    previous = for key <- @keys, do: {key, Application.get_env(:fountain, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:fountain, key),
          else: Application.put_env(:fountain, key, value)
      end
    end)

    Application.delete_env(:fountain, :broker_url)
    Application.delete_env(:fountain, :broker_token)
    Application.put_env(:fountain, :broker_listen_port, 0)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")

    user = insert_verified_user()
    Application.put_env(:fountain, :broker_tenants, [user.id])
    conv = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))

    {:ok, user: user, conv: conv}
  end

  defp binding(key, host, auth_type, extra \\ %{}) do
    struct(
      %Binding{key: key, host: host, auth_type: auth_type, headers: %{}, enabled: true},
      extra
    )
  end

  describe "the switch" do
    test "BROKER_LISTEN_PORT selects the native backend", %{user: user} do
      assert Broker.backend() == :native
      assert Broker.configured?()
      assert Broker.enabled_for?(user.id)
      refute Broker.enabled_for?("someone-else")
    end

    test "with neither variable there is no backend and nothing answers" do
      Application.delete_env(:fountain, :broker_listen_port)
      assert Broker.backend() == nil
      refute Broker.configured?()
      assert {:error, {:broker, :unreachable, :not_configured}} = Broker.preflight()
      assert {:error, {:broker, :ca, :not_configured}} = Broker.ca_pem()
      assert {:error, {:broker, :session, :not_configured}} = Broker.prepare("c", %{})
      assert :ok = Broker.release("c")
    end

    test "BROKER_URL still selects Agent Vault" do
      Application.delete_env(:fountain, :broker_listen_port)
      Application.put_env(:fountain, :broker_url, "http://broker.test:14321")
      assert Broker.backend() == :agent_vault
    end
  end

  describe "the CA" do
    test "the seed is 32 bytes derived from the master key, and is not the master key" do
      seed = Native.ca_seed()
      assert byte_size(seed) == 32
      refute seed == Application.fetch_env!(:fountain, :master_secrets_key)
      assert seed == Native.ca_seed()
    end

    test "ca_pem is the derived root, the same anchor every time" do
      assert {:ok, pem} = Broker.ca_pem()
      assert [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(pem)
      cert = X509.Certificate.from_der!(der)

      assert X509.Certificate.subject(cert) |> X509.RDNSequence.to_string() =~
               "Managoat Broker CA"

      {:ok, again} = Broker.ca_pem()
      [{:Certificate, der2, :not_encrypted}] = :public_key.pem_decode(again)

      assert X509.Certificate.public_key(X509.Certificate.from_der!(der2)) ==
               X509.Certificate.public_key(cert)
    end
  end

  describe "prepare/4" do
    test "creates a session the store can look up, with the catalog pair for an unbound GitHub key",
         %{user: user, conv: conv} do
      assert {:ok, session} =
               Broker.prepare(conv.id, %{"GITHUB_TOKEN" => "ghp_real"}, %{}, user_id: user.id)

      assert session.vault == Broker.vault_name(conv.id)
      assert "fb_" <> _ = session.token
      assert DateTime.compare(session.expires_at, DateTime.utc_now()) == :gt

      assert {:ok, %Managoat.Broker.Session{} = found} = Sessions.lookup(session.token)
      assert found.unmatched_host_policy == :passthrough
      assert found.meta == %{"conversation_id" => conv.id, "user_id" => user.id}
      assert found.expires_at == session.expires_at

      assert [
               %Rule{
                 name: "github-api",
                 pattern: "api.github.com",
                 scheme: :bearer,
                 credential: "ghp_real"
               },
               %Rule{
                 name: "github-api",
                 pattern: "api.github.com",
                 scheme: :substitute,
                 placeholder: "__github_token__",
                 credential: "ghp_real"
               },
               %Rule{
                 name: "github-git",
                 pattern: "github.com",
                 scheme: :basic,
                 credential: {"x-access-token", "ghp_real"}
               }
             ] = found.rules
    end

    test "resolves the tenant from the conversation when the caller has no user id", %{
      conv: conv
    } do
      assert {:ok, session} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"})
      assert {:ok, %{rules: [%Rule{credential: "g"} | _]}} = Sessions.lookup(session.token)

      assert {:error, {:broker, :session, :unknown_conversation}} =
               Broker.prepare(Ecto.UUID.generate(), %{"GH_TOKEN" => "g"})
    end

    test "every binding shape becomes a rule with the credential resolved", %{
      user: user,
      conv: conv
    } do
      brokered = %{
        "STRIPE_KEY" => "sk_live",
        "DISCORD_BOT_TOKEN" => "disc",
        "PD" => "pd_real",
        "HTTPBIN" => "hb",
        "CLAUDE_CODE_OAUTH_TOKEN" => "oat_real"
      }

      bindings = %{
        "STRIPE_KEY" => [binding("STRIPE_KEY", "api.stripe.com/v1/*", "bearer")],
        "DISCORD_BOT_TOKEN" => [
          binding("DISCORD_BOT_TOKEN", "discord.com/api/*", "api_key", %{
            header: "Authorization",
            prefix: "Bot "
          })
        ],
        "PD" => [
          binding("PD", "api.pagerduty.com", "custom", %{
            headers: %{"Authorization" => "Token token={{ PD }}"}
          })
        ],
        "HTTPBIN" => [binding("HTTPBIN", "httpbin.org", "basic", %{username: "alice"})],
        "CLAUDE_CODE_OAUTH_TOKEN" => [
          binding("CLAUDE_CODE_OAUTH_TOKEN", "api.anthropic.com", "substitute")
        ]
      }

      assert {:ok, session} = Broker.prepare(conv.id, brokered, bindings, user_id: user.id)
      {:ok, %{rules: rules}} = Sessions.lookup(session.token)

      by = fn name, scheme -> Enum.find(rules, &(&1.name == name and &1.scheme == scheme)) end

      # Sorted by key: the OAuth token's rule comes first.
      assert %Rule{scheme: :substitute, placeholder: "sk-ant-oat01-__claude_code_oauth_token__"} =
               hd(rules)

      assert %Rule{pattern: "api.stripe.com/v1/*", credential: "sk_live"} =
               by.("stripe-key-api-stripe-com-v1", :bearer)

      assert %Rule{placeholder: "__stripe_key__", credential: "sk_live"} =
               by.("stripe-key-api-stripe-com-v1", :substitute)

      assert %Rule{header: "Authorization", prefix: "Bot ", credential: "disc"} =
               by.("discord-bot-token-discord-com-api", :api_key)

      assert %Rule{template: %{"Authorization" => "Token token={{ PD }}"}, credential: ^brokered} =
               by.("pd-api-pagerduty-com", :custom)

      assert %Rule{credential: {"alice", "hb"}} = by.("httpbin-httpbin-org", :basic)

      # A bound key gets no catalog pair, and there is no GitHub key here.
      refute Enum.any?(rules, &(&1.name in ["github-api", "github-git"]))
    end

    test "a bound GitHub key keeps its own rule and gets no catalog pair", %{
      user: user,
      conv: conv
    } do
      bindings = %{"GITHUB_TOKEN" => [binding("GITHUB_TOKEN", "ghe.example.com", "bearer")]}

      {:ok, session} =
        Broker.prepare(conv.id, %{"GITHUB_TOKEN" => "gh"}, bindings, user_id: user.id)

      {:ok, %{rules: rules}} = Sessions.lookup(session.token)
      assert Enum.map(rules, & &1.pattern) == ["ghe.example.com", "ghe.example.com"]
    end

    test "a limited network is deny plus a passthrough per allowed host, minus the credentialed ones",
         %{user: user, conv: conv} do
      bindings = %{"K" => [binding("K", "api.example.com", "bearer")]}

      {:ok, session} =
        Broker.prepare(conv.id, %{"K" => "v"}, bindings,
          user_id: user.id,
          network:
            {:limited, ["registry.npmjs.org", " API.Example.com ", "", "registry.npmjs.org"]}
        )

      {:ok, %{unmatched_host_policy: :deny, rules: rules}} = Sessions.lookup(session.token)

      assert [
               %Rule{pattern: "api.example.com", scheme: :bearer},
               %Rule{pattern: "api.example.com", scheme: :substitute},
               %Rule{
                 name: "allow-registry-npmjs-org",
                 pattern: "registry.npmjs.org",
                 scheme: :passthrough
               }
             ] = rules
    end

    test "a second prepare mints a second token; the first stays valid until it expires", %{
      user: user,
      conv: conv
    } do
      {:ok, first} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)
      {:ok, second} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)
      refute first.token == second.token
      assert {:ok, _} = Sessions.lookup(first.token)
      assert {:ok, _} = Sessions.lookup(second.token)
    end
  end

  describe "the store" do
    test "an unknown token is :error", _ctx do
      assert :error = Sessions.lookup("fb_nope")
    end

    test "release deletes every session of the conversation, and only those", %{
      user: user,
      conv: conv
    } do
      other = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))
      {:ok, a} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)
      {:ok, b} = Broker.prepare(other.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)

      assert :ok = Broker.release(conv.id)
      assert :error = Sessions.lookup(a.token)
      assert {:ok, _} = Sessions.lookup(b.token)
    end

    test "an expired session is refused, and the sweep deletes it", %{user: user, conv: conv} do
      {:ok, live} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)
      {:ok, stale} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)

      past = DateTime.add(DateTime.utc_now(), -1, :second)

      Repo.update_all(
        from(s in Fountain.Broker.Native.Session,
          where: s.token_hash == ^:crypto.hash(:sha256, stale.token)
        ),
        set: [expires_at: past]
      )

      assert :error = Sessions.lookup(stale.token)
      assert 1 = Sessions.sweep_expired()
      assert 0 = Sessions.sweep_expired()
      assert {:ok, _} = Sessions.lookup(live.token)

      # The reaper's native branch is the same sweep.
      Repo.update_all(
        from(s in Fountain.Broker.Native.Session,
          where: s.token_hash == ^:crypto.hash(:sha256, live.token)
        ),
        set: [expires_at: past]
      )

      assert %{deleted: 1, failed: 0, kept: 0} = Fountain.Workers.BrokerVaultReaper.run()
    end

    test "a row whose ciphertext does not decrypt is :error, not a crash", %{
      user: user,
      conv: conv
    } do
      {:ok, session} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)

      Repo.update_all(Fountain.Broker.Native.Session,
        set: [rules_ciphertext: :crypto.strong_rand_bytes(64)]
      )

      log = capture_log(fn -> assert :error = Sessions.lookup(session.token) end)
      assert log =~ "unreadable"
    end
  end

  describe "the listener" do
    setup do
      Ecto.Adapters.SQL.Sandbox.mode(Fountain.Repo, {:shared, self()})
      :ok
    end

    test "preflight says so when nothing listens" do
      assert {:error, {:broker, :unreachable, :listener_down}} = Broker.preflight()
    end

    test "up on the configured port, it serves a token the store knows and refuses one it does not",
         %{user: user, conv: conv} do
      start_supervised!(Native.listener_spec())
      assert :ok = Broker.preflight()
      port = Managoat.Broker.port()

      # The listener signs with the root ca_pem/0 hands the sandbox: same
      # key (the PEM bytes differ per derivation, the anchor does not).
      {:ok, pem} = Broker.ca_pem()
      assert public_key(pem) == public_key(Managoat.Broker.ca_pem())

      {:ok, session} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)
      [{"HTTPS_PROXY", url} | _] = Broker.sandbox_env(session)
      %URI{userinfo: userinfo} = URI.parse(url)
      good = "Basic " <> Base.encode64(userinfo)
      bad = "Basic " <> Base.encode64("fb_nope:" <> session.vault)

      # The good token is accepted; the origin is then refused because it is
      # a loopback address, which is the SSRF guard doing its job.
      assert connect(port, good) =~ "HTTP/1.1 403"
      assert connect(port, bad) =~ "HTTP/1.1 407"
    end

    defp public_key(pem) do
      [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(pem)
      der |> X509.Certificate.from_der!() |> X509.Certificate.public_key()
    end

    defp connect(port, auth) do
      {:ok, tcp} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 5_000)

      :ok =
        :gen_tcp.send(
          tcp,
          "CONNECT localhost:443 HTTP/1.1\r\nHost: localhost:443\r\nProxy-Authorization: #{auth}\r\n\r\n"
        )

      {:ok, reply} = :gen_tcp.recv(tcp, 0, 5_000)
      :gen_tcp.close(tcp)
      reply
    end
  end

  describe "the request log" do
    test "request_log/2 is an empty page: no stored log on this backend yet", %{conv: conv} do
      assert {:ok, %{events: [], next: nil}} = Broker.request_log(conv.id)
    end

    test "the telemetry handler writes conversation, method, host, path and outcome, never a header" do
      assert :ok = Native.attach_telemetry()
      assert :ok = Native.attach_telemetry()

      # The suite logs at :warning; the request line is :info, on purpose.
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      log =
        capture_log(fn ->
          :telemetry.execute([:managoat, :broker, :request], %{count: 1}, %{
            method: "GET",
            host: "api.github.com",
            path: "/user",
            outcome: :injected,
            rule: "github-api",
            meta: %{"conversation_id" => "conv-1", "user_id" => "u-1"},
            headers: [{"authorization", "Bearer secret"}]
          })

          :telemetry.execute([:managoat, :broker, :request], %{count: 1}, %{
            method: "POST",
            host: "example.com",
            path: "/x",
            outcome: :denied,
            rule: nil,
            meta: %{"conversation_id" => "conv-1"}
          })
        end)

      assert log =~ "broker: conv conv-1 GET api.github.com/user injected github-api"
      assert log =~ "broker: conv conv-1 POST example.com/x denied"
      refute log =~ "secret"
    end
  end

  test "the Agent Vault reaper branch is not taken on native", %{user: user, conv: conv} do
    {:ok, _} = Broker.prepare(conv.id, %{"GH_TOKEN" => "g"}, %{}, user_id: user.id)
    assert %{deleted: 0, failed: 0, kept: 0} = Fountain.Workers.BrokerVaultReaper.run()
    assert {:ok, []} = Broker.list_vaults()
    assert :ok = Broker.delete_vault("c-x")
  end
end
