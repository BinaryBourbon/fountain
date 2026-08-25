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
  def plan_turn_hours(plan) do
    cents = plan.included_turn_hours * Fountain.Credits.price_card().turn_hour
    "#{Fountain.Credits.format_cents(cents)} of credit a month"
  end

  @doc """
  The trial plan, so the page can state what fourteen days actually gets you.

  Read from the catalog rather than written into the template: the trial's
  numbers are enforced from `Fountain.Plans`, and a page that repeats them by
  hand is a page that will one day advertise limits the product does not have.
  """
  def trial_plan, do: Plans.fetch!("trial")

  # The customer prices, read from the same card the ledger burns at, so the
  # page cannot quote a number the meter does not charge (ADR 0030).
  def turn_hour_price, do: Fountain.Credits.format_cents(Fountain.Credits.price_card().turn_hour)

  def credit_packs do
    Enum.map_join(Fountain.Credits.packs(), ", ", &Fountain.Credits.format_cents/1)
  end

  # Nil when this deployment charges nothing for a line, so the page says
  # nothing about it rather than quoting $0.
  def rent_line do
    card = Fountain.Credits.price_card()

    parts =
      [
        card.number_month &&
          "a phone number #{Fountain.Credits.format_cents(card.number_month)} a month",
        card.inbox_month &&
          "an email inbox #{Fountain.Credits.format_cents(card.inbox_month)} a month"
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: nil, else: Enum.join(parts, ", ")
  end

  def message_line do
    card = Fountain.Credits.price_card()

    parts =
      [
        card.email_message && "#{Fountain.Credits.format_cents(card.email_message)} an email",
        card.sms_message &&
          "#{Fountain.Credits.format_cents(card.sms_message)} a text, sent or received"
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: nil, else: Enum.join(parts, " and ")
  end
end
