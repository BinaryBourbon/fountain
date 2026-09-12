defmodule Fountain.PlatformChatGPT.Account do
  @moduledoc """
  The deployment's ChatGPT grant for the codex runtime (ADR 0047): one row
  whose `user_id` is nil. The refresh token and the access token are
  encrypted under the master key (`Fountain.Crypto.encrypt_platform/1`);
  `id_claims` holds the non-secret claims codex reads back from its
  `id_token`, and nothing else from it.

  `kind` says what the row holds: `"chatgpt"` is a ChatGPT sign-in with a
  rotating refresh token that `Fountain.PlatformChatGPT` owns;
  `"workspace_token"` is a static Business/Enterprise access token with no
  refresh token, which lapses on its admin-set expiry.

  Reconnect changes `generation`. Normal refresh retains the generation and
  increments `lock_version`, as do terminal lifecycle writes. These fields
  fence stale writes; broker authorization is not yet generation-aware.

  There is no plaintext column and no `_unsafe_` reader: the deployment owns
  this, not a tenant, and the only writers are the admin surface and the
  refresher.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(chatgpt workspace_token)
  @statuses ~w(active revoked expired)

  @type t :: %__MODULE__{}
  schema "platform_chatgpt_account" do
    field :user_id, :binary_id
    field :generation, Ecto.UUID, autogenerate: true
    field :lock_version, :integer, default: 1
    field :kind, :string
    field :refresh_token_ciphertext, :binary
    field :access_token_ciphertext, :binary
    field :id_claims, :map, default: %{}
    field :account_id, :string
    field :account_email, :string
    field :plan_type, :string
    field :access_expires_at, :utc_datetime
    field :last_refreshed_at, :utc_datetime
    field :status, :string, default: "active"
    field :revoked_reason, :string

    belongs_to :updated_by, Fountain.Accounts.User, foreign_key: :updated_by_user_id

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  @doc "A fresh grant, or a reconnect over an existing row."
  def connect_changeset(account, attrs) do
    account
    |> cast(attrs, [
      :kind,
      :refresh_token_ciphertext,
      :access_token_ciphertext,
      :id_claims,
      :account_id,
      :account_email,
      :plan_type,
      :access_expires_at,
      :last_refreshed_at,
      :updated_by_user_id
    ])
    |> put_change(:status, "active")
    |> put_change(:revoked_reason, nil)
    |> put_change(:generation, Ecto.UUID.generate())
    |> version_existing()
    |> validate_required([:kind, :access_token_ciphertext, :last_refreshed_at])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint(:user_id, name: :platform_chatgpt_account_platform_row)
  end

  @doc "A refresh rotated the tokens; the claims are updated when the response carried an id_token."
  def refresh_changeset(account, attrs) do
    account
    |> cast(attrs, [
      :refresh_token_ciphertext,
      :access_token_ciphertext,
      :id_claims,
      :account_id,
      :account_email,
      :plan_type,
      :access_expires_at,
      :last_refreshed_at
    ])
    |> validate_required([:access_token_ciphertext, :last_refreshed_at])
  end

  @doc "The auth server refused the refresh token; the reason is its error code."
  def revoke_changeset(account, reason) when is_binary(reason) do
    account
    |> change(status: "revoked", revoked_reason: reason)
    |> validate_inclusion(:status, @statuses)
  end

  @doc "A token with no refresh token lapsed."
  def expire_changeset(account) do
    account
    |> change(status: "expired")
    |> validate_inclusion(:status, @statuses)
  end

  defp version_existing(%{data: %{__meta__: %{state: :loaded}}} = changeset),
    do: optimistic_lock(changeset, :lock_version)

  defp version_existing(changeset), do: changeset
end
