defmodule Fountain.Repo.Migrations.CreateClaimablePrincipals do
  use Ecto.Migration

  @moduledoc """
  Claimable principals (ADR 0044, #1551).

  A principal is a `users` row, so the only column users gains is the flag that
  says so. Everything provisional about it — who opened it, when it expires,
  what it may spend, the hashed claim token — lives in `claimable_users`, and
  who ended up owning it lives in `principal_owners`.
  """

  def up do
    # `principal: true` is read on the API auth path (an identity-less row has
    # no verified email and must still authenticate) and by the unverified
    # account pruner (which must not delete one). Both want the answer without
    # a join, hence a column here rather than an EXISTS against claimable_users.
    alter table(:users) do
      add :principal, :boolean, null: false, default: false
    end

    # A principal has no identity and never will, so `email` stops being
    # mandatory at the database level. The application-level guard is unchanged
    # and is where it belongs: every registration changeset still
    # `validate_required([:email])`, and `User.principal_changeset/2` is the
    # only one that does not cast an email at all.
    alter table(:users) do
      modify :email, :string, null: true, from: {:string, null: false}
    end

    create index(:users, [:principal], where: "principal = true", name: :users_principal_index)

    create table(:claimable_users, primary_key: false) do
      add :id, :binary_id, primary_key: true

      # The principal itself. Deleting the row deletes the grant with it, which
      # is what account deletion and the expirer's teardown rely on.
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      # The application that opened it: a Fountain account holding a full-scope
      # key (ADR 0044 decision 1). Nilified rather than cascaded so that
      # deleting an application account cannot silently take the trail of the
      # principals it opened.
      add :application_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :application_id, :string, null: false

      add :status, :string, null: false, default: "unclaimed"
      add :claim_token_hash, :string
      add :expires_at, :utc_datetime, null: false

      add :claimed_at, :utc_datetime
      add :claimed_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :expired_at, :utc_datetime
      add :released_at, :utc_datetime
      add :budget_exhausted_at, :utc_datetime

      add :grant_cents, :integer, null: false, default: 0
      add :max_live_sandboxes, :integer

      add :create_idempotency_key, :string
      add :claim_idempotency_key, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:claimable_users, [:user_id])

    # Idempotent creation, per application. A second POST with the same key
    # returns the principal the first one opened rather than a second machine.
    create unique_index(:claimable_users, [:application_user_id, :create_idempotency_key],
             where: "create_idempotency_key IS NOT NULL",
             name: :claimable_users_application_idempotency_index
           )

    # The expirer's sweep: unclaimed rows whose date has passed.
    create index(:claimable_users, [:status, :expires_at])
    create index(:claimable_users, [:application_user_id])
    create index(:claimable_users, [:claimed_by_user_id])

    create table(:principal_owners, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :owner_user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      add :principal_user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime)
    end

    # One owner per principal. The unique index is the serialization backstop
    # behind the row lock claim takes: two claims that somehow both got past
    # the lock still produce one row and one conflict.
    create unique_index(:principal_owners, [:principal_user_id])
    create index(:principal_owners, [:owner_user_id])
  end

  # Written out rather than left to `change/0`, because the automatic reverse
  # is not correct here. Putting `NOT NULL` back on `users.email` fails while a
  # single principal still exists, and dropping the tables would leave those
  # rows behind with no way to reach them and nothing that knows they are not
  # accounts. A rollback of this migration is "the feature goes away", so the
  # principals go with it — their sprites are the expirer's job before anyone
  # rolls back, which is why this is a down and not a teardown path.
  def down do
    execute "DELETE FROM users WHERE principal = true"

    drop table(:principal_owners)
    drop table(:claimable_users)
    drop index(:users, [:principal], name: :users_principal_index)

    alter table(:users) do
      remove :principal
      modify :email, :string, null: false
    end
  end
end
