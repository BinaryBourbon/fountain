defmodule Fountain.Connections do
  @moduledoc """
  Provider accounts a tenant has signed in to once, whose credentials
  Fountain holds (#1178). This is how a managed-agent platform does
  connectors: the platform runs the OAuth flow, keeps the refresh token, and
  hands an agent a capability rather than a credential.

  A connection reaches an agent two ways, both only for accounts the egress
  broker is on for (`Fountain.Broker.enabled_for?/1`):

    * **A Fountain-served MCP server.** An agent's `mcp_servers` names the
      connection (`%{"gmail" => %{"connection" => id}}`) and the conversation
      gets `POST /api/mcp/gmail/:conversation_id/:connection_id`, authenticated
      by its own callback token. The token never leaves the server.
    * **A brokered secret.** The access token is a synthetic secret under
      `env_key` (`GOOGLE_ACCESS_TOKEN`), brokered like an inference key: the
      sandbox holds a placeholder, the broker attaches the value to requests
      for the provider's hosts, and a binding of the tenant's own on the same
      name sends it to an MCP server they run instead. Rotated tokens are
      re-uploaded by `Fountain.Conversations.ConversationServer` at each turn.

  Every read of a token goes through `access_token/1`, which refreshes near
  expiry and marks the connection `revoked` when the provider refuses the
  grant (`invalid_grant`). A revoked connection stays listed so the console
  can say why the tools stopped working; reconnecting replaces it.

  Audit: `connection.created` / `connection.revoked` carry provider, scopes
  and the account address — never a token (ADR 0013).
  """

  import Ecto.Query, warn: false

  alias Fountain.{Audit, Crypto, Repo}
  alias Fountain.Connections.{Connection, Google}

  # How close to expiry a token is considered stale. A turn may run for a
  # while on the token it started with, so refresh well ahead.
  @refresh_margin_seconds 300

  # ── reads ─────────────────────────────────────────────────────────────────

  @spec list_connections(String.t()) :: [Connection.t()]
  def list_connections(user_id) when is_binary(user_id) do
    Repo.all(
      from c in Connection,
        where: c.user_id == ^user_id,
        order_by: [asc: c.provider, asc: c.account_email]
    )
  end

  @spec get_connection(String.t(), String.t()) :: Connection.t() | nil
  def get_connection(id, user_id) when is_binary(id) and is_binary(user_id) do
    if valid_uuid?(id), do: Repo.get_by(Connection, id: id, user_id: user_id)
  end

  @doc "The tenant's active connections only — what a sandbox may be handed."
  @spec active_connections(String.t()) :: [Connection.t()]
  def active_connections(user_id) when is_binary(user_id) do
    Repo.all(
      from c in Connection,
        where: c.user_id == ^user_id and c.status == "active",
        order_by: [asc: c.env_key]
    )
  end

  # ── writes ────────────────────────────────────────────────────────────────

  @doc """
  Store a fresh grant for `provider`. One connection per (provider, account):
  signing the same account in again replaces its tokens and reactivates it.
  `grant` is what `Fountain.Connections.Google.exchange_code/2` returns.
  """
  @spec connect(String.t(), String.t(), map(), keyword()) ::
          {:ok, Connection.t()} | {:error, Ecto.Changeset.t() | atom()}
  def connect(user_id, provider, grant, opts \\ [])
      when is_binary(user_id) and is_binary(provider) and is_map(grant) do
    with {:ok, dek} <- Crypto.load_tenant_key(user_id) do
      existing =
        Repo.get_by(Connection,
          user_id: user_id,
          provider: provider,
          account_email: grant.account_email
        )

      attrs = %{
        user_id: user_id,
        provider: provider,
        account_email: grant.account_email,
        scopes: grant.scopes,
        env_key: (existing && existing.env_key) || free_env_key(user_id, provider),
        refresh_token: grant.refresh_token,
        access_token: grant.access_token,
        expires_at: grant.expires_at
      }

      (existing || %Connection{})
      |> Connection.changeset(attrs, dek)
      |> Repo.insert_or_update()
      |> audited("connection.created", opts)
    end
  end

  @doc """
  Revoke a connection: the provider is told to forget the grant (best
  effort), and the row is marked `revoked` so every door says why. The next
  MCP tool call on it fails with `connection revoked`, not a 401 from the
  provider.
  """
  @spec revoke(Connection.t(), keyword()) :: {:ok, Connection.t()} | {:error, term()}
  def revoke(%Connection{} = conn, opts \\ []) do
    if conn.status == "active" do
      with {:ok, dek} <- Crypto.load_tenant_key(conn.user_id) do
        case decrypt(conn.refresh_token_ciphertext, dek) do
          {:ok, refresh} -> Google.revoke(refresh)
          _ -> :ok
        end
      end
    end

    conn
    |> Connection.revoke_changeset()
    |> Repo.update()
    |> audited("connection.revoked", opts)
  end

  @doc "Delete a connection outright. Revokes at the provider first."
  @spec delete(Connection.t(), keyword()) :: {:ok, Connection.t()} | {:error, term()}
  def delete(%Connection{} = conn, opts \\ []) do
    with {:ok, conn} <- revoke(conn, opts) do
      Repo.delete(conn)
    end
  end

  # Marks the connection revoked because the provider refused the grant.
  # A system event, not the tenant's: attributed to the refresher.
  defp mark_refused(%Connection{} = conn) do
    conn
    |> Connection.revoke_changeset()
    |> Repo.update()
    |> audited("connection.revoked",
      actor: "system:connection_refresh",
      metadata: %{"reason" => "invalid_grant"}
    )
  end

  # ── tokens ────────────────────────────────────────────────────────────────

  @doc """
  A valid access token for the connection, refreshing when it is within
  #{@refresh_margin_seconds}s of expiry. `{:error, :revoked}` for a revoked
  connection, including one the provider has just refused.
  """
  @spec access_token(Connection.t()) :: {:ok, String.t()} | {:error, term()}
  def access_token(%Connection{status: "revoked"}), do: {:error, :revoked}

  def access_token(%Connection{} = conn) do
    with {:ok, dek} <- Crypto.load_tenant_key(conn.user_id) do
      if fresh?(conn) do
        decrypt(conn.access_token_ciphertext, dek)
      else
        refresh_token(conn, dek)
      end
    end
  end

  @doc """
  The synthetic secrets a tenant's active connections contribute to a
  sandbox: `%{"GOOGLE_ACCESS_TOKEN" => token}`. A connection whose refresh
  fails is left out, and the sandbox runs without it; the console says why.
  """
  @spec synthetic_secrets(String.t()) :: %{String.t() => String.t()}
  def synthetic_secrets(user_id) when is_binary(user_id) do
    user_id
    |> active_connections()
    |> Enum.reduce(%{}, fn conn, acc ->
      case access_token(conn) do
        {:ok, token} -> Map.put(acc, conn.env_key, token)
        _ -> acc
      end
    end)
  end

  @doc "The env var names a tenant's connections are brokered under (for the bindings catalog)."
  @spec env_keys(String.t()) :: [String.t()]
  def env_keys(user_id) when is_binary(user_id) do
    Repo.all(from c in Connection, where: c.user_id == ^user_id, select: c.env_key)
  end

  @doc """
  The hosts an `env_key`'s token is implicitly bound to as a bearer, or `[]`
  for a key that is not a connection's. A second account of the same
  provider is `GOOGLE_ACCESS_TOKEN_2`, and binds the same way.
  """
  @spec implicit_hosts(String.t()) :: [String.t()]
  def implicit_hosts(key) when is_binary(key) do
    if String.starts_with?(key, Google.env_key()), do: Google.token_hosts(), else: []
  end

  # The first account of a provider takes the bare key; each further one
  # takes the next numbered key, so every connection is addressable by name
  # in a binding and none shadows another.
  defp free_env_key(user_id, provider) do
    base = env_key_for(provider)
    taken = MapSet.new(env_keys(user_id))

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> "#{base}_#{n}"
    end)
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  defp fresh?(%Connection{access_token_ciphertext: nil}), do: false
  defp fresh?(%Connection{expires_at: nil}), do: false

  defp fresh?(%Connection{expires_at: at}) do
    DateTime.diff(at, DateTime.utc_now(), :second) > @refresh_margin_seconds
  end

  defp refresh_token(conn, dek) do
    with {:ok, refresh} <- decrypt(conn.refresh_token_ciphertext, dek) do
      case Google.refresh(refresh) do
        {:ok, access, expires_at} ->
          case conn |> Connection.refresh_changeset(access, expires_at, dek) |> Repo.update() do
            {:ok, _} -> {:ok, access}
            {:error, changeset} -> {:error, changeset}
          end

        {:error, :invalid_grant} ->
          _ = mark_refused(conn)
          {:error, :revoked}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp decrypt(nil, _dek), do: {:error, :no_token}

  defp decrypt(blob, dek) do
    case Crypto.decrypt(blob, dek) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :undecryptable}
    end
  end

  defp env_key_for("google"), do: Google.env_key()

  defp valid_uuid?(id), do: match?({:ok, _}, Ecto.UUID.cast(id))

  # Provider, scopes and the address name the connection; no token is ever
  # in the trail (ADR 0013).
  defp audited({:ok, %Connection{} = conn} = ok, action, opts) do
    metadata = %{
      "provider" => conn.provider,
      "account_email" => conn.account_email,
      "scopes" => conn.scopes,
      "env_key" => conn.env_key
    }

    opts = Keyword.update(opts, :metadata, metadata, &Map.merge(metadata, &1))
    Audit.record_resource(action, "connection", conn, opts)
    ok
  end

  defp audited(other, _action, _opts), do: other
end
