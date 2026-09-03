defmodule Fountain.OAuth do
  @moduledoc """
  Fountain's OAuth 2.0 authorization server.

  The authorization-code and device-grant state machines come from
  `Managoat.OAuth`. Fountain adds two client registries: operator-configured
  clients are published and can sign in any account, while tenant-owned
  clients start in development mode and can sign in only their owner.

  That owner-only boundary is what makes self-service registration safe.
  A tenant can register a sandbox or loopback redirect without turning the
  server into an open redirector for other accounts. Unpublished loopback
  redirects follow RFC 8252 and may use a different port from the registered
  URI.

  Tokens are ordinary full-scope Fountain API keys. The client registry also
  supplies the CORS origins that let a browser use such a key against `/api`.
  """

  import Ecto.Query, warn: false

  use Managoat.OAuth, otp_app: :fountain, host: Fountain.OAuth.Host

  defoverridable get_client: 1, validate_request: 1, authorize: 2, authorize: 3

  alias Fountain.{Accounts, Audit, Repo}
  alias Fountain.OAuth.Client
  alias Managoat.OAuth.Clients

  @type client :: %{
          id: String.t(),
          name: String.t(),
          redirect_uris: [String.t()],
          published: boolean(),
          owner_id: String.t() | nil,
          record_id: String.t() | nil
        }

  @doc """
  Operator-configured clients, treated as published.

  The configuration is still the authority for first-party apps. It wins over
  a database row with the same id, so a tenant cannot shadow an operator app.
  """
  @spec config_clients() :: [client()]
  def config_clients do
    __managoat_oauth__()
    |> Managoat.OAuth.clients()
    |> Enum.map(&Map.merge(&1, %{published: true, owner_id: nil, record_id: nil}))
  end

  @doc "The client with `id`, or nil. Operator configuration wins."
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
  Validate an authorization request without a resolved subject.

  This keeps the instance API available to callers that only use configured
  clients. A development-mode client fails closed until the caller supplies
  the signed-in subject to `validate_request/2`.
  """
  @spec validate_request(map()) :: {:ok, client()} | {:error, atom()}
  def validate_request(params), do: validate_request(params, nil)

  @doc """
  Validate the client, development-mode boundary, redirect and PKCE request.

  The owner check intentionally comes before redirect matching. A different
  account learns only that the client is in development mode, never which
  redirects its owner registered.
  """
  @spec validate_request(map(), String.t() | nil) :: {:ok, client()} | {:error, atom()}
  def validate_request(params, user_id) when is_map(params) do
    with %{} = client <- get_client(params["client_id"]) || {:error, :unknown_client},
         true <- authorizable_by?(client, user_id) || {:error, :development_mode},
         true <-
           redirect_registered?(client, params["redirect_uri"]) ||
             {:error, :redirect_uri_mismatch},
         {:ok, _} <- Clients.validate_request([grant_client(client, params)], params) do
      {:ok, client}
    end
  end

  @doc "Whether a subject may authorize through a client."
  @spec authorizable_by?(client(), String.t() | nil) :: boolean()
  def authorizable_by?(%{published: true}, _user_id), do: true

  def authorizable_by?(%{owner_id: owner_id}, user_id)
      when is_binary(owner_id) and is_binary(user_id),
      do: owner_id == user_id

  def authorizable_by?(_client, _user_id), do: false

  defp redirect_registered?(client, uri) when is_binary(uri) do
    cond do
      uri in client.redirect_uris -> true
      client.published -> false
      true -> Enum.any?(client.redirect_uris, &loopback_match?(&1, uri))
    end
  end

  defp redirect_registered?(_client, _uri), do: false

  defp loopback_match?(registered, requested) do
    registered = URI.parse(registered)
    requested = URI.parse(requested)

    Client.loopback?(registered.host) and Client.loopback?(requested.host) and
      registered.scheme == requested.scheme and
      String.downcase(registered.host) == String.downcase(requested.host) and
      registered.userinfo == requested.userinfo and registered.path == requested.path and
      registered.query == requested.query and registered.fragment == requested.fragment
  end

  # Managoat validates exact redirect matches. Once Fountain has accepted an
  # RFC 8252 any-port loopback redirect, give the state machine the validated
  # requested URI so its second validation reaches the same conclusion.
  defp grant_client(client, params) do
    client
    |> Map.take([:id, :name])
    |> Map.put(:redirect_uris, [params["redirect_uri"]])
  end

  @doc "Issue an authorization code after applying Fountain's client policy."
  def authorize(subject, params, opts \\ []) when is_binary(subject) and is_map(params) do
    with {:ok, client} <- validate_request(params, subject) do
      config = %{__managoat_oauth__() | clients: [grant_client(client, params)]}
      Managoat.OAuth.authorize(config, subject, params, opts)
    end
  end

  @doc "The one validated redirect origin allowed by the consent response's CSP."
  @spec form_action_origins(String.t()) :: [String.t()]
  def form_action_origins(redirect_uri) do
    case Client.origin_of(redirect_uri) do
      nil -> []
      origin -> [origin]
    end
  end

  @doc "Revoke the token presented by an app that is signing out."
  @spec revoke(Accounts.ApiKey.t(), keyword()) ::
          {:ok, Accounts.ApiKey.t()} | {:error, :not_found}
  def revoke(%Accounts.ApiKey{} = key, opts \\ []) do
    Accounts.revoke_api_key(key.user_id, key.id, opts)
  end

  @doc "A tenant's registered clients, newest first."
  @spec list_clients(String.t()) :: [Client.t()]
  def list_clients(user_id) when is_binary(user_id) do
    Repo.all(from c in Client, where: c.user_id == ^user_id, order_by: [desc: c.inserted_at])
  end

  @doc "One tenant-owned client by record id, or nil."
  @spec get_client_record(String.t(), String.t()) :: Client.t() | nil
  def get_client_record(id, user_id) when is_binary(id) and is_binary(user_id) do
    Repo.get_by(Client, id: id, user_id: user_id)
  end

  @doc "Register an unpublished client for a tenant."
  @spec create_client(String.t(), map(), keyword()) ::
          {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def create_client(user_id, attrs, opts \\ []) when is_binary(user_id) and is_map(attrs) do
    %Client{}
    |> Client.changeset(attrs, user_id)
    |> Repo.insert()
    |> audited("oauth_client.created", opts)
  end

  @doc "Rename a client or replace its redirect URIs."
  @spec update_client(Client.t(), map(), keyword()) ::
          {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def update_client(%Client{} = client, attrs, opts \\ []) when is_map(attrs) do
    changeset =
      client
      |> Client.changeset(Map.drop(attrs, ["user_id", "client_id", "published"]))
      |> prevent_published_update(client)

    changeset
    |> Repo.update()
    |> audited(
      "oauth_client.updated",
      Keyword.put(opts, :metadata, Audit.changed_fields(changeset))
    )
  end

  @doc "Delete a tenant-owned client."
  @spec delete_client(Client.t(), keyword()) ::
          {:ok, Client.t()} | {:error, Ecto.Changeset.t()}
  def delete_client(%Client{} = client, opts \\ []) do
    client |> Repo.delete() |> audited("oauth_client.deleted", opts)
  end

  @doc """
  Whether an origin belongs to an operator or tenant client.

  CORS still requires a bearer key. This predicate grants no account access;
  it only lets a browser present that key from its registered origin.
  """
  @spec registered_origin?(term()) :: boolean()
  def registered_origin?(origin) when is_binary(origin) do
    case Client.origin_key(origin) do
      nil -> false
      key -> key in config_origin_keys() or Repo.exists?(origin_key_query(key))
    end
  end

  def registered_origin?(_), do: false

  defp origin_key_query(key) do
    from c in Client, where: fragment("? @> ?", c.origin_keys, ^[key])
  end

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

  defp config_origin_keys do
    config_clients()
    |> Enum.flat_map(& &1.redirect_uris)
    |> Client.origins_of()
    |> Enum.map(&Client.origin_key/1)
    |> Enum.reject(&is_nil/1)
  end

  defp audited({:ok, %Client{} = client} = ok, action, opts) do
    metadata =
      %{"client_id" => client.client_id, "redirect_uris" => client.redirect_uris}
      |> Map.merge(Keyword.get(opts, :metadata, %{}))

    Audit.record_resource(action, "oauth_client", client, Keyword.put(opts, :metadata, metadata))
    ok
  end

  defp audited(other, _action, _opts), do: other
end
