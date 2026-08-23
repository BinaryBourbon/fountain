defmodule FountainWeb.AdminBillingLiveTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.Accounts

  defp insert_admin(overrides \\ %{}) do
    user = insert_active_user(overrides)
    {:ok, admin} = Accounts.update_user_role(user, "admin")
    admin
  end

  describe "AdminLive.Billing — billing overview section" do
    test "renders tiles, status chips linking to the filtered table, and events", %{conn: conn} do
      admin = insert_admin()

      Fountain.Repo.update!(
        Ecto.Changeset.change(insert_active_user(), subscription_status: "active")
      )

      Fountain.Repo.insert_all("stripe_events", [
        %{
          id: "evt_admin_test",
          type: "checkout.session.completed",
          inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }
      ])

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin/billing")

      assert html =~ "MRR"
      assert html =~ "Trials ending in 7 days"
      assert html =~ "Conversions this month"
      # MRR is priced from the plan catalog now, so it is a real number even
      # with no price env var set — and the tile leads to the finance panel.
      assert html =~ "active subscriptions, per plan"
      assert html =~ "/admin/finance"
      # status chips link into the filtered user table from #285
      assert html =~ "/admin/users?status=active"
      assert html =~ "/admin/users?status=past_due"
      # recent webhook events listed
      assert html =~ "evt_admin_test"
      assert html =~ "checkout.session.completed"
      # no failures → the quiet all-clear, not the red alert (#501)
      assert html =~ "No unresolved webhook failures"
    end

    test "unresolved webhook failures render as a red alert (#501)", %{conn: conn} do
      admin = insert_admin()

      Fountain.Billing.record_webhook_failure(
        %Stripe.Event{id: "evt_admin_fail", type: "invoice.paid"},
        :database_unavailable
      )

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin/billing")

      assert html =~ "webhook event is failing"
      assert html =~ "evt_admin_fail"
      assert html =~ "database_unavailable"
      refute html =~ "No unresolved webhook failures"
    end
  end
end
