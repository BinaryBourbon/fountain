defmodule Fountain.Webhooks.Endpoint do
  @moduledoc """
  A tenant-owned URL that lifecycle events are POSTed to.

  The signing secret is **encrypted, not hashed**, unlike `api_keys.key_hash`:
  we have to read it back to sign with it. That is what `Fountain.Crypto`
  envelope encryption is for, and it is the same path environment and vault
  secrets take. It is shown once at creation and once at each rotation, and
  never rendered again.

  `consecutive_failures` counts *events* that exhausted their retries, not
  attempts. It resets on any delivery the receiver accepted, so an endpoint
  that is merely flaky never trips the auto-disable, and one that is gone
  trips it in the low tens of hours.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Fountain.Crypto
  alias Fountain.Webhooks.{Events, Url}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active disabled)

  @type t :: %__MODULE__{}

  @doc "The status vocabulary."
  def statuses, do: @statuses

  schema "webhook_endpoints" do
    field :url, :string
    field :description, :string
    field :secret_ciphertext, :binary
    field :secret, :string, virtual: true, redact: true
    field :event_types, {:array, :string}, default: []
    field :status, :string, default: "active"
    field :consecutive_failures, :integer, default: 0
    field :disabled_at, :utc_datetime
    field :disabled_reason, :string
    belongs_to :user, Fountain.Accounts.User
    timestamps(type: :utc_datetime)
  end

  @doc """
  Cast the tenant-settable fields, encrypting `attrs["secret"]` with the
  per-tenant `dek` when one is being set.

  `status` is deliberately not castable here. An endpoint is disabled by the
  delivery worker or re-enabled by `Fountain.Webhooks.enable_endpoint/2`,
  both of which have bookkeeping to do that a bare field write would skip.
  """
  def changeset(endpoint, attrs, dek) when is_binary(dek) do
    endpoint
    |> cast(attrs, [:url, :description, :event_types, :secret, :user_id])
    |> update_change(:event_types, &normalize_event_types/1)
    |> validate_required([:url, :user_id])
    |> validate_length(:description, max: 500)
    |> validate_url()
    |> validate_event_types()
    |> put_ciphertext(dek)
    |> validate_required([:secret_ciphertext])
  end

  defp normalize_event_types(types) when is_list(types) do
    types |> Enum.map(&String.trim(to_string(&1))) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
  end

  defp normalize_event_types(other), do: other

  defp validate_url(changeset) do
    validate_change(changeset, :url, fn :url, url ->
      case Url.check_saveable(url) do
        {:ok, _uri} -> []
        {:error, reason} -> [url: reason]
      end
    end)
  end

  # `get_field/2` rather than `validate_change/3`: an empty list is the
  # column default, so on a new record it is not a *change* and a
  # change-scoped validation would never see it.
  defp validate_event_types(changeset) do
    types = get_field(changeset, :event_types) || []
    unknown = Enum.reject(types, &Events.valid_filter?/1)

    cond do
      types == [] ->
        add_error(changeset, :event_types, "must name at least one event")

      unknown != [] ->
        add_error(changeset, :event_types, "unknown event #{Enum.join(unknown, ", ")}")

      true ->
        changeset
    end
  end

  defp put_ciphertext(changeset, dek) do
    case get_change(changeset, :secret) do
      nil -> changeset
      secret -> put_change(changeset, :secret_ciphertext, Crypto.encrypt(secret, dek))
    end
  end

  @doc "Decrypt the signing secret. `{:ok, plaintext}` or `:error`."
  @spec decrypt_secret(t(), binary()) :: {:ok, String.t()} | :error
  def decrypt_secret(%__MODULE__{secret_ciphertext: ct}, dek)
      when is_binary(ct) and is_binary(dek),
      do: Crypto.decrypt(ct, dek)

  def decrypt_secret(_, _), do: :error

  @doc """
  A fresh signing secret.

  32 random bytes, base64url without padding, prefixed so it is greppable in
  a receiver's config and recognisable in a support thread.
  """
  @spec generate_secret() :: String.t()
  def generate_secret do
    "whsec_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end
end
