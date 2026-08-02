defmodule Fountain.Conversations.ProvisioningTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations.Provisioning

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

      assert :ok = Provisioning.apply_network_policy(%{name: "test-sprite"}, env, conv.id)
    end

    test "absent allowed_hosts (no networking_config at all) also denies by default" do
      env = insert_env(%{"networking_type" => "limited"})
      conv = insert_conversation()

      expect(Sprites, :update_network_policy, fn _sprite, policy ->
        assert %Sprites.Policy{rules: [%Sprites.Policy.Rule{domain: "*", action: "deny"}]} =
                 policy

        :ok
      end)

      assert :ok = Provisioning.apply_network_policy(%{name: "test-sprite"}, env, conv.id)
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

      assert :ok = Provisioning.apply_network_policy(%{name: "test-sprite"}, env, conv.id)
    end
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
    test "write_env_file survives one transport failure on the file write" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      stub(Sprites, :filesystem, fn _sprite, _root -> :fake_fs end)

      stub(Sprites.Filesystem, :write, fn :fake_fs, _path, _body ->
        case Agent.get_and_update(counter, &{&1 + 1, &1 + 1}) do
          1 -> {:error, :timeout}
          _ -> :ok
        end
      end)

      stub(Sprites, :cmd, fn _sprite, "chmod", _args, _opts -> {"", 0} end)

      assert :ok = Provisioning.write_env_file(%{name: "s"}, [{"A", "1"}])
      assert Agent.get(counter, & &1) == 2
    end

    test "write_env_file does not retry a permanent api_error" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      stub(Sprites, :filesystem, fn _sprite, _root -> :fake_fs end)

      stub(Sprites.Filesystem, :write, fn :fake_fs, _path, _body ->
        Agent.update(counter, &(&1 + 1))
        {:error, {:api_error, 404, "no such sprite"}}
      end)

      assert {:error, {:api_error, 404, _}} =
               Provisioning.write_env_file(%{name: "s"}, [{"A", "1"}])

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

      assert :ok = Provisioning.apply_network_policy(%{name: "s"}, env, conv.id)
      assert Agent.get(counter, & &1) == 2
    end
  end
end
