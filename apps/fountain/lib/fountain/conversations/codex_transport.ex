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
  # and select it.
  #
  # Two things the substitution has to carry across, because the built-in
  # provider has them and a custom one does not:
  #
  #   * **The endpoint.** The built-in reads `OPENAI_BASE_URL`, which is how
  #     an environment points codex at a gateway. `base_url/1` reads the same
  #     variable out of the spawn env, so hard-coding OpenAI's URL here does
  #     not silently redirect a conversation that had been going elsewhere.
  #   * **The credential.** A custom provider does not read `~/.codex/auth.json`,
  #     which is where `codex login --with-api-key` puts the key at provision
  #     time (ADR 0019 gate 3) and where a sandbox shared by several
  #     conversations still holds one. So the substitution happens only when
  #     `OPENAI_API_KEY` is in this spawn's env for `env_key` to name. Without
  #     it the conversation keeps the built-in provider and pays the stall —
  #     the wrong provider would cost it the turn instead.
  #
  # Brokered, `OPENAI_API_KEY` holds the placeholder the broker substitutes
  # for the real key on the way out (`Fountain.Broker.split_inference/2`), so
  # nothing about which key pays changes.
  #
  # **Scope.** This reads the CODEX_CONFIG overlay and nothing else. A
  # `model_provider` an environment's setup script wrote into
  # `~/.codex/config.toml` is invisible here, and the overlay outranks the
  # file, so such a conversation is moved onto this provider. Fountain writes
  # no `model_provider` of its own into that file; `env_vars` is the supported
  # way to point codex somewhere else, and `OPENAI_BASE_URL` set there is
  # carried across.
  @provider_id "fountain_openai_http"
  @openai_base_url "https://api.openai.com/v1"

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
        |> select_http_provider(providers, env)

      env = List.keystore(env, "CODEX_CONFIG", 0, {"CODEX_CONFIG", Jason.encode!(config)})
      {:ok, Keyword.put(opts, :env, env)}
    else
      # Do not include the config: it may contain provider credentials.
      _ -> {:error, :invalid_codex_config}
    end
  end

  def spawn_opts(_state, _runtime, opts), do: {:ok, opts}

  # Repoint the conversation at an equivalent provider with the websocket
  # transport off. Only the one that would otherwise dial OpenAI directly: an
  # agent already pointed at a gateway keeps the provider it names, because
  # that provider decides its own transport and its endpoint is not ours to
  # replace. A declaration of this id that the config already carries is the
  # operator's, and is left alone.
  defp select_http_provider(config, providers, env) do
    if substitute?(config, env) do
      config
      |> Map.put("model_provider", @provider_id)
      |> Map.put("model_providers", Map.put_new(providers, @provider_id, provider(env)))
    else
      config
    end
  end

  defp substitute?(config, env) do
    Map.get(config, "model_provider", "openai") in ["openai", @provider_id] and
      match?(
        {_, value} when is_binary(value) and value != "",
        List.keyfind(env, "OPENAI_API_KEY", 0)
      )
  end

  defp provider(env) do
    %{
      "name" => "OpenAI",
      "base_url" => base_url(env),
      "wire_api" => "responses",
      "env_key" => "OPENAI_API_KEY",
      "supports_websockets" => false
    }
  end

  defp base_url(env) do
    case List.keyfind(env, "OPENAI_BASE_URL", 0) do
      {_, url} when is_binary(url) and url != "" -> url
      _ -> @openai_base_url
    end
  end
end
