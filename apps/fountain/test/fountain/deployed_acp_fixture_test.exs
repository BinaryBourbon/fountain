defmodule Fountain.DeployedACPFixtureTest do
  # Enabling this runtime changes application-wide admission and catalog state.
  use ExUnit.Case, async: false

  alias Fountain.Agents.Agent
  alias Fountain.DeployedACPFixture
  alias Fountain.RuntimeDispatch

  @owner "aaaaaaaa-1111-4111-8111-111111111111"
  @other "bbbbbbbb-2222-4222-8222-222222222222"

  setup do
    previous = Application.get_env(:fountain, :deployed_acp_fixture)
    Application.delete_env(:fountain, :deployed_acp_fixture)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:fountain, :deployed_acp_fixture, previous),
        else: Application.delete_env(:fountain, :deployed_acp_fixture)
    end)

    :ok
  end

  defp attrs(user_id \\ @owner) do
    %{
      name: "fixture",
      runtime: "fountain-fixture",
      model: "fixture/deterministic-v1",
      user_id: user_id
    }
  end

  defp enable do
    Application.put_env(:fountain, :deployed_acp_fixture, %{enabled: true, user_id: @owner})
  end

  test "fixture is absent and denied by default, and requires a valid configured account" do
    refute DeployedACPFixture.enabled?()
    refute "fountain-fixture" in Agent.runtimes()
    refute Agent.changeset(%Agent{}, attrs()).valid?
    assert {:error, _} = RuntimeDispatch.for_agent(attrs())

    Application.put_env(:fountain, :deployed_acp_fixture, %{enabled: true, user_id: "invalid"})
    refute DeployedACPFixture.enabled?()
  end

  test "explicit fixture admission is restricted at creation and runtime dispatch" do
    enable()
    assert "fountain-fixture" in Agent.runtimes()
    assert Agent.changeset(%Agent{}, attrs()).valid?
    assert {:ok, DeployedACPFixture} = RuntimeDispatch.for_agent(attrs())
    refute Agent.changeset(%Agent{}, attrs(@other)).valid?
    assert {:error, _} = RuntimeDispatch.for_agent(attrs(@other))

    assert {:error, :fixture_disabled} =
             DeployedACPFixture.prepare_sandbox(nil, attrs(@other), [])

    Application.put_env(:fountain, :deployed_acp_fixture, %{enabled: false, user_id: @owner})
    assert {:error, _} = RuntimeDispatch.for_agent(attrs())
  end

  test "fixture cannot present a real model, ignored persona, skill or MCP configuration as working" do
    enable()

    for additions <- [
          %{model: "anthropic/claude-haiku-4-5"},
          %{system: "ignored persona"},
          %{skills: [%{"name" => "ignored"}]},
          %{mcp_servers: %{"ignored" => %{"command" => "echo"}}}
        ] do
      refute Agent.changeset(%Agent{}, Map.merge(attrs(), additions)).valid?
    end

    assert DeployedACPFixture.default_env(attrs(), %{anthropic_api_key: "not-exported"}) == []
  end

  test "packaged runtimes retain their dispatcher, ACP command, concurrency and permissions" do
    enable()

    for runtime <- ~w(claude codex gemini opencode) do
      assert RuntimeDispatch.for_agent(%{runtime: runtime}) ==
               Managoat.Runtimes.for_runtime(runtime)

      assert RuntimeDispatch.command(runtime) == Managoat.Runtimes.ACP.command(runtime)
      assert RuntimeDispatch.concurrency(runtime) == Managoat.Runtimes.ACP.concurrency(runtime)

      assert RuntimeDispatch.asks_permission?(runtime) ==
               Managoat.Runtimes.ACP.asks_permission?(runtime)
    end

    assert RuntimeDispatch.command("fountain-fixture") == {"node", [".fountain-acp-fixture.mjs"]}
    assert RuntimeDispatch.concurrency("fountain-fixture") == 1
    assert RuntimeDispatch.acp_enabled?("fountain-fixture")
  end

  test "the installed source has stable digest evidence" do
    source = Application.app_dir(:fountain, "priv/deployed/acp-fixture.mjs") |> File.read!()

    assert DeployedACPFixture.sha256() ==
             Base.encode16(:crypto.hash(:sha256, source), case: :lower)
  end
end
