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

      assert body =~
               "#{Fountain.Credits.format_cents(plan.included_credit_cents)} of credit a month"
    end
  end

  # The hours are a public promise, so the page has to say what a turn hour
  # is. A reader who assumes it means wall-clock sandbox time reads Solo's
  # 100 hours as four days and concludes the plan is unusable.
  # Scale-to-zero (0017) is the strongest claim the rest of the page makes. A
  # pricing page that charged for parked time, or merely failed to say it did
  # not, would undercut it.
  test "the pricing table says parked and idle time cost nothing", %{conn: conn} do
    price_all()

    body = conn |> get(~p"/") |> html_response(200)
    assert body =~ "counted only while a prompt is in flight"
    assert body =~ "A parked agent, an idle one"
    assert body =~ "your own machine all cost nothing"
  end

  # "800 hours included" followed by silence reads as a hard stop, and a hard
  # stop on hours sounds like an agent dying mid-task. The two limits behave
  # differently and the page has to say which is which.
  test "the pricing table says what happens at each limit", %{conn: conn} do
    price_all()

    body = conn |> get(~p"/") |> html_response(200)

    # What a credit buys, in the meter's own numbers (ADR 0030).
    assert body =~ "How billing works"
    assert body =~ "Agent time costs $0.25 an hour"
    assert body =~ "Buy credit in packs of $10.00, $25.00, $100.00"
    assert body =~ "At zero, new work pauses; nothing dies"
    assert body =~ "Anything already running finishes"
    # No rent or message price in test config, so the page says nothing about
    # contacts rather than quoting $0.
    refute body =~ "Teammate contacts come out of the same balance"
    refute body =~ "Going over the hours does not stop anything"
    assert body =~ "At the concurrency cap, the next start waits for you"
    assert body =~ "is refused rather than queued"
  end

  # #1026: the page promised a queue for a whole release, pinned by a test that
  # asserted the sentence was present. There is no queue —
  # `Quotas.check_sandbox_quota/2` refuses the next start, and
  # `FallbackController` returns 429. A buyer picks a tier on this sentence, so
  # the queue wording is asserted absent, not merely replaced.
  test "the pricing table does not promise a queue behind the cap", %{conn: conn} do
    price_all()

    body = conn |> get(~p"/") |> html_response(200)

    refute body =~ "waits for a free slot"
    refute body =~ "Queue as much work"
  end

  # The trial's numbers are enforced from the catalog, so the page reads them
  # from there. Hardcoding them is how a pricing page ends up advertising
  # limits the product does not have.
  test "the trial line comes from the catalog, not from the template", %{conn: conn} do
    price_all()
    trial = Plans.fetch!("trial")

    body = conn |> get(~p"/") |> html_response(200)

    assert body =~ "#{trial.concurrent_sandboxes} agents at once"

    assert body =~
             "with #{Fountain.Credits.format_cents(trial.included_credit_cents)} of credit"

    assert body =~ "so you can judge it before paying"
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
    assert body =~ "#{Fountain.Plans.concurrent_sandboxes("team")} agents at once"
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

  test "priced contacts and messages are quoted from the price card", %{conn: conn} do
    cfg = Application.get_env(:fountain, :credits)
    on_exit(fn -> Application.put_env(:fountain, :credits, cfg) end)

    Application.put_env(
      :fountain,
      :credits,
      Keyword.merge(cfg,
        number_cents: 300,
        inbox_cents: 200,
        email_message_cents: 2,
        sms_message_cents: 2
      )
    )

    price_all()
    body = conn |> get("/") |> html_response(200)
    assert body =~ "A phone number $3.00 a month, an email inbox $2.00 a month"
    assert body =~ "a month up front"
    assert body =~ "$0.02 an email and $0.02 a text, sent or received"
  end
end
