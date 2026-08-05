defmodule FountainWeb.MarketingHTML do
  @moduledoc false
  use FountainWeb, :html

  embed_templates "marketing_html/*"

  @doc """
  Display price for the marketing page, read from `:stripe_price_monthly_cents`
  (`STRIPE_PRICE_MONTHLY_CENTS`) — the same value the admin MRR tile uses, so
  the homepage cannot drift from the configured Stripe price.

  Returns e.g. `"$29"`, or `nil` when billing is disabled or the price isn't
  configured — the pricing sentence is omitted rather than fabricated.
  """
  def monthly_price do
    with true <- Fountain.Billing.enabled?(),
         cents when is_integer(cents) and cents > 0 <-
           Application.get_env(:fountain, :stripe_price_monthly_cents) do
      format_usd(cents)
    else
      _ -> nil
    end
  end

  defp format_usd(cents) when rem(cents, 100) == 0, do: "$#{div(cents, 100)}"
  defp format_usd(cents), do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"
end
