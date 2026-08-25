defmodule FountainWeb.MarketingHTML do
  @moduledoc false
  use FountainWeb, :html

  embed_templates "marketing_html/*"

  @doc "Whether the pricing section renders at all: only where the deployment bills."
  def pricing?, do: Fountain.Billing.enabled?()

  @doc "The opening credit a new account gets, and how long it lasts."
  def opening_credit do
    cfg = Application.get_env(:fountain, :credits, [])

    {Fountain.Credits.format_cents(Keyword.get(cfg, :opening_cents, 1_000)),
     Keyword.get(cfg, :opening_days, 14)}
  end

  @doc "The concurrency rule (ADR 0031), read from the same settings Quotas enforces."
  def cap_rule do
    %{reserve_cents: reserve, cap_floor: floor, cap_ceiling: ceiling} = Fountain.Quotas.settings()
    {Fountain.Credits.format_cents(reserve), floor, ceiling}
  end

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
