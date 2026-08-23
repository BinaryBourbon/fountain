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
    # Every literal below is deliberate: comparing against
    # Quotas.default_limit() would compare the function under test to its own
    # source and pass for any value (#406). The same reasoning applies to the
    # plan caps — writing them out is what pins the ladder the tiers are sold
    # on, so changing a cap in the catalog has to be a deliberate edit here.

    test "a user with no plan gets the default plan's cap, which is 5" do
      assert Quotas.sandbox_limit(insert_active_user().id) == 5
    end

    test "the cap follows the plan" do
      assert Quotas.sandbox_limit(insert_active_user(plan: "solo").id) == 5
      assert Quotas.sandbox_limit(insert_active_user(plan: "team").id) == 15
      assert Quotas.sandbox_limit(insert_active_user(plan: "scale").id) == 40
    end

    # Grandfathering, in one assertion: the closed plan is priced like Solo
    # and capped like Team, so nobody lost capacity at the changeover.
    test "the closed legacy plan carries Team's cap" do
      assert Quotas.sandbox_limit(insert_active_user(plan: "legacy").id) == 15
    end

    test "an override beats the plan, in either direction" do
      up = insert_active_user(plan: "solo")
      {:ok, up} = Fountain.Accounts.update_sandbox_limit(up, 25)
      assert Quotas.sandbox_limit(up.id) == 25

      down = insert_active_user(plan: "scale")
      {:ok, down} = Fountain.Accounts.update_sandbox_limit(down, 1)
      assert Quotas.sandbox_limit(down.id) == 1
    end

    # Zero is the abuse lever and must survive the "is there an override?"
    # test, which a truthiness check would get wrong.
    test "an override of zero is an override, not an absent one" do
      user = insert_active_user(plan: "scale")
      {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 0)

      assert Quotas.sandbox_limit(user.id) == 0
    end

    test "clearing the override hands the cap back to the plan" do
      user = insert_active_user(plan: "team")
      {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 1)
      {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, nil)

      assert Quotas.sandbox_limit(user.id) == 15
    end

    test "an unknown user falls back to the default plan rather than being unlimited" do
      assert Quotas.sandbox_limit(Ecto.UUID.generate()) == 5
    end
  end

  describe "sandbox_limit_for/1" do
    # The admin table renders it per row and must not query per row, so it has
    # to agree with the querying version for every combination that matters.
    test "agrees with sandbox_limit/1 without touching the database" do
      for plan <- ["solo", "team", "scale", "legacy", nil],
          override <- [nil, 0, 25] do
        user = insert_active_user(plan: plan)
        {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, override)

        assert Quotas.sandbox_limit_for(user) == Quotas.sandbox_limit(user.id),
               "plan=#{inspect(plan)} override=#{inspect(override)}"
      end
    end
  end

  describe "check_sandbox_quota/2" do
    test "passes below the cap" do
      user = insert_active_user()
      insert_sandbox(user_id: user.id, status: "ready")

      assert :ok = Quotas.check_sandbox_quota(user.id)
    end

    test "denies at the cap" do
      user = insert_active_user()
      for _ <- 1..Quotas.default_limit(), do: insert_sandbox(user_id: user.id, status: "ready")

      assert {:error, {:sandbox_quota_exceeded, %{count: 5, limit: 5}}} =
               Quotas.check_sandbox_quota(user.id)
    end

    test "denies above the cap" do
      user = insert_active_user()
      for _ <- 1..7, do: insert_sandbox(user_id: user.id, status: "ready")

      assert {:error, {:sandbox_quota_exceeded, %{count: 7, limit: 5}}} =
               Quotas.check_sandbox_quota(user.id)
    end

    test "one tenant at its cap does not affect another" do
      user = insert_active_user()
      other = insert_active_user()
      for _ <- 1..5, do: insert_sandbox(user_id: user.id, status: "ready")

      assert {:error, _} = Quotas.check_sandbox_quota(user.id)
      assert :ok = Quotas.check_sandbox_quota(other.id)
    end

    test "exclude: lets a replacement through at exactly the cap" do
      user = insert_active_user()
      [replacing | _] = for _ <- 1..5, do: insert_sandbox(user_id: user.id, status: "ready")

      assert {:error, _} = Quotas.check_sandbox_quota(user.id)
      assert :ok = Quotas.check_sandbox_quota(user.id, exclude: replacing.id)
    end

    test "a raised cap admits more" do
      user = insert_active_user()
      for _ <- 1..5, do: insert_sandbox(user_id: user.id, status: "ready")
      assert {:error, _} = Quotas.check_sandbox_quota(user.id)

      {:ok, _} = Fountain.Accounts.update_sandbox_limit(user, 10)
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
      for _ <- 1..5, do: insert_sandbox(user_id: user.id, status: "ready")

      assert {:error, {:sandbox_quota_exceeded, %{count: 5, limit: 5}}} =
               Quotas.with_sandbox_reservation(user.id, fn ->
                 flunk("fun must not run once the quota refuses")
               end)

      assert Quotas.active_sandbox_count(user.id) == 5
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
      sandboxes = for _ <- 1..5, do: insert_sandbox(user_id: user.id, status: "ready")
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
      for _ <- 1..5, do: insert_sandbox(user_id: user.id, status: "ready")

      err =
        assert_raise Quotas.QuotaExceededError, fn ->
          Quotas.check_sandbox_quota!(user.id)
        end

      assert err.count == 5
      assert err.limit == 5
      assert err.message =~ "5/5"
    end
  end
end
