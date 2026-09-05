defmodule Fountain.SandboxSkillsTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Fountain.SandboxSkills

  setup :verify_on_exit!

  @handle %Managoat.Sandbox.Handle{provider: :sprites, name: "skills-test"}

  test "bundled/0 is the API skill then the team set-up skill, read from priv" do
    assert [
             %{"name" => "fountain", "content" => api},
             %{"name" => "create-team", "content" => team}
           ] =
             SandboxSkills.bundled()

    assert api =~ "FOUNTAIN_CONVERSATION_ID"
    assert team =~ "team"
  end

  test "mount/3 prepends the bundled skills to the agent's own and installs through the library" do
    test = self()

    stub(Managoat.Sandbox, :write_file, fn @handle, path, _body ->
      send(test, {:wrote, path})
      :ok
    end)

    stub(Managoat.Sandbox, :exec, fn _, _, _, _ -> {:ok, "", 0} end)

    assert :ok = SandboxSkills.mount(@handle, "claude", [%{"name" => "mine", "content" => "# m"}])

    assert_receive {:wrote, "/home/sprite/.claude/skills/fountain/SKILL.md"}
    assert_receive {:wrote, "/home/sprite/.claude/skills/create-team/SKILL.md"}
    assert_receive {:wrote, "/home/sprite/.claude/skills/mine/SKILL.md"}
  end

  test "a nil skills list mounts the bundled skills alone" do
    test = self()
    stub(Managoat.Sandbox, :exec, fn _, _, _, _ -> {:ok, "", 0} end)
    stub(Managoat.Sandbox, :write_file, fn _h, path, _b -> send(test, {:wrote, path}) && :ok end)

    assert :ok = SandboxSkills.mount(@handle, "codex", nil)
    assert_receive {:wrote, "/home/sprite/.codex/skills/fountain/SKILL.md"}
    assert_receive {:wrote, "/home/sprite/.codex/skills/create-team/SKILL.md"}
    assert_receive {:wrote, "/home/sprite/.codex/skills/.fountain-managed-skills"}
    refute_receive {:wrote, _}
  end

  defmodule DiskRuntime do
    def skills_root, do: Process.get(:skills_test_root)
    def skills_sh_agent, do: "claude"
  end

  describe "reconciliation on disk" do
    setup do
      root = Fountain.TmpDir.mkdir!("fountain-skills")
      Process.put(:skills_test_root, root)

      stub(Managoat.Sandbox, :write_file, fn _, path, content ->
        File.mkdir_p!(Path.dirname(path))
        File.write(path, content)
      end)

      stub(Managoat.Sandbox, :exec, fn _, "bash", args, _ ->
        {output, code} = System.cmd("bash", args, stderr_to_stdout: true)
        {:ok, output, code}
      end)

      %{root: root}
    end

    test "removes an obsolete inline skill while preserving unrelated files", %{root: root} do
      File.mkdir_p!(Path.join(root, "personal"))
      File.write!(Path.join(root, "personal/SKILL.md"), "My local skill")

      assert :ok =
               SandboxSkills.mount(@handle, DiskRuntime, [
                 %{"name" => "old", "content" => "Old skill"}
               ])

      assert :ok =
               SandboxSkills.mount(@handle, DiskRuntime, [
                 %{"name" => "new", "content" => "New skill"}
               ])

      refute File.exists?(Path.join(root, "old"))
      assert File.read!(Path.join(root, "new/SKILL.md")) == "New skill"
      assert File.read!(Path.join(root, "personal/SKILL.md")) == "My local skill"
      assert File.exists?(Path.join(root, "fountain/SKILL.md"))
    end

    test "seeds legacy named skills and ignores unsafe manifest paths", %{root: root} do
      File.mkdir_p!(Path.join(root, "legacy"))
      File.write!(Path.join(root, "legacy/SKILL.md"), "Old skill")
      File.write!(Path.join(root, ".fountain-managed-skills"), "..\n../outside\n/absolute\n")

      assert :ok =
               SandboxSkills.reconcile(@handle, DiskRuntime, [], [
                 %{"name" => "legacy", "content" => "Old skill"}
               ])

      refute File.exists?(Path.join(root, "legacy"))
      assert File.dir?(root)
    end

    test "recovers unnamed legacy GitHub skills from the source lock", %{root: root} do
      File.mkdir_p!(Path.join(root, "legacy-remote"))
      File.write!(Path.join(root, "legacy-remote/SKILL.md"), "Old remote skill")
      File.mkdir_p!(Path.join(root, "unrelated"))

      stub(Managoat.Sandbox, :exec, fn _, "bash", args, _ ->
        if Enum.any?(args, &String.contains?(&1, "skills_lock=")) do
          {:ok,
           Jason.encode!(%{
             "skills" => %{
               "legacy-remote" => %{"source" => "owner/repo", "sourceType" => "github"},
               "unrelated" => %{"source" => "another/repo", "sourceType" => "github"}
             }
           }), 0}
        else
          {output, code} = System.cmd("bash", args, stderr_to_stdout: true)
          {:ok, output, code}
        end
      end)

      assert :ok =
               SandboxSkills.reconcile(@handle, DiskRuntime, [], [%{"source" => "owner/repo"}])

      refute File.exists?(Path.join(root, "legacy-remote"))
      assert File.dir?(Path.join(root, "unrelated"))
    end

    test "a retained remote skill survives an offline reinstall", %{root: root} do
      skill = %{"source" => "owner/repo", "name" => "remote"}
      File.mkdir_p!(Path.join(root, "remote"))
      File.write!(Path.join(root, "remote/SKILL.md"), "Already installed")

      stub(Managoat.Sandbox, :exec, fn _, "bash", args, _ ->
        case args do
          ["-lc", "npx " <> _] ->
            {:ok, "offline", 1}

          _ ->
            {output, code} = System.cmd("bash", args, stderr_to_stdout: true)
            {:ok, output, code}
        end
      end)

      assert :ok = SandboxSkills.reconcile(@handle, DiskRuntime, [skill], [skill])
      assert File.read!(Path.join(root, "remote/SKILL.md")) == "Already installed"
    end

    test "tracks discovered GitHub skill names for subsequent removal", %{root: root} do
      stub(Managoat.Sandbox, :exec, fn _, "bash", args, _ ->
        case args do
          ["-lc", "npx " <> _] ->
            File.mkdir_p!(Path.join(root, "discovered"))
            File.write!(Path.join(root, "discovered/SKILL.md"), "Remote skill")
            {:ok, "", 0}

          _ ->
            {output, code} = System.cmd("bash", args, stderr_to_stdout: true)
            {:ok, output, code}
        end
      end)

      assert :ok = SandboxSkills.mount(@handle, DiskRuntime, [%{"source" => "owner/repo"}])
      assert File.read!(Path.join(root, ".fountain-managed-skills")) =~ "discovered"
      assert :ok = SandboxSkills.mount(@handle, DiskRuntime, [])
      refute File.exists?(Path.join(root, "discovered"))
    end
  end
end
