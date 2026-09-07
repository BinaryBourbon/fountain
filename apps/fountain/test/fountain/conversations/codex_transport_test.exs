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
             CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: [key("sk-x")])

    config = config(result)

    assert config["model_provider"] == "fountain_openai_http"

    # Everything the built-in provider declares, minus the two fields that
    # cannot carry across: `requires_openai_auth` (a custom provider cannot
    # read auth.json, so `env_key` replaces it) and the compiled-in `version`
    # header, which names the CLI build Fountain is not in a position to know.
    # Audited against codex-rs/model-provider-info/src/lib.rs at rust-v0.153.3.
    assert config["model_providers"] == %{
             "fountain_openai_http" => %{
               "name" => "OpenAI",
               "base_url" => "https://api.openai.com/v1",
               "wire_api" => "responses",
               "env_key" => "OPENAI_API_KEY",
               "supports_websockets" => false,
               "supports_standalone_web_search" => true,
               "env_http_headers" => %{
                 "OpenAI-Organization" => "OPENAI_ORGANIZATION",
                 "OpenAI-Project" => "OPENAI_PROJECT"
               }
             }
           }
  end

  # `SpriteEnv.build/4` appends the decrypted secrets after the runtime's own
  # defaults, so a vault entry for either variable appears twice and the last
  # one is what the process gets. Reading the first would substitute on a key
  # the conversation is not using, and would miss a deliberately emptied one.
  test "the effective value of a repeated variable is the one that counts" do
    env = [
      key("sk-runtime-default"),
      {"OPENAI_BASE_URL", "https://api.openai.com/v1"},
      key(""),
      {"OPENAI_BASE_URL", "https://gw.example/v1"}
    ]

    assert {:ok, result} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: env)

    # Emptied by the later entry: no credential, so no substitution.
    refute Map.has_key?(config(result), "model_provider")

    env = List.keyreplace(env, "OPENAI_API_KEY", 0, key("sk-x")) ++ [key("sk-vault")]

    assert {:ok, result} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: env)

    assert config(result)["model_providers"]["fountain_openai_http"]["base_url"] ==
             "https://gw.example/v1"
  end

  # The built-in provider reads OPENAI_BASE_URL, so an environment pointing
  # codex at a gateway through `env_vars` was already working. Hard-coding
  # OpenAI's URL into the replacement would have redirected it silently.
  test "the replacement provider keeps the endpoint OPENAI_BASE_URL names" do
    env = [key("sk-x"), {"OPENAI_BASE_URL", "https://gw.example/v1"}]

    assert {:ok, result} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: env)

    assert config(result)["model_providers"]["fountain_openai_http"]["base_url"] ==
             "https://gw.example/v1"
  end

  # A custom provider does not read ~/.codex/auth.json, so a conversation
  # with no OPENAI_API_KEY in its spawn env would have nothing to
  # authenticate with. A shared sandbox may still hold the auth.json that
  # `codex login --with-api-key` wrote for whoever provisioned it, and the
  # built-in provider can use it. Paying the stall beats losing the turn.
  test "a spawn with no OPENAI_API_KEY keeps the built-in provider" do
    for env <- [[], [{"OPENAI_API_KEY", ""}]] do
      assert {:ok, result} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", env: env)

      config = config(result)

      refute Map.has_key?(config, "model_provider")
      refute Map.has_key?(config, "model_providers")
      # The proxy half does not depend on the credential.
      assert config["features"]["respect_system_proxy"] == true
    end
  end

  test "an agent already pointed at a gateway keeps the provider it names" do
    original = %{
      "model_provider" => "litellm",
      "model_providers" => %{"litellm" => %{"base_url" => "https://gw.example/v1"}}
    }

    assert {:ok, result} =
             CodexTransport.spawn_opts(%{broker: %{}}, "codex",
               env: [key("sk-x"), {"CODEX_CONFIG", Jason.encode!(original)}]
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
               env: [key("sk-x"), {"CODEX_CONFIG", Jason.encode!(original)}]
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

    opts = [env: [key("sk-x"), {"CODEX_CONFIG", Jason.encode!(original)}]]
    assert {:ok, result} = CodexTransport.spawn_opts(%{broker: %{}}, "codex", opts)
    updated = config(result)
    assert updated["features"] == %{"multi_agent" => false, "respect_system_proxy" => true}
    refute Map.has_key?(updated, "features.respect_system_proxy")
    assert updated["model"] == original["model"]

    # Exactly one entry added, every neighbour untouched.
    assert Map.keys(updated["model_providers"]) |> Enum.sort() ==
             ["custom", "fountain_openai_http"]

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

  defp key(value), do: {"OPENAI_API_KEY", value}

  defp config(opts) do
    {_, raw} = List.keyfind(opts[:env], "CODEX_CONFIG", 0)
    Jason.decode!(raw)
  end
end
