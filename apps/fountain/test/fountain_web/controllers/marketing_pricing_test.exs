# async: false — these tests mutate the global :credits_enabled / :credits app
# env, which concurrent tests read.
defmodule FountainWeb.MarketingPricingTest do
  use FountainWeb.ConnCase, async: false

  setup do
    billing = Application.get_env(:fountain, :credits_enabled)
    credits = Application.get_env(:fountain, :credits)

    on_exit(fn ->
      Application.put_env(:fountain, :credits_enabled, billing)
      Application.put_env(:fountain, :credits, credits)
    end)

    :ok
  end

  # Credits are the product (ADR 0031): the page quotes the hour price, the
  # opening grant and the concurrency rule, all read from the same config the
  # meter and the cap enforce.
  test "the pricing section quotes the price per hour, the opening credit and the cap", %{
    conn: conn
  } do
    body = conn |> get(~p"/") |> html_response(200)

    assert body =~ "Pay for what your agents do"
    assert body =~ "$0.25"
    assert body =~ "per agent hour"
    assert body =~ "$5.00"
    assert body =~ "to start, free"
    assert body =~ "Good for 14 days"
    assert body =~ "agents at once, at most"
    assert body =~ "One more for every $2.00 you hold, from 2"
    assert body =~ "Start with $5.00 free"
    # A monthly price renders as a number attached to "/mo". The bare string
    # would now match GET /v1/models in the protocols section.
    refute body =~ ~r"\$[\d,.]+\s*/\s*mo"
  end

  # Scale-to-zero (0017) is the strongest claim the rest of the page makes. A
  # pricing page that charged for parked time, or merely failed to say it did
  # not, would undercut it.
  test "the pricing section says parked and idle time cost nothing", %{conn: conn} do
    body = conn |> get(~p"/") |> html_response(200)
    assert body =~ "An hour with a prompt in flight"
    assert body =~ "A parked agent, an idle one"
    assert body =~ "your own machine all cost nothing"
  end

  test "the page says what happens at zero and at the cap", %{conn: conn} do
    body = conn |> get(~p"/") |> html_response(200)

    assert body =~ "How billing works"
    assert body =~ "Credit is the whole product"
    assert body =~ "Agent time costs $0.25 an hour"
    assert body =~ "Buy credit in packs of $10.00, $25.00, $100.00"
    assert body =~ "At zero, new work pauses; nothing dies"
    assert body =~ "Anything already running finishes"
    assert body =~ "Your balance sets how many agents run at once"
    assert body =~ "is refused rather than queued"
    # No rent or message price in test config, so the page says nothing about
    # contacts rather than quoting $0.
    refute body =~ "Teammate contacts come out of the same balance"
    refute body =~ "Going over the hours does not stop anything"
    refute body =~ "waits for a free slot"
  end

  test "the hero quotes the opening credit", %{conn: conn} do
    body = conn |> get(~p"/") |> html_response(200)
    assert body =~ "$5.00 of credit to start"
  end

  test "omits pricing when billing is disabled", %{conn: conn} do
    Application.put_env(:fountain, :credits_enabled, false)

    body = conn |> get(~p"/") |> html_response(200)
    refute body =~ "Pay for what your agents do"
    refute body =~ "per agent hour"
    refute body =~ "of credit to start"
  end

  test "priced contacts and messages are quoted from the price card", %{conn: conn} do
    cfg = Application.get_env(:fountain, :credits)

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

    body = conn |> get("/") |> html_response(200)
    assert body =~ "A phone number $3.00 a month, an email inbox $2.00 a month"
    assert body =~ "a month up front"
    assert body =~ "$0.02 an email and $0.02 a text, sent or received"
  end
end
