defmodule Fountain.Conversations.CodexTransportTest do
  use ExUnit.Case, async: true

  alias Fountain.Conversations.CodexTransport

  test "brokered Codex gets TLS proxy support without changing proxy credentials or spawn options" do
    opts = [
      env: [{"HTTPS_PROXY", "https://token:label@broker.example:443"}],
      dir: "/track",
      stdin: true
    ]

    assert {:ok, result} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", opts)
    assert Keyword.delete(result, :env) == Keyword.delete(opts, :env)
    assert List.keyfind(result[:env], "HTTPS_PROXY", 0) == hd(opts[:env])
    assert config(result)["features"]["respect_system_proxy"] == true
    # Applying the policy again must not duplicate CODEX_CONFIG.
    assert {:ok, ^result} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", result)
  end

  test "existing settings survive, including unrelated feature flags" do
    original = %{
      "model" => "gpt-5.3-codex",
      "features" => %{"multi_agent" => false, "respect_system_proxy" => false},
      "features.respect_system_proxy" => false,
      "model_providers" => %{"custom" => %{"base_url" => "https://example.com"}}
    }

    opts = [env: [{"CODEX_CONFIG", Jason.encode!(original)}]]
    assert {:ok, result} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", opts)
    updated = config(result)
    assert updated["features"] == %{"multi_agent" => false, "respect_system_proxy" => true}
    refute Map.has_key?(updated, "features.respect_system_proxy")
    assert updated["model"] == original["model"]
    assert updated["model_providers"] == original["model_providers"]
  end

  test "unbrokered Codex and other runtimes retain their exact options" do
    opts = [env: [{"CODEX_CONFIG", "unchanged"}]]
    assert {:ok, ^opts} = CodexTransport.spawn_opts(%{broker: nil}, "codex", opts)
    assert {:ok, ^opts} = CodexTransport.spawn_opts(%{}, "codex", opts)

    for runtime <- ["claude", "gemini", "opencode"] do
      assert {:ok, ^opts} = CodexTransport.spawn_opts(%{broker: %{}}, runtime, opts)
    end
  end

  test "invalid configuration fails without leaking its contents" do
    for raw <- ["secret-invalid-json", "[]", "null", ~s({"features":false})] do
      assert {:error, :invalid_codex_config} =
               CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: [{"CODEX_CONFIG", raw}])
    end
  end

  defp config(opts) do
    {_, raw} = List.keyfind(opts[:env], "CODEX_CONFIG", 0)
    Jason.decode!(raw)
  end
end
