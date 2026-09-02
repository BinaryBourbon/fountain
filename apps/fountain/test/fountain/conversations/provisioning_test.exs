defmodule Fountain.Conversations.ProvisioningTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations.Provisioning

  # Full-stack: Provisioning -> Managoat.Sandbox facade -> real Sprites
  # adapter -> stubbed SDK, so the provider-quirk pins below still assert
  # the exact wire shapes Sprites receives.
  defp sandbox_handle(name \\ "test-sprite") do
    stub(Managoat.Sandbox.Sprites.Client, :get!, fn -> %Sprites.Client{token: "test"} end)
    Managoat.Sandbox.Sprites.build_handle(name)
  end

  describe "apply_network_policy/3 — limited networking" do
    test "empty allowed_hosts denies by default instead of sending an empty rule list" do
      env = insert_env(%{"networking_type" => "limited", "networking_config" => %{}})
      conv = insert_conversation()

      expect(Sprites, :update_network_policy, fn _sprite, policy ->
        refute policy.rules == [],
               "an empty rules list is Sprites' documented allow-all — limited " <>
                 "with no allowed_hosts must not send that"

        assert %Sprites.Policy{rules: [%Sprites.Policy.Rule{domain: "*", action: "deny"}]} =
                 policy

        :ok
      end)

      assert :ok = Provisioning.apply_network_policy(sandbox_handle(), env, conv.id)
    end

    test "absent allowed_hosts (no networking_config at all) also denies by default" do
      env = insert_env(%{"networking_type" => "limited"})
      conv = insert_conversation()

      expect(Sprites, :update_network_policy, fn _sprite, policy ->
        assert %Sprites.Policy{rules: [%Sprites.Policy.Rule{domain: "*", action: "deny"}]} =
                 policy

        :ok
      end)

      assert :ok = Provisioning.apply_network_policy(sandbox_handle(), env, conv.id)
    end

    test "non-empty allowed_hosts still builds an allowlist" do
      env =
        insert_env(%{
          "networking_type" => "limited",
          "networking_config" => %{"allowed_hosts" => ["github.com", "registry.npmjs.org"]}
        })

      conv = insert_conversation()

      expect(Sprites, :update_network_policy, fn _sprite, policy ->
        assert %Sprites.Policy{
                 rules: [
                   %Sprites.Policy.Rule{domain: "github.com", action: "allow"},
                   %Sprites.Policy.Rule{domain: "registry.npmjs.org", action: "allow"}
                 ]
               } = policy

        :ok
      end)

      assert :ok = Provisioning.apply_network_policy(sandbox_handle(), env, conv.id)
    end
  end

  describe "check_broker_support/4 (ADR 0019 gate 1a)" do
    setup do
      previous = Application.get_env(:fountain, :broker_allow_unenforced)
      on_exit(fn -> Application.put_env(:fountain, :broker_allow_unenforced, previous) end)
      Application.put_env(:fountain, :broker_allow_unenforced, false)
      :ok
    end

    test "an unbrokered conversation is not checked at all" do
      env = insert_env(%{"networking_type" => "limited"})
      conv = insert_conversation()

      reject(Fountain.Broker, :preflight, 0)
      assert :ok = Provisioning.check_broker_support(false, :runner, env, conv.id)
      assert stage_events(conv.id, "broker") == []
    end

    test "a limited environment passes: its allowlist is enforced at the broker (gate 2)" do
      env = insert_env(%{"networking_type" => "limited"})
      conv = insert_conversation()

      expect(Fountain.Broker, :preflight, fn -> :ok end)
      assert :ok = Provisioning.check_broker_support(true, :sprites, env, conv.id)
      assert stage_events(conv.id, "broker") == []
    end

    test "a backend without :network_policy is refused: placeholders without a floor are half a control" do
      env = insert_env(%{"networking_type" => "unrestricted"})
      conv = insert_conversation()

      reject(Fountain.Broker, :preflight, 0)

      assert {:error, {:broker, :backend_lacks_network_policy}} =
               Provisioning.check_broker_support(true, :runner, env, conv.id)

      assert [event] = stage_events(conv.id, "broker")

      assert %{"reason" => "backend_lacks_network_policy", "provider" => "runner"} =
               Jason.decode!(event.data)
    end

    test "BROKER_ALLOW_UNENFORCED lets a runner host an advisory broker, for development" do
      Application.put_env(:fountain, :broker_allow_unenforced, true)
      conv = insert_conversation()

      expect(Fountain.Broker, :preflight, fn -> :ok end)
      assert :ok = Provisioning.check_broker_support(true, :runner, nil, conv.id)
    end

    test "a broker that does not answer fails the conversation before a sandbox exists" do
      conv = insert_conversation()

      expect(Fountain.Broker, :preflight, fn ->
        {:error, {:broker, :unreachable, :econnrefused}}
      end)

      assert {:error, {:broker, :unreachable, :econnrefused}} =
               Provisioning.check_broker_support(true, :sprites, nil, conv.id)

      assert [event] = stage_events(conv.id, "broker")
      assert event.state == "failed"

      assert %{"reason" => "broker_unreachable", "detail" => ":econnrefused"} =
               Jason.decode!(event.data)
    end
  end

  describe "apply_broker_floor/2" do
    test "the broker host is the one allowed domain, whatever the environment says" do
      conv = insert_conversation()
      test = self()

      stub(Fountain.Broker, :proxy_host, fn -> "broker.example" end)

      Mimic.stub(Managoat.Sandbox.Sprites, :apply_network_policy, fn _handle, policy ->
        send(test, {:policy, policy})
        :ok
      end)

      assert :ok = Provisioning.apply_broker_floor(sandbox_handle(), conv.id)
      assert_received {:policy, %Managoat.Sandbox.NetworkPolicy{allow: ["broker.example"]}}

      assert [started, done] = stage_events(conv.id, "network")
      assert %{"type" => "broker"} = Jason.decode!(started.data)
      assert done.state == "done"
    end
  end

  describe "install_broker_ca/2" do
    test "writes the CA where update-ca-certificates reads it, then runs it" do
      conv = insert_conversation()
      test = self()

      stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)

      Mimic.stub(Managoat.Sandbox.Sprites, :write_file, fn _h, path, data, opts ->
        send(test, {:wrote, path, data, opts})
        :ok
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :exec, fn _h, cmd, args, _opts ->
        send(test, {:exec, cmd, args})
        {:ok, "Updating certificates... 1 added", 0}
      end)

      assert :ok = Provisioning.install_broker_ca(sandbox_handle(), conv.id)
      assert_received {:wrote, "/tmp/agent-vault-ca.crt", "PEM", [mode: 0o644]}

      assert_received {:exec, "bash", ["-lc", cmd]}

      assert cmd ==
               "sudo install -D -m 644 '/tmp/agent-vault-ca.crt' " <>
                 "'/usr/local/share/ca-certificates/agent-vault.crt' && sudo update-ca-certificates && " <>
                 "printf '%s\\n' 'Defaults env_keep += \"HTTPS_PROXY HTTP_PROXY https_proxy http_proxy " <>
                 "NO_PROXY NODE_EXTRA_CA_CERTS SSL_CERT_FILE REQUESTS_CA_BUNDLE CARGO_HTTP_CAINFO " <>
                 "UV_NATIVE_TLS\"' > '/tmp/fountain-broker-proxy.sudoers' && " <>
                 "sudo visudo -cf '/tmp/fountain-broker-proxy.sudoers' && " <>
                 "sudo install -m 440 '/tmp/fountain-broker-proxy.sudoers' '/etc/sudoers.d/fountain-broker-proxy'"
    end

    test "sudo keeps every proxy variable the broker sets, so `sudo apt-get` reaches a mirror" do
      conv = insert_conversation()
      test = self()

      stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)
      Mimic.stub(Managoat.Sandbox.Sprites, :write_file, fn _h, _p, _d, _o -> :ok end)

      Mimic.stub(Managoat.Sandbox.Sprites, :exec, fn _h, _cmd, [_, script], _opts ->
        send(test, {:script, script})
        {:ok, "", 0}
      end)

      assert :ok = Provisioning.install_broker_ca(sandbox_handle(), conv.id)
      assert_received {:script, script}

      # The token-bearing variables must survive sudo for apt's sake, but the
      # drop-in itself carries only names, never the proxy URL.
      for key <- Fountain.Broker.env_keys(), do: assert(script =~ key)
      refute script =~ "@"
      assert script =~ "visudo -cf"
    end

    test "a failed install is a broker failure, by name" do
      conv = insert_conversation()

      stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)
      Mimic.stub(Managoat.Sandbox.Sprites, :write_file, fn _h, _p, _d, _o -> :ok end)
      Mimic.stub(Managoat.Sandbox.Sprites, :exec, fn _h, _c, _a, _o -> {:ok, "no sudo", 1} end)

      assert {:error, {:broker, :ca_install_exit, 1, "no sudo"}} =
               Provisioning.install_broker_ca(sandbox_handle(), conv.id)

      assert [event] = stage_events(conv.id, "broker")
      assert %{"reason" => "ca_install_exit", "exit_code" => 1} = Jason.decode!(event.data)
    end
  end

  describe "check_network_policy_support/3" do
    test "a limited environment on a backend without :network_policy is refused by name" do
      env = insert_env(%{"networking_type" => "limited"})
      conv = insert_conversation()

      refute Managoat.Sandbox.supports?(:runner, :network_policy)

      assert {:error, {:network_policy, :unsupported_by_backend}} =
               Provisioning.check_network_policy_support(:runner, env, conv.id)

      # The point of the check: the operator is told which backend and why,
      # before a sandbox exists, instead of reading a transport-shaped error
      # out of the middle of provisioning (#935).
      assert [event] = stage_events(conv.id, "network")
      assert event.state == "failed"

      assert %{"reason" => "backend_lacks_network_policy", "provider" => "runner"} =
               Jason.decode!(event.data)
    end

    test "a limited environment on a backend that advertises the capability passes" do
      env = insert_env(%{"networking_type" => "limited"})
      conv = insert_conversation()

      assert Managoat.Sandbox.supports?(:sprites, :network_policy)
      assert :ok = Provisioning.check_network_policy_support(:sprites, env, conv.id)
      assert stage_events(conv.id, "network") == []
    end

    test "an unrestricted environment passes on a backend without the capability" do
      env = insert_env(%{"networking_type" => "unrestricted"})
      conv = insert_conversation()

      assert :ok = Provisioning.check_network_policy_support(:runner, env, conv.id)
      assert stage_events(conv.id, "network") == []
    end

    test "no environment at all passes" do
      conv = insert_conversation()

      assert :ok = Provisioning.check_network_policy_support(:runner, nil, conv.id)
      assert stage_events(conv.id, "network") == []
    end
  end

  defp stage_events(conv_id, stage) do
    Fountain.Repo.all(
      from(e in Fountain.Conversations.LogEvent,
        where: e.conversation_id == ^conv_id and e.kind == "stage" and e.stage == ^stage,
        order_by: e.id
      )
    )
  end

  # ── .env quoting ───────────────────────────────────────────────────────────

  # The file exists to be `source`d by the user's setup_script, so the only
  # assertion worth making is what a real shell sees when it reads it back.
  # Values used to be wrapped in *double* quotes with only `"` escaped, so
  # $(...), backticks and backslashes stayed live, and a newline split the value
  # across lines.
  defp sourced_value(value) do
    body = Provisioning.render_env_file(%{"SECRET" => value})
    dir = Path.join(System.tmp_dir!(), "envq-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    file = Path.join(dir, ".env")
    File.write!(file, body)

    try do
      {out, 0} =
        System.cmd("bash", ["-c", "set -a; source #{file}; printf %s \"$SECRET\""],
          stderr_to_stdout: true
        )

      out
    after
      File.rm_rf!(dir)
    end
  end

  describe "render_env_file/1" do
    test "a command substitution is not executed" do
      assert sourced_value("pw-$(id -u)-end") == "pw-$(id -u)-end"
      assert sourced_value("pw-`id -u`-end") == "pw-`id -u`-end"
    end

    test "a variable reference is not expanded" do
      assert sourced_value("literal-$HOME") == "literal-$HOME"
      assert sourced_value("literal-${HOME}") == "literal-${HOME}"
    end

    test "backslashes survive" do
      # Windows-style paths and anything base64/PEM-adjacent hit this.
      assert sourced_value("C:\\Users\\me") == "C:\\Users\\me"
      assert sourced_value("a\\nb") == "a\\nb"
    end

    test "a multi-line value survives instead of splitting the file" do
      pem = "-----BEGIN KEY-----\nabc\ndef\n-----END KEY-----"
      assert sourced_value(pem) == pem
    end

    test "quotes of both kinds survive" do
      assert sourced_value(~s|it's a "quote"|) == ~s|it's a "quote"|
      assert sourced_value("'") == "'"
    end

    test "a value cannot introduce a second assignment" do
      assert sourced_value("x\nINJECTED=1") == "x\nINJECTED=1"

      body = Provisioning.render_env_file(%{"SECRET" => "x\nINJECTED=1"})
      script = "set -a; source /dev/stdin <<'EOF'\n#{body}EOF\necho \"[${INJECTED-}]\""
      {out, 0} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)

      assert String.trim(out) == "[]"
    end

    test "ordinary values still round-trip" do
      assert sourced_value("plain") == "plain"
      assert sourced_value("") == ""
    end
  end

  describe "retry behaviour on transient Sprites failures" do
    defp stub_chmod_exec do
      # The belt-and-suspenders chmod goes through the adapter's exec, which
      # spawns and collects frames; hand back an immediate clean exit.
      stub(Sprites, :spawn, fn _sprite, "chmod", _args, _opts ->
        ref = make_ref()
        send(self(), {:exit, %{ref: ref}, 0})
        {:ok, %Sprites.Command{ref: ref}}
      end)
    end

    test "write_env_file survives one transport failure on the file write" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      handle = sandbox_handle("s")

      stub(Sprites, :filesystem, fn _sprite, _root -> :fake_fs end)

      stub(Sprites.Filesystem, :write, fn :fake_fs, _path, _body, _opts ->
        case Agent.get_and_update(counter, &{&1 + 1, &1 + 1}) do
          1 -> {:error, :timeout}
          _ -> :ok
        end
      end)

      stub_chmod_exec()

      assert :ok = Provisioning.write_env_file(handle, [{"A", "1"}])
      assert Agent.get(counter, & &1) == 2
    end

    test "write_env_file does not retry a permanent not-found" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      handle = sandbox_handle("s")

      stub(Sprites, :filesystem, fn _sprite, _root -> :fake_fs end)

      stub(Sprites.Filesystem, :write, fn :fake_fs, _path, _body, _opts ->
        Agent.update(counter, &(&1 + 1))
        {:error, {:api_error, 404, "no such sprite"}}
      end)

      assert {:error, :not_found} = Provisioning.write_env_file(handle, [{"A", "1"}])

      assert Agent.get(counter, & &1) == 1
    end

    test "apply_network_policy retries a 503 and succeeds" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      env = insert_env(%{"networking_type" => "limited", "networking_config" => %{}})
      conv = insert_conversation()

      stub(Sprites, :update_network_policy, fn _sprite, _policy ->
        case Agent.get_and_update(counter, &{&1 + 1, &1 + 1}) do
          1 -> {:error, {:api_error, 503, "unavailable"}}
          _ -> :ok
        end
      end)

      assert :ok = Provisioning.apply_network_policy(sandbox_handle("s"), env, conv.id)
      assert Agent.get(counter, & &1) == 2
    end
  end
end
