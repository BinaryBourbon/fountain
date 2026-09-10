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

    reject(&Managoat.Sandbox.exec/4)

    assert :ok = SandboxSkills.mount(@handle, "claude", [%{"name" => "mine", "content" => "# m"}])

    assert_receive {:wrote, "/home/sprite/.claude/skills/fountain/SKILL.md"}
    assert_receive {:wrote, "/home/sprite/.claude/skills/create-team/SKILL.md"}
    assert_receive {:wrote, "/home/sprite/.claude/skills/mine/SKILL.md"}
  end

  # #1634: the string used to be forwarded to the library's own dispatcher,
  # which is a closed map of the four LLM runtimes. It answered
  # {:error, "unsupported runtime: acp"} and the sandbox came up with no
  # skills at all, silently.
  test "mount/3 resolves the acp runtime through Fountain.RuntimeDispatch" do
    test = self()

    stub(Managoat.Sandbox, :write_file, fn @handle, path, _body ->
      send(test, {:wrote, path})
      :ok
    end)

    assert :ok = SandboxSkills.mount(@handle, "acp", [%{"name" => "mine", "content" => "# m"}])

    root = Fountain.CommandRuntime.skills_root()
    assert_receive {:wrote, ^root <> "/fountain/SKILL.md"}
    assert_receive {:wrote, ^root <> "/create-team/SKILL.md"}
    assert_receive {:wrote, ^root <> "/mine/SKILL.md"}
  end

  test "a module is passed straight through to the library" do
    test = self()
    stub(Managoat.Sandbox, :write_file, fn _h, path, _b -> send(test, {:wrote, path}) && :ok end)

    assert :ok = SandboxSkills.mount(@handle, Fountain.CommandRuntime, nil)
    assert_receive {:wrote, "/home/sprite/.claude/skills/fountain/SKILL.md"}
  end

  test "a runtime nothing implements is logged and returned, never silent" do
    reject(&Managoat.Sandbox.write_file/3)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, reason} = SandboxSkills.mount(@handle, "nonesuch", [])
        assert reason =~ "unsupported runtime"
      end)

    assert log =~ "skills not mounted for runtime nonesuch"
  end

  test "a nil skills list mounts the bundled skills alone" do
    test = self()
    stub(Managoat.Sandbox, :write_file, fn _h, path, _b -> send(test, {:wrote, path}) && :ok end)

    assert :ok = SandboxSkills.mount(@handle, "codex", nil)
    assert_receive {:wrote, "/home/sprite/.codex/skills/fountain/SKILL.md"}
    assert_receive {:wrote, "/home/sprite/.codex/skills/create-team/SKILL.md"}
    refute_receive {:wrote, _}
  end
end
