defmodule Fountain.RuntimeDispatch do
  @moduledoc """
  Host dispatch for the four packaged runtimes and the opt-in deployed ACP fixture.

  The fixture is one fixed, account-restricted testing seam for #1611/#1007.
  It does not register tenant-provided code or replace a packaged runtime.
  """

  alias Fountain.DeployedACPFixture
  alias Managoat.Runtimes
  alias Managoat.Runtimes.ACP

  def for_agent(%{runtime: "fountain-fixture", user_id: user_id}) do
    if DeployedACPFixture.allowed?(user_id),
      do: {:ok, DeployedACPFixture},
      else: {:error, "deployed ACP fixture is not enabled for this account"}
  end

  def for_agent(%{runtime: runtime}), do: Runtimes.for_runtime(runtime)

  def acp_enabled?(%{runtime: runtime}), do: acp_enabled?(runtime)
  def acp_enabled?("fountain-fixture"), do: DeployedACPFixture.enabled?()
  def acp_enabled?(runtime), do: ACP.enabled?(runtime)

  def command("fountain-fixture"), do: {"node", [".fountain-acp-fixture.mjs"]}
  def command(runtime), do: ACP.command(runtime)

  def bootstrap_command("fountain-fixture", cmd, args), do: {cmd, args}
  def bootstrap_command(runtime, cmd, args), do: ACP.bootstrap_command(runtime, cmd, args)

  def cwd("fountain-fixture"), do: "/home/sprite"
  def cwd(runtime), do: ACP.cwd(runtime)

  def concurrency("fountain-fixture"), do: 1
  def concurrency(runtime), do: ACP.concurrency(runtime)

  def asks_permission?("fountain-fixture"), do: true
  def asks_permission?(runtime), do: ACP.asks_permission?(runtime)

  def install(_handle, "fountain-fixture", _env), do: :ok
  def install(handle, runtime, env), do: ACP.install(handle, runtime, env)
end
