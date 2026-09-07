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
  # Endpoint and authentication need special handling in the substitution:
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

    raw = Map.get(Map.new(env), "CODEX_CONFIG", "{}")

    with {:ok, config} when is_map(config) <- Jason.decode(raw),
         features when is_map(features) <- Map.get(config, "features", %{}),
         providers when is_map(providers) <- Map.get(config, "model_providers", %{}) do
      config =
        config
        |> Map.put("features", Map.put(features, "respect_system_proxy", true))
        |> Map.delete("features.respect_system_proxy")
        |> select_http_provider(providers, env)

      env =
        Enum.reject(env, &match?({"CODEX_CONFIG", _}, &1)) ++
          [{"CODEX_CONFIG", Jason.encode!(config)}]

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
    # SpriteEnv appends secrets and broker placeholders after plain variables.
    # Resolve both endpoint and credential with the same last-entry precedence.
    env = Map.new(env)

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
        value when is_binary(value) and value != "",
        Map.get(env, "OPENAI_API_KEY")
      )
  end

  # Field audit: Codex rust-v0.147.0 (installed in the review image) and
  # rust-v0.153.3, codex-rs/model-provider-info/src/lib.rs,
  # built_in_model_providers -> create_openai_provider:
  # https://github.com/openai/codex/blob/rust-v0.147.0/codex-rs/model-provider-info/src/lib.rs
  # Both set name, base_url, wire_api, env_http_headers, http_headers,
  # requires_openai_auth, supports_websockets and supports_standalone_web_search.
  # Preserve organization/project mappings and standalone search. Their sole
  # provider http_header is the compiled CLI version; deliberately omit it:
  # Fountain does not know the conversation sandbox's CLI version, and using
  # the review image's version would misidentify an unpinned installation.
  # Neither version declares OpenAI-Beta or originator as provider headers.
  # env_key replaces requires_openai_auth only with a spawn credential;
  # supports_websockets is deliberately false. env_key_instructions,
  # experimental_bearer_token, auth, aws and query_params are all unset.
  # request_max_retries, stream_max_retries, stream_idle_timeout_ms and
  # websocket_connect_timeout_ms are also unset, using the same global
  # defaults for built-in and custom providers; keep them unset here.
  defp provider(env) do
    %{
      "name" => "OpenAI",
      "base_url" => base_url(env),
      "wire_api" => "responses",
      "env_key" => "OPENAI_API_KEY",
      "supports_websockets" => false,
      "supports_standalone_web_search" => true,
      "env_http_headers" => %{
        "OpenAI-Organization" => "OPENAI_ORGANIZATION",
        "OpenAI-Project" => "OPENAI_PROJECT"
      }
    }
  end

  defp base_url(env) do
    case Map.get(env, "OPENAI_BASE_URL") do
      url when is_binary(url) and url != "" -> url
      _ -> @openai_base_url
    end
  end
end
