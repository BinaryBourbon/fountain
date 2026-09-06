defmodule Fountain.Conversations.CodexTransport do
  @moduledoc false

  # codex-acp 1.10 passes CODEX_CONFIG to thread/start and thread/resume.
  # Codex's default WebSocket dialer rejects HTTPS proxy URLs. Its explicit
  # proxy route supports TLS to the broker, but is opt-in in Codex 0.153.3.
  # Keep this process-local: persistent sandboxes are shared by conversations.
  def spawn_opts(%{broker: broker}, "codex", opts) when not is_nil(broker) do
    env = Keyword.get(opts, :env, [])

    raw =
      case List.keyfind(env, "CODEX_CONFIG", 0) do
        nil -> "{}"
        {_, value} -> value
      end

    with {:ok, config} when is_map(config) <- Jason.decode(raw),
         features when is_map(features) <- Map.get(config, "features", %{}) do
      config =
        config
        |> Map.put("features", Map.put(features, "respect_system_proxy", true))
        |> Map.delete("features.respect_system_proxy")

      env = List.keystore(env, "CODEX_CONFIG", 0, {"CODEX_CONFIG", Jason.encode!(config)})
      {:ok, Keyword.put(opts, :env, env)}
    else
      # Do not include the config: it may contain provider credentials.
      _ -> {:error, :invalid_codex_config}
    end
  end

  def spawn_opts(_state, _runtime, opts), do: {:ok, opts}
end
