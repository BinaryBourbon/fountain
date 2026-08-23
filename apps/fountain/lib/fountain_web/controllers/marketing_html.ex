defmodule FountainWeb.MarketingHTML do
  @moduledoc false
  use FountainWeb, :html

  embed_templates "marketing_html/*"

  alias Fountain.Plans

  @doc """
  The plans to show in the pricing table: the ones this deployment can
  actually sell (`Fountain.Billing.available_plans/0`).

  Empty when billing is off or no price id is configured, and the pricing
  section renders nothing rather than advertising a tier whose button leads to
  a Stripe error.
  """
  def pricing_plans, do: Fountain.Billing.available_plans()

  @doc """
  The cheapest sellable plan's price, e.g. `"$29"` — the "from" figure in the
  hero, where a table would be too much.

  `nil` when there is nothing to sell, in which case the pricing sentence is
  omitted rather than fabricated.
  """
  def monthly_price do
    case pricing_plans() do
      [cheapest | _] -> Plans.format_usd(cheapest.monthly_cents)
      [] -> nil
    end
  end

  @doc "A plan's monthly price, formatted."
  def plan_price(plan), do: Plans.format_usd(plan.monthly_cents)

  @doc """
  The one-line capacity claim under a plan's price. Concurrency is the axis
  the tiers are sold on, so it is the headline number.
  """
  def plan_capacity(plan), do: "#{plan.concurrent_sandboxes} agents at once"

  @doc """
  The work that comes with the capacity. A turn hour is an hour with a prompt
  in flight, so an agent left sitting idle does not spend one — which is the
  part worth being explicit about on a pricing page.
  """
  def plan_turn_hours(plan), do: "#{plan.included_turn_hours} turn hours a month"

  @doc """
  The trial plan, so the page can state what fourteen days actually gets you.

  Read from the catalog rather than written into the template: the trial's
  numbers are enforced from `Fountain.Plans`, and a page that repeats them by
  hand is a page that will one day advertise limits the product does not have.
  """
  def trial_plan, do: Plans.fetch!("trial")
end
