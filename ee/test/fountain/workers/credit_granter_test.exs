defmodule Fountain.Workers.CreditGranterTest do
  @moduledoc """
  Expiry (ADR 0030 decision 2, ADR 0031): a grant past its date loses what
  its lot still holds, once, and purchased money survives.
  """

  use Fountain.DataCase, async: true

  alias Fountain.Credits
  alias Fountain.Workers.CreditGranter

  @expires ~U[2026-09-01 00:00:00Z]
  @day_before ~U[2026-08-31 00:00:00Z]
  @day_after ~U[2026-09-01 00:00:01Z]

  test "no-ops with billing off" do
    user = insert_empty_user()

    {:ok, _} =
      Credits.grant(user.id, 1000, "grant_trial", idempotency_key: "g", expires_at: @expires)

    Application.put_env(:fountain, :billing_enabled, false)
    on_exit(fn -> Application.put_env(:fountain, :billing_enabled, true) end)
    assert %{expired: 0} = CreditGranter.run(now: @day_after)
  end

  test "an unspent grant expires in full, once; a spent one expires nothing" do
    full = insert_empty_user()
    spent = insert_empty_user()

    {:ok, _} =
      Credits.grant(full.id, 1000, "grant_trial", idempotency_key: "f", expires_at: @expires)

    {:ok, _} =
      Credits.grant(spent.id, 1000, "grant_trial", idempotency_key: "s", expires_at: @expires)

    {:ok, _} = Credits.debit(spent.id, 1000, "burn_turn", idempotency_key: "spent-all")

    assert %{expired: 0} = CreditGranter.run(now: @day_before)
    assert %{expired: 1} = CreditGranter.run(now: @day_after)
    assert Credits.balance(full.id) == 0
    assert Credits.balance(spent.id) == 0

    x = Credits.list_entries(full.id) |> Enum.find(&(&1.reason == "expire"))
    assert x.amount_cents == -1000 and x.metadata["granted_cents"] == 1000

    assert %{expired: 0} = CreditGranter.run(now: DateTime.add(@day_after, 86_400, :second))
  end

  test "purchased money survives an expiry; only the grant's remainder goes" do
    user = insert_empty_user()

    {:ok, _} =
      Credits.grant(user.id, 1000, "grant_trial", idempotency_key: "g", expires_at: @expires)

    {:ok, _} = Credits.grant(user.id, 2500, "purchase", idempotency_key: "p")
    {:ok, _} = Credits.debit(user.id, 600, "burn_turn", idempotency_key: "b")

    assert %{expired: 1} = CreditGranter.run(now: @day_after)
    assert Credits.balance(user.id) == 2500
  end

  test "a negative balance has nothing to expire" do
    user = insert_empty_user()

    {:ok, _} =
      Credits.grant(user.id, 1000, "grant_trial", idempotency_key: "g", expires_at: @expires)

    {:ok, _} = Credits.debit(user.id, 1200, "burn_turn", idempotency_key: "over")
    assert %{expired: 0} = CreditGranter.run(now: @day_after)
    assert Credits.balance(user.id) == -200
  end

  test "perform/1 is a thin shell over run/1" do
    assert :ok = CreditGranter.perform(%Oban.Job{args: %{}})
  end
end
