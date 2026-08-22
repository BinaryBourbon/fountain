defmodule Fountain.Repo.Migrations.AddPlanToUsers do
  use Ecto.Migration

  @moduledoc """
  Plans (`Fountain.Plans`): a `plan` slug per user, and the concurrency cap
  demoted from "the entitlement" to "an override of the plan's".

  ## Why the cap column is not renamed

  `max_concurrent_sandboxes` keeps its name in Postgres and is read in Elixir
  as `sandbox_limit_override` through Ecto's `:source`. A rename would break
  every pod still running the previous release for the length of a rolling
  deploy; making the column nullable does not, because the previous release
  already treats a null as "use the default" (`Quotas.sandbox_limit/1`). So
  the worst an old pod does mid-rollout is apply the old default of 5, and it
  applies it to exactly the rows this migration nulled — the ones that were 5.

  ## Backfill

  * `plan` — `legacy` for every account Stripe knows about, which is every
    account that bought the single flat price these tiers replace. It carries
    Team capacity at the old price (`Fountain.Plans`), so nobody's cap fell at
    the changeover. Accounts with no Stripe customer (self-hosted, or never
    verified) stay null and follow `DEFAULT_PLAN`.
  * `max_concurrent_sandboxes` — nulled wherever it still holds the old
    default of 5, so those accounts follow their plan from here on. Any other
    value was set deliberately by an operator (raised for a trusted tenant,
    or dropped to zero during abuse) and survives as an override.
  """

  def up do
    alter table(:users) do
      add :plan, :string
      modify :max_concurrent_sandboxes, :integer, null: true, default: nil
    end

    execute("UPDATE users SET plan = 'legacy' WHERE stripe_customer_id IS NOT NULL")
    execute("UPDATE users SET max_concurrent_sandboxes = NULL WHERE max_concurrent_sandboxes = 5")
  end

  def down do
    execute(
      "UPDATE users SET max_concurrent_sandboxes = 5 WHERE max_concurrent_sandboxes IS NULL"
    )

    alter table(:users) do
      modify :max_concurrent_sandboxes, :integer, null: false, default: 5
      remove :plan
    end
  end
end
