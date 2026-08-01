defmodule Fountain.QuotasTest do
  use Fountain.DataCase, async: true

  alias Fountain.Quotas

  describe "active_sandbox_count/2" do
    test "counts only the given tenant's sandboxes" do
      user = insert_verified_user()
      other = insert_verified_user()

      insert_sandbox(user_id: user.id, status: "ready")
      insert_sandbox(user_id: user.id, status: "pending")
      insert_sandbox(user_id: other.id, status: "ready")

      assert Quotas.active_sandbox_count(user.id) == 2
      assert Quotas.active_sandbox_count(other.id) == 1
    end

    test "pending and starting count — a sprite bills from provisioning, not from ready" do
      user = insert_verified_user()

      for status <- ~w(pending starting ready) do
        insert_sandbox(user_id: user.id, status: status)
      end

      assert Quotas.active_sandbox_count(user.id) == 3
    end

    test "terminated and failed do not count" do
      user = insert_verified_user()

      insert_sandbox(user_id: user.id, status: "ready")
      insert_sandbox(user_id: user.id, status: "terminated")
      insert_sandbox(user_id: user.id, status: "failed")

      assert Quotas.active_sandbox_count(user.id) == 1
    end

    test "exclude: leaves the named sandbox out" do
      user = insert_verified_user()
      keep = insert_sandbox(user_id: user.id, status: "ready")
      insert_sandbox(user_id: user.id, status: "ready")

      assert Quotas.active_sandbox_count(user.id) == 2
      assert Quotas.active_sandbox_count(user.id, exclude: keep.id) == 1
    end

    test "is zero for a tenant with no sandboxes" do
      assert Quotas.active_sandbox_count(insert_verified_user().id) == 0
    end
  end

  describe "sandbox_limit/1" do
    test "defaults to 5" do
      assert Quotas.sandbox_limit(insert_verified_user().id) == Quotas.default_limit()
    end

    test "reflects an admin-adjusted cap" do
      user = insert_verified_user()
      {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 25)

      assert Quotas.sandbox_limit(user.id) == 25
    end

    test "an unknown user falls back to the default rather than being unlimited" do
      assert Quotas.sandbox_limit(Ecto.UUID.generate()) == Quotas.default_limit()
    end
  end

  describe "check_sandbox_quota/2" do
    test "passes below the cap" do
      user = insert_verified_user()
      insert_sandbox(user_id: user.id, status: "ready")

      assert :ok = Quotas.check_sandbox_quota(user.id)
    end

    test "denies at the cap" do
      user = insert_verified_user()
      for _ <- 1..Quotas.default_limit(), do: insert_sandbox(user_id: user.id, status: "ready")

      assert {:error, {:sandbox_quota_exceeded, %{count: 5, limit: 5}}} =
               Quotas.check_sandbox_quota(user.id)
    end

    test "denies above the cap" do
      user = insert_verified_user()
      for _ <- 1..7, do: insert_sandbox(user_id: user.id, status: "ready")

      assert {:error, {:sandbox_quota_exceeded, %{count: 7, limit: 5}}} =
               Quotas.check_sandbox_quota(user.id)
    end

    test "one tenant at its cap does not affect another" do
      user = insert_verified_user()
      other = insert_verified_user()
      for _ <- 1..5, do: insert_sandbox(user_id: user.id, status: "ready")

      assert {:error, _} = Quotas.check_sandbox_quota(user.id)
      assert :ok = Quotas.check_sandbox_quota(other.id)
    end

    test "exclude: lets a replacement through at exactly the cap" do
      user = insert_verified_user()
      [replacing | _] = for _ <- 1..5, do: insert_sandbox(user_id: user.id, status: "ready")

      assert {:error, _} = Quotas.check_sandbox_quota(user.id)
      assert :ok = Quotas.check_sandbox_quota(user.id, exclude: replacing.id)
    end

    test "a raised cap admits more" do
      user = insert_verified_user()
      for _ <- 1..5, do: insert_sandbox(user_id: user.id, status: "ready")
      assert {:error, _} = Quotas.check_sandbox_quota(user.id)

      {:ok, _} = Fountain.Accounts.update_sandbox_limit(user, 10)
      assert :ok = Quotas.check_sandbox_quota(user.id)
    end

    test "a cap of zero denies everything — the lever for shutting off abuse" do
      user = insert_verified_user()
      {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 0)

      assert {:error, {:sandbox_quota_exceeded, %{count: 0, limit: 0}}} =
               Quotas.check_sandbox_quota(user.id)
    end
  end

  describe "check_sandbox_quota!/2" do
    test "returns :ok below the cap" do
      assert :ok = Quotas.check_sandbox_quota!(insert_verified_user().id)
    end

    test "raises at the cap with the counts in the message" do
      user = insert_verified_user()
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
