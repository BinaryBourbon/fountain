defmodule Fountain.Conversations.CodexChatGPT do
  @moduledoc """
  How the deployment's ChatGPT grant reaches a codex sandbox (ADR 0047
  decision 4).

  `Managoat.Runtimes.Codex` knows one credential, `OPENAI_API_KEY`, which
  its `prepare_sandbox/3` pipes into `codex login --with-api-key`. The grant
  is a different shape: an access token codex must not try to refresh, and
  an account id it sends beside the bearer. Rather than teach the library a
  second login (a release and a pin bump), Fountain writes the file itself:

    * `env/2` exports `CODEX_CHATGPT_ACCESS_TOKEN` for a codex spawn whose
      credentials carry the grant. Brokered, that value is the placeholder
      `Fountain.Broker.split_inference/2` put there, and the broker
      substitutes the real token on `chatgpt.com`.
    * `prepare_sandbox/3` writes `~/.codex/auth.json` in `chatgptAuthTokens`
      mode ("externally managed tokens": codex never refreshes and never
      checks `exp`) with that value where the bearer goes, the real account
      id, and an `id_token` synthesised from the stored claims. It runs
      before the library's `prepare_sandbox/3` would, and replaces it.

  The file names the placeholder, so it is worthless off the box. A
  persistent sandbox shared by a conversation on the API-key path and one
  on the grant holds whichever file was written last; the API-key provider
  reads its key from the env and is unaffected, the grant's provider reads
  the file.
  """

  alias Fountain.PlatformChatGPT
  alias Managoat.Runtimes.Layout

  @env_key "CODEX_CHATGPT_ACCESS_TOKEN"
  @credential :codex_chatgpt_access_token
  @runtime "codex"

  @doc "The env var the grant travels under, and the credential atom it comes from."
  def env_key, do: @env_key
  def credential, do: @credential

  @doc """
  The spawn env entry for the grant: `[{"CODEX_CHATGPT_ACCESS_TOKEN", value}]`
  for the codex runtime when the credentials carry it, else `[]`.
  """
  @spec env(module() | nil, map()) :: [{String.t(), String.t()}]
  def env(Managoat.Runtimes.Codex, credentials) when is_map(credentials) do
    case Map.get(credentials, @credential) do
      value when is_binary(value) and value != "" -> [{@env_key, value}]
      _ -> []
    end
  end

  def env(_runtime_module, _credentials), do: []

  @doc """
  Write the sandbox's `auth.json` when this codex spawn runs on the grant.
  `:skip` when it does not (the library's `prepare_sandbox/3` then runs as
  today); `:ok` or `{:error, reason}` when it does.
  """
  @spec prepare_sandbox(Managoat.Sandbox.Handle.t(), String.t(), [{String.t(), String.t()}]) ::
          :skip | :ok | {:error, term()}
  def prepare_sandbox(handle, @runtime, sprite_env) do
    case List.keyfind(sprite_env, @env_key, 0) do
      {@env_key, value} when is_binary(value) and value != "" ->
        case PlatformChatGPT.sandbox_auth() do
          {:ok, auth} -> write(handle, auth_json(value, auth))
          :none -> {:error, :platform_chatgpt_not_connected}
        end

      _ ->
        :skip
    end
  end

  def prepare_sandbox(_handle, _runtime, _sprite_env), do: :skip

  @doc "The `auth.json` body: `chatgptAuthTokens`, the bearer value, the real account id, the synthesised id_token."
  @spec auth_json(String.t(), %{account_id: String.t(), id_token: String.t()}) :: String.t()
  def auth_json(access_value, %{account_id: account_id, id_token: id_token}) do
    Jason.encode!(%{
      "auth_mode" => "chatgptAuthTokens",
      "tokens" => %{
        "id_token" => id_token,
        "access_token" => access_value,
        "refresh_token" => "",
        "account_id" => account_id
      },
      "last_refresh" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    })
  end

  @doc "Where the file goes: `$CODEX_HOME/auth.json`, under the runtime's layout."
  @spec auth_path() :: String.t()
  def auth_path, do: Path.join(Layout.config_root(@runtime), "auth.json")

  defp write(handle, body) do
    dir = Layout.config_root(@runtime)

    with {:ok, _out, 0} <- Managoat.Sandbox.exec(handle, "mkdir", ["-p", dir], []),
         :ok <- Managoat.Sandbox.write_file(handle, auth_path(), body, mode: 0o600) do
      :ok
    else
      {:ok, out, code} -> {:error, {:codex_auth_mkdir, code, out}}
      {:error, reason} -> {:error, {:codex_auth_write, reason}}
    end
  end
end
