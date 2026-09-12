defmodule Fountain.Repo.Migrations.AddTurnExecutionLimits do
  use Ecto.Migration

  # The allowance a bounded turn was admitted under, frozen onto its journal
  # row beside the absolute deadline. Recovery reads this rather than resolving
  # the policy again: an account ceiling lowered mid-turn must not retroactively
  # change what an in-flight turn was allowed, and one raised mid-turn must not
  # widen it. `users.execution_limits` and `execution_allowances` already exist
  # (#1787, #1790); this is only the per-turn copy.
  #
  # Numbered after main's `20260911020000_add_waiting_to_turns` (#1635): two
  # migrations sharing a version make `mix ecto.migrate` refuse the entire run,
  # not just the pair.
  def change do
    alter table(:turn_executions) do
      add :execution_limits, :map, null: false, default: %{}
    end

    create constraint(:turn_executions, :turn_executions_limits_object,
             check: "jsonb_typeof(execution_limits) = 'object'"
           )
  end
end
