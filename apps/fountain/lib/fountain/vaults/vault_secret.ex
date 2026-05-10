defmodule Fountain.Vaults.VaultSecret do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Crypto
  alias Fountain.Vaults.Vault

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "vault_secrets" do
    field :key, :string
    field :value_ciphertext, :binary
    field :value, :string, virtual: true, redact: true
    belongs_to :vault, Vault
    timestamps(type: :utc_datetime)
  end

  def changeset(secret, attrs) do
    secret
    |> cast(attrs, [:key, :value, :vault_id])
    |> validate_required([:key, :value, :vault_id])
    |> validate_format(:key, ~r/^[A-Z][A-Z0-9_]*$/, message: "must be UPPER_SNAKE_CASE")
    |> validate_length(:key, min: 1, max: 200)
    |> put_ciphertext()
    |> unique_constraint([:vault_id, :key])
  end

  defp put_ciphertext(changeset) do
    case get_change(changeset, :value) do
      nil -> changeset
      value -> put_change(changeset, :value_ciphertext, Crypto.encrypt(value))
    end
  end

  @doc "Decrypt the value. Returns `{:ok, plaintext}` or `:error`."
  def decrypt(%__MODULE__{value_ciphertext: ct}) when is_binary(ct), do: Crypto.decrypt(ct)
  def decrypt(_), do: :error
end
