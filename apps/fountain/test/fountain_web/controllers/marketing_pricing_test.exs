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

  # Credits are the product (ADR 0031): the page quotes the hour price and the
  # opening grant from the same config the meter enforces.
  test "the pricing section quotes the price per hour and the opening credit", %{
    conn: conn
  } do
    body = conn |> get(~p"/") |> html_response(200)

    assert body =~ "You pay only while an agent is working."
    assert body =~ "spend it only while a prompt is in flight"
    assert body =~ "$0.25"
    assert body =~ "per active agent hour"
    assert body =~ "$5.00"
    assert body =~ "free credit to start"
    assert body =~ "No card required"
    assert body =~ "Starter credit expires after 14 days"
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
    assert body =~ "One agent hour is one hour with a prompt in flight"
    assert body =~ "Two agents working"
    assert body =~ "Parked and idle agents cost nothing"
  end

  test "the page says what happens at zero and at the cap", %{conn: conn} do
    body = conn |> get(~p"/") |> html_response(200)

    assert body =~ "How billing works"
    assert body =~ "Purchased credit never expires"
    assert body =~ "Add credit in packs of $10.00, $25.00, $100.00"
    assert body =~ "Bring your own model key"
    assert body =~ "Fountain bills agent time, not inference"
    assert body =~ "Your balance sets your concurrency"
    assert body =~ "Each $2.00 in your balance supports one agent working at a time"
    assert body =~ "with a minimum of 2 and a maximum of 20"
    assert body =~ "Starts beyond your limit are refused, not queued"
    assert body =~ "At zero, new work pauses"
    assert body =~ "Work already in flight finishes"
    # No rent or message price in test config, so the page says nothing about
    # contacts rather than quoting $0.
    refute body =~ "Teammate contacts come out of the same balance"
    refute body =~ "Going over the hours does not stop anything"
    refute body =~ "waits for a free slot"
  end

  test "the hero quotes the opening credit", %{conn: conn} do
    body = conn |> get(~p"/") |> html_response(200)
    assert body =~ "Run coding agents on ready machines."
    assert body =~ "Pay only while they work."
    assert body =~ "$5.00 of credit to start"
  end

  test "omits pricing when billing is disabled", %{conn: conn} do
    Application.put_env(:fountain, :credits_enabled, false)

    body = conn |> get(~p"/") |> html_response(200)
    assert body =~ "Run coding agents on ready machines."
    refute body =~ "Pay only while they work."
    refute body =~ "You pay only while an agent is working."
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
    assert body =~ "A phone number is $3.00 a month and an email inbox is $2.00 a month"
    assert body =~ "billed in advance"
    assert body =~ "$0.02 an email and $0.02 a text, sent or received"
  end
end
