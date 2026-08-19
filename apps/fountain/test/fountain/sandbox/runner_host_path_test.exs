defmodule Fountain.Sandbox.RunnerHostPathTest do
  @moduledoc """
  The ACP `cwd` is validated in band by the agent CLI against the real
  filesystem, so on a runner it must be the sandbox's real directory, not the
  literal `/home/sprite` (ADR 0022). `Fountain.Sandbox.host_path/2` resolves
  it; it is the identity on providers where sandbox paths are already real.
  """
  use Fountain.DataCase, async: true

  alias Fountain.Runners.FakeDaemon
  alias Fountain.Sandbox

  @runner_id "0f0e0d0c-0b0a-4908-8706-050403020100"
  @user_id "11111111-2222-4333-8444-555555555555"

  test "host_path maps /home/sprite onto the daemon's real path, and passes others through" do
    {:ok, daemon} = FakeDaemon.start(@runner_id, @user_id, name: "hp")
    on_exit(fn -> FakeDaemon.stop(daemon) end)

    name = Fountain.Runners.sandbox_name_for(@runner_id)
    {:ok, handle} = Sandbox.create(:runner, name)
    {:ok, %{raw: %{"path" => real}}} = Sandbox.get(handle)

    assert Sandbox.host_path(handle, "/home/sprite") == real
    assert Sandbox.host_path(handle, "/home/sprite/.local/bin") == real <> "/.local/bin"
    assert Sandbox.host_path(handle, "/tmp/gemini-workspace") == "/tmp/gemini-workspace"
  end

  test "host_path is the identity for providers without the callback" do
    handle = Sandbox.build_handle(:sprites, "x")
    assert Sandbox.host_path(handle, "/home/sprite") == "/home/sprite"
  end
end
