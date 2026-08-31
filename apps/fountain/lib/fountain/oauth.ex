defmodule Fountain.OAuth do
  @moduledoc """
  Fountain as the OAuth 2.0 authorization server for its own first-party
  browser apps — the standalone team and conversations clients on another
  origin (#818).

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
  alias Fountain.OAuth.{AuthorizationCode, DeviceGrant}

  @code_ttl_seconds 300
  @token_ttl_seconds 30 * 24 * 3600

  @device_ttl_seconds 900
  @device_interval_seconds 5
  # RFC 8628's suggested consonant alphabet: no vowels (no words, no
  # accidental profanity), no ambiguous glyphs. 20^8 codes for a
  # fifteen-minute, rate-limited window.
  @user_code_alphabet ~c"BCDFGHJKLMNPQRSTVWXZ"
  @user_code_length 8

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

  @doc """
  The distinct origins (`scheme://host[:port]`) of every registered client's
  redirect URIs — what the consent page's `form-action` CSP must allow, since
  a successful consent POST redirects the browser to the app's origin (#818).
  """
  @spec redirect_origins() :: [String.t()]
  def redirect_origins do
    clients()
    |> Enum.flat_map(& &1.redirect_uris)
    |> Enum.map(&origin_of/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp origin_of(uri) do
    case URI.parse(uri) do
      %URI{scheme: s, host: h} = u when is_binary(s) and is_binary(h) ->
        port = if u.port && u.port != URI.default_port(s), do: ":#{u.port}", else: ""
        "#{s}://#{h}#{port}"

      _ ->
        nil
    end
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

  ## ─── Device authorization (RFC 8628 shape, for the CLI — #1305) ───────────
  #
  # `fountain auth login --device` cannot exchange a password: an account
  # created with "Sign up with GitHub" has none. Instead the CLI starts a
  # grant, shows the human a short code and the console's `/device` page,
  # and polls with its own high-entropy device code until the signed-in
  # browser session approves. The mint mirrors `POST /api/auth/token`:
  # a full-scope API key with no expiry, because it replaces that endpoint
  # for these accounts.

  @doc """
  Start a device grant. Returns `{:ok, %{device_code, user_code, expires_in,
  interval}}` — `device_code` is raw (only its hash is stored) and stays on
  the polling machine; `user_code` is formatted `XXXX-XXXX` for a human to
  type. Unauthenticated and deliberately unaudited: nothing has happened to
  any account yet, and the poll's mint audits `api_key.created` as usual.
  """
  def start_device_grant do
    raw = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    insert_device_grant(raw, _attempts_left = 3)
  end

  defp insert_device_grant(_raw, 0), do: {:error, :server_error}

  defp insert_device_grant(raw, attempts_left) do
    user_code = generate_user_code()

    %DeviceGrant{}
    |> DeviceGrant.changeset(%{
      device_code_hash: hash(raw),
      user_code: user_code,
      expires_at:
        DateTime.utc_now()
        |> DateTime.add(@device_ttl_seconds, :second)
        |> DateTime.truncate(:second)
    })
    |> Repo.insert()
    |> case do
      {:ok, _grant} ->
        {:ok,
         %{
           device_code: raw,
           user_code: format_user_code(user_code),
           expires_in: @device_ttl_seconds,
           interval: @device_interval_seconds
         }}

      # A user_code collision (20^8 space, so effectively never) — roll again.
      {:error, %Ecto.Changeset{errors: errors}} ->
        if Keyword.has_key?(errors, :user_code),
          do: insert_device_grant(raw, attempts_left - 1),
          else: {:error, :server_error}
    end
  end

  defp generate_user_code do
    for _ <- 1..@user_code_length, into: "" do
      <<Enum.random(@user_code_alphabet)>>
    end
  end

  @doc ~S(Format a stored user code for humans: "BCDFGHJK" → "BCDF-GHJK".)
  def format_user_code(<<a::binary-size(4), b::binary-size(4)>>), do: a <> "-" <> b
  def format_user_code(code), do: code

  @doc """
  Normalize what a human typed: case, the display dash, stray spaces.
  """
  def normalize_user_code(input) when is_binary(input) do
    input |> String.upcase() |> String.replace(~r/[^A-Z]/, "")
  end

  @doc """
  The pending, unexpired grant for a typed user code — what the `/device`
  approval page shows before the user decides. `{:ok, grant}` or
  `{:error, :not_found}` (one answer for unknown, expired and decided alike).
  """
  def get_device_grant_for_approval(input) when is_binary(input) do
    now = DateTime.utc_now()
    code = normalize_user_code(input)

    Repo.one(
      from g in DeviceGrant,
        where:
          g.user_code == ^code and is_nil(g.approved_at) and is_nil(g.denied_at) and
            is_nil(g.used_at) and g.expires_at > ^now
    )
    |> case do
      %DeviceGrant{} = grant -> {:ok, grant}
      nil -> {:error, :not_found}
    end
  end

  @doc """
  The signed-in user approves the grant behind a typed user code: binds their
  account to it so the next poll mints them a key. Conditional on the grant
  still being pending and unexpired, so approve/deny/expiry cannot race.
  Records `oauth.device_approved`.
  """
  def approve_device_grant(input, user_id, opts \\ []) when is_binary(user_id) do
    decide_device_grant(input, user_id, [approved_at: now_s()], "oauth.device_approved", opts)
  end

  @doc """
  The signed-in user denies the grant: the polling CLI gets `access_denied`.
  Records `oauth.device_denied`.
  """
  def deny_device_grant(input, user_id, opts \\ []) when is_binary(user_id) do
    decide_device_grant(input, user_id, [denied_at: now_s()], "oauth.device_denied", opts)
  end

  defp decide_device_grant(input, user_id, set, action, opts) do
    with {:ok, grant} <- get_device_grant_for_approval(input) do
      from(g in DeviceGrant,
        where:
          g.id == ^grant.id and is_nil(g.approved_at) and is_nil(g.denied_at) and
            is_nil(g.used_at)
      )
      |> Repo.update_all(set: [{:user_id, user_id} | set])
      |> case do
        {1, _} ->
          Audit.record(%{
            user_id: user_id,
            action: action,
            resource_type: "oauth_device_grant",
            resource_id: grant.id,
            actor: Keyword.get(opts, :actor, "ui"),
            request_ip: Keyword.get(opts, :request_ip)
          })

          :ok

        {0, _} ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  The CLI polls with its device code. One of:

  - `{:ok, %{access_token, api_key}}` — approved; the grant is consumed and a
    full-scope API key minted (once: the conditional update that marks the
    grant used means two concurrent polls cannot both win)
  - `{:error, :authorization_pending}` — nobody has decided yet
  - `{:error, :slow_down}` — polled faster than the advertised interval
  - `{:error, :access_denied}` — denied in the console, or the approving
    account cannot hold a key (suspended, unverified)
  - `{:error, :expired_token}` — the grant timed out
  - `{:error, :invalid_grant}` — unknown or already-consumed code
  """
  def poll_device_grant(device_code, opts \\ []) when is_binary(device_code) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.get_by(DeviceGrant, device_code_hash: hash(device_code)) do
      nil ->
        {:error, :invalid_grant}

      %DeviceGrant{used_at: %DateTime{}} ->
        {:error, :invalid_grant}

      %DeviceGrant{denied_at: %DateTime{}} ->
        {:error, :access_denied}

      %DeviceGrant{} = grant ->
        if DateTime.compare(grant.expires_at, now) == :gt,
          do: poll_live_grant(grant, now, opts),
          else: {:error, :expired_token}
    end
  end

  defp poll_live_grant(%DeviceGrant{approved_at: nil} = grant, now, _opts) do
    threshold = DateTime.add(now, -(@device_interval_seconds - 1), :second)

    from(g in DeviceGrant,
      where: g.id == ^grant.id and (is_nil(g.last_polled_at) or g.last_polled_at <= ^threshold)
    )
    |> Repo.update_all(set: [last_polled_at: now])
    |> case do
      {1, _} -> {:error, :authorization_pending}
      {0, _} -> {:error, :slow_down}
    end
  end

  defp poll_live_grant(%DeviceGrant{} = grant, now, opts) do
    # user_id was established by the approval above; the grant is the proof.
    user = Repo.preload(grant, :user).user

    cond do
      is_nil(user) ->
        {:error, :invalid_grant}

      # The console page sits behind `require_authenticated_user`, which
      # turns away unverified and suspended sessions — so these are
      # belt-and-braces for state that changed between approval and poll.
      Accounts.suspended?(user) or is_nil(user.email_verified_at) ->
        {:error, :access_denied}

      true ->
        mint_device_key(grant, user, now, opts)
    end
  end

  defp mint_device_key(grant, user, now, opts) do
    from(g in DeviceGrant, where: g.id == ^grant.id and is_nil(g.used_at))
    |> Repo.update_all(set: [used_at: now])
    |> case do
      {0, _} ->
        {:error, :invalid_grant}

      {1, _} ->
        name = "CLI login — #{DateTime.to_date(now)}"

        case Accounts.create_api_key(user.id, name,
               actor: Keyword.get(opts, :actor, "api"),
               request_ip: Keyword.get(opts, :request_ip)
             ) do
          {:ok, {api_key, raw_key}} -> {:ok, %{access_token: raw_key, api_key: api_key}}
          {:error, _} -> {:error, :server_error}
        end
    end
  end

  defp now_s, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc "Delete codes and device grants past their expiry (a sweep; hygiene)."
  def prune_expired do
    now = DateTime.utc_now()
    {codes, _} = Repo.delete_all(from(c in AuthorizationCode, where: c.expires_at < ^now))
    {grants, _} = Repo.delete_all(from(g in DeviceGrant, where: g.expires_at < ^now))
    codes + grants
  end

  def token_ttl_seconds, do: @token_ttl_seconds
  def device_interval_seconds, do: @device_interval_seconds

  defp hash(raw), do: Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
end
