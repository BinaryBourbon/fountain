defmodule Fountain.QuotasFleetCeilingTest do
  # `async: false` on purpose: the ceiling is read from application config, and
  # the only way to lower it here is `Application.put_env`, which every other
  # module sees. Run async, this raced `sandbox_mode_test` in the same CI
  # partition and its third launch got `:fleet_full` (fountain #1205, twice).
  use Fountain.DataCase, async: false

  alias Fountain.Quotas

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
end
