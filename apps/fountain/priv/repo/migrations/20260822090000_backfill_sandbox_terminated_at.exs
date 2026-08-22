defmodule Fountain.Repo.Migrations.BackfillSandboxTerminatedAt do
  use Ecto.Migration

  # Only the paths that *terminated* a sandbox ever passed a `terminated_at`;
  # the ones that marked it `failed` did not, so a failed row carried a null
  # end for the rest of its life. Spend attribution reads that column as the
  # end of the billed interval, and a null there reads as "still running" —
  # every historical failure would accrue minutes forever.
  #
  # `updated_at` is the closest thing to the truth for these rows: the write
  # that set the terminal status was, for a failed sandbox, the last write it
  # ever received. Conversations.update_sandbox/2 now stamps the column, so
  # this only has to repair the backlog.
  def up do
    execute("""
    UPDATE sandboxes
       SET terminated_at = updated_at
     WHERE status IN ('terminated', 'failed')
       AND terminated_at IS NULL
    """)
  end

  # Irreversible by design: the pre-migration state is "we do not know when
  # this ended", and nulling the column again would only throw away the best
  # estimate we have. Rolling back leaves the repaired timestamps in place.
  def down, do: :ok
end
