defmodule Fountain.Sandbox.RunnerConformanceTest do
  @moduledoc """
  The conformance suite against the runner adapter, with the wire protocol
  served by `Fountain.Runners.FakeDaemon` — the adapter, the connection
  process and the JSON framing are all real; only the machine is not.
  """

  use Fountain.SandboxConformanceCase,
    adapter: Fountain.Sandbox.Runner,
    name: {Fountain.Runners, :sandbox_name_for, ["0f0e0d0c-0b0a-4908-8706-050403020100"]},
    fixtures: %{
      exec_ok: {"emit", ["out:hello"], "hello"},
      exec_fail: {"emit", ["out:oops", "exit:3"], 3},
      spawn_ok: {"emit", ["out:hello", "exit:0"]},
      spawn_drop: {"emit", ["out:partial", "drop"]},
      spawn_stay: {"emit", ["out:ready", "stay"]}
    }

  alias Fountain.Runners.FakeDaemon

  @runner_id "0f0e0d0c-0b0a-4908-8706-050403020100"
  @user_id "11111111-2222-4333-8444-555555555555"

  setup do
    {:ok, daemon} = FakeDaemon.start(@runner_id, @user_id, name: "conformance")
    on_exit(fn -> FakeDaemon.stop(daemon) end)
    :ok
  end
end
