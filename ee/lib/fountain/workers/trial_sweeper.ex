defmodule Fountain.Workers.TrialSweeper do
  @moduledoc """
  Daily backstop that expires stale `trialing` rows (#504).

  Stripe ends trials itself — the signup subscription cancels when the trial
  lapses with no payment method, and the webhook flips the status — but that
  depends on a signal arriving. When it doesn't (missed webhook, or a
  local-only trial with no Stripe subscription), the row sits at `trialing`
  forever. Access is already denied at read time (`Billing.check_active/1`
  checks the clock), so what this sweep repairs is recorded status: admin
  counts, status-based queries, and the trial-expired lifecycle email.

  Thin shell over `Billing.expire_stale_trials/1`; no-ops when billing is
  disabled — on a self-hosted instance trial state is not stamped at all
  (#480) and there is nothing to sweep.
  """

  use Oban.Worker, queue: :billing, max_attempts: 1

  alias Fountain.Billing

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    if Billing.enabled?() do
      counts = Billing.expire_stale_trials()

      if counts |> Map.values() |> Enum.sum() > 0 do
        Logger.info(
          "trial sweeper: expired #{counts.expired} local, synced #{counts.synced} " <>
            "from Stripe, repaired #{counts.extended} clocks, skipped #{counts.skipped}"
        )
      end
    end

    :ok
  end
end
