defmodule Fountain.CreditsTest do
  @moduledoc """
  The credit ledger (ADR 0030, #1086 phase 2 step 1).

  What is tested hard: the cache moves with the row and only with the row,
  posting a key twice writes nothing, the sign follows the reason, and the
  two short-circuits answer before the balance is read.
  """

  use Fountain.DataCase, async: true

  alias Fountain.Accounts.User
  alias Fountain.Audit
  alias Fountain.Credits
  alias Fountain.Credits.LedgerEntry
  alias Fountain.Repo

  defp reload(user), do: Repo.get!(User, user.id)

  describe "grant/4 and debit/4" do
    test "a grant moves the cached balance by exactly the row" do
      user = insert_empty_user()
      assert Credits.balance(user) == 0

      assert {:ok, %LedgerEntry{amount_cents: 1000, reason: "grant_tier"}} =
               Credits.grant(user.id, 1000, "grant_tier", idempotency_key: "t1")

      assert Credits.balance(reload(user)) == 1000
      assert Credits.balance(user.id) == 1000
    end

    test "a debit is stored negative and may take the balance below zero" do
      user = insert_empty_user()
      {:ok, _} = Credits.grant(user.id, 100, "purchase", idempotency_key: "p1")

      assert {:ok, %LedgerEntry{amount_cents: -250}} =
               Credits.debit(user.id, 250, "burn_turn", idempotency_key: "b1")

      assert Credits.balance(reload(user)) == -150
    end

    test "posting the same idempotency key twice writes nothing" do
      user = insert_empty_user()
      {:ok, first} = Credits.grant(user.id, 500, "purchase", idempotency_key: "dup")

      assert {:ok, :duplicate, ^first} =
               Credits.grant(user.id, 999, "purchase", idempotency_key: "dup")

      assert Credits.balance(reload(user)) == 500
      assert length(Credits.list_entries(user.id)) == 1
    end

    test "the sign follows the reason" do
      user = insert_empty_user()

      assert {:error, %Ecto.Changeset{} = cs} =
               Credits.post(user.id, -5, "grant_tier", idempotency_key: "neg-grant")

      assert "a credit must be positive" in errors_on(cs).amount_cents

      assert {:error, %Ecto.Changeset{} = cs} =
               Credits.post(user.id, 5, "burn_turn", idempotency_key: "pos-burn")

      assert "a debit must be negative" in errors_on(cs).amount_cents

      assert {:error, %Ecto.Changeset{} = cs} =
               Credits.post(user.id, 0, "purchase", idempotency_key: "zero")

      assert "must not be zero" in errors_on(cs).amount_cents

      assert {:error, %Ecto.Changeset{}} =
               Credits.post(user.id, 5, "made_up", idempotency_key: "bad-reason")

      assert Credits.balance(reload(user)) == 0
    end

    test "a rejected row leaves no audit event, a posted one leaves exactly one" do
      user = insert_empty_user()
      {:error, _} = Credits.post(user.id, 0, "purchase", idempotency_key: "z")

      assert Audit.list_recent_for_user(user.id, 50) |> Enum.filter(&(&1.action =~ "credit.")) ==
               []

      {:ok, entry} = Credits.grant(user.id, 1000, "grant_trial", idempotency_key: "g")
      {:ok, :duplicate, _} = Credits.grant(user.id, 1000, "grant_trial", idempotency_key: "g")

      [event] =
        Audit.list_recent_for_user(user.id, 50) |> Enum.filter(&(&1.action == "credit.granted"))

      assert event.resource_type == "credit_ledger"
      assert event.resource_id == entry.id
      assert event.metadata["amount_cents"] == 1000
      assert event.metadata["reason"] == "grant_trial"
      refute Map.has_key?(event.metadata, "balance")
    end

    test "each reason family has its own audit action" do
      user = insert_empty_user()
      {:ok, _} = Credits.grant(user.id, 10, "purchase", idempotency_key: "a1")
      {:ok, _} = Credits.debit(user.id, 1, "burn_rent", idempotency_key: "a2")
      {:ok, _} = Credits.debit(user.id, 1, "expire", idempotency_key: "a3")
      {:ok, _} = Credits.debit(user.id, 1, "clawback_refund", idempotency_key: "a4")

      actions = Audit.list_recent_for_user(user.id, 50) |> Enum.map(& &1.action)

      for a <- ~w(credit.purchased credit.burned credit.expired credit.clawed_back) do
        assert a in actions
      end
    end

    test "a grant can carry an expiry and a resource reference" do
      user = insert_empty_user()
      at = ~U[2026-09-01 00:00:00Z]

      {:ok, entry} =
        Credits.grant(user.id, 1000, "grant_tier",
          idempotency_key: "exp",
          expires_at: at,
          resource_type: "billing_period",
          resource_id: "2026-08"
        )

      assert entry.expires_at == at
      assert entry.resource_id == "2026-08"
    end

    test "concurrent posts of one key move the balance once" do
      user = insert_empty_user()

      results =
        1..8
        |> Task.async_stream(
          fn _ ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), self())
            Credits.grant(user.id, 100, "purchase", idempotency_key: "race")
          end,
          max_concurrency: 8
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.count(results, &match?({:ok, %LedgerEntry{}}, &1)) == 1
      assert Enum.count(results, &match?({:ok, :duplicate, _}, &1)) == 7
      assert Credits.balance(reload(user)) == 100
    end
  end

  describe "check_balance/1" do
    test "answers ok with billing off before reading anything" do
      user = insert_empty_user()
      Application.put_env(:fountain, :billing_enabled, false)
      on_exit(fn -> Application.put_env(:fountain, :billing_enabled, true) end)
      assert :ok = Credits.check_balance(user)
      assert :ok = Credits.check_balance(user.id)
    end

    test "a comped tenant is never short of credits" do
      user = insert_empty_user()
      {:ok, user} = Fountain.Billing.comp_account(user)
      assert user.comped
      assert :ok = Credits.check_balance(user)
      assert :ok = Credits.check_balance(user.id)
    end

    test "zero and negative are insufficient, positive is ok" do
      user = insert_empty_user()
      assert {:error, :insufficient_credits} = Credits.check_balance(user)
      {:ok, _} = Credits.grant(user.id, 1, "purchase", idempotency_key: "one")
      assert :ok = Credits.check_balance(user.id)
      {:ok, _} = Credits.debit(user.id, 2, "burn_turn", idempotency_key: "two")
      assert {:error, :insufficient_credits} = Credits.check_balance(user.id)
    end
  end

  describe "recompute_balance/1 and drift/0" do
    test "repairs a cache that disagrees with the ledger" do
      user = insert_empty_user()
      {:ok, _} = Credits.grant(user.id, 300, "purchase", idempotency_key: "r1")
      {:ok, _} = Credits.debit(user.id, 120, "burn_turn", idempotency_key: "r2")

      Repo.update_all(from(u in User, where: u.id == ^user.id), set: [credit_balance_cents: 999])
      assert [{id, 999, 180}] = Credits.drift() |> Enum.filter(&(elem(&1, 0) == user.id))
      assert id == user.id

      assert 180 = Credits.recompute_balance(user.id)
      assert Credits.balance(reload(user)) == 180
      refute Enum.any?(Credits.drift(), &(elem(&1, 0) == user.id))
    end
  end

  describe "prices" do
    test "turn cost rounds to the nearest cent at the configured rate" do
      assert Credits.price_card().turn_hour == 25
      assert Credits.turn_cost_cents(3600) == 25
      assert Credits.turn_cost_cents(0) == 0
      # 72 s at 25c/h = 0.5c, rounds up; 71 s rounds down.
      assert Credits.turn_cost_cents(72) == 1
      assert Credits.turn_cost_cents(71) == 0
      assert Credits.turn_cost_cents(10 * 3600) == 250
    end

    test "comms prices are unset by default and the packs ascend" do
      card = Credits.price_card()
      assert card.number_month == nil and card.inbox_month == nil
      assert card.email_message == nil and card.sms_message == nil
      assert Credits.packs() == [1_000, 2_500, 10_000]
    end

    test "format_cents" do
      assert Credits.format_cents(1240) == "$12.40"
      assert Credits.format_cents(5) == "$0.05"
      assert Credits.format_cents(-150) == "-$1.50"
      assert Credits.format_cents(0) == "$0.00"
    end
  end

  describe "lots" do
    defp remaining(entry), do: Credits.unspent_of(entry, 0)

    test "a debit consumes the earliest-expiring lot first, then purchased money" do
      user = insert_empty_user()

      {:ok, late} =
        Credits.grant(user.id, 1000, "grant_tier",
          idempotency_key: "late",
          expires_at: ~U[2099-02-01 00:00:00Z]
        )

      {:ok, bought} = Credits.grant(user.id, 500, "purchase", idempotency_key: "bought")

      {:ok, early} =
        Credits.grant(user.id, 1000, "grant_tier",
          idempotency_key: "early",
          expires_at: ~U[2099-01-01 00:00:00Z]
        )

      {:ok, _} = Credits.debit(user.id, 1200, "burn_turn", idempotency_key: "b1")
      assert remaining(early) == 0
      assert remaining(late) == 800
      assert remaining(bought) == 500

      {:ok, _} = Credits.debit(user.id, 1000, "burn_turn", idempotency_key: "b2")
      assert remaining(late) == 0
      assert remaining(bought) == 300
      assert Credits.balance(user.id) == 300
    end

    test "a named lot is consumed first, and debt beyond the lots is carried by the balance" do
      user = insert_empty_user()

      {:ok, a} =
        Credits.grant(user.id, 100, "grant_tier",
          idempotency_key: "a",
          expires_at: ~U[2099-01-01 00:00:00Z]
        )

      {:ok, b} = Credits.grant(user.id, 100, "purchase", idempotency_key: "b")

      {:ok, _} = Credits.debit(user.id, 60, "clawback_refund", idempotency_key: "c", lot_id: b.id)
      assert remaining(a) == 100
      assert remaining(b) == 40

      {:ok, _} = Credits.debit(user.id, 200, "burn_turn", idempotency_key: "d")
      assert remaining(a) == 0 and remaining(b) == 0
      assert Credits.balance(user.id) == -60
    end

    test "a credit posted into debt repays it first" do
      user = insert_empty_user()
      {:ok, _} = Credits.debit(user.id, 30, "burn_turn", idempotency_key: "debt")
      {:ok, lot} = Credits.grant(user.id, 100, "purchase", idempotency_key: "p")
      assert remaining(lot) == 70
      assert Credits.balance(user.id) == 70
    end

    test "rebuild_lots replays the ledger to the same lots the live path wrote" do
      user = insert_empty_user()

      {:ok, g} =
        Credits.grant(user.id, 1000, "grant_tier",
          idempotency_key: "g",
          expires_at: ~U[2099-01-01 00:00:00Z]
        )

      {:ok, p} = Credits.grant(user.id, 500, "purchase", idempotency_key: "p")
      {:ok, _} = Credits.debit(user.id, 1200, "burn_turn", idempotency_key: "b")

      {:ok, _} =
        Credits.debit(user.id, 100, "clawback_refund",
          idempotency_key: "c",
          lot_id: p.id,
          metadata: %{"purchase_id" => p.id}
        )

      before = {remaining(g), remaining(p)}

      Repo.update_all(Fountain.Credits.LedgerEntry, set: [remaining_cents: nil])
      assert 2 = Credits.rebuild_lots(user.id)
      assert {remaining(g), remaining(p)} == before
      assert before == {0, 200}
    end
  end
end
