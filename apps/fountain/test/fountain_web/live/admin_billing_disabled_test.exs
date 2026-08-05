defmodule FountainWeb.AdminBillingDisabledTest do
  @moduledoc """
  The admin panel on a billing-disabled instance (#481): no billing tiles,
  filters, sorts or Stripe actions — while the user-management half (verified
  filter, suspension, deletion, sandbox limits) stays fully present.

  async: false because these flip the global :billing_enabled app env, the
  same pattern as `Fountain.SelfHostSwitchesTest`.
  """

  use FountainWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fountain.Accounts

  defp insert_admin(overrides \\ %{}) do
    user = insert_verified_user(overrides)
    {:ok, admin} = Accounts.update_user_role(user, "admin")
    admin
  end

  defp with_billing_disabled(fun) do
    previous = Application.get_env(:fountain, :billing_enabled)
    Application.put_env(:fountain, :billing_enabled, false)

    try do
      fun.()
    after
      Application.put_env(:fountain, :billing_enabled, previous)
    end
  end

  describe "/admin" do
    test "renders no billing tiles, filters, sorts or actions", %{conn: conn} do
      admin = insert_admin()
      insert_verified_user()

      with_billing_disabled(fn ->
        {:ok, _lv, html} = live(login_user(conn, admin), ~p"/admin")

        refute html =~ "MRR"
        refute html =~ "Trials ending in 7 days"
        refute html =~ "Conversions this month"
        refute html =~ "Recent webhook events"
        # Funnel keeps its four real stages; the subscribed tile is noise here.
        refute html =~ "Subscribed"
        # No subscription-status filter, no trial_end sort (the Billing column
        # header carries it), no Stripe-backed row actions.
        refute html =~ ~s(name="status")
        refute html =~ "sort=trial_end"
        refute html =~ ~s(phx-submit="extend_trial")
        refute html =~ ~s(phx-click="toggle_comp")
        refute html =~ ~s(phx-click="resync_stripe")
        refute html =~ "dashboard.stripe.com"
      end)
    end

    test "user management is fully present", %{conn: conn} do
      admin = insert_admin()
      other = insert_verified_user()

      with_billing_disabled(fn ->
        {:ok, _lv, html} = live(login_user(conn, admin), ~p"/admin")

        assert html =~ other.email
        assert html =~ ~s(name="verified")
        assert html =~ ~s(phx-click="toggle_suspend")
        assert html =~ ~s(phx-click="delete_user")
        assert html =~ ~s(phx-submit="set_sandbox_limit")
        assert html =~ "Registered"
        assert html =~ "Activated"
      end)
    end

    test "hand-sent extend_trial and toggle_comp events are refused before Stripe",
         %{conn: conn} do
      # The buttons are hidden, but an event can still be sent by hand (#399's
      # lesson) — and both talk to Stripe, which this instance does not have.
      admin = insert_admin()
      target = insert_verified_user()

      with_billing_disabled(fn ->
        {:ok, lv, _html} = live(login_user(conn, admin), ~p"/admin")

        html = render_submit(lv, "extend_trial", %{"user_id" => target.id, "days" => "14"})
        assert html =~ "Billing is disabled on this instance"

        html = render_click(lv, "toggle_comp", %{"id" => target.id})
        assert html =~ "Billing is disabled on this instance"

        html = render_click(lv, "resync_stripe", %{"id" => target.id})
        assert html =~ "Billing is disabled on this instance"
      end)
    end

    test "with billing enabled the billing surface is unchanged", %{conn: conn} do
      admin = insert_admin()

      {:ok, _lv, html} = live(login_user(conn, admin), ~p"/admin")

      assert html =~ "MRR"
      assert html =~ "Subscribed"
      assert html =~ ~s(name="status")
      assert html =~ ~s(phx-submit="extend_trial")
    end
  end

  describe "/admin/users/:id" do
    test "shows no subscription badge, trial tile or Stripe link", %{conn: conn} do
      admin = insert_admin()

      # Residue on purpose: an account that kept billing fields from before
      # the flag flipped must still render clean.
      user = insert_verified_user()

      {:ok, user} =
        user
        |> Accounts.User.billing_changeset(%{
          subscription_status: "trialing",
          stripe_customer_id: "cus_residue"
        })
        |> Fountain.Repo.update()

      with_billing_disabled(fn ->
        {:ok, _lv, html} = live(login_user(conn, admin), ~p"/admin/users/#{user.id}")

        refute html =~ "trialing"
        refute html =~ "Trial / period"
        refute html =~ "dashboard.stripe.com"
        assert html =~ "Onboarding"
        assert html =~ user.email
      end)
    end
  end

  describe "funnel" do
    test "subscribed stage reports 0 even for residue statuses" do
      user = insert_verified_user()

      {:ok, _} =
        user
        |> Accounts.User.billing_changeset(%{subscription_status: "active"})
        |> Fountain.Repo.update()

      with_billing_disabled(fn ->
        summary = Fountain.Funnel.summary_admin()
        subscribed = Enum.find(summary.stages, &(&1.key == :subscribed))

        # The stage stays in the list (the telemetry gauge keeps its shape);
        # only the count is pinned to zero.
        assert subscribed.count == 0
      end)
    end

    test "telemetry emits subscribed as 0" do
      ref = make_ref()
      test = self()

      :telemetry.attach(
        ref,
        [:fountain, :funnel],
        fn _ev, measurements, _meta, _ -> send(test, {:funnel, measurements}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(ref) end)

      user = insert_verified_user()

      {:ok, _} =
        user
        |> Accounts.User.billing_changeset(%{subscription_status: "active"})
        |> Fountain.Repo.update()

      with_billing_disabled(fn ->
        assert :ok = Fountain.Funnel.emit_telemetry()
        assert_receive {:funnel, measurements}
        assert measurements.subscribed == 0
        assert measurements.registered >= 1
      end)
    end
  end
end
