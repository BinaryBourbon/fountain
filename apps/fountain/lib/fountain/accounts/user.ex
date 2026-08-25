defmodule Fountain.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles ~w(user admin)
  # "comped" is operator-granted free access, set only from the admin panel.
  # It is deliberately distinct from a nil trial_ends_at (the legacy accident
  # expire_legacy_trials cleans up) so a comp can never be swept by a backfill,
  # and Billing.sync_subscription refuses to overwrite it from webhooks.
  @subscription_statuses ~w(trialing active past_due canceled comped)
  @theme_values ~w(light dark system)
  @visible_stream_values ~w(stdout stderr stage)
  @view_mode_values ~w(chat pretty raw)

  @type t :: %__MODULE__{}
  schema "users" do
    field :email, :string
    field :password_hash, :string
    field :password, :string, virtual: true, redact: true
    field :email_verified_at, :utc_datetime
    field :onboarding_completed_at, :utc_datetime
    field :onboarding_state, :string, default: "step_1"
    # Per-user override of the plan's concurrent-sandbox cap; null means "the
    # plan's". The Postgres column is still `max_concurrent_sandboxes` — it
    # predates plans and renaming it would break a rolling deploy — so the
    # honest name lives here and the migration explains the split.
    field :sandbox_limit_override, :integer, source: :max_concurrent_sandboxes
    # `Fountain.Plans` slug. Null means this deployment's `DEFAULT_PLAN`,
    # which is how a self-hosted instance runs with no plan concept at all.
    # Written from the Stripe price on the subscription, never guessed.
    field :plan, :string
    # Teammate contacts this account is not charged for. Distinct from a
    # `comped` subscription_status, which makes everything free: this is the
    # tenant who pays for their tier and holds a number Fountain eats.
    # Cached sum of `credit_ledger` (ADR 0030). Written only by
    # `Fountain.Credits`, in the same transaction as the ledger row; never
    # cast from user input.
    field :credit_balance_cents, :integer, default: 0
    field :role, :string, default: "user"
    field :stripe_customer_id, :string
    # The subscription of record. Webhook sync applies events for this
    # subscription only — a customer can briefly carry two (mid-trial upgrade),
    # and customer-keyed sync let the doomed one write the account's status.
    field :stripe_subscription_id, :string
    field :subscription_status, :string, default: "trialing"
    field :trial_ends_at, :utc_datetime
    field :suspended_at, :utc_datetime
    # Stripe `created` of the last subscription event applied — the ordering
    # guard's watermark. See Billing.sync_subscription/1.
    field :subscription_synced_at, :utc_datetime
    # A portal cancellation leaves the subscription "active" with this flag set;
    # access continues until current_period_end, when `.deleted` fires. Synced
    # from subscription webhooks so the UI can say "access until <date>".
    field :cancel_at_period_end, :boolean, default: false
    # The invoiced period, both ends of it, synced from the Stripe
    # subscription. `current_period_start` is what makes an allowance
    # measurable over the window the customer is actually charged for rather
    # than over a calendar month that drifts out of step with every renewal.
    # Null on a trialing account Stripe has not reported a period for, on a
    # comped account, and on a self-hosted deployment with no Stripe —
    # `Fountain.Billing.billing_period/2` handles all three.
    field :current_period_start, :utc_datetime
    field :current_period_end, :utc_datetime
    field :session_version, :integer, default: 0
    field :theme_preference, :string, default: "system"
    field :conversations_roots_only, :boolean, default: false
    field :conversation_visible_streams, {:array, :string}, default: ["stdout", "stderr", "stage"]
    field :conversation_view_mode, :string, default: "pretty"

    has_many :api_keys, Fountain.Accounts.ApiKey
    has_one :data_key, Fountain.Accounts.UserDataKey
    has_many :oauth_identities, Fountain.Accounts.OauthIdentity

    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles
  def subscription_statuses, do: @subscription_statuses

  @doc "Changeset for new user registration (email + password path)."
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password, :role, :sandbox_limit_override])
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
    |> cast(attrs, [:email, :role, :sandbox_limit_override, :email_verified_at])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email address"
    )
    |> validate_inclusion(:role, @roles)
    |> update_change(:email, &String.downcase/1)
    |> unique_constraint(:email)
  end

  @doc """
  Changeset for the per-tenant sandbox concurrency override (ADR 0005).

  Admin-only. Zero is valid and meaningful — it is the lever for cutting off an
  abusive tenant without deleting their account. `nil` is valid too and means
  something different: clear the override and let the plan decide again.
  """
  def sandbox_limit_changeset(user, attrs) do
    user
    |> cast(attrs, [:sandbox_limit_override])
    |> validate_number(:sandbox_limit_override, greater_than_or_equal_to: 0)
  end

  @doc """
  Changeset for the plan slug. Driven by the Stripe price on the
  subscription (`Fountain.Billing.sync_subscription/1`) or set by an admin.
  """
  def plan_changeset(user, attrs) do
    user
    |> cast(attrs, [:plan])
    |> validate_inclusion(:plan, Fountain.Plans.slugs())
  end

  @doc "Changeset for billing field updates (driven by Stripe webhooks)."
  def billing_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :stripe_customer_id,
      :stripe_subscription_id,
      :subscription_status,
      :trial_ends_at,
      :subscription_synced_at,
      :cancel_at_period_end,
      :current_period_start,
      :current_period_end,
      # Only ever put here when the price on the subscription mapped to a
      # known plan. An unrecognised price leaves the key out entirely rather
      # than nulling a tenant's entitlement from a half-configured replica.
      :plan
    ])
    |> validate_inclusion(:subscription_status, @subscription_statuses)
    |> validate_inclusion(:plan, Fountain.Plans.slugs())
    |> unique_constraint(:stripe_customer_id)
  end

  @doc "Changeset for updating theme preference (light | dark | system)."
  def theme_changeset(user, attrs) do
    user
    |> cast(attrs, [:theme_preference])
    |> validate_inclusion(:theme_preference, @theme_values)
  end

  @doc "Changeset for updating conversation filter preferences."
  def preferences_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :conversations_roots_only,
      :conversation_visible_streams,
      :conversation_view_mode
    ])
    |> validate_subset(:conversation_visible_streams, @visible_stream_values)
    |> validate_inclusion(:conversation_view_mode, @view_mode_values)
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
