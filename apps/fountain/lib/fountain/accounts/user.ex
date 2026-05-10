defmodule Fountain.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles ~w(user admin)
  @subscription_statuses ~w(trialing active past_due canceled)
  @theme_values ~w(light dark system)

  schema "users" do
    field :email, :string
    field :password_hash, :string
    field :password, :string, virtual: true, redact: true
    field :email_verified_at, :utc_datetime
    field :onboarding_completed_at, :utc_datetime
    field :onboarding_state, :string, default: "step_1"
    field :max_concurrent_sandboxes, :integer, default: 5
    field :role, :string, default: "user"
    field :stripe_customer_id, :string
    field :subscription_status, :string, default: "trialing"
    field :trial_ends_at, :utc_datetime
    field :session_version, :integer, default: 0
    field :theme_preference, :string, default: "system"

    has_many :api_keys, Fountain.Accounts.ApiKey
    has_one :data_key, Fountain.Accounts.UserDataKey
    has_many :oauth_identities, Fountain.Accounts.OauthIdentity

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for new user registration (email + password path)."
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password, :role, :max_concurrent_sandboxes])
    |> validate_required([:email, :password])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address"
    )
    |> validate_length(:password, min: 8, message: "must be at least 8 characters")
    |> validate_inclusion(:role, @roles)
    |> update_change(:email, &String.downcase/1)
    |> unique_constraint(:email)
    |> hash_password()
  end

  @doc "Changeset for OAuth registration (no password required; email pre-verified by provider)."
  def oauth_registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :role, :max_concurrent_sandboxes, :email_verified_at])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address"
    )
    |> validate_inclusion(:role, @roles)
    |> update_change(:email, &String.downcase/1)
    |> unique_constraint(:email)
  end

  @doc "Changeset for billing field updates (driven by Stripe webhooks)."
  def billing_changeset(user, attrs) do
    user
    |> cast(attrs, [:stripe_customer_id, :subscription_status, :trial_ends_at])
    |> validate_inclusion(:subscription_status, @subscription_statuses)
  end

  @doc "Changeset for updating theme preference (light | dark | system)."
  def theme_changeset(user, attrs) do
    user
    |> cast(attrs, [:theme_preference])
    |> validate_inclusion(:theme_preference, @theme_values)
  end

  @doc "Changeset for resetting a password (validates + hashes new password)."
  def password_reset_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 8, message: "must be at least 8 characters")
    |> hash_password()
  end

  @doc "Changeset for bumping session_version (e.g. on password reset). Accepts a User struct or an existing changeset."
  def invalidate_sessions_changeset(%Ecto.Changeset{data: %__MODULE__{} = user} = changeset) do
    put_change(changeset, :session_version, (user.session_version || 0) + 1)
  end

  def invalidate_sessions_changeset(%__MODULE__{} = user) do
    user
    |> change()
    |> put_change(:session_version, (user.session_version || 0) + 1)
  end

  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      password ->
        changeset
        |> put_change(:password_hash, Bcrypt.hash_pwd_salt(password))
        |> delete_change(:password)
    end
  end
end
