defmodule Fountain.Billing.FinanceTest do
  @moduledoc """
  The finance panel's numbers: revenue per plan, cost per tenant, and the
  margin between them.

  Three properties carry the page, and each is tested against the way it would
  otherwise lie:

    * **`nil` is not zero.** An unpriced line has to stay unpriced all the way
      to the total. A cost that silently drops the part nobody gave a rate for
      reads as a cheap tenant.
    * **Revenue is per plan.** The number this replaced charged every active
      account the legacy price, which was invisible precisely because it was
      still a plausible-looking dollar figure.
    * **The cost basis changes the price and never the hours.** Which hours a
      provider bills is a fact about their invoice, so the panel offers both;
      a toggle whose arithmetic did not differ would be decoration.
  """

  use Fountain.DataCase, async: false

  alias Fountain.Accounts
  alias Fountain.Billing
  alias Fountain.Billing.Finance
  alias Fountain.Conversations
  alias Fountain.Plans

  # Wholly in the past, so the attribution ceiling is the period end and every
  # figure below is exact rather than a function of the wall clock.
  @period_start ~U[2026-05-01 00:00:00Z]
  @period_end ~U[2026-06-01 00:00:00Z]
  @period {@period_start, @period_end}
  # After the period, so `period_fraction/3` is a full month.
  @now ~U[2026-06-02 00:00:00Z]

  setup do
    # async: false and an explicit reset: the rate card is application env,
    # which is global. Every test states the card it wants.
    original =
      Map.new(
        [
          :provider_hourly_cents,
          :agentmail_inbox_cents,
          :agentphone_number_cents,
          :agentmail_message_cents,
          :agentphone_message_cents,
          :cost_basis
        ],
        &{&1, Application.get_env(:fountain, &1)}
      )

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> Application.delete_env(:fountain, key)
        {key, value} -> Application.put_env(:fountain, key, value)
      end)
    end)

    Enum.each(original, fn {key, _} -> Application.delete_env(:fountain, key) end)
    :ok
  end

  defp rate_card(opts) do
    Enum.each(opts, fn {key, value} -> Application.put_env(:fountain, key, value) end)
  end

  defp subscriber(plan, status \\ "active") do
    user = insert_verified_user()

    {:ok, user} =
      user
      |> Ecto.Changeset.change(
        plan: plan,
        subscription_status: status,
        # A real subscription: the contact add-on needs an item to sit on, and
        # `sync_contact_addon/1` bills nothing without one.
        stripe_subscription_id: "sub_#{System.unique_integer([:positive])}"
      )
      |> Repo.update()

    user
  end

  # Turn on contact billing for a test. Off by default, which is both the
  # shipped default and prod's actual state.
  defp bill_contacts! do
    Application.put_env(:fountain, :stripe_price_ids, %{"contact" => "price_contact_test"})
    on_exit(fn -> Application.delete_env(:fountain, :stripe_price_ids) end)
  end

  # A sandbox that ran for `hours`, with a prompt in flight for `busy_hours` of
  # them. The rest is idle: real cost, no allowance spent.
  defp ran(user, provider, hours, busy_hours) do
    started = @period_start
    ended = DateTime.add(started, hours * 3600, :second)

    sandbox =
      insert_sandbox(
        user_id: user.id,
        provider: provider,
        status: "terminated",
        inserted_at: started,
        terminated_at: ended
      )

    if busy_hours > 0 do
      agent = insert_agent(user_id: user.id)

      conversation =
        insert_conversation(user_id: user.id, agent_id: agent.id, sandbox: sandbox)

      {:ok, _} =
        Conversations._unsafe_create_turn(%{
          conversation_id: conversation.id,
          turn_number: System.unique_integer([:positive]),
          prompt: "hello",
          status: "completed",
          started_at: started,
          ended_at: DateTime.add(started, busy_hours * 3600, :second)
        })
    end

    sandbox
  end

  defp summary, do: Finance.summary(period: @period, now: @now)

  defp row_for(summary, user), do: Enum.find(summary.tenants, &(&1.user_id == user.id))

  ## ── the rate card ─────────────────────────────────────────────────────────

  describe "rate_card/0 and priced?/0" do
    test "a deployment that has set nothing prices nothing" do
      refute Finance.priced?()

      assert %{providers: %{}, inbox_month: nil, number_month: nil, email: nil, sms: nil} =
               Finance.rate_card()
    end

    test "one rate is enough to be priced" do
      rate_card(agentmail_inbox_cents: 200)
      assert Finance.priced?()
    end

    test "a negative or non-integer rate is no rate at all" do
      rate_card(agentmail_inbox_cents: -1, agentphone_number_cents: "200")

      assert %{inbox_month: nil, number_month: nil} = Finance.rate_card()
    end

    test "a fractional rate survives, because per-message rates are fractional" do
      # AgentMail bills about $0.002 an email. Read as whole cents that is
      # zero, and every deployment that priced email would report it as free.
      rate_card(agentmail_message_cents: 0.2, provider_hourly_cents: %{"sprites" => 10.76})

      assert %{email: 0.2, providers: %{"sprites" => 10.76}} = Finance.rate_card()
      assert Finance.priced?()
    end

    test "the default basis is active, and only an exact \"turn\" changes it" do
      assert Finance.default_basis() == :active

      Application.put_env(:fountain, :cost_basis, :turn)
      assert Finance.default_basis() == :turn

      # A typo must not quietly halve the reported bill.
      Application.put_env(:fountain, :cost_basis, "Turn")
      assert Finance.default_basis() == :active

      Application.delete_env(:fountain, :cost_basis)
    end
  end

  ## ── cost, and the nil that must not become a zero ─────────────────────────

  describe "cost" do
    test "sandbox cost is active hours at the provider's rate, idle included" do
      rate_card(provider_hourly_cents: %{"sprites" => 100})
      user = subscriber("solo")
      ran(user, "sprites", 10, 2)

      row = row_for(summary(), user)

      # Ten hours awake, two of them working. The provider charges for ten.
      assert row.active_hours == 10.0
      assert row.turn_hours == 2.0
      assert row.idle_hours == 8.0
      assert row.sandbox_cost_cents == 1000
    end

    test "the turn basis charges only the hours with a prompt in flight" do
      # Which of the two a provider actually bills is a fact about their
      # invoice. The panel offers both so the totals can be compared against
      # one; the arithmetic has to differ, or the toggle is decoration.
      rate_card(provider_hourly_cents: %{"sprites" => 100})
      user = subscriber("solo")
      ran(user, "sprites", 10, 2)

      active = Finance.summary(period: @period, now: @now, basis: :active) |> row_for(user)
      turn = Finance.summary(period: @period, now: @now, basis: :turn) |> row_for(user)

      assert active.sandbox_cost_cents == 1000
      assert turn.sandbox_cost_cents == 200

      # Both rows still report both hour figures whichever basis priced them.
      assert turn.active_hours == 10.0
      assert turn.turn_hours == 2.0
    end

    test "the turn basis reports no idle saving, because idle is already free" do
      rate_card(provider_hourly_cents: %{"sprites" => 100})
      user = subscriber("solo")
      ran(user, "sprites", 10, 2)

      assert Finance.summary(period: @period, now: @now, basis: :active).cost.idle_cents == 800
      # Nothing for a shorter timeout to remove — claiming a saving here would
      # be an invention.
      assert Finance.summary(period: @period, now: @now, basis: :turn).cost.idle_cents == nil
    end

    test "the basis reaches the totals and says which one it was" do
      rate_card(provider_hourly_cents: %{"sprites" => 100})
      user = subscriber("solo")
      ran(user, "sprites", 10, 2)

      turn = Finance.summary(period: @period, now: @now, basis: :turn)

      assert turn.cost.basis == :turn
      assert turn.rate_card.basis == :turn
      assert turn.cost.sandbox_cents == 200
      # The hours themselves never change with the basis; only the price does.
      assert turn.cost.active_hours == 10.0
    end

    test "an unattributable sandbox is priced on the same basis as the rest" do
      rate_card(provider_hourly_cents: %{"sprites" => 100})
      user = subscriber("solo")
      ran(user, "sprites", 10, 2)
      Repo.update_all(Fountain.Conversations.Sandbox, set: [user_id: nil])

      assert Finance.summary(period: @period, now: @now, basis: :active).unattributed_cost_cents ==
               1000

      assert Finance.summary(period: @period, now: @now, basis: :turn).unattributed_cost_cents ==
               200
    end

    test "a provider with no rate leaves the tenant's cost nil, not short" do
      # The failure this guards: pricing sprites, saying nothing about e2b, and
      # reporting a cost that quietly covers only half the hours.
      rate_card(provider_hourly_cents: %{"sprites" => 100})
      user = subscriber("solo")
      ran(user, "sprites", 10, 10)
      ran(user, "e2b", 10, 10)

      row = row_for(summary(), user)

      assert row.active_hours == 20.0
      assert row.sandbox_cost_cents == nil
      assert row.cost_cents == nil
      assert row.margin_cents == nil
    end

    test "a tenant's own runner costs nothing, and needs no rate to say so" do
      rate_card(provider_hourly_cents: %{"sprites" => 100})
      user = subscriber("solo")
      ran(user, "sprites", 1, 1)
      ran(user, "runner", 100, 100)

      row = row_for(summary(), user)

      # The runner hours are real and reported...
      assert row.active_hours == 101.0
      # ...and priced at zero rather than dropping the whole row to nil:
      # ADR 0022 says Fountain pays nothing for that machine.
      assert row.sandbox_cost_cents == 100
    end

    test "runner turn hours do not count against the plan" do
      user = subscriber("solo")
      ran(user, "runner", 50, 50)

      row = row_for(summary(), user)

      assert row.active_hours == 50.0
      assert row.turn_hours == 0.0
    end

    test "contacts are pro-rated to the window, and counted per channel" do
      rate_card(agentmail_inbox_cents: 300, agentphone_number_cents: 500)
      user = subscriber("solo")
      contact(user, email: true, phone: true)
      contact(user, email: true, phone: false)

      row = row_for(summary(), user)

      assert row.inboxes == 2
      assert row.numbers == 1
      # A full month elapsed, so no pro-rating: 2×300 + 1×500.
      assert row.contact_cost_cents == 1100
    end

    test "half a period charges half a month of contacts" do
      rate_card(agentmail_inbox_cents: 300, agentphone_number_cents: 500)
      user = subscriber("solo")
      contact(user, email: true, phone: true)

      halfway = ~U[2026-05-16 12:00:00Z]
      row = Finance.summary(period: @period, now: halfway) |> row_for(user)

      assert_in_delta row.contact_cost_cents, 400, 5
    end

    test "no contacts costs zero even with no rate configured" do
      user = subscriber("solo")

      row = row_for(summary(), user)

      # Nothing bought is a known price, not a missing one — otherwise every
      # tenant on an unpriced-contacts deployment would have a nil cost.
      assert row.contact_cost_cents == 0
    end

    test "sub-cent email rates accumulate instead of rounding away" do
      # 400 emails at 0.2c is $0.80, not $0. Rounding per channel first would
      # make the email column zero however much mail an agent sent.
      rate_card(agentmail_message_cents: 0.2, agentphone_message_cents: 2)
      user = subscriber("solo")

      message(user, "comms_email_sent", 400)
      message(user, "comms_sms_sent", 10)

      row = row_for(summary(), user)

      # 400 x 0.2c = 80c, plus 10 texts at 2c = 20c.
      assert row.message_cost_cents == 100
    end

    test "a fractional provider rate prices the hours it should" do
      rate_card(provider_hourly_cents: %{"sprites" => 10.76})
      user = subscriber("solo")
      ran(user, "sprites", 100, 100)

      # 100 hours at 10.76c, whichever basis — they are equal here.
      assert row_for(summary(), user).sandbox_cost_cents == 1076
    end

    test "messages are counted each way and priced apart" do
      rate_card(agentmail_message_cents: 2, agentphone_message_cents: 10)
      user = subscriber("solo")

      message(user, "comms_email_sent", 3)
      message(user, "comms_sms_sent", 2)
      message(user, "comms_sms_received", 4)

      row = row_for(summary(), user)

      assert row.emails_sent == 3
      assert row.sms_sent == 2
      assert row.sms_received == 4
      # 3×2 email, plus 6 SMS both directions at 10.
      assert row.message_cost_cents == 66
    end

    test "messages outside the period are not this period's cost" do
      rate_card(agentmail_message_cents: 2)
      user = subscriber("solo")

      message(user, "comms_email_sent", 1, ~U[2026-04-15 00:00:00Z])
      message(user, "comms_email_sent", 1, ~U[2026-05-15 00:00:00Z])

      assert row_for(summary(), user).emails_sent == 1
    end

    test "the three parts add up to the tenant's cost" do
      rate_card(
        provider_hourly_cents: %{"sprites" => 100},
        agentmail_inbox_cents: 300,
        agentphone_number_cents: 500,
        agentmail_message_cents: 2
      )

      user = subscriber("solo")
      ran(user, "sprites", 4, 1)
      contact(user, email: true, phone: true)
      message(user, "comms_email_sent", 5)

      row = row_for(summary(), user)

      assert row.sandbox_cost_cents == 400
      assert row.contact_cost_cents == 800
      assert row.message_cost_cents == 10
      assert row.cost_cents == 1210
    end
  end

  ## ── revenue ──────────────────────────────────────────────────────────────

  describe "revenue" do
    test "each active account is priced at its own plan, not one flat price" do
      # The bug this replaced: `active × STRIPE_PRICE_MONTHLY_CENTS` billed the
      # Scale account $29.
      subscriber("solo")
      subscriber("team")
      subscriber("scale")

      revenue = summary().revenue

      assert revenue.mrr_cents ==
               Plans.monthly_cents("solo") + Plans.monthly_cents("team") +
                 Plans.monthly_cents("scale")

      assert [%{plan: %{slug: "solo"}}, %{plan: %{slug: "team"}}, %{plan: %{slug: "scale"}}] =
               revenue.by_plan
    end

    test "only active subscriptions are MRR" do
      subscriber("scale", "trialing")
      subscriber("scale", "past_due")
      subscriber("scale", "comped")
      subscriber("scale", "canceled")

      revenue = summary().revenue

      assert revenue.mrr_cents == 0
      # ...but each cohort is reported at what it would bill, which is the
      # number an operator actually wants from them.
      assert revenue.trialing_cents == Plans.monthly_cents("scale")
      assert revenue.at_risk_cents == Plans.monthly_cents("scale")
      assert revenue.comped_cents == Plans.monthly_cents("scale")
    end

    test "the contact add-on is revenue, less what an operator comped" do
      bill_contacts!()
      user = subscriber("team")
      contact(user, email: true, phone: true)
      contact(user, email: true, phone: true)
      contact(user, email: true, phone: true)
      {:ok, _} = Accounts.update_comped_contacts(user, 1, actor: "admin")

      row = row_for(summary(), user)

      assert row.contact_revenue_cents == 2 * Plans.contact_monthly_cents()
      assert row.revenue_cents == Plans.monthly_cents("team") + row.contact_revenue_cents
    end

    test "comping more contacts than exist does not become negative revenue" do
      bill_contacts!()
      user = subscriber("team")
      contact(user, email: true, phone: true)
      {:ok, _} = Accounts.update_comped_contacts(user, 5, actor: "admin")

      assert row_for(summary(), user).contact_revenue_cents == 0
    end

    test "contacts earn nothing where the deployment does not bill for them" do
      # Prod's actual state: STRIPE_PRICE_ID_CONTACT unset, so
      # `sync_contact_addon/1` returns :not_billed and Stripe charges nothing.
      # The panel used to report $5 a contact against those invoices.
      user = subscriber("team")
      contact(user, email: true, phone: true)
      contact(user, email: true, phone: true)

      refute Finance.contacts_billed?()

      row = row_for(summary(), user)

      assert row.contact_revenue_cents == 0
      assert row.revenue_cents == Plans.monthly_cents("team")
      # The cost side is untouched: we pay AgentMail and AgentPhone regardless.
      assert row.inboxes == 2
      assert row.numbers == 2
      # ...and the tile that reads the same numbers agrees.
      assert Finance.mrr().contact_cents == 0
    end

    test "an account with no Stripe subscription has no item to bill the add-on on" do
      bill_contacts!()
      user = subscriber("team")
      Repo.update!(Ecto.Changeset.change(user, stripe_subscription_id: nil))
      contact(user, email: true, phone: true)

      assert row_for(summary(), user).contact_revenue_cents == 0
    end

    test "mrr/0 agrees with the full pass" do
      bill_contacts!()
      # Two code paths to the same number is two chances to disagree, and a
      # tile that contradicts the table below it destroys trust in both.
      subscriber("solo")
      subscriber("team")
      user = subscriber("scale")
      contact(user, email: true, phone: true)

      assert Finance.mrr().mrr_cents == summary().revenue.mrr_cents
    end

    test "mrr/0 merges a null plan into the deployment default" do
      # A row with no plan resolves to the default; so does an unknown slug.
      # Rendered as two groups they would show the same tier twice.
      user = insert_verified_user()

      {:ok, _} =
        user
        |> Ecto.Changeset.change(plan: nil, subscription_status: "active")
        |> Repo.update()

      other = subscriber(Plans.default_slug())

      assert other
      assert [%{accounts: 2}] = Finance.mrr().by_plan
    end
  end

  ## ── margin ───────────────────────────────────────────────────────────────

  describe "margin" do
    test "a tenant costing more than they pay shows negative, and sorts first" do
      rate_card(provider_hourly_cents: %{"sprites" => 500})

      cheap = subscriber("scale")
      ran(cheap, "sprites", 1, 1)

      expensive = subscriber("solo")
      ran(expensive, "sprites", 100, 100)

      summary = summary()

      assert row_for(summary, expensive).margin_cents ==
               Plans.monthly_cents("solo") - 50_000

      assert row_for(summary, expensive).margin_cents < 0
      assert row_for(summary, cheap).margin_cents > 0
      assert hd(summary.tenants).user_id == expensive.id
    end

    test "with no rate card there is no margin, and rows sort by hours" do
      quiet = subscriber("solo")
      ran(quiet, "sprites", 1, 1)

      busy = subscriber("solo")
      ran(busy, "sprites", 40, 40)

      summary = summary()

      assert row_for(summary, busy).margin_cents == nil
      assert hd(summary.tenants).user_id == busy.id
    end
  end

  ## ── the totals ───────────────────────────────────────────────────────────

  describe "summary/1" do
    test "credits: granted, burned and sold over the period, deferred balance today" do
      user = subscriber("solo")
      other = subscriber("team")
      at = DateTime.add(@period_start, 3600, :second)

      {:ok, _} = Fountain.Credits.grant(user.id, 1000, "grant_tier", idempotency_key: "g1")
      {:ok, _} = Fountain.Credits.grant(user.id, 2500, "purchase", idempotency_key: "p1")
      {:ok, _} = Fountain.Credits.debit(user.id, 700, "burn_turn", idempotency_key: "b1")
      {:ok, _} = Fountain.Credits.grant(other.id, 2500, "grant_tier", idempotency_key: "g2")
      # An expiry is neither granted nor burned.
      {:ok, _} = Fountain.Credits.debit(other.id, 2500, "expire", idempotency_key: "x1")

      # The ledger stamps now; the summary is over a fixed past month, so
      # place the rows inside it.
      Repo.update_all(Fountain.Credits.LedgerEntry, set: [inserted_at: at])

      credits = summary().credits
      assert credits.granted_cents == 3500
      assert credits.burned_cents == 700
      assert credits.sold_cents == 2500
      # user holds 2800, other holds 0.
      assert credits.deferred_cents == 2800
      assert credits.negative_balances == 0
      assert credits.utilization == Float.round(700 / 6000, 4)

      row = row_for(summary(), user)
      assert row.credit_granted_cents == 1000
      assert row.credit_burned_cents == 700
      assert row.credit_sold_cents == 2500
      assert row.credit_balance_cents == 2800
      assert summary().revenue.credit_sales_cents == 2500
    end

    test "a balance below zero is counted" do
      user = subscriber("solo")
      {:ok, _} = Fountain.Credits.debit(user.id, 5, "burn_turn", idempotency_key: "neg")
      assert summary().credits.negative_balances == 1
      assert row_for(summary(), user).credit_balance_cents == -5
    end

    test "spend by a deleted account stays in the total and out of the rows" do
      rate_card(provider_hourly_cents: %{"sprites" => 100})
      user = subscriber("solo")
      ran(user, "sprites", 10, 10)

      # Deletion nilifies the owner rather than dropping the row (0009); the
      # platform still paid for those hours.
      Repo.update_all(Fountain.Conversations.Sandbox, set: [user_id: nil])

      summary = summary()

      assert summary.tenants |> Enum.map(& &1.active_hours) |> Enum.sum() == 0.0
      assert summary.cost.active_hours == 10.0
      assert summary.unattributed_cost_cents == 1000
    end

    test "the cost total includes providers no tenant row could carry" do
      rate_card(provider_hourly_cents: %{"sprites" => 100})
      user = subscriber("solo")
      ran(user, "sprites", 2, 2)

      summary = summary()

      assert summary.cost.sandbox_cents == 200
      assert summary.cost.active_hours == 2.0
      assert summary.cost.idle_hours == 0.0
    end

    test "period_fraction is bounded and a past period is whole" do
      assert Finance.period_fraction(@period_start, @period_end, @now) == 1.0
      assert Finance.period_fraction(@period_start, @period_end, ~U[2026-04-01 00:00:00Z]) == 0.0

      assert_in_delta Finance.period_fraction(
                        @period_start,
                        @period_end,
                        ~U[2026-05-16 12:00:00Z]
                      ),
                      0.5,
                      0.01
    end
  end

  ## ── the fold /admin shares ────────────────────────────────────────────────

  describe "usage_by_user/1" do
    test "keeps the busy/idle split by_user/1 collapses away" do
      user = subscriber("solo")
      ran(user, "sprites", 10, 3)

      rows = Fountain.Billing.SandboxUsage.attribution(@period_start, @period_end, now: @now)
      usage = Finance.usage_by_user(rows)

      assert %{active_seconds: 36_000, busy_seconds: 10_800, idle_seconds: 25_200} =
               usage[user.id]

      assert [%{provider: "sprites", active: 36_000, busy: 10_800}] = usage[user.id].by_provider
    end

    test "drops the unattributable rows a user map has no key for" do
      user = subscriber("solo")
      ran(user, "sprites", 1, 1)
      Repo.update_all(Fountain.Conversations.Sandbox, set: [user_id: nil])

      rows = Fountain.Billing.SandboxUsage.attribution(@period_start, @period_end, now: @now)

      assert Finance.usage_by_user(rows) == %{}
    end
  end

  ## ── usage_summaries, which /admin's table reads ───────────────────────────

  describe "Billing.usage_summaries/2 turn hours" do
    test "reports turn hours beside sandbox minutes" do
      user = subscriber("solo")
      ran(user, "sprites", 10, 3)

      summary = Billing.usage_summaries(@period_start, @period_end)[user.id]

      assert summary.turn_hours == 3.0
      assert summary.sandbox_minutes == 600.0
    end

    test "excludes runner hours from turn hours but not from sandbox minutes" do
      user = subscriber("solo")
      ran(user, "runner", 4, 4)

      summary = Billing.usage_summaries(@period_start, @period_end)[user.id]

      assert summary.turn_hours == 0.0
      assert summary.sandbox_minutes == 240.0
    end
  end

  ## ── helpers ──────────────────────────────────────────────────────────────

  defp contact(user, opts) do
    agent = insert_agent(user_id: user.id)
    id = System.unique_integer([:positive])

    %Fountain.Team.Contact{}
    |> Fountain.Team.Contact.changeset(%{
      user_id: user.id,
      agent_id: agent.id,
      email_address: if(opts[:email], do: "t#{id}@example.com"),
      email_inbox_id: if(opts[:email], do: "inbox_#{id}"),
      phone_number: if(opts[:phone], do: "+1555000#{rem(id, 10_000)}"),
      phone_number_id: if(opts[:phone], do: "num_#{id}"),
      prompt_from_number: "+15551234567"
    })
    |> Repo.insert!()
  end

  defp message(user, event_type, count, at \\ ~U[2026-05-10 00:00:00Z]) do
    for _ <- 1..count do
      %Fountain.Billing.UsageEvent{}
      |> Fountain.Billing.UsageEvent.changeset(%{
        user_id: user.id,
        event_type: event_type,
        resource_type: "team_contact",
        inserted_at: at
      })
      |> Repo.insert!()
    end
  end
end
