defmodule Fountain.PlatformInference.Key do
  @moduledoc """
  A platform inference key an operator set from `/admin/inference`: one row
  per provider, the value encrypted under the master key
  (`Fountain.Crypto.encrypt_platform/1`).

  `Fountain.PlatformInference.key_for/1` reads this before the
  `PLATFORM_<PROVIDER>_API_KEY` variable, so a row here is the live key and
  the variable is the seed. There is no plaintext column and no `_unsafe_`
  reader: the deployment owns these, not a tenant, and the only writer is
  the admin surface.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:provider, :string, autogenerate: false}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}
  schema "platform_inference_keys" do
    field :ciphertext, :binary

    belongs_to :updated_by, Fountain.Accounts.User, foreign_key: :updated_by_user_id

    timestamps(type: :utc_datetime)
  end

  def changeset(key, attrs, providers) do
    key
    |> cast(attrs, [:provider, :ciphertext, :updated_by_user_id])
    |> validate_required([:provider, :ciphertext])
    |> validate_inclusion(:provider, providers)
  end
end
