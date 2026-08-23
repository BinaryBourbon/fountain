defmodule FountainWeb.BillingApiJSON do
  @moduledoc false

  def show(%{user: user, usage: usage, allowance: allowance, period: period}) do
    %{
      data: %{
        status: user.subscription_status,
        plan: plan_data(user),
        trial_ends_at: user.trial_ends_at,
        current_period_start: user.current_period_start,
        current_period_end: user.current_period_end,
        # Only an active subscription can be pending cancellation; once the
        # `.deleted` event lands the status is canceled and the flag clears.
        cancel_at_period_end:
          user.subscription_status == "active" and user.cancel_at_period_end == true,
        has_stripe_customer: user.stripe_customer_id not in [nil, ""],
        # `source` is not decoration: `calendar_month` means these numbers
        # cover a window the customer is not invoiced over, which a client
        # showing an allowance has to be able to say.
        period: %{start: period.start, end: period.end, source: period.source},
        usage: %{
          conversations: usage.conversations,
          turns: usage.turns,
          # Hours with a prompt in flight, on providers Fountain pays for —
          # the unit `plan.included_turn_hours` is denominated in. Distinct
          # from `sandbox_minutes`, which is wall-clock and includes idle.
          turn_hours: allowance.used,
          turn_hours_included: allowance.included,
          turn_hours_remaining: allowance.remaining,
          sandbox_minutes: Float.round(usage.sandbox_minutes, 2),
          # Which sandbox provider the minutes ran on. Absent providers were
          # not used; the values sum to `sandbox_minutes`.
          sandbox_minutes_by_provider: usage.sandbox_minutes_by_provider
        }
      }
    }
  end

  def url(%{url: url}), do: %{data: %{url: url}}

  # `concurrent_sandboxes` is the plan's number; `sandbox_limit` is what is
  # actually enforced for this account. They differ when an operator has set
  # an override, and a client showing "3 of 5 running" needs the second one.
  defp plan_data(user) do
    plan = Fountain.Plans.resolve(user.plan)

    %{
      slug: plan.slug,
      name: plan.name,
      monthly_cents: plan.monthly_cents,
      concurrent_sandboxes: plan.concurrent_sandboxes,
      included_turn_hours: plan.included_turn_hours,
      sandbox_limit: Fountain.Quotas.sandbox_limit_for(user),
      team_contacts: plan.team_contacts
    }
  end
end
