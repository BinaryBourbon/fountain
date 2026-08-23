# async: false — these tests mutate the global :stripe_price_ids /
# :billing_enabled app env, which concurrent tests (admin MRR, billing) read.
defmodule FountainWeb.MarketingPricingTest do
  use FountainWeb.ConnCase, async: false

  alias Fountain.Plans

  setup do
    price_ids = Application.get_env(:fountain, :stripe_price_ids)
    price = Application.get_env(:fountain, :stripe_price_monthly_cents)
    billing = Application.get_env(:fountain, :billing_enabled)

    # delete_env when there was nothing there: put_env(key, nil) leaves the key
    # *present* holding nil, which is a different state from absent and leaks
    # into whatever runs next.
    on_exit(fn ->
      case price_ids do
        nil -> Application.delete_env(:fountain, :stripe_price_ids)
        value -> Application.put_env(:fountain, :stripe_price_ids, value)
      end

      Application.put_env(:fountain, :stripe_price_monthly_cents, price)
      Application.put_env(:fountain, :billing_enabled, billing)
    end)

    :ok
  end

  defp price_all do
    Application.put_env(:fountain, :stripe_price_ids, %{
      "solo" => "price_solo",
      "team" => "price_team",
      "scale" => "price_scale"
    })
  end

  test "the pricing table renders a card per sellable plan", %{conn: conn} do
    price_all()

    body = conn |> get(~p"/") |> html_response(200)

    for plan <- Plans.public() do
      assert body =~ plan.name
      assert body =~ Plans.format_usd(plan.monthly_cents)
      assert body =~ "#{plan.concurrent_sandboxes} agents at once"
    end
  end

  test "the hero quotes the cheapest sellable plan", %{conn: conn} do
    price_all()

    body = conn |> get(~p"/") |> html_response(200)
    assert body =~ "then from $29/mo"
  end

  # The whole point of filtering on price id: a tier with no price is a button
  # that leads to a Stripe error, and quoting it in the hero is worse still.
  test "a plan with no price id is neither listed nor quoted", %{conn: conn} do
    Application.put_env(:fountain, :stripe_price_ids, %{"team" => "price_team"})

    body = conn |> get(~p"/") |> html_response(200)
    assert body =~ "then from $79/mo"
    assert body =~ "15 agents at once"
    refute body =~ "Solo"
    refute body =~ "Scale"
  end

  test "the closed legacy plan is never listed, even when its price is set", %{conn: conn} do
    price_all()
    Application.put_env(:fountain, :stripe_price_id, "price_legacy")

    body = conn |> get(~p"/") |> html_response(200)
    refute body =~ "Legacy"
  end

  test "omits pricing entirely when no plan has a price", %{conn: conn} do
    Application.put_env(:fountain, :stripe_price_ids, %{})
    Application.put_env(:fountain, :stripe_price_id, nil)

    body = conn |> get(~p"/") |> html_response(200)
    refute body =~ "/mo"
    refute body =~ "agents at once"
    assert body =~ "Free 14-day trial. Cancel anytime."
    assert body =~ "Cancel anytime. No lock-in."
  end

  test "omits pricing when billing is disabled even with prices configured", %{conn: conn} do
    price_all()
    Application.put_env(:fountain, :billing_enabled, false)

    body = conn |> get(~p"/") |> html_response(200)
    refute body =~ "/mo"
    refute body =~ "agents at once"
  end

  test "non-whole-dollar amounts render with cents" do
    assert Plans.format_usd(2950) == "$29.50"
    assert Plans.format_usd(2900) == "$29"
  end
end
