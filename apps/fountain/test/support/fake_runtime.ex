defmodule Fountain.Test.FakeRuntime do
  @moduledoc """
  A `Fountain.Runtimes` implementation for tests.

  `ConversationServer` takes its runtime module as a start argument, which is
  the one dependency-injection seam the module already has. Using it avoids
  stubbing four real runtime modules to test behaviour that has nothing to do
  with which CLI is being driven.

  Every callback records itself in the calling process so a test can assert what
  the server asked the runtime to do.
  """

  @behaviour Fountain.Runtimes

  @doc "Where callbacks report to. Set by the test harness."
  def observer, do: Application.get_env(:fountain, :test_observer)

  defp report(msg) do
    # The server runs in its own process, so self() here is the GenServer, not
    # the test. Report to the pid the harness registered instead.
    if pid = observer(), do: send(pid, msg)
    :ok
  end

  @impl true
  def build_command(_agent, prompt, mode, session_id, opts) do
    report({:build_command, prompt, mode, session_id, opts})
    {"echo", [prompt], stdin?: true}
  end

  @impl true
  def default_env(_agent, _credentials), do: [{"FAKE_RUNTIME", "1"}]

  @impl true
  def write_config(_sprite, _agent), do: report(:write_config)

  @impl true
  def prepare_sandbox(_sprite, _agent, _sprite_env), do: report(:prepare_sandbox)

  @impl true
  def skills_root, do: "/home/sprite/.fake/skills"

  @impl true
  def skills_sh_agent, do: "fake"
end

defmodule Fountain.Test.FailingRuntime do
  @moduledoc """
  A runtime whose `prepare_sandbox/3` fails, for exercising the provisioning
  failure path without having to make a Sprites call fail.
  """

  @behaviour Fountain.Runtimes

  @impl true
  def build_command(_agent, prompt, _mode, _session_id, _opts), do: {"echo", [prompt], []}

  @impl true
  def default_env(_agent, _credentials), do: []

  @impl true
  def write_config(_sprite, _agent), do: :ok

  @impl true
  def prepare_sandbox(_sprite, _agent, _sprite_env), do: {:error, :prepare_failed}

  @impl true
  def skills_root, do: "/home/sprite/.fake/skills"

  @impl true
  def skills_sh_agent, do: "fake"
end

defmodule Fountain.Test.ConfigFailingRuntime do
  @moduledoc """
  A runtime whose `write_config/2` fails: the sandbox never took the runtime's
  config file. Provisioning must treat that as a failure rather than run the
  agent without its MCP servers.
  """

  @behaviour Fountain.Runtimes

  @impl true
  def build_command(_agent, prompt, _mode, _session_id, _opts), do: {"echo", [prompt], []}

  @impl true
  def default_env(_agent, _credentials), do: []

  @impl true
  def write_config(_sprite, _agent), do: {:error, {:runtime_config, "/x/.mcp.json", :timeout}}

  @impl true
  def prepare_sandbox(_sprite, _agent, _sprite_env), do: :ok

  @impl true
  def skills_root, do: "/home/sprite/.fake/skills"

  @impl true
  def skills_sh_agent, do: "fake"
end
