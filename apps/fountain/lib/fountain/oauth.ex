defmodule Fountain.OAuth do
  @moduledoc """
  Fountain as the OAuth 2.0 authorization server for its own first-party
  browser apps — the standalone team and conversations clients on another
  origin (#817).

  The problem it solves: those apps authenticate every API call with a
  bearer API key, and until now the key had to be pasted in. This turns a
  Fountain *session* (however it was opened — password or GitHub) into an
  API key for the app, with the user's consent, without the app ever seeing
  credentials.

  The grant is **authorization code + PKCE (S256), public clients only** —
  what a browser app can do safely. There is no client secret; the redirect
  URI allowlist and the PKCE verifier are what bind a code to the app that
  started the flow.

  ## Clients

  A registry in application config, not a table: there are two of them and
  they are ours. `config :fountain, :oauth_clients, [%{id, name, redirect_uris}]`
  (runtime.exs reads `OAUTH_CLIENTS` as JSON). Redirect URIs match **exactly**.

  ## Tokens are API keys

  A successful exchange mints an ordinary API key (`Accounts.create_api_key/3`)
  named `oauth:<client_id>`, full scope, with an expiry — so it lists and
  revokes under Account → API keys, `TenantAPIAuth` needs no change, and the
  audit trail already knows the shape. No refresh tokens (yet): the app
  signs in again when the key expires.
  """

  import Ecto.Query, warn: false

  alias Fountain.{Accounts, Audit, Repo}
  alias Fountain.OAuth.AuthorizationCode

  @code_ttl_seconds 300
  @token_ttl_seconds 30 * 24 * 3600

  @type client :: %{id: String.t(), name: String.t(), redirect_uris: [String.t()]}

  @doc "The registered public clients."
  @spec clients() :: [client()]
  def clients do
    Application.get_env(:fountain, :oauth_clients, [])
    |> Enum.map(fn c ->
      %{
        id: to_string(c[:id] || c["id"]),
        name: to_string(c[:name] || c["name"] || c[:id] || c["id"]),
        redirect_uris: Enum.map(c[:redirect_uris] || c["redirect_uris"] || [], &to_string/1)
      }
    end)
  end

  @doc "The client with `id`, or nil."
  @spec get_client(String.t()) :: client() | nil
  def get_client(id) when is_binary(id), do: Enum.find(clients(), &(&1.id == id))
  def get_client(_), do: nil

  @doc """
  Validate an authorization request's identity part — the bits that decide
  whether we may redirect at all. `{:ok, client}` or `{:error, reason}`:
  `:unknown_client`, `:redirect_uri_mismatch`, `:invalid_code_challenge`,
  `:unsupported_code_challenge_method`.

  An error here must render, never redirect: a redirect to an unregistered
  URI is exactly the open redirector the allowlist exists to prevent.
  """
  def validate_request(params) do
    with %{} = client <- get_client(params["client_id"]) || {:error, :unknown_client},
         true <-
           params["redirect_uri"] in client.redirect_uris || {:error, :redirect_uri_mismatch},
         true <-
           (params["code_challenge_method"] || "S256") == "S256" ||
             {:error, :unsupported_code_challenge_method},
         true <- valid_challenge?(params["code_challenge"]) || {:error, :invalid_code_challenge} do
      {:ok, client}
    end
  end

  # 43..128 chars of the base64url alphabet — a S256 challenge is 43.
  defp valid_challenge?(c) when is_binary(c), do: Regex.match?(~r/^[A-Za-z0-9._~-]{43,128}$/, c)
  defp valid_challenge?(_), do: false

  @doc """
  The user consented: issue a code for this request. Returns `{:ok, raw_code}`;
  the raw code goes to the redirect and is never stored — only its hash is.
  Records `oauth.authorized`.
  """
  def authorize(user_id, params, opts \\ []) when is_binary(user_id) do
    with {:ok, client} <- validate_request(params) do
      raw = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      %AuthorizationCode{}
      |> AuthorizationCode.changeset(%{
        code_hash: hash(raw),
        user_id: user_id,
        client_id: client.id,
        redirect_uri: params["redirect_uri"],
        code_challenge: params["code_challenge"],
        expires_at:
          DateTime.utc_now()
          |> DateTime.add(@code_ttl_seconds, :second)
          |> DateTime.truncate(:second)
      })
      |> Repo.insert()
      |> case do
        {:ok, _code} ->
          Audit.record(%{
            user_id: user_id,
            action: "oauth.authorized",
            resource_type: "oauth_client",
            resource_id: nil,
            actor: Keyword.get(opts, :actor, "ui"),
            request_ip: Keyword.get(opts, :request_ip),
            metadata: %{"client_id" => client.id, "redirect_uri" => params["redirect_uri"]}
          })

          {:ok, raw}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Exchange a code for an API key. `params` is the token request:
  `code`, `code_verifier`, `client_id`, `redirect_uri`. Returns
  `{:ok, %{access_token: raw_key, expires_in: seconds, api_key: %ApiKey{}}}`
  or `{:error, :invalid_grant}` — deliberately one error for every way a
  grant can be wrong (unknown, used, expired, wrong client, wrong redirect,
  wrong verifier), so the response says nothing about which.

  Single use is enforced by the conditional update that marks the code
  used: two concurrent exchanges of one code cannot both win.
  """
  def exchange(params, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    with code when is_binary(code) <- params["code"] || {:error, :invalid_grant},
         verifier when is_binary(verifier) <- params["code_verifier"] || {:error, :invalid_grant},
         %AuthorizationCode{} = row <-
           Repo.get_by(AuthorizationCode, code_hash: hash(code)) || {:error, :invalid_grant},
         true <- row.client_id == params["client_id"] || {:error, :invalid_grant},
         true <- row.redirect_uri == params["redirect_uri"] || {:error, :invalid_grant},
         true <- DateTime.compare(row.expires_at, now) == :gt || {:error, :invalid_grant},
         true <- pkce_verify(verifier, row.code_challenge) || {:error, :invalid_grant},
         {1, _} <- mark_used(row.id, now) || {:error, :invalid_grant} do
      expires_at = DateTime.add(now, @token_ttl_seconds, :second)

      case Accounts.create_api_key(row.user_id, "oauth:#{row.client_id}",
             expires_at: expires_at,
             actor: Keyword.get(opts, :actor, "self"),
             request_ip: Keyword.get(opts, :request_ip)
           ) do
        {:ok, {api_key, raw_key}} ->
          {:ok, %{access_token: raw_key, expires_in: @token_ttl_seconds, api_key: api_key}}

        {:error, _} ->
          {:error, :server_error}
      end
    else
      {0, _} -> {:error, :invalid_grant}
      {:error, _} = err -> err
      _ -> {:error, :invalid_grant}
    end
  end

  defp mark_used(id, now) do
    from(c in AuthorizationCode, where: c.id == ^id and is_nil(c.used_at))
    |> Repo.update_all(set: [used_at: now])
  end

  @doc "S256: base64url(sha256(verifier)) == challenge, constant-time."
  def pkce_verify(verifier, challenge) when is_binary(verifier) and is_binary(challenge) do
    computed = Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
    byte_size(computed) == byte_size(challenge) and :crypto.hash_equals(computed, challenge)
  end

  def pkce_verify(_, _), do: false

  @doc "Revoke the token (an API key) presented by an app that is signing out."
  def revoke(%Accounts.ApiKey{} = key, opts \\ []) do
    Accounts.revoke_api_key(key.user_id, key.id, opts)
  end

  @doc "Delete codes past their expiry (a sweep; codes are tiny, this is hygiene)."
  def prune_expired do
    now = DateTime.utc_now()
    {n, _} = Repo.delete_all(from(c in AuthorizationCode, where: c.expires_at < ^now))
    n
  end

  def token_ttl_seconds, do: @token_ttl_seconds

  defp hash(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
end
