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

  # ── ssh clone ──────────────────────────────────────────────────────────────

  # Built as a struct rather than through the factory on purpose: the
  # Environment changeset has rejected any url that is not https:// since the
  # schema was written, so no environment reachable through the UI, the API or
  # the manifest apply can carry an ssh repo — production has 9 repositories,
  # all https, none with an ssh_key_secret. clone_ssh/4 is unreachable today.
  # That is why these bugs were never hit, not a reason to leave them in: the
  # branch is live code that a one-line validation change would switch on.
  defp ssh_repo_env do
    %Fountain.Environments.Environment{
      id: Ecto.UUID.generate(),
      name: "ssh-env",
      repositories: [
        %{
          "url" => "git@github.com:acme/widgets.git",
          "mount_path" => "/home/sprite/widgets",
          "ssh_key_secret" => "DEPLOY_KEY"
        }
      ]
    }
  end

  # Runs a clone and returns the shell command plus every file written into the
  # sprite, keyed by path.
  defp run_ssh_clone(env, conv, key) do
    test = self()

    stub(Sprites, :filesystem, fn _sprite, _dir -> :fs end)

    stub(Sprites.Filesystem, :write, fn :fs, path, contents ->
      send(test, {:wrote, path, contents})
      :ok
    end)

    stub(Sprites, :cmd, fn _sprite, "bash", ["-lc", cmd], _opts ->
      send(test, {:cmd, cmd})
      {"", 0}
    end)

    assert :ok =
             Provisioning.clone_repositories(
               %{name: "test-sprite"},
               env,
               %{"DEPLOY_KEY" => key},
               conv.id
             )

    assert_received {:cmd, cmd}
    {cmd, collect_writes(%{})}
  end

  defp collect_writes(acc) do
    receive do
      {:wrote, path, contents} -> collect_writes(Map.put(acc, path, contents))
    after
      0 -> acc
    end
  end

  describe "clone_repositories/4 over ssh" do
    test "the private key is written as a file, never embedded in the command" do
      # It used to be heredoc'd in with the fixed sentinel AOD_KEY_EOF, so a key
      # containing that line closed the heredoc early and the remainder ran as
      # shell — command injection into provisioning for anyone who can set a
      # secret, which is every user on their own sandbox and anyone they share
      # a vault with.
      key = "-----BEGIN OPENSSH PRIVATE KEY-----\nAOD_KEY_EOF\ntouch /tmp/pwned\n"
      {cmd, writes} = run_ssh_clone(ssh_repo_env(), insert_conversation(), key)

      refute cmd =~ "AOD_KEY_EOF"
      refute cmd =~ "touch /tmp/pwned"
      refute cmd =~ "BEGIN OPENSSH PRIVATE KEY"

      {key_path, ^key} = Enum.find(writes, fn {path, _} -> path =~ "aod_ssh_" end)
      assert key_path =~ ~r|^/tmp/aod_ssh_\d+$|
      assert cmd =~ "chmod 600 '#{key_path}'"
      assert cmd =~ "ssh -i #{key_path} "
    end

    test "host keys are pinned and checking stays on" do
      {cmd, writes} = run_ssh_clone(ssh_repo_env(), insert_conversation(), "key")

      # StrictHostKeyChecking=no accepted whatever answered the connection, so
      # anything on the network path could serve its own repository contents
      # and have an agent execute them inside the sandbox.
      refute cmd =~ "StrictHostKeyChecking=no"
      refute cmd =~ "UserKnownHostsFile=/dev/null"
      assert cmd =~ "StrictHostKeyChecking=accept-new"

      {hosts_path, hosts} = Enum.find(writes, fn {path, _} -> path =~ "aod_known_hosts_" end)
      assert cmd =~ "UserKnownHostsFile=#{hosts_path}"

      for host <- ~w(github.com gitlab.com bitbucket.org) do
        assert hosts =~ "#{host} ssh-ed25519 AAAA"
      end

      # accept-new alone would be nearly worthless here: every sprite is fresh,
      # so with an empty known_hosts every host is trusted on first sight. The
      # pinned entries are what actually closes the window.
      assert String.trim(hosts) != ""
    end

    test "both temp files are removed even when the clone fails" do
      # `set -e` meant a failing clone exited the shell before the trailing rm,
      # leaving the private key on the sprite for the rest of its life.
      {cmd, _writes} = run_ssh_clone(ssh_repo_env(), insert_conversation(), "key")

      assert String.starts_with?(cmd, "set -e; trap 'rm -f ")
      assert cmd =~ ~r/trap 'rm -f \S*aod_ssh\S* \S*aod_known_hosts\S*' EXIT/
    end

    test "a failed write is reported rather than clone running without the key" do
      stub(Sprites, :filesystem, fn _sprite, _dir -> :fs end)
      stub(Sprites.Filesystem, :write, fn :fs, _path, _contents -> {:error, :enospc} end)
      reject(&Sprites.cmd/4)

      assert {:error, {:clone_ssh_write, :enospc}} =
               Provisioning.clone_repositories(
                 %{name: "test-sprite"},
                 ssh_repo_env(),
                 %{"DEPLOY_KEY" => "key"},
                 insert_conversation().id
               )
    end
  end
end
