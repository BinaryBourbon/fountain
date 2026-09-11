defmodule Fountain.OAuth do
  @moduledoc """
  Fountain as the OAuth 2.0 authorization server for its own first-party
  apps — the standalone team and conversations clients on another origin
  (#818) and the CLI's device login (#1305) — as an instance of
  `Managoat.OAuth` (ADR 0037, #1343).

  The problem it solves: those apps authenticate every API call with a
  bearer API key, and until now the key had to be pasted in. This turns a
  Fountain *session* (however it was opened — password or GitHub) into an
  API key for the app, with the user's consent, without the app ever seeing
  credentials.

  The grant is **authorization code + PKCE (S256), public clients only** —
  what a browser app can do safely — plus the device grant for a terminal
  that cannot hold a password. There is no client secret; the redirect URI
  allowlist and the PKCE verifier are what bind a code to the app that
  started the flow. The state machine, the two tables' schemas and the
  client registry's shape are the library's; what the library asks of the
  platform is `Fountain.OAuth.Host`: whether a user may hold a key, minting
  the key, and the audit trail.

  ## Clients

  Two registries. Application config holds the operator's — `config :fountain,
  Fountain.OAuth, clients: [%{id, name, redirect_uris}]`, which runtime.exs
  reads from `OAUTH_CLIENTS` as JSON — and the `oauth_clients` table holds
  the ones a tenant registers for itself (#1125). Redirect URIs match
  **exactly**.

  The client functions at the bottom of this module own the second registry:
  a tenant's own rows, scoped by `user_id`, audited, and capped. A row starts
  unpublished, and the authorization flow does not read the table yet. The
  next change makes it, under the development-mode rule that is what makes a
  self-chosen redirect URI safe.

  ## Tokens are API keys

  A successful exchange mints an ordinary API key (`Accounts.create_api_key/3`)
  named `oauth:<client_id>`, full scope, with an expiry — so it lists and
  revokes under Account → API keys, `TenantAPIAuth` needs no change, and the
  audit trail already knows the shape. No refresh tokens (yet): the app
  signs in again when the key expires. That is a Fountain decision, made in
  the host, not the library's.
  """

  import Ecto.Query, warn: false

  use Managoat.OAuth, otp_app: :fountain, host: Fountain.OAuth.Host

  alias Fountain.{Accounts, Audit, Repo}
  alias Fountain.OAuth.Client

  # An abuse ceiling, not an allowance: every row here will widen the
  # deployment's CORS allowlist (ADR 0021), so registration must not be
  # unbounded.
  @max_clients_per_account 25

  @doc """
  Revoke the token (an API key) presented by an app that is signing out.

  Fountain's own, not the library's: the library never learns what a token
  is, so revoking one is revoking an API key.
  """
  @spec revoke(Accounts.ApiKey.t(), keyword()) ::
          {:ok, Accounts.ApiKey.t()} | {:error, :not_found}
  def revoke(%Accounts.ApiKey{} = key, opts \\ []) do
    Accounts.revoke_api_key(key.user_id, key.id, opts)
  end

  @doc "A tenant's registered clients, newest first."
  @spec list_clients(String.t()) :: [Client.t()]
  def list_clients(user_id) when is_binary(user_id) do
    # `id` breaks the tie: timestamps are second-precision, so two clients
    # registered in the same second would otherwise come back in whatever
    # order the planner chose, and the console list would reorder itself.
    Repo.all(
      from c in Client,
        where: c.user_id == ^user_id,
        order_by: [desc: c.inserted_at, desc: c.id]
    )
  end

  @doc "One tenant-owned client by record id, or nil."
  @spec get_client_record(String.t(), String.t()) :: Client.t() | nil
  def get_client_record(id, user_id) when is_binary(id) and is_binary(user_id) do
    # A path segment is whatever the caller typed. Casting a non-UUID to
    # :binary_id raises, which phoenix_ecto turns into a 400 -- so the
    # documented 404 would never reach a client that mistyped an id.
    if valid_uuid?(id), do: Repo.get_by(Client, id: id, user_id: user_id)
  end

  @doc """
  Register an unpublished client for a tenant.

  The ceiling is per account rather than per deployment, and it is reported as
  an ordinary changeset error so every surface says the same thing.
  """
  @spec create_client(String.t(), map(), keyword()) ::
          {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def create_client(user_id, attrs, opts \\ []) when is_binary(user_id) and is_map(attrs) do
    changeset = Client.changeset(%Client{}, attrs, user_id)

    if client_count(user_id) >= @max_clients_per_account do
      {:error,
       changeset
       |> Ecto.Changeset.add_error(
         :base,
         "at most #{@max_clients_per_account} apps per account"
       )
       |> Map.put(:action, :insert)}
    else
      changeset |> Repo.insert() |> audited("oauth_client.created", opts)
    end
  end

  @doc """
  Rename a client or replace its redirect URIs.

  A call that moves no field succeeds and records nothing.

  `client_id`, the owner and `published` are dropped rather than rejected:
  they are not the caller's to set, and a surface that hands back what it read
  should not fail for sending a field it was given.
  """
  @spec update_client(Client.t(), map(), keyword()) ::
          {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def update_client(%Client{} = client, attrs, opts \\ []) when is_map(attrs) do
    changeset =
      client
      |> Client.changeset(Map.drop(attrs, ["user_id", "client_id", "published"]))
      |> prevent_published_update(client)

    if changeset.valid? and changeset.changes == %{} do
      # A request that moves nothing is not a change. Recording it would put a
      # row in the trail whose `changed` list is empty, which is the "logs
      # attempts as changes" shape ADR 0013 rules out. `Repo.update/1` would
      # not issue a statement here either.
      {:ok, client}
    else
      changeset
      |> Repo.update()
      |> audited(
        "oauth_client.updated",
        Keyword.put(opts, :metadata, Audit.changed_fields(changeset))
      )
    end
  end

  @doc """
  Delete a tenant-owned client.

  Refused once the client is published, for the reason `update_client/3` is:
  publication moved the trust boundary to every account, and deleting the row
  would break sign-in for all of them with a `client_id` nobody can recreate.
  """
  @spec delete_client(Client.t(), keyword()) ::
          {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def delete_client(%Client{} = client, opts \\ []) do
    if client.published do
      {:error,
       client
       |> Ecto.Changeset.change()
       |> Ecto.Changeset.add_error(
         :base,
         "published clients can only be removed by an operator"
       )
       |> Map.put(:action, :delete)}
    else
      client |> Repo.delete() |> audited("oauth_client.deleted", opts)
    end
  end

  defp client_count(user_id) do
    Repo.aggregate(from(c in Client, where: c.user_id == ^user_id), :count)
  end

  defp valid_uuid?(id), do: match?({:ok, _}, Ecto.UUID.cast(id))

  # Publishing changes the trust boundary from owner-only to every account.
  # The owner must not be able to change that operator-approved registration
  # afterward. An operator can unpublish it before handing control back.
  defp prevent_published_update(changeset, %Client{published: true}) do
    Ecto.Changeset.add_error(
      changeset,
      :base,
      "published clients can only be changed by an operator"
    )
  end

  defp prevent_published_update(changeset, _client), do: changeset

  # The trail names the client and where it sends people, never a secret:
  # there is none here, and the redirect URIs are what an operator reading the
  # trail actually needs (ADR 0013).
  defp audited({:ok, %Client{} = client} = ok, action, opts) do
    metadata =
      %{"client_id" => client.client_id, "redirect_uris" => client.redirect_uris}
      |> Map.merge(Keyword.get(opts, :metadata, %{}))

    Audit.record_resource(action, "oauth_client", client, Keyword.put(opts, :metadata, metadata))
    ok
  end

  defp audited(other, _action, _opts), do: other
end
