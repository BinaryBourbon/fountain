defmodule Fountain.Accounts do
  @moduledoc """
  Context for user accounts, API keys, per-tenant encryption keys, and OAuth identities.

  Does NOT own auth plugs, sessions, or LiveView hooks — those live in FountainWeb.

  ## Key functions

  - `register_user/1` — email+password registration; also creates a UserDataKey
  - `get_user_by_email/1` — lookup for login
  - `create_api_key/2` — issue a new API key (returns the plaintext once)
  - `revoke_api_key/2` — permanently invalidate a key
  - `get_user_by_api_key/1` — authenticate a raw API key string
  """

  import Ecto.Query
  alias Fountain.Repo
  alias Fountain.Accounts.{User, ApiKey, UserDataKey, OauthIdentity}
  alias Fountain.Crypto

  ## Users

  @doc """
  Look up a user by (downcased) email. Returns `nil` if not found.
  """
  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: String.downcase(email))
  end

  @doc """
  Register a new user with email + password.

  Also creates a `UserDataKey` row in the same transaction, wrapping a freshly
  generated DEK with the platform master key.

  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  @spec register_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def register_user(attrs) do
    Repo.transaction(fn ->
      with {:ok, user} <- insert_user(attrs),
           {:ok, _udk} <- create_user_data_key(user.id) do
        user
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp insert_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  defp create_user_data_key(user_id) do
    dek = Crypto.generate_dek()
    wrapped = Crypto.wrap_dek(dek)

    %UserDataKey{}
    |> UserDataKey.changeset(%{user_id: user_id, wrapped_key: wrapped})
    |> Repo.insert()
  end

  ## API keys

  @doc """
  Generate and persist a new API key for `user_id` with the given human-readable `name`.

  The raw key is `"ftn_" <> 64 hex chars`. It is returned once and never stored.
  Only the SHA-256 hash and the first 8-character prefix are persisted.

  Returns `{:ok, {%ApiKey{}, raw_key_string}}` or `{:error, changeset}`.
  """
  @spec create_api_key(binary(), String.t()) ::
          {:ok, {ApiKey.t(), String.t()}} | {:error, Ecto.Changeset.t()}
  def create_api_key(user_id, name) when is_binary(user_id) and is_binary(name) do
    raw = "ftn_" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    key_hash = hash_key(raw)
    key_prefix = String.slice(raw, 0, 8)

    %ApiKey{}
    |> ApiKey.changeset(%{
      user_id: user_id,
      name: name,
      key_hash: key_hash,
      key_prefix: key_prefix
    })
    |> Repo.insert()
    |> case do
      {:ok, key} -> {:ok, {key, raw}}
      {:error, cs} -> {:error, cs}
    end
  end

  @doc """
  Revoke an API key by setting `revoked_at` to now. Only the owning user's key is revoked
  (pass `user_id` to prevent one user revoking another's key; admins have a separate path).

  Revocation is permanent — revoked keys cannot be un-revoked.

  Returns `{:ok, api_key}` or `{:error, :not_found}`.
  """
  @spec revoke_api_key(binary(), binary()) :: {:ok, ApiKey.t()} | {:error, :not_found}
  def revoke_api_key(user_id, key_id) when is_binary(user_id) and is_binary(key_id) do
    case Repo.get_by(ApiKey, id: key_id, user_id: user_id) do
      nil ->
        {:error, :not_found}

      key ->
        key
        |> Ecto.Changeset.change(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))
        |> Repo.update()
    end
  end

  @doc """
  Authenticate a raw API key string.

  Hashes the raw key with SHA-256, queries `api_keys` for an active (non-revoked) match,
  and returns the associated user.

  Returns `{:ok, user}` or `{:error, :invalid}`. Revoked keys always return `:invalid`.
  """
  @spec get_user_by_api_key(String.t()) :: {:ok, User.t()} | {:error, :invalid}
  def get_user_by_api_key(raw_key) when is_binary(raw_key) do
    key_hash = hash_key(raw_key)

    query =
      from k in ApiKey,
        where: k.key_hash == ^key_hash and is_nil(k.revoked_at),
        join: u in assoc(k, :user),
        preload: [user: u]

    case Repo.one(query) do
      nil -> {:error, :invalid}
      key -> {:ok, key.user}
    end
  end

  ## Internal helpers

  @doc false
  def hash_key(raw_key) when is_binary(raw_key) do
    :crypto.hash(:sha256, raw_key) |> Base.encode16(case: :lower)
  end
end
