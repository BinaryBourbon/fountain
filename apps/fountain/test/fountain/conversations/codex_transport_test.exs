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

  # #1674. `responses_websocket` cannot use an https-scheme proxy, but it
  # spends the full connect timeout finding that out — 303, 292 and 306
  # seconds on three consecutive Sprites turns whose work took about a
  # second. `supports_websockets` lives on the provider and the built-in
  # `openai` id is reserved, so declare the same endpoint under an id of our
  # own and select it.
  test "brokered Codex talks to OpenAI over a provider with no websocket transport" do
    assert {:ok, result} =
             CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: [])

    config = config(result)

    assert config["model_provider"] == "fountain_openai_http"

    assert config["model_providers"]["fountain_openai_http"] == %{
             "name" => "OpenAI",
             "base_url" => "https://api.openai.com/v1",
             "wire_api" => "responses",
             "env_key" => "OPENAI_API_KEY",
             "supports_websockets" => false
           }

    # Nothing else may name the built-in provider: codex rejects the whole
    # configuration with "model_providers contains reserved built-in provider
    # IDs" rather than ignoring the entry.
    refute Map.has_key?(config["model_providers"], "openai")
  end

  test "an agent already pointed at a gateway keeps the provider it names" do
    original = %{
      "model_provider" => "litellm",
      "model_providers" => %{"litellm" => %{"base_url" => "https://gw.example/v1"}}
    }

    assert {:ok, result} =
             CodexTransport.spawn_opts(%{broker: %{}}, "codex",
               env: [{"CODEX_CONFIG", Jason.encode!(original)}]
             )

    config = config(result)

    assert config["model_provider"] == "litellm"
    assert config["model_providers"] == original["model_providers"]
    # The proxy half still applies: that is about the transport, not the host.
    assert config["features"]["respect_system_proxy"] == true
  end

  test "a provider declaration of our own id is left as the operator wrote it" do
    mine = %{"base_url" => "https://proxy.internal/v1", "supports_websockets" => false}

    original = %{
      "model_provider" => "fountain_openai_http",
      "model_providers" => %{"fountain_openai_http" => mine}
    }

    assert {:ok, result} =
             CodexTransport.spawn_opts(%{broker: %{}}, "codex",
               env: [{"CODEX_CONFIG", Jason.encode!(original)}]
             )

    assert config(result)["model_providers"]["fountain_openai_http"] == mine
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
    assert updated["model_providers"]["custom"] == original["model_providers"]["custom"]
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
    for raw <- [
          "secret-invalid-json",
          "[]",
          "null",
          ~s({"features":false}),
          ~s({"model_providers":"openai"})
        ] do
      assert {:error, :invalid_codex_config} =
               CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: [{"CODEX_CONFIG", raw}])
    end
  end

  defp config(opts) do
    {_, raw} = List.keyfind(opts[:env], "CODEX_CONFIG", 0)
    Jason.decode!(raw)
  end
end
