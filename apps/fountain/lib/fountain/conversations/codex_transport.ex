defmodule Fountain.Conversations.CodexTransport do
  @moduledoc false

  # codex-acp 1.10 passes CODEX_CONFIG to thread/start and thread/resume.
  # Codex's default WebSocket dialer rejects HTTPS proxy URLs. Its explicit
  # proxy route supports TLS to the broker, but is opt-in in Codex 0.153.3.
  # Keep this process-local: persistent sandboxes are shared by conversations.

  # Rejecting the proxy URL is not the expensive part — waiting to find out
  # is. `responses_websocket` dials `wss://api.openai.com/v1/responses`, sits
  # on the connect timeout, reports `Proxy URL scheme not supported` and only
  # then falls back to HTTP. Measured on Sprites (#1674), that was 303, 292
  # and 306 seconds on three consecutive turns whose actual work took about a
  # second each.
  #
  # `supports_websockets` is a provider field, and the built-in `openai`
  # provider cannot be overridden — `model_providers contains reserved
  # built-in provider IDs` is a hard configuration error, from the file and
  # from here alike (openai/codex#13103). A provider id of our own is not
  # reserved, so declare the same endpoint with the websocket transport off
  # and select it. `env_key` rather than the built-in's `auth.json`, because a
  # custom provider does not read that store; `OPENAI_API_KEY` is in the
  # sandbox env either way, and on a brokered conversation it is the
  # placeholder the broker substitutes for the real key on the way out
  # (`Fountain.Broker.split_inference/2`), so nothing about who pays changes.
  @provider_id "fountain_openai_http"
  @provider %{
    "name" => "OpenAI",
    "base_url" => "https://api.openai.com/v1",
    "wire_api" => "responses",
    "env_key" => "OPENAI_API_KEY",
    "supports_websockets" => false
  }

  def spawn_opts(%{broker: broker}, "codex", opts) when not is_nil(broker) do
    env = Keyword.get(opts, :env, [])

    raw =
      case List.keyfind(env, "CODEX_CONFIG", 0) do
        nil -> "{}"
        {_, value} -> value
      end

    with {:ok, config} when is_map(config) <- Jason.decode(raw),
         features when is_map(features) <- Map.get(config, "features", %{}),
         providers when is_map(providers) <- Map.get(config, "model_providers", %{}) do
      config =
        config
        |> Map.put("features", Map.put(features, "respect_system_proxy", true))
        |> Map.delete("features.respect_system_proxy")
        |> disable_websockets(providers)

      env = List.keystore(env, "CODEX_CONFIG", 0, {"CODEX_CONFIG", Jason.encode!(config)})
      {:ok, Keyword.put(opts, :env, env)}
    else
      # Do not include the config: it may contain provider credentials.
      _ -> {:error, :invalid_codex_config}
    end
  end

  def spawn_opts(_state, _runtime, opts), do: {:ok, opts}

  # Only the conversation that would otherwise dial OpenAI directly. An agent
  # already pointed at a gateway keeps the provider it names: that provider
  # decides its own transport, and its base URL is not ours to replace.
  defp disable_websockets(config, providers) do
    if Map.get(config, "model_provider", "openai") in ["openai", @provider_id] do
      config
      |> Map.put("model_provider", @provider_id)
      |> Map.put("model_providers", Map.put_new(providers, @provider_id, @provider))
    else
      config
    end
  end
end
