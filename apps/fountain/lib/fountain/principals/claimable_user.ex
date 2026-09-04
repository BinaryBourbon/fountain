defmodule Fountain.Principals.ClaimableUser do
  @moduledoc """
  The provisional grant behind a claimable principal (ADR 0044).

  The principal is the `users` row this points at; this row is everything
  temporary about it — who opened it, when it stops being usable, what it may
  spend, and the hashed one-time capability that claims it.

  ## Statuses

    * `unclaimed` — open, usable by the credential the application holds
    * `claimed`   — an account owns it; `principal_owners` says who
    * `expired`   — `expires_at` passed with nobody claiming it
    * `released`  — the application abandoned it

  There is deliberately no `claiming` state. The claim runs inside one
  transaction under a row lock, so there is no window in which a caller could
  observe a half-claimed principal; the issue's `claiming` would have been a
  status nothing could ever read.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(unclaimed claimed expired released)

  @type t :: %__MODULE__{}
  schema "claimable_users" do
    field :application_id, :string
    field :status, :string, default: "unclaimed"
    field :claim_token_hash, :string, redact: true
    field :expires_at, :utc_datetime
    field :claimed_at, :utc_datetime
    field :expired_at, :utc_datetime
    field :released_at, :utc_datetime
    field :budget_exhausted_at, :utc_datetime
    field :grant_cents, :integer, default: 0
    field :max_live_sandboxes, :integer
    field :create_idempotency_key, :string
    field :claim_idempotency_key, :string
    field :metadata, :map, default: %{}

    belongs_to :user, Fountain.Accounts.User
    belongs_to :application_user, Fountain.Accounts.User
    belongs_to :claimed_by_user, Fountain.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "The closed status list, which the OpenAPI enum is checked against."
  def statuses, do: @statuses

  def changeset(claimable, attrs) do
    claimable
    |> cast(attrs, [
      :user_id,
      :application_user_id,
      :application_id,
      :status,
      :claim_token_hash,
      :expires_at,
      :grant_cents,
      :max_live_sandboxes,
      :create_idempotency_key,
      :metadata
    ])
    |> validate_required([:user_id, :application_user_id, :application_id, :expires_at])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:application_id, min: 1, max: 100)
    |> validate_number(:grant_cents, greater_than_or_equal_to: 0)
    |> validate_number(:max_live_sandboxes, greater_than_or_equal_to: 0)
    |> unique_constraint(:user_id)
    |> unique_constraint([:application_user_id, :create_idempotency_key],
      name: :claimable_users_application_idempotency_index
    )
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:application_user_id)
  end

  @doc """
  Whether this grant is still open for work.

  An `unclaimed` grant stops being usable the moment `expires_at` passes, and
  that has to be answered from the row rather than from `status`: the expirer
  runs on a schedule, so between the deadline and the sweep the status still
  reads `unclaimed` while the principal is, in fact, over.
  """
  @spec usable?(t(), DateTime.t()) :: boolean()
  def usable?(%__MODULE__{} = c, now \\ DateTime.utc_now()) do
    case c.status do
      "claimed" -> true
      "unclaimed" -> DateTime.compare(now, c.expires_at) == :lt
      _ -> false
    end
  end
end
