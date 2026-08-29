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

  Two registries, read as one (#1125).

  **Config** — `config :fountain, :oauth_clients, [%{id, name, redirect_uris}]`
  (runtime.exs reads `OAUTH_CLIENTS` as JSON). The operator's own apps. They
  are treated as **published**: any account may sign in to them.

  **The `oauth_clients` table** — what a tenant registers for itself, so that
  an app built inside a sprite or on `localhost` can offer "Sign in with
  Fountain" without an operator editing config and redeploying. Every one of
  these starts **unpublished**, and an unpublished client may only authorize
  its own owner. That is the whole security boundary, and it is why its owner
  may then register any redirect URI they like: the only account reachable
  through it is theirs. `Fountain.OAuth.Client` has the long form.

  Redirect URIs match **exactly**, with one exception: on an unpublished
  client a loopback URI matches on any port (RFC 8252 §7.3), because the port
  a local dev server lands on is not a fact anybody registered.

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
  alias Fountain.OAuth.Client

  @code_ttl_seconds 300
  @token_ttl_seconds 30 * 24 * 3600

  @type client :: %{
          id: String.t(),
          name: String.t(),
          redirect_uris: [String.t()],
          published: boolean(),
          owner_id: String.t() | nil,
          record_id: String.t() | nil
        }

  @doc """
  The operator's own clients, from application config. Treated as published:
  the operator registering an app in `OAUTH_CLIENTS` is the vouching that
  `published` means for a tenant-registered one.
  """
  @spec config_clients() :: [client()]
  def config_clients do
    Application.get_env(:fountain, :oauth_clients, [])
    |> Enum.map(fn c ->
      %{
        id: to_string(c[:id] || c["id"]),
        name: to_string(c[:name] || c["name"] || c[:id] || c["id"]),
        redirect_uris: Enum.map(c[:redirect_uris] || c["redirect_uris"] || [], &to_string/1),
        published: true,
        owner_id: nil,
        record_id: nil
      }
    end)
  end

  @doc """
  The origins the consent page's `form-action` CSP must allow: the one the
  browser will actually be sent to, which is the origin of the **validated**
  redirect URI of this request (#818).

  Not the client's registered origins, and emphatically not the registry's.
  The registry-wide header this replaced would grow without bound once tenants
  register their own apps, and would hand every registered app's origin to
  whoever loaded any consent page. Registered origins are wrong for a subtler
  reason: an unpublished client's loopback redirect matches on any port, so a
  client registered against `:5199` and asked for `:5200` would get a header
  naming `:5199` — the redirect is legal and Chrome blocks it anyway. Pass the
  requested URI, which `validate_request/2` has already approved.
  """
  @spec form_action_origins(String.t()) :: [String.t()]
  def form_action_origins(redirect_uri) do
    case Client.origin_of(redirect_uri) do
      nil -> []
      origin -> [origin]
    end
  end

  @doc "The client with `id`, or nil. Config wins, so a row can never shadow one."
  @spec get_client(term()) :: client() | nil
  def get_client(id) when is_binary(id) do
    Enum.find(config_clients(), &(&1.id == id)) || db_client(id)
  end

  def get_client(_), do: nil

  defp db_client(id) do
    case Repo.get_by(Client, client_id: id) do
      nil -> nil
      %Client{} = row -> to_client(row)
    end
  end

  defp to_client(%Client{} = row) do
    %{
      id: row.client_id,
      name: row.name,
      redirect_uris: row.redirect_uris,
      published: row.published,
      owner_id: row.user_id,
      record_id: row.id
    }
  end

  @doc """
  Validate an authorization request's identity part — the bits that decide
  whether we may redirect at all. `{:ok, client}` or `{:error, reason}`:
  `:unknown_client`, `:development_mode`, `:redirect_uri_mismatch`,
  `:invalid_code_challenge`, `:unsupported_code_challenge_method`.

  `user_id` is whoever is signed in. An **unpublished** client authorizes only
  its owner; for anyone else this is `:development_mode`, which is the reason
  the owner is free to register whatever redirect URI they like (#1125). It is
  checked before the redirect URI on purpose, so a stranger's error page says
  nothing about what the app is registered for.

  An error here must render, never redirect: a redirect to an unregistered
  URI is exactly the open redirector the allowlist exists to prevent.
  """
  @spec validate_request(map(), String.t() | nil) :: {:ok, client()} | {:error, atom()}
  def validate_request(params, user_id \\ nil) do
    with %{} = client <- get_client(params["client_id"]) || {:error, :unknown_client},
         true <- authorizable_by?(client, user_id) || {:error, :development_mode},
         true <-
           redirect_registered?(client, params["redirect_uri"]) ||
             {:error, :redirect_uri_mismatch},
         true <-
           (params["code_challenge_method"] || "S256") == "S256" ||
             {:error, :unsupported_code_challenge_method},
         true <- valid_challenge?(params["code_challenge"]) || {:error, :invalid_code_challenge} do
      {:ok, client}
    end
  end

  @doc """
  Whether `user_id` may sign in to `client`. Published clients take anyone;
  an unpublished one takes its owner and nobody else — including nobody at
  all, so a caller that has not resolved a user fails closed.
  """
  @spec authorizable_by?(client(), String.t() | nil) :: boolean()
  def authorizable_by?(%{published: true}, _user_id), do: true

  def authorizable_by?(%{owner_id: owner_id}, user_id)
      when is_binary(owner_id) and is_binary(user_id),
      do: owner_id == user_id

  def authorizable_by?(_client, _user_id), do: false

  # Exact, except that an unpublished client's loopback URI matches on any
  # port: the developer registered `http://localhost:5173/callback` and Vite
  # started on 5174 because 5173 was busy (RFC 8252 §7.3). Published clients
  # get no such latitude — they are reachable by every account.
  defp redirect_registered?(client, uri) when is_binary(uri) do
    cond do
      uri in client.redirect_uris -> true
      client.published -> false
      true -> Enum.any?(client.redirect_uris, &loopback_match?(&1, uri))
    end
  end

  defp redirect_registered?(_client, _uri), do: false

  defp loopback_match?(registered, requested) do
    r = URI.parse(registered)
    q = URI.parse(requested)

    Client.loopback?(r.host) and Client.loopback?(q.host) and r.scheme == q.scheme and
      String.downcase(r.host) == String.downcase(q.host) and r.path == q.path and
      r.query == q.query
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
    with {:ok, client} <- validate_request(params, user_id) do
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
            resource_id: client.record_id,
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

  # ── the tenant's own clients (#1125) ─────────────────────────────────────

  @doc "A tenant's registered clients, newest first."
  @spec list_clients(String.t()) :: [Client.t()]
  def list_clients(user_id) when is_binary(user_id) do
    Repo.all(from c in Client, where: c.user_id == ^user_id, order_by: [desc: c.inserted_at])
  end

  @doc "One of a tenant's clients by row id, or nil."
  @spec get_client_record(String.t(), String.t()) :: Client.t() | nil
  def get_client_record(id, user_id) when is_binary(id) and is_binary(user_id) do
    Repo.get_by(Client, id: id, user_id: user_id)
  end

  @doc """
  Register a client for a tenant. `attrs` is string-keyed and carries `name`
  and `redirect_uris`; the owner comes from the first argument and the
  `client_id` is generated, never accepted.

  The client is unpublished, so it will sign in `user_id` and refuse everyone
  else. That is what lets the caller register a sprite's public URL or a
  `localhost` port without an operator's involvement.
  """
  @spec create_client(String.t(), map(), keyword()) ::
          {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def create_client(user_id, attrs, opts \\ []) when is_binary(user_id) and is_map(attrs) do
    %Client{}
    |> Client.changeset(Map.put(attrs, "user_id", user_id))
    |> Repo.insert()
    |> audited("oauth_client.created", opts)
  end

  @doc "Rename a client or change its redirect URIs. `published` is not settable here."
  @spec update_client(Client.t(), map(), keyword()) ::
          {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def update_client(%Client{} = client, attrs, opts \\ []) when is_map(attrs) do
    changeset = Client.changeset(client, Map.drop(attrs, ["user_id", "client_id", "published"]))

    changeset
    |> Repo.update()
    |> audited(
      "oauth_client.updated",
      Keyword.put(opts, :metadata, Audit.changed_fields(changeset))
    )
  end

  @doc """
  Delete a client. Keys already issued through it are ordinary API keys and
  outlive it — revoking those is Account, then API keys, as it always was.
  """
  @spec delete_client(Client.t(), keyword()) :: {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def delete_client(%Client{} = client, opts \\ []) do
    client |> Repo.delete() |> audited("oauth_client.deleted", opts)
  end

  @doc """
  Whether `origin` is one some registered client redirects to — the predicate
  the CORS plug adds to the static `API_CORS_ORIGINS` list (#1125).

  A preflight carries no authentication, so the origin is the only thing there
  is to key on, and that is precisely why this is the right question: the
  answer admits a browser to `/api`, where it still has to present a bearer
  key, and no cookie crosses an origin either way.
  """
  @spec registered_origin?(term()) :: boolean()
  def registered_origin?(origin) when is_binary(origin) do
    case Client.origin_key(origin) do
      nil -> false
      key -> key in config_origin_keys() or Repo.exists?(origin_key_query(key))
    end
  end

  def registered_origin?(_), do: false

  # `@>` rather than `in`, so the GIN index on origin_keys is the plan.
  defp origin_key_query(key) do
    from c in Client, where: fragment("? @> ?", c.origin_keys, ^[key])
  end

  defp config_origin_keys do
    config_clients()
    |> Enum.flat_map(& &1.redirect_uris)
    |> Client.origins_of()
    |> Enum.map(&Client.origin_key/1)
    |> Enum.reject(&is_nil/1)
  end

  # ── audit ────────────────────────────────────────────────────────────────

  # The redirect URIs are the interesting half of a client and they are not
  # tenant data in the sense the trail avoids — they are public by the time a
  # browser sees them — so an incident can read where an app sent people.
  defp audited({:ok, %Client{} = client} = ok, action, opts) do
    metadata =
      %{"client_id" => client.client_id, "redirect_uris" => client.redirect_uris}
      |> Map.merge(Keyword.get(opts, :metadata, %{}))

    Audit.record_resource(action, "oauth_client", client, Keyword.put(opts, :metadata, metadata))

    ok
  end

  defp audited(other, _action, _opts), do: other
end
