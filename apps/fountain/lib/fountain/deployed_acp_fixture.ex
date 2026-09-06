defmodule Fountain.DeployedACPFixture do
  @moduledoc """
  Pinned ACP fixture installed only for the explicitly configured test account.

  This bypasses inference credentials, provider CLI installation and model
  behavior. Sandbox provisioning, process transport and ACP remain real.
  The test runner supplies structured scenario prompts, not arbitrary code.
  """

  @behaviour Managoat.Runtimes
  @source Path.expand("../../priv/deployed/acp-fixture.mjs", __DIR__)
  @external_resource @source
  @script File.read!(@source)
  @sha256 :crypto.hash(:sha256, @script) |> Base.encode16(case: :lower)

  def enabled? do
    case Application.get_env(:fountain, :deployed_acp_fixture) do
      %{enabled: true, user_id: id} when is_binary(id) -> match?({:ok, _}, Ecto.UUID.cast(id))
      _ -> false
    end
  end

  def allowed?(user_id) when is_binary(user_id) do
    enabled?() and Application.fetch_env!(:fountain, :deployed_acp_fixture).user_id == user_id
  end

  def allowed?(_), do: false
  def sha256, do: @sha256

  @impl true
  def default_env(_agent, _credentials), do: []

  @impl true
  def prepare_sandbox(handle, agent, _env) do
    if allowed?(agent.user_id) do
      Managoat.Sandbox.write_file(handle, "/home/sprite/.fountain-acp-fixture.mjs", @script)
    else
      {:error, :fixture_disabled}
    end
  end

  @impl true
  def skills_root, do: "/home/sprite/.fountain-acp-fixture/skills"

  @impl true
  def skills_sh_agent, do: ""
end
