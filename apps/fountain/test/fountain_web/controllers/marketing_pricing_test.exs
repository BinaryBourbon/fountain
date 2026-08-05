# async: false — these tests mutate the global :stripe_price_monthly_cents /
# :billing_enabled app env, which concurrent tests (admin MRR) also read.
defmodule FountainWeb.MarketingPricingTest do
  use FountainWeb.ConnCase, async: false

  setup do
    price = Application.get_env(:fountain, :stripe_price_monthly_cents)
    billing = Application.get_env(:fountain, :billing_enabled)

    on_exit(fn ->
      Application.put_env(:fountain, :stripe_price_monthly_cents, price)
      Application.put_env(:fountain, :billing_enabled, billing)
    end)

    :ok
  end

  test "homepage renders the configured monthly price in both pricing lines", %{conn: conn} do
    Application.put_env(:fountain, :stripe_price_monthly_cents, 2900)

    body = conn |> get(~p"/") |> html_response(200)
    assert body =~ "then $29/mo per team"
    assert body =~ "$29/mo per team after trial"
  end

  test "non-whole-dollar prices render with cents", %{conn: conn} do
    Application.put_env(:fountain, :stripe_price_monthly_cents, 2950)

    body = conn |> get(~p"/") |> html_response(200)
    assert body =~ "$29.50/mo per team"
  end

  test "omits the price when STRIPE_PRICE_MONTHLY_CENTS is unset", %{conn: conn} do
    Application.put_env(:fountain, :stripe_price_monthly_cents, nil)

    body = conn |> get(~p"/") |> html_response(200)
    refute body =~ "/mo per team"
    assert body =~ "Free 14-day trial. Cancel anytime."
    assert body =~ "Cancel anytime. No lock-in."
  end

  test "omits the price when billing is disabled even if a price is configured", %{conn: conn} do
    Application.put_env(:fountain, :stripe_price_monthly_cents, 2900)
    Application.put_env(:fountain, :billing_enabled, false)

    body = conn |> get(~p"/") |> html_response(200)
    refute body =~ "/mo per team"
  end
end
