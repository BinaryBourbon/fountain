defmodule Fountain.OAuth.Client do
  @moduledoc """
  An OAuth client a tenant registered for itself (#1125).

  ADR 0021 kept the client registry in config because there were two clients
  and both were ours. This is the row for everybody else's: a person building
  an app inside a sprite, or on `localhost`, who wants "Sign in with Fountain"
  against a running server without an operator editing `OAUTH_CLIENTS` and
  redeploying.

  ## `published` is the security boundary, not the redirect allowlist

  The obvious answer — wildcard the sandbox domain in the redirect allowlist —
  is a phishing kit: anyone with any sandbox could start a flow with their own
  PKCE challenge and their own box as `redirect_uri`, and a consenting user's
  full-scope key would land there. PKCE does not help when the attacker
  initiates the flow.

  So an unpublished client, which is every client registered here, may only
  ever authorize **its own owner** (`Fountain.OAuth.validate_request/2`).
  The only account it can capture belongs to the person who registered it,
  which is what makes the next sentence safe: the owner may register an HTTPS
  redirect or an HTTP loopback redirect — their sprite's public URL or a
  `localhost` port — because no one else's account is reachable through it.

  `published` is an operator flip (there is no self-serve path to it), and a
  published client is an ordinary first-party client on config's terms.

  ## `origin_keys`

  Derived from `redirect_uris` on every write, and indexed, because a CORS
  preflight carries no authentication: the only thing the plug can key on is
  the origin, and "an origin some registered client redirects to" is exactly
  the predicate that makes registering an app enough to call the API from it.

  It holds a lookup *key* rather than the origin verbatim, because a loopback
  redirect matches on any port (RFC 8252) and a CORS rule that did not would
  half-work: the sign-in would land and the first API call would fail, the
  moment Vite moved off 5173.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @max_redirect_uris 10
  @max_uri_length 2000
  @loopback_hosts ~w(localhost 127.0.0.1 ::1)

  @type t :: %__MODULE__{}

  schema "oauth_clients" do
    field :client_id, :string
    field :name, :string
    field :redirect_uris, {:array, :string}, default: []
    field :origin_keys, {:array, :string}, default: []
    field :published, :boolean, default: false

    belongs_to :user, Fountain.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for a tenant-registered client. `client_id` is generated here and
  never accepted from the caller: it is the name the whole flow is keyed on,
  so letting an app choose it would let one app claim another's identity.
  Ownership comes from the context's third argument. Neither `user_id` nor
  `published` is cast from caller attributes.
  """
  def changeset(client, attrs, user_id \\ nil) do
    client
    |> cast(attrs, [:name, :redirect_uris])
    |> put_user_id(user_id)
    |> put_client_id()
    |> validate_required([:name, :user_id])
    |> update_change(:name, &String.trim/1)
    |> validate_length(:name, min: 1, max: 120)
    |> validate_redirect_uris()
    |> put_origin_keys()
    |> unique_constraint(:client_id)
    |> foreign_key_constraint(:user_id)
  end

  defp put_user_id(changeset, user_id) when is_binary(user_id),
    do: put_change(changeset, :user_id, user_id)

  defp put_user_id(changeset, _user_id), do: changeset

  defp put_client_id(%Ecto.Changeset{data: %__MODULE__{client_id: nil}} = changeset),
    do: put_change(changeset, :client_id, generate_client_id())

  defp put_client_id(changeset), do: changeset

  @doc """
  A fresh client id: random, url-safe, and long enough that it is not
  guessable. Not derived from the name — two people may both call their app
  "notes", and an id that collides is an id that can be claimed.
  """
  @spec generate_client_id() :: String.t()
  def generate_client_id do
    "app_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
  end

  # At least one URI, because a client with none can never complete a flow,
  # and a registration that silently cannot work is worse than a rejection.
  defp validate_redirect_uris(changeset) do
    uris = get_field(changeset, :redirect_uris) || []

    changeset
    |> put_change(:redirect_uris, Enum.uniq(uris))
    |> then(fn cs ->
      cond do
        uris == [] ->
          add_error(cs, :redirect_uris, "add at least one redirect URI")

        length(uris) > @max_redirect_uris ->
          add_error(cs, :redirect_uris, "at most #{@max_redirect_uris} redirect URIs")

        true ->
          Enum.reduce(uris, cs, fn uri, acc ->
            case uri_error(uri) do
              nil -> acc
              msg -> add_error(acc, :redirect_uris, "#{uri}: #{msg}")
            end
          end)
      end
    end)
  end

  @doc """
  Why `uri` cannot be a redirect URI, or nil. Public so the API and the
  console can say the same thing before a write is attempted.
  """
  @spec uri_error(term()) :: String.t() | nil
  def uri_error(uri) when is_binary(uri) do
    parsed = URI.parse(uri)

    cond do
      String.length(uri) > @max_uri_length -> "too long"
      String.trim(uri) != uri -> "has leading or trailing whitespace"
      parsed.scheme not in ["http", "https"] -> "must start with https:// or http://"
      is_nil(parsed.host) or parsed.host == "" -> "must have a host"
      parsed.fragment != nil -> "must not have a #fragment"
      parsed.scheme == "http" and not loopback?(parsed.host) -> "must be https, unless loopback"
      true -> nil
    end
  end

  def uri_error(_), do: "must be a string"

  @doc "Whether `host` is the developer's own machine (RFC 8252 §7.3)."
  @spec loopback?(String.t() | nil) :: boolean()
  def loopback?(host) when is_binary(host), do: String.downcase(host) in @loopback_hosts
  def loopback?(_), do: false

  # Kept in step with redirect_uris on every write, so the CORS lookup is one
  # indexed array containment and never a scan over parsed URIs.
  defp put_origin_keys(changeset) do
    case get_field(changeset, :redirect_uris) do
      uris when is_list(uris) ->
        put_change(changeset, :origin_keys, uris |> origins_of() |> Enum.map(&origin_key/1))

      _ ->
        changeset
    end
  end

  @doc "The distinct `scheme://host[:port]` origins of a list of redirect URIs."
  @spec origins_of([String.t()]) :: [String.t()]
  def origins_of(uris) when is_list(uris) do
    uris |> Enum.map(&origin_of/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  @doc "The `scheme://host[:port]` origin of a URI, or nil if it has none."
  @spec origin_of(term()) :: String.t() | nil
  def origin_of(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host} = parsed when is_binary(scheme) and is_binary(host) ->
        port =
          if parsed.port && parsed.port != URI.default_port(scheme),
            do: ":#{parsed.port}",
            else: ""

        "#{scheme}://#{format_host(host)}#{port}"

      _ ->
        nil
    end
  end

  def origin_of(_), do: nil

  @doc """
  What an origin is stored and looked up as. The origin itself, except on
  loopback, where the port is dropped so that `http://localhost:5174` matches
  a client registered against `http://localhost:5173` — the same any-port rule
  the redirect URI gets (RFC 8252 §7.3), for the same reason: the port a local
  dev server ends up on is not a fact anybody registered.
  """
  @spec origin_key(term()) :: String.t() | nil
  def origin_key(origin) when is_binary(origin) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host} when is_binary(scheme) and is_binary(host) ->
        if loopback?(host), do: "#{scheme}://#{format_host(host)}", else: origin_of(origin)

      _ ->
        nil
    end
  end

  def origin_key(_), do: nil

  defp format_host(host) do
    host = String.downcase(host)
    if String.contains?(host, ":"), do: "[#{host}]", else: host
  end
end
