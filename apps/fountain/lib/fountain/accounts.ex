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
  Whether `email` may create an account on this instance.

  Registration was open to the world with no way to close it: a self-hoster
  exposing an instance had no control over who signed up, and on the hosted side
  every signup consumes the platform Sprites token.

  Checked in the context rather than the controller because there are three
  ways to create an account — the HTML form, the JSON endpoint, and an OAuth
  callback for an unrecognised identity. A control that only covers the form is
  not a control.
  """
  @spec registration_allowed?(String.t() | nil) :: :ok | {:error, atom()}
  def registration_allowed?(email) do
    cond do
      not Application.get_env(:fountain, :registration_enabled, true) ->
        {:error, :registration_closed}

      not domain_allowed?(email) ->
        {:error, :email_domain_not_allowed}

      true ->
        :ok
    end
  end

  defp domain_allowed?(email) do
    case Application.get_env(:fountain, :registration_allowed_email_domains, []) do
      [] ->
        true

      domains ->
        case String.split(to_string(email), "@") do
          [_, domain] -> String.downcase(domain) in domains
          _ -> false
        end
    end
  end

  @doc """
  Register a new user with email + password.

  Also creates a `UserDataKey` row in the same transaction, wrapping a freshly
  generated DEK with the platform master key.

  Returns `{:ok, user}`, `{:error, changeset}`, or `{:error, reason}` when
  registration is closed or the email domain is not allowed.
  """
  @spec register_user(map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t() | atom()}
  def register_user(attrs) do
    email = attrs["email"] || attrs[:email]

    with :ok <- registration_allowed?(email) do
      do_register_user(attrs)
    end
  end

  defp do_register_user(attrs) do
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
  # The error can also be a registration_allowed?/1 atom: a brand-new OAuth
  # identity on a closed instance rolls the transaction back with it. The spec
  # used to omit the atoms, which made dialyzer condemn the controller branch
  # that handles them as unreachable — it is not.
  @spec upsert_oauth_user(String.t(), String.t(), map()) ::
          {:ok, User.t(), :new | :existing}
          | {:error, Ecto.Changeset.t() | :registration_closed | :email_domain_not_allowed}
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
              # Brand-new user from OAuth — a registration like any other, and
              # the path most likely to be forgotten by a controller-level gate.
              case registration_allowed?(email) do
                :ok -> :ok
                {:error, reason} -> Repo.rollback(reason)
              end

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
  @spec create_api_key(binary(), String.t(), keyword()) ::
          {:ok, {ApiKey.t(), String.t()}} | {:error, Ecto.Changeset.t()}
  def create_api_key(user_id, name, opts \\ []) when is_binary(user_id) and is_binary(name) do
    raw = "ftn_" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    key_hash = hash_key(raw)
    key_prefix = String.slice(raw, 0, 8)

    %ApiKey{}
    |> ApiKey.changeset(%{
      user_id: user_id,
      name: name,
      key_hash: key_hash,
      key_prefix: key_prefix,
      scopes: Keyword.get(opts, :scopes, ["full"]),
      expires_at: Keyword.get(opts, :expires_at)
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
          {:ok, User.t()} | {:error, :revoked | :expired | :not_found}
  def get_user_by_api_key(raw_key) when is_binary(raw_key) do
    case authenticate_api_key(raw_key) do
      {:ok, user, _key} -> {:ok, user}
      {:error, _} = err -> err
    end
  end

  @doc """
  Authenticate a raw API key and return the key record alongside the user.

  The auth plug needs the record, not just the user: scope is carried on the key,
  so a caller holding a sandbox token is otherwise indistinguishable from the
  human who owns the tenant.

  Returns `{:ok, user, api_key}`, or `{:error, :revoked | :expired | :not_found}`.
  """
  @spec authenticate_api_key(String.t()) ::
          {:ok, User.t(), ApiKey.t()} | {:error, :revoked | :expired | :not_found}
  def authenticate_api_key(raw_key) when is_binary(raw_key) do
    key_hash = hash_key(raw_key)

    query =
      from k in ApiKey,
        where: k.key_hash == ^key_hash,
        join: u in assoc(k, :user),
        preload: [user: u]

    case Repo.one(query) do
      nil ->
        {:error, :not_found}

      %ApiKey{revoked_at: revoked} when not is_nil(revoked) ->
        {:error, :revoked}

      %ApiKey{} = key ->
        if ApiKey.expired?(key), do: {:error, :expired}, else: {:ok, key.user, key}
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
    |> put_trial_end()
    |> Repo.insert()
  end

  defp insert_user(attrs, :oauth) do
    %User{}
    |> User.oauth_registration_changeset(attrs)
    |> put_trial_end()
    |> Repo.insert()
  end

  # Every account gets a trial deadline the moment it exists, before Stripe is
  # involved at all.
  #
  # The trial is really driven by a Stripe subscription, and the gate reads
  # `trial_ends_at`, treating nil as "no expiry". If the date were only written
  # when Stripe was successfully reached, an account whose customer or
  # subscription call failed would sit at nil and be free forever — which is
  # exactly how 159 production accounts got there. Stripe's `trial_end`
  # overwrites this with the authoritative value as soon as the subscription
  # exists; until then the local date is a floor, not a guess nobody checks.
  defp put_trial_end(changeset) do
    Ecto.Changeset.put_change(changeset, :trial_ends_at, Fountain.Billing.trial_end_from_now())
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

  @sortable_columns %{
    "email" => :email,
    "joined" => :inserted_at,
    "trial_end" => :trial_ends_at,
    "last_activity" => :last_activity
  }

  @doc """
  Filtered, sorted, paginated user listing for the admin panel.

  Options:

  - `:search` — case-insensitive email substring
  - `:status` — exact `subscription_status`
  - `:role` — `"admin"` or `"user"`
  - `:verified` — `true`/`false` (whether `email_verified_at` is set)
  - `:sort` — `"email"`, `"joined"`, `"trial_end"`, or `"last_activity"`
    (unknown values fall back to `"joined"`)
  - `:dir` — `"asc"` or `"desc"` (default `"desc"`)
  - `:page` / `:per_page` — 1-based offset pagination

  Returns `%{users: users, total: filtered_count}`. Each user carries a
  `:last_activity_at` key (latest usage event, `nil` if none) — sorting by it
  needs the join anyway, so every caller gets the value for free.
  """
  @spec list_users_admin(keyword()) :: %{users: [User.t()], total: non_neg_integer()}
  def list_users_admin(opts \\ []) do
    page = opts |> Keyword.get(:page, 1) |> max(1)
    per_page = Keyword.get(opts, :per_page, 25)

    base = filter_users(opts)
    total = Repo.aggregate(base, :count)

    users =
      base
      |> join(:left, [u], a in subquery(last_activity_query()), on: a.user_id == u.id, as: :activity)
      |> order_users(Keyword.get(opts, :sort), Keyword.get(opts, :dir, "desc"))
      |> offset(^((page - 1) * per_page))
      |> limit(^per_page)
      |> select([u, activity: a], {u, a.last_at})
      |> Repo.all()
      |> Enum.map(fn {user, last_at} -> Map.put(user, :last_activity_at, last_at) end)

    %{users: users, total: total}
  end

  defp filter_users(opts) do
    Enum.reduce(opts, from(u in User), fn
      {:search, term}, q when is_binary(term) and term != "" ->
        where(q, [u], ilike(u.email, ^"%#{sanitize_like(term)}%"))

      {:status, status}, q when is_binary(status) and status != "" ->
        where(q, [u], u.subscription_status == ^status)

      {:role, role}, q when role in ~w(admin user) ->
        where(q, [u], u.role == ^role)

      {:verified, true}, q ->
        where(q, [u], not is_nil(u.email_verified_at))

      {:verified, false}, q ->
        where(q, [u], is_nil(u.email_verified_at))

      _, q ->
        q
    end)
  end

  defp last_activity_query do
    from(e in Fountain.Billing.UsageEvent,
      group_by: e.user_id,
      select: %{user_id: e.user_id, last_at: max(e.inserted_at)}
    )
  end

  defp order_users(query, sort, dir) do
    dir = if dir == "asc", do: :asc, else: :desc

    case Map.get(@sortable_columns, sort, :inserted_at) do
      :last_activity ->
        # nulls always sink so never-active accounts don't bury the signal
        dir = if dir == :asc, do: :asc_nulls_last, else: :desc_nulls_last
        order_by(query, [u, activity: a], [{^dir, a.last_at}, {:asc, u.id}])

      column ->
        order_by(query, [u], [{^dir, field(u, ^column)}, {:asc, u.id}])
    end
  end

  defp sanitize_like(term) do
    String.replace(term, ~r/[\\%_]/, fn ch -> "\\" <> ch end)
  end

  @doc "Update a user's role. Role must be 'admin' or 'user'."
  def update_user_role(%User{} = user, role) when role in ~w(admin user) do
    user |> Ecto.Changeset.change(role: role) |> Repo.update()
  end

  @doc """
  Set a user's concurrent-sandbox cap (ADR 0005). Admin-only.

  Without this the cap is only adjustable with direct database access, which
  makes it unusable in the two situations it exists for: raising it for a
  trusted tenant, and dropping it to zero during abuse.
  """
  def update_sandbox_limit(%User{} = user, limit) do
    user
    |> User.sandbox_limit_changeset(%{max_concurrent_sandboxes: limit})
    |> Repo.update()
  end

  @doc false
  def hash_key(raw_key) when is_binary(raw_key) do
    :crypto.hash(:sha256, raw_key) |> Base.encode16(case: :lower)
  end
end
