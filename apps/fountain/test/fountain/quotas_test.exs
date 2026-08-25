defmodule Fountain.QuotasTest do
  use Fountain.DataCase, async: true

  alias Fountain.Quotas

  describe "active_sandbox_count/2" do
    test "counts only the given tenant's sandboxes" do
      user = insert_active_user()
      other = insert_active_user()

      insert_sandbox(user_id: user.id, status: "ready")
      insert_sandbox(user_id: user.id, status: "pending")
      insert_sandbox(user_id: other.id, status: "ready")

      assert Quotas.active_sandbox_count(user.id) == 2
      assert Quotas.active_sandbox_count(other.id) == 1
    end

    test "pending and starting count — a sprite bills from provisioning, not from ready" do
      user = insert_active_user()

      for status <- ~w(pending starting ready) do
        insert_sandbox(user_id: user.id, status: status)
      end

      assert Quotas.active_sandbox_count(user.id) == 3
    end

    test "terminated and failed do not count" do
      user = insert_active_user()

      insert_sandbox(user_id: user.id, status: "ready")
      insert_sandbox(user_id: user.id, status: "terminated")
      insert_sandbox(user_id: user.id, status: "failed")

      assert Quotas.active_sandbox_count(user.id) == 1
    end

    test "suspended does not count — a parked sprite is not compute (0017)" do
      # Otherwise five abandoned conversations would permanently lock a
      # default-cap tenant out of starting anything. Waking a suspended
      # sandbox re-runs the gate (Conversations.wake_suspended_sandbox/2).
      user = insert_active_user()

      insert_sandbox(user_id: user.id, status: "ready")
      insert_sandbox(user_id: user.id, status: "suspended")

      assert Quotas.active_sandbox_count(user.id) == 1
    end

    test "exclude: leaves the named sandbox out" do
      user = insert_active_user()
      keep = insert_sandbox(user_id: user.id, status: "ready")
      insert_sandbox(user_id: user.id, status: "ready")

      assert Quotas.active_sandbox_count(user.id) == 2
      assert Quotas.active_sandbox_count(user.id, exclude: keep.id) == 1
    end

    test "is zero for a tenant with no sandboxes" do
      assert Quotas.active_sandbox_count(insert_active_user().id) == 0
    end
  end

  describe "sandbox_limit/1" do
    # The balance rule (ADR 0031): clamp(balance / reserve, floor, ceiling),
    # with reserve $2, floor 2 and ceiling 20 in test config.
    defp with_balance(user, cents) do
      {:ok, _} =
        Fountain.Credits.grant(user.id, cents, "purchase", idempotency_key: "q-#{user.id}")

      user
    end

    # Every verified account holds the $10 opening grant: five sandboxes.
    test "the opening grant funds five; nothing in the balance funds the floor" do
      user = insert_active_user()
      assert Quotas.sandbox_limit(user.id) == 5

      {:ok, _} =
        Fountain.Credits.debit(user.id, 1_000, "burn_turn", idempotency_key: "drain-#{user.id}")

      assert Quotas.sandbox_limit(user.id) == 2
    end

    test "the cap follows the balance, one sandbox per reserve" do
      assert Quotas.sandbox_limit(with_balance(insert_active_user(), 1_000).id) == 10
      assert Quotas.sandbox_limit(with_balance(insert_active_user(), 1_199).id) == 10
      assert Quotas.sandbox_limit(with_balance(insert_active_user(), 100).id) == 5
    end

    test "the ceiling bounds it however large the balance" do
      assert Quotas.sandbox_limit(with_balance(insert_active_user(), 100_000).id) == 20
    end

    # Billing off is covered in credits_enforcement_test (async: false): it
    # flips global config, which an async module must not do.
    test "a comped account gets the ceiling" do
      {:ok, comped} = Fountain.Billing.comp_account(insert_active_user())
      assert Quotas.sandbox_limit(comped.id) == 20
    end

    test "an override beats the balance, in either direction" do
      up = insert_active_user()
      {:ok, up} = Fountain.Accounts.update_sandbox_limit(up, 25)
      assert Quotas.sandbox_limit(up.id) == 25

      down = with_balance(insert_active_user(), 100_000)
      {:ok, down} = Fountain.Accounts.update_sandbox_limit(down, 1)
      assert Quotas.sandbox_limit(down.id) == 1
    end

    test "an override of zero is an override, not an absent one" do
      user = with_balance(insert_active_user(), 100_000)
      {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 0)
      assert Quotas.sandbox_limit(user.id) == 0
    end

    test "clearing the override hands the cap back to the balance" do
      user = with_balance(insert_active_user(), 1_000)
      {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 1)
      {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, nil)
      assert Quotas.sandbox_limit(user.id) == 10
    end

    test "an unknown user gets the floor rather than being unlimited" do
      assert Quotas.sandbox_limit(Ecto.UUID.generate()) == 2
    end
  end

  describe "the fleet ceiling" do
    test "refuses the reservation once every slot is live, whoever holds them" do
      cfg = Application.get_env(:fountain, :sandboxes)
      on_exit(fn -> Application.put_env(:fountain, :sandboxes, cfg) end)
      Application.put_env(:fountain, :sandboxes, Keyword.put(cfg, :fleet_ceiling, 2))

      other = insert_active_user()
      insert_sandbox(user_id: other.id, status: "ready")
      insert_sandbox(user_id: other.id, status: "starting")

      user = insert_active_user()
      {:ok, _} = Fountain.Credits.grant(user.id, 1_000, "purchase", idempotency_key: "fleet")

      assert {:error, :fleet_full} = Quotas.check_fleet_ceiling()

      assert {:error, :fleet_full} =
               Quotas.with_sandbox_reservation(user.id, [], fn -> {:ok, :never} end)

      # A suspended sandbox is not compute and does not hold a slot.
      Fountain.Repo.update_all(Fountain.Conversations.Sandbox, set: [status: "suspended"])
      assert :ok = Quotas.check_fleet_ceiling()
      assert {:ok, :ran} = Quotas.with_sandbox_reservation(user.id, [], fn -> {:ok, :ran} end)
    end
  end

  describe "sandbox_limit_for/1" do
    # The admin table renders it per row and must not query per row, so it has
    # to agree with the querying version for every combination that matters.
    test "agrees with sandbox_limit/1 without touching the database" do
      for cents <- [0, 1_000, 5_000, 100_000],
          override <- [nil, 0, 25] do
        user = insert_active_user()

        if cents > 0,
          do:
            {:ok, _} =
              Fountain.Credits.grant(user.id, cents, "purchase", idempotency_key: "q-#{user.id}")

        {:ok, user} =
          Fountain.Accounts.update_sandbox_limit(Fountain.Repo.reload!(user), override)

        assert Quotas.sandbox_limit_for(user) == Quotas.sandbox_limit(user.id),
               "cents=#{cents} override=#{inspect(override)}"
      end
    end
  end

  describe "check_sandbox_quota/2" do
    test "passes below the cap" do
      user = insert_active_user()
      insert_sandbox(user_id: user.id, status: "ready")

      assert :ok = Quotas.check_sandbox_quota(user.id)
    end

    # Unlike the block above, these derive the cap rather than writing it out:
    # what is under test is the counting and the exclusion, not which number
    # the catalog holds. Pinning it here only makes every future cap change
    # break six unrelated tests.
    test "denies at the cap" do
      user = insert_active_user()
      limit = Quotas.sandbox_limit(user.id)
      for _ <- 1..limit, do: insert_sandbox(user_id: user.id, status: "ready")

      assert {:error, {:sandbox_quota_exceeded, %{count: ^limit, limit: ^limit}}} =
               Quotas.check_sandbox_quota(user.id)
    end

    test "denies above the cap" do
      user = insert_active_user()
      limit = Quotas.sandbox_limit(user.id)
      over = limit + 2
      for _ <- 1..over, do: insert_sandbox(user_id: user.id, status: "ready")

      assert {:error, {:sandbox_quota_exceeded, %{count: ^over, limit: ^limit}}} =
               Quotas.check_sandbox_quota(user.id)
    end

    test "one tenant at its cap does not affect another" do
      user = insert_active_user()
      other = insert_active_user()

      for _ <- 1..Quotas.sandbox_limit(user.id),
          do: insert_sandbox(user_id: user.id, status: "ready")

      assert {:error, _} = Quotas.check_sandbox_quota(user.id)
      assert :ok = Quotas.check_sandbox_quota(other.id)
    end

    test "exclude: lets a replacement through at exactly the cap" do
      user = insert_active_user()

      [replacing | _] =
        for _ <- 1..Quotas.sandbox_limit(user.id),
            do: insert_sandbox(user_id: user.id, status: "ready")

      assert {:error, _} = Quotas.check_sandbox_quota(user.id)
      assert :ok = Quotas.check_sandbox_quota(user.id, exclude: replacing.id)
    end

    test "a raised cap admits more" do
      user = insert_active_user()
      limit = Quotas.sandbox_limit(user.id)
      for _ <- 1..limit, do: insert_sandbox(user_id: user.id, status: "ready")
      assert {:error, _} = Quotas.check_sandbox_quota(user.id)

      {:ok, _} = Fountain.Accounts.update_sandbox_limit(user, limit + 5)
      assert :ok = Quotas.check_sandbox_quota(user.id)
    end

    test "a cap of zero denies everything — the lever for shutting off abuse" do
      user = insert_active_user()
      {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 0)

      assert {:error, {:sandbox_quota_exceeded, %{count: 0, limit: 0}}} =
               Quotas.check_sandbox_quota(user.id)
    end
  end

  describe "with_sandbox_reservation/3 (#330)" do
    # The cross-connection serialization itself rests on
    # pg_advisory_xact_lock and cannot be observed under the SQL sandbox
    # (every allowed process shares one transaction). What these pin is the
    # transactional composition: check + insert commit or roll back as one.

    alias Fountain.Quotas

    test "creates the row when below the cap" do
      user = insert_active_user()

      assert {:ok, sandbox} =
               Quotas.with_sandbox_reservation(user.id, fn ->
                 {:ok, insert_sandbox(user_id: user.id, status: "pending")}
               end)

      assert Quotas.active_sandbox_count(user.id) == 1
      assert sandbox.user_id == user.id
    end

    test "refuses at the cap and creates nothing" do
      user = insert_active_user()
      limit = Quotas.sandbox_limit(user.id)
      for _ <- 1..limit, do: insert_sandbox(user_id: user.id, status: "ready")

      assert {:error, {:sandbox_quota_exceeded, %{count: ^limit, limit: ^limit}}} =
               Quotas.with_sandbox_reservation(user.id, fn ->
                 flunk("fun must not run once the quota refuses")
               end)

      assert Quotas.active_sandbox_count(user.id) == limit
    end

    test "a failure in fun rolls the reservation back" do
      user = insert_active_user()

      assert {:error, :boom} =
               Quotas.with_sandbox_reservation(user.id, fn ->
                 insert_sandbox(user_id: user.id, status: "pending")
                 {:error, :boom}
               end)

      # The row created inside the reservation is gone with it.
      assert Quotas.active_sandbox_count(user.id) == 0
    end

    test "honours the :exclude option the wake path needs" do
      user = insert_active_user()

      sandboxes =
        for _ <- 1..Quotas.sandbox_limit(user.id),
            do: insert_sandbox(user_id: user.id, status: "ready")

      replacing = hd(sandboxes)

      assert {:ok, _} =
               Quotas.with_sandbox_reservation(user.id, [exclude: replacing.id], fn ->
                 {:ok, insert_sandbox(user_id: user.id, status: "pending")}
               end)
    end
  end

  describe "check_sandbox_quota!/2" do
    test "returns :ok below the cap" do
      assert :ok = Quotas.check_sandbox_quota!(insert_active_user().id)
    end

    test "raises at the cap with the counts in the message" do
      user = insert_active_user()
      limit = Quotas.sandbox_limit(user.id)
      for _ <- 1..limit, do: insert_sandbox(user_id: user.id, status: "ready")

      err =
        assert_raise Quotas.QuotaExceededError, fn ->
          Quotas.check_sandbox_quota!(user.id)
        end

      assert err.count == limit
      assert err.limit == limit
      assert err.message =~ "#{limit}/#{limit}"
    end
  end
end
