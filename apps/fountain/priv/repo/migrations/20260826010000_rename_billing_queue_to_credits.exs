defmodule Fountain.Repo.Migrations.RenameBillingQueueToCredits do
  use Ecto.Migration

  # #1144: the `:billing` Oban queue ran only the Credit* workers and is now
  # `:credits`. A job still waiting under the old name would never run (a
  # queue nothing is configured to drain is silent, not an error), so move it.
  def up do
    execute "UPDATE oban_jobs SET queue = 'credits' WHERE queue = 'billing'"
  end

  def down do
    execute "UPDATE oban_jobs SET queue = 'billing' WHERE queue = 'credits'"
  end
end
