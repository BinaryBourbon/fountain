defmodule FountainWeb.BillingApiJSON do
  @moduledoc false

  def show(%{user: user, usage: usage, credits: credits, sandbox_cap: cap, period: period}) do
    %{
      data: %{
        comped: user.comped,
        has_stripe_customer: user.stripe_customer_id not in [nil, ""],
        sandbox_cap: cap,
        period: %{start: period.start, end: period.end, source: period.source},
        credits: credits_data(credits),
        usage: %{
          conversations: usage.conversations,
          turns: usage.turns,
          # Hours with a prompt in flight, on providers Fountain pays for —
          # what burns credit (ADR 0030). Distinct from `sandbox_minutes`,
          # which is wall-clock and includes idle.
          turn_hours: usage.turn_hours,
          sandbox_minutes: Float.round(usage.sandbox_minutes, 2),
          # Which sandbox provider the minutes ran on. Absent providers were
          # not used; the values sum to `sandbox_minutes`.
          sandbox_minutes_by_provider: usage.sandbox_minutes_by_provider
        }
      }
    }
  end

  def url(%{url: url}), do: %{data: %{url: url}}

  defp credits_data(%{active?: false}), do: nil

  defp credits_data(c) do
    %{
      balance_cents: c.balance_cents,
      expiring_cents: c.expiring_cents,
      expires_at: c.expires_at,
      purchased_cents: c.purchased_cents,
      turn_hour_cents: c.turn_hour_cents,
      packs_cents: Fountain.Credits.packs()
    }
  end
end
