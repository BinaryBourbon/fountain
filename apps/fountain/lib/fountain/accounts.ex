defmodule Fountain.Accounts do
  @moduledoc """
  Context for user accounts, API keys, per-tenant encryption keys, and OAuth identities.

  Does NOT own auth plugs, sessions, or LiveView hooks — those live in FountainWeb.

  ## Key functions

  - `register_user/1` — email+password registration; also creates a UserDataKey
  - `authenticate_user/2` — verify email + password for login
  - `get_user_by_email/1` — lookup by email
  - `get_user/1` / `get_user!/1` — lookup by id
  - `verify_email/1` — set email_verified_at on the user
  - `reset_password/2` — update password hash + bump session_version
  - `create_api_key/2` — issue a new API key (returns the plaintext once)
  - `revoke_api_key/2` — permanently invalidate a key
  - `get_user_by_api_key/1` — authenticate a raw API key string
  - `touch_api_key/1` — update last_used_at (called async after auth)
  - `upsert_oauth_user/3` — find-or-create user from OAuth callback
  """

  import Ecto.Query
  alias Fountain.Repo
  alias Fountain.Accounts.{User, ApiKey, UserDataKey, OauthIdentity}
  alias Fountain.Crypto

  ## Users

  @doc "Look up a user by (downcased) email. Returns `nil` if not found."
  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: String.downcase(email))
  end

  @doc "Load a user by id. Returns `nil` if not found."
  @spec get_user(binary()) :: User.t() | nil
  def get_user(id) when is_binary(id), do: Repo.get(User, id)

  @doc "Load a user by id. Raises `Ecto.NoResultsError` if not found."
  @spec get_user!(binary()) :: User.t()
  def get_user!(id) when is_binary(id), do: Repo.get!(User, id)

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

  @doc """
  Verify a user's email address by setting `email_verified_at` to now.

  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  @spec verify_email(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def verify_email(%User{} = user) do
    user
    |> Ecto.Changeset.change(email_verified_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
  end

  @doc """
  Authenticate a user by email and password.

  Returns `{:ok, user}` on success, or one of:
  - `{:error, :not_found}` — no user with that email
  - `{:error, :wrong_password}` — user exists but password doesn't match
  """
  @spec authenticate_user(String.t(), String.t()) ::
          {:ok, User.t()} | {:error, :not_found | :wrong_password}
  def authenticate_user(email, password)
      when is_binary(email) and is_binary(password) do
    user = get_user_by_email(email)

    if user do
      if Bcrypt.verify_pass(password, user.password_hash) do
        {:ok, user}
      else
        {:error, :wrong_password}
      end
    else
      # Constant-time dummy verify to prevent timing-based enumeration
      Bcrypt.no_user_verify()
      {:error, :not_found}
    end
  end

  @doc """
  Reset a user's password.

  Updates `password_hash` and bumps `session_version` to invalidate all
  existing sessions.

  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  @spec reset_password(User.t(), String.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def reset_password(%User{} = user, new_password) when is_binary(new_password) do
    user
    |> User.password_reset_changeset(%{password: new_password})
    |> User.invalidate_sessions_changeset()
    |> Repo.update()
  end

  @doc """
  Mark onboarding as completed by setting `onboarding_completed_at` to now.
  """
  @spec complete_onboarding(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def complete_onboarding(%User{} = user) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    user
    |> Ecto.Changeset.change(
      onboarding_completed_at: now,
      onboarding_state: "completed"
    )
    |> Repo.update()
  end

  @doc """
  Advance the onboarding wizard to the given state.
  Valid states: "step_1", "step_2", "step_3", "step_4", "completed"

  When state is "completed", also sets `onboarding_completed_at`.
  """
  @spec advance_onboarding(User.t(), String.t()) ::
          {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def advance_onboarding(%User{} = user, state)
      when state in ~w(step_1 step_2 step_3 step_4 completed) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    changes =
      if state == "completed" do
        %{onboarding_state: state, onboarding_completed_at: now}
      else
        %{onboarding_state: state}
      end

    user
    |> Ecto.Changeset.change(changes)
    |> Repo.update()
  end

  @doc """
  Update conversation filter preferences for the user.

  Accepts a subset of: `conversations_roots_only` (boolean) and
  `conversation_visible_streams` (list of "stdout", "stderr", "stage").

  Returns `{:ok, user}` or `{:error, changeset}`.
  """
  @spec update_preferences(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_preferences(%User{} = user, attrs) do
    user
    |> User.preferences_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Find or create a user from an OAuth provider callback.

  Looks up by `(provider, provider_uid)` first; falls back to email lookup
  to link an existing account. Creates a new user if neither matches.

  For new users: skips email verification (provider-verified email is trusted),
  creates a `UserDataKey`, and creates an `OauthIdentity` row.

  For existing users: upserts the `OauthIdentity` row (safe to call on
  every login).

  Returns `{:ok, user, :new | :existing}` or `{:error, changeset}`.
  """
  @spec upsert_oauth_user(String.t(), String.t(), map()) ::
          {:ok, User.t(), :new | :existing} | {:error, Ecto.Changeset.t()}
  def upsert_oauth_user(provider, provider_uid, attrs)
      when is_binary(provider) and is_binary(provider_uid) do
    Repo.transaction(fn ->
      existing_identity =
        Repo.get_by(OauthIdentity, provider: provider, provider_uid: provider_uid)

      case existing_identity do
        %OauthIdentity{user_id: user_id} ->
          user = Repo.get!(User, user_id)
          {:ok, user, :existing}

        nil ->
          email = String.downcase(attrs[:email] || attrs["email"] || "")

          case Repo.get_by(User, email: email) do
            %User{} = user ->
              # Link the existing account to this OAuth identity
              with {:ok, _} <- insert_oauth_identity(user.id, provider, provider_uid) do
                {:ok, user, :existing}
              else
                {:error, cs} -> Repo.rollback(cs)
              end

            nil ->
              # Brand-new user from OAuth
              verified_at = DateTime.utc_now() |> DateTime.truncate(:second)

              with {:ok, user} <-
                     insert_user(
                       Map.merge(attrs, %{
                         "email" => email,
                         "email_verified_at" => verified_at
                       }),
                       :oauth
                     ),
                   {:ok, _udk} <- create_user_data_key(user.id),
                   {:ok, _} <- insert_oauth_identity(user.id, provider, provider_uid) do
                {:ok, user, :new}
              else
                {:error, cs} -> Repo.rollback(cs)
              end
          end
      end
    end)
    |> case do
      {:ok, {:ok, user, status}} -> {:ok, user, status}
      {:ok, result} -> result
      {:error, _} = err -> err
    end
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

  Hashes the raw key with SHA-256, queries `api_keys` for a matching row, and
  returns the associated user when the key is active.

  Returns `{:ok, user}` for an active match, `{:error, :revoked}` when the hash
  matches a row whose `revoked_at` is set, and `{:error, :not_found}` when no
  row matches. Callers (e.g. the auth plug) can distinguish these to give
  legitimate clients holding a stale token a more useful error than a generic
  401.
  """
  @spec get_user_by_api_key(String.t()) ::
          {:ok, User.t()} | {:error, :revoked | :not_found}
  def get_user_by_api_key(raw_key) when is_binary(raw_key) do
    key_hash = hash_key(raw_key)

    query =
      from k in ApiKey,
        where: k.key_hash == ^key_hash,
        join: u in assoc(k, :user),
        preload: [user: u]

    case Repo.one(query) do
      nil -> {:error, :not_found}
      %ApiKey{revoked_at: nil} = key -> {:ok, key.user}
      %ApiKey{} -> {:error, :revoked}
    end
  end

  @doc """
  Update `last_used_at` for the API key matching `raw_key`. Intended to be called
  asynchronously (via `Task.async`) so it does not block the request.
  """
  @spec touch_api_key(String.t()) :: :ok
  def touch_api_key(raw_key) when is_binary(raw_key) do
    key_hash = hash_key(raw_key)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(k in ApiKey, where: k.key_hash == ^key_hash)
    |> Repo.update_all(set: [last_used_at: now])

    :ok
  end

  ## Internal helpers

  defp insert_user(attrs, kind \\ :password)

  defp insert_user(attrs, :password) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  defp insert_user(attrs, :oauth) do
    %User{}
    |> User.oauth_registration_changeset(attrs)
    |> Repo.insert()
  end

  defp create_user_data_key(user_id) do
    dek = Crypto.generate_dek()
    wrapped = Crypto.wrap_dek(dek)

    %UserDataKey{}
    |> UserDataKey.changeset(%{user_id: user_id, wrapped_key: wrapped})
    |> Repo.insert()
  end

  defp insert_oauth_identity(user_id, provider, provider_uid) do
    %OauthIdentity{}
    |> OauthIdentity.changeset(%{
      user_id: user_id,
      provider: provider,
      provider_uid: provider_uid
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:provider, :provider_uid])
  end

  @doc "List all active (non-revoked) API keys for a user, newest first."
  def list_api_keys(user_id) when is_binary(user_id) do
    from(k in ApiKey,
      where: k.user_id == ^user_id and is_nil(k.revoked_at),
      order_by: [desc: k.inserted_at]
    )
    |> Repo.all()
  end

  @doc "List all users, ordered by insertion date."
  def list_users do
    from(u in User, order_by: [asc: u.inserted_at]) |> Repo.all()
  end

  @doc "Update a user's role. Role must be 'admin' or 'user'."
  def update_user_role(%User{} = user, role) when role in ~w(admin user) do
    user |> Ecto.Changeset.change(role: role) |> Repo.update()
  end

  @doc false
  def hash_key(raw_key) when is_binary(raw_key) do
    :crypto.hash(:sha256, raw_key) |> Base.encode16(case: :lower)
  end
end
