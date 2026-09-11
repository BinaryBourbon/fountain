defmodule Fountain.Repo.Migrations.FenceSandboxResets do
  use Ecto.Migration

  require Logger

  def up do
    alter table(:sandboxes) do
      add :reset_requested_at, :utc_datetime_usec
    end
  end

  # A rollback has to work. Refusing it whenever evidence exists would brick
  # the deploy-rollback path permanently, because a *successful* reset keeps
  # its `reset_requested_at` by design, so the first reset in production would
  # be the last time this migration could be reversed.
  #
  # Dropping the column is also the correct rollback semantic: the code being
  # rolled back to has no concept of a fence, and reads these rows as the
  # ordinary sandboxes they were. What the operator loses is the record of
  # which machines had an unconfirmed delete, so name them on the way out.
  def down do
    # Keep a concurrent reset from adding evidence between the count and the drop.
    execute "LOCK TABLE sandboxes IN ACCESS EXCLUSIVE MODE"

    warn_about_unconfirmed_resets()

    alter table(:sandboxes) do
      remove :reset_requested_at
    end
  end

  defp warn_about_unconfirmed_resets do
    %{rows: rows} =
      repo().query!("""
      -- id::text, because a raw query hands back the 16-byte UUID and the
      -- Logger formatter raises on the invalid UTF-8 that interpolates into.
      SELECT id::text, sprite_name, provider
        FROM sandboxes
       WHERE reset_requested_at IS NOT NULL
         AND status NOT IN ('terminated', 'failed')
      """)

    for [id, name, provider] <- rows do
      Logger.warning(
        "rollback: sandbox #{id} (#{provider}/#{name}) had an unconfirmed reset. " <>
          "Its machine may still exist at the provider; check it by hand."
      )
    end
  end
end
