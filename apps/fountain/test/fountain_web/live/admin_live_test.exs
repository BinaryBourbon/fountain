defmodule FountainWeb.AdminLiveTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.Accounts

  defp insert_admin(overrides \\ %{}) do
    user = insert_active_user(overrides)
    {:ok, admin} = Accounts.update_user_role(user, "admin")
    admin
  end

  describe "AdminLive.Index — access control" do
    test "admin user can access /admin", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")
      assert html =~ "Admin"
      assert html =~ "Users"
    end

    test "regular user is redirected away from /admin", %{conn: conn} do
      user = insert_active_user()
      conn = login_user(conn, user)
      assert {:error, {:live_redirect, _}} = live(conn, ~p"/admin")
    end

    test "unauthenticated user is redirected to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin")
      assert path =~ "/auth/login"
    end
  end

  describe "AdminLive.Index — user list" do
    test "displays all users", %{conn: conn} do
      admin = insert_admin()
      other = insert_active_user()
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ admin.email
      assert html =~ other.email
    end

    test "shows onboarding state for each user", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "step_1"
    end
  end

  describe "AdminLive.Index — toggle_admin" do
    test "promotes a regular user to admin", %{conn: conn} do
      admin = insert_admin()
      target = insert_active_user()
      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin")

      lv |> element("button[phx-value-id='#{target.id}']", "Make admin") |> render_click()

      updated = Accounts.get_user!(target.id)
      assert updated.role == "admin"
    end

    test "demotes an admin to regular user", %{conn: conn} do
      admin = insert_admin()
      target = insert_admin()
      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin")

      lv |> element("button[phx-value-id='#{target.id}']", "Remove admin") |> render_click()

      updated = Accounts.get_user!(target.id)
      assert updated.role == "user"
    end
  end

  describe "AdminLive.Index — :refresh handle_info" do
    test "page re-renders on :refresh message without error", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin")

      # Send the refresh message directly; the page should still render
      send(lv.pid, :refresh)
      html = render(lv)
      assert html =~ "Admin"
      assert html =~ "Users"
    end

    test ":refresh picks up newly inserted users", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)
      {:ok, lv, html_before} = live(conn, ~p"/admin")

      new_user = insert_active_user()

      send(lv.pid, :refresh)
      html_after = render(lv)

      refute html_before =~ new_user.email
      assert html_after =~ new_user.email
    end
  end

  describe "AdminLive.Index — sandboxes section" do
    test "shows 'No active sandboxes' when there are none", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "No active sandboxes"
    end

    test "renders active sandboxes in the table", %{conn: conn} do
      admin = insert_admin()
      sandbox = insert_sandbox(user_id: admin.id, status: "ready")
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ String.slice(sandbox.id, 0, 8)
      assert html =~ "ready"
    end

    test "shows the sandbox owner and links conversations to the admin view (#446)", %{
      conn: conn
    } do
      admin = insert_admin()
      owner = insert_active_user()
      sandbox = insert_sandbox(user_id: owner.id, status: "ready")
      conv = insert_conversation(user_id: owner.id, sandbox: sandbox)

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      # owner column, linking to the user detail page
      assert html =~ owner.email
      assert html =~ ~p"/admin/users/#{owner.id}"
      # conversation link resolves through the admin read path, not the
      # tenant-scoped show (which 404s for other tenants' conversations)
      assert html =~ ~p"/admin/conversations/#{conv.id}"
      refute html =~ ~s{href="/conversations/#{conv.id}"}
    end

    test "does not show terminated sandboxes", %{conn: conn} do
      admin = insert_admin()
      terminated = insert_sandbox(user_id: admin.id, status: "terminated")
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      refute html =~ String.slice(terminated.id, 0, 8)
    end

    test "shows ready sandbox with correct status badge", %{conn: conn} do
      admin = insert_admin()
      _sandbox = insert_sandbox(user_id: admin.id, status: "ready")
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "ready"
    end

    test "shows failed sandbox with correct status badge", %{conn: conn} do
      admin = insert_admin()
      _sandbox = insert_sandbox(user_id: admin.id, status: "failed")
      conn = login_user(conn, admin)
      # failed is excluded by _unsafe_list_sandboxes_admin (status not in ["terminated","failed"])
      # so page should show "No active sandboxes"
      {:ok, _lv, html} = live(conn, ~p"/admin")
      assert html =~ "Active sandboxes"
    end
  end

  describe "AdminLive.Index — user list formatting" do
    test "shows joined date for each user", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      # inserted_at is always set so date column should have a year
      assert html =~ to_string(Date.utc_today().year)
    end

    test "shows onboarding_completed_at date when set", %{conn: conn} do
      admin = insert_admin()
      # Mark onboarding complete via direct Repo update
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, admin_with_date} =
        Fountain.Repo.update(Ecto.Changeset.change(admin, onboarding_completed_at: now))

      conn = login_user(conn, admin_with_date)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ to_string(now.year)
    end
  end

  describe "AdminLive.Index — sandbox conversations branch" do
    test "shows dash when sandbox has no conversations", %{conn: conn} do
      admin = insert_admin()
      _sandbox = insert_sandbox(user_id: admin.id, status: "ready")
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      # The empty-conversations span renders an em-dash
      assert html =~ "—"
    end

    test "renders conversation links when sandbox has conversations", %{conn: conn} do
      admin = insert_admin()
      sandbox = insert_sandbox(user_id: admin.id, status: "ready")
      conv = insert_conversation(sandbox: sandbox, user_id: admin.id)
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      # The conversation id prefix should appear as a link
      assert html =~ String.slice(conv.id, 0, 8)
      assert html =~ "/conversations/#{conv.id}"
    end

    test "renders pending sandbox with fallback zinc status color", %{conn: conn} do
      admin = insert_admin()
      _sandbox = insert_sandbox(user_id: admin.id, status: "pending")
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "pending"
      # fallback clause: zinc classes
      assert html =~ "text-zinc-500"
    end

    test "renders starting sandbox with fallback zinc status color", %{conn: conn} do
      admin = insert_admin()
      _sandbox = insert_sandbox(user_id: admin.id, status: "starting")
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "starting"
      assert html =~ "text-zinc-500"
    end

    test "sandbox inserted_at timestamp is formatted in the table", %{conn: conn} do
      admin = insert_admin()
      _sandbox = insert_sandbox(user_id: admin.id, status: "ready")
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      # format_ts renders "YYYY-MM-DD HH:MM" — the year is always present
      assert html =~ to_string(Date.utc_today().year)
    end

    test "renders running sandbox with blue status color", %{conn: conn} do
      admin = insert_admin()
      # "running" is not in the changeset enum so insert directly via Ecto.Changeset.change/2
      sandbox = insert_sandbox(user_id: admin.id, status: "ready")

      {:ok, _sandbox} =
        Ecto.Changeset.change(sandbox, status: "running")
        |> Fountain.Repo.update()

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "running"
      assert html =~ "text-blue-800"
    end
  end

  describe "AdminLive.Index — sandbox concurrency cap" do
    test "shows each user's active sandbox count against their cap", %{conn: conn} do
      admin = insert_admin()
      insert_sandbox(user_id: admin.id, status: "ready")
      insert_sandbox(user_id: admin.id, status: "pending")

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "Sandboxes"
      assert html =~ "2 /"
    end

    test "admin can raise a user's cap", %{conn: conn} do
      admin = insert_admin()
      target = insert_active_user()

      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin")

      lv
      |> element("#sandbox-limit-#{target.id}")
      |> render_submit(%{"user_id" => target.id, "limit" => "25"})

      assert Fountain.Quotas.sandbox_limit(target.id) == 25
      assert render(lv) =~ "Sandbox limit override set"
    end

    # A comped account cannot change its own plan — Billing.change_plan/3
    # refuses — so without an admin door there is no way at all onto the
    # entitlements of exactly the accounts an operator hand-manages.
    test "admin can set a user's plan", %{conn: conn} do
      admin = insert_admin()
      target = insert_active_user(plan: "solo")

      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin")

      lv
      |> element("#plan-#{target.id}")
      |> render_change(%{"user_id" => target.id, "plan" => "scale"})

      assert Fountain.Accounts.get_user(target.id).plan == "scale"

      assert Fountain.Quotas.sandbox_limit(target.id) ==
               Fountain.Plans.concurrent_sandboxes("scale")

      # The privilege trail, not just the effect: record_admin/1 is
      # best-effort and silently drops an event type missing from its closed
      # allowlist, which is how admin actions have shipped unaudited before.
      assert_admin_event(target.id, "admin.plan.changed")
    end

    test "admin can comp a user's teammate contacts", %{conn: conn} do
      admin = insert_admin()
      target = insert_active_user(plan: "team")

      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin")

      lv
      |> element("#comped-contacts-#{target.id}")
      |> render_submit(%{"user_id" => target.id, "count" => "2"})

      assert Fountain.Accounts.get_user(target.id).comped_contacts == 2
      assert_admin_event(target.id, "admin.comped_contacts.changed")
    end

    defp assert_admin_event(target_id, event_type) do
      types =
        target_id
        |> Fountain.Audit._unsafe_list_admin_events_for_target(50)
        |> Enum.map(& &1.event_type)

      assert event_type in types,
             "no #{event_type} admin event recorded (got #{inspect(types)}) — " <>
               "the type is probably missing from AdminEvent's allowlist"
    end

    test "an empty field clears the override and the cap follows the plan", %{conn: conn} do
      admin = insert_admin()
      target = insert_active_user(plan: "team")
      {:ok, _} = Fountain.Accounts.update_sandbox_limit(target, 25, actor: "admin")

      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin")

      lv
      |> element("#sandbox-limit-#{target.id}")
      |> render_submit(%{"user_id" => target.id, "limit" => ""})

      assert render(lv) =~ "Override cleared"

      assert Fountain.Quotas.sandbox_limit(target.id) ==
               Fountain.Plans.fetch!("team").concurrent_sandboxes

      assert Fountain.Accounts.get_user(target.id).sandbox_limit_override == nil
    end

    test "admin can drop a cap to zero to cut off an abusive tenant", %{conn: conn} do
      admin = insert_admin()
      target = insert_active_user()

      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin")

      lv
      |> element("#sandbox-limit-#{target.id}")
      |> render_submit(%{"user_id" => target.id, "limit" => "0"})

      assert Fountain.Quotas.sandbox_limit(target.id) == 0

      assert {:error, {:sandbox_quota_exceeded, _}} =
               Fountain.Quotas.check_sandbox_quota(target.id)
    end

    test "a negative cap is rejected", %{conn: conn} do
      admin = insert_admin()
      target = insert_active_user()

      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin")

      lv
      |> element("#sandbox-limit-#{target.id}")
      |> render_submit(%{"user_id" => target.id, "limit" => "-1"})

      assert Fountain.Quotas.sandbox_limit(target.id) == Fountain.Quotas.default_limit()
      assert render(lv) =~ "whole number"
    end

    test "a non-numeric cap is rejected", %{conn: conn} do
      admin = insert_admin()
      target = insert_active_user()

      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin")

      lv
      |> element("#sandbox-limit-#{target.id}")
      |> render_submit(%{"user_id" => target.id, "limit" => "lots"})

      assert Fountain.Quotas.sandbox_limit(target.id) == Fountain.Quotas.default_limit()
      assert render(lv) =~ "whole number"
    end
  end

  describe "AdminLive.Index — billing column" do
    test "shows subscription status, trial end and a Stripe link", %{conn: conn} do
      admin = insert_admin()

      user = insert_active_user()

      user =
        Fountain.Repo.update!(
          Ecto.Changeset.change(user,
            subscription_status: "trialing",
            trial_ends_at: ~U[2027-03-01 00:00:00Z],
            stripe_customer_id: "cus_admin_test"
          )
        )

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "trialing"
      assert html =~ "ends 2027-03-01"
      assert html =~ "https://dashboard.stripe.com/customers/#{user.stripe_customer_id}"
    end
  end

  describe "AdminLive.Index — extend_trial" do
    test "extends the trial and records an admin audit event", %{conn: conn} do
      admin = insert_admin()

      user =
        Fountain.Repo.update!(
          Ecto.Changeset.change(insert_active_user(),
            subscription_status: "canceled",
            trial_ends_at: nil
          )
        )

      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin")

      lv
      |> form("#extend-trial-#{user.id}", %{"days" => "7"})
      |> render_submit()

      updated = Fountain.Repo.reload!(user)
      assert updated.subscription_status == "trialing"
      expected = DateTime.add(DateTime.utc_now(), 7 * 24 * 60 * 60, :second)
      assert abs(DateTime.diff(updated.trial_ends_at, expected, :second)) < 60

      assert Enum.any?(
               Fountain.Audit._unsafe_list_recent_admin(10),
               &(&1.event_type == "admin.trial.extended" and &1.target_user_id == user.id)
             )
    end

    test "rejects a non-numeric day count", %{conn: conn} do
      admin = insert_admin()
      # Trialing on purpose: the extend-trial form is only rendered for an
      # account that has a trial, and `extend_trial/2` refuses an active one.
      user = insert_verified_user()
      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin")

      html =
        lv
        |> form("#extend-trial-#{user.id}", %{"days" => "nope"})
        |> render_submit()

      assert html =~ "whole number"
    end
  end

  describe "AdminLive.Index — toggle_comp" do
    test "comps and un-comps an account, with audit events", %{conn: conn} do
      admin = insert_admin()
      user = insert_active_user()
      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin")

      lv
      |> element("button[phx-value-id='#{user.id}'][phx-click='toggle_comp']")
      |> render_click()

      assert Fountain.Repo.reload!(user).subscription_status == "comped"

      lv
      |> element("button[phx-value-id='#{user.id}'][phx-click='toggle_comp']")
      |> render_click()

      assert Fountain.Repo.reload!(user).subscription_status == "canceled"

      events = Fountain.Audit._unsafe_list_recent_admin(10)
      assert Enum.any?(events, &(&1.event_type == "admin.comp.granted"))
      assert Enum.any?(events, &(&1.event_type == "admin.comp.revoked"))
    end
  end

  describe "AdminLive.Index — reap_sandbox" do
    test "reaps a ready sandbox with no live server and audits it", %{conn: conn} do
      admin = insert_admin()
      sandbox = insert_sandbox(status: "ready")
      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin")

      html =
        lv
        |> element("button[phx-value-id='#{sandbox.id}'][phx-click='reap_sandbox']")
        |> render_click()

      assert html =~ "released"
      reloaded = Fountain.Conversations._unsafe_get_sandbox!(sandbox.id)
      assert reloaded.status == "terminated"
      assert reloaded.terminated_at

      assert Enum.any?(
               Fountain.Audit._unsafe_list_recent_admin(10),
               &(&1.event_type == "admin.sandbox.reaped" and
                   &1.metadata["sandbox_id"] == sandbox.id)
             )
    end
  end

  describe "AdminLive.Index — funnel section" do
    test "renders stage tiles with counts and conversions", %{conn: conn} do
      admin = insert_admin()
      _unverified = insert_user()
      conn = login_user(conn, admin)

      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "Funnel"
      assert html =~ "Registered"
      assert html =~ "Verified"
      assert html =~ "Onboarded"
      assert html =~ "Activated"
      assert html =~ "Subscribed"
      # 2 registered, 1 verified → 50% conversion tile
      assert html =~ "50% of prev"
    end

    test "shows the stalled-verified breakdown", %{conn: conn} do
      admin = insert_admin()
      stalled = insert_active_user()
      insert_agent(user_id: stalled.id)
      conn = login_user(conn, admin)

      {:ok, _lv, html} = live(conn, ~p"/admin")

      # admin + stalled are both verified with no conversations
      assert html =~ "2 verified users have never started a conversation"
      assert html =~ "built an agent: 1"
    end
  end

  describe "AdminLive.Index — suspend (#287)" do
    test "suspends and unsuspends with audit events and a badge", %{conn: conn} do
      admin = insert_admin()
      target = insert_active_user()
      insert_sandbox(user_id: target.id, status: "ready")
      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin")

      html =
        lv
        |> element("button[phx-click='toggle_suspend'][phx-value-id='#{target.id}']")
        |> render_click()

      assert Fountain.Accounts.suspended?(Fountain.Repo.reload!(target))
      assert html =~ "suspended"
      assert html =~ "Unsuspend"
      assert html =~ "1 sandbox(es) reaped"

      html =
        lv
        |> element("button[phx-click='toggle_suspend'][phx-value-id='#{target.id}']")
        |> render_click()

      refute Fountain.Accounts.suspended?(Fountain.Repo.reload!(target))
      assert html =~ "Suspension lifted"

      events = Fountain.Audit._unsafe_list_recent_admin(10)
      assert Enum.any?(events, &(&1.event_type == "admin.account.suspended"))
      assert Enum.any?(events, &(&1.event_type == "admin.account.unsuspended"))
    end

    test "an admin cannot suspend themselves", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin")

      render_click(lv, "toggle_suspend", %{"id" => admin.id})

      refute Fountain.Accounts.suspended?(Fountain.Repo.reload!(admin))
      assert render(lv) =~ "cannot suspend your own account"
    end
  end

  describe "AdminLive.Index — billing overview section" do
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
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "MRR"
      assert html =~ "Trials ending in 7 days"
      assert html =~ "Conversions this month"
      # MRR is priced from the plan catalog now, so it is a real number even
      # with no price env var set — and the tile leads to the finance panel.
      assert html =~ "active subscriptions, per plan"
      assert html =~ "/admin/finance"
      # status chips link into the filtered user table from #285
      assert html =~ "/admin?status=active"
      assert html =~ "/admin?status=past_due"
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
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "webhook event is failing"
      assert html =~ "evt_admin_fail"
      assert html =~ "database_unavailable"
      refute html =~ "No unresolved webhook failures"
    end
  end

  describe "AdminLive.Index — search, filter, sort" do
    # The layout renders the logged-in admin's email in the nav, so negative
    # assertions must target a third user, never the admin.
    test "?q= narrows the table to matching emails", %{conn: conn} do
      admin = insert_admin()
      needle = insert_active_user(%{email: "needle@example.com"})
      straw = insert_active_user(%{email: "straw@example.com"})
      conn = login_user(conn, admin)

      {:ok, _lv, html} = live(conn, ~p"/admin?q=needle")

      assert html =~ needle.email
      refute html =~ straw.email
    end

    test "typing in the search box patches the URL and filters", %{conn: conn} do
      admin = insert_admin()
      needle = insert_active_user(%{email: "needle@example.com"})
      straw = insert_active_user(%{email: "straw@example.com"})
      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin")

      html =
        lv
        |> form("#user-filters")
        |> render_change(%{"q" => "needle", "status" => "", "role" => "", "verified" => ""})

      assert_patch(lv, ~p"/admin?q=needle")
      assert html =~ needle.email
      refute html =~ straw.email
    end

    test "filters by subscription status", %{conn: conn} do
      admin = insert_admin()
      trialing = insert_active_user(%{email: "still-trialing@example.com"})

      canceled =
        Fountain.Repo.update!(
          Ecto.Changeset.change(insert_active_user(), subscription_status: "canceled")
        )

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin?status=canceled")

      assert html =~ canceled.email
      refute html =~ trialing.email
    end

    test "filters by verification state and badges unverified users", %{conn: conn} do
      admin = insert_admin()
      verified = insert_active_user(%{email: "is-verified@example.com"})
      unverified = insert_user()
      conn = login_user(conn, admin)

      {:ok, _lv, html} = live(conn, ~p"/admin?verified=no")
      assert html =~ unverified.email
      assert html =~ "unverified"
      refute html =~ verified.email
    end

    test "sorts by email via the header link", %{conn: conn} do
      admin = insert_admin()
      insert_active_user(%{email: "zzz-sort@example.com"})
      insert_active_user(%{email: "aaa-sort@example.com"})
      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin")

      html = lv |> element("thead a", "Email") |> render_click()
      assert_patch(lv, ~p"/admin?dir=asc&sort=email")

      # Each email appears several times per row (confirm dialogs etc.);
      # first-appearance order is what reflects row order.
      assert Regex.scan(~r/(?:aaa|zzz)-sort@example\.com/, html)
             |> List.flatten()
             |> Enum.uniq() ==
               ["aaa-sort@example.com", "zzz-sort@example.com"]
    end

    test "shows an empty state when nothing matches", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)

      {:ok, _lv, html} = live(conn, ~p"/admin?q=no-such-user")
      assert html =~ "No users match."
    end
  end

  describe "AdminLive.Index — pagination" do
    # Bypasses register_user: 26 bcrypt hashes in one test is pure drag, and
    # this test needs rows, not the registration pipeline.
    defp insert_bare_users(count) do
      for i <- 1..count do
        Fountain.Repo.insert!(%Fountain.Accounts.User{
          email: "bulk-#{i}-#{System.unique_integer([:positive])}@example.com",
          password_hash: "not-a-real-hash"
        })
      end
    end

    test "shows 25 rows per page and preserves the page across refresh", %{conn: conn} do
      admin = insert_admin()

      # Back-date the admin so ascending order puts them firmly on page 1 —
      # same-second inserts would otherwise tie-break on random uuid.
      earlier = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)
      Fountain.Repo.update!(Ecto.Changeset.change(admin, inserted_at: earlier))

      insert_bare_users(26)
      conn = login_user(conn, admin)

      {:ok, lv, html} = live(conn, ~p"/admin?page=2&dir=asc")

      # 27 users total (admin + 26): page 2 holds exactly the last two
      assert html =~ "Page 2 of 2"
      assert html =~ "Users (27)"

      page2_emails =
        Regex.scan(~r/bulk-\d+-\d+@example\.com/, html) |> List.flatten() |> Enum.uniq()

      assert length(page2_emails) == 2

      send(lv.pid, :refresh)
      assert render(lv) =~ "Page 2 of 2"
    end

    test "prev/next links walk the pages", %{conn: conn} do
      admin = insert_admin()
      insert_bare_users(26)
      conn = login_user(conn, admin)

      {:ok, lv, _html} = live(conn, ~p"/admin")

      lv |> element("a", "next →") |> render_click()
      assert_patch(lv, ~p"/admin?page=2")

      lv |> element("a", "← prev") |> render_click()
      assert_patch(lv, ~p"/admin")
    end

    test "no pagination controls when everything fits on one page", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)

      {:ok, _lv, html} = live(conn, ~p"/admin")
      refute html =~ "Page 1 of"
    end
  end

  describe "AdminLive.Index — usage column" do
    test "shows 30-day usage per user", %{conn: conn} do
      admin = insert_admin()
      user = insert_active_user()
      {:ok, _} = Fountain.Billing.record_usage(user.id, "turn_started", nil, nil)
      {:ok, _} = Fountain.Billing.record_usage(user.id, "sandbox_provisioned", nil, nil)

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "1c · 1t · 0m"
    end
  end

  describe "AdminLive.Index — sandbox spend by provider" do
    defp sandbox_run(user, provider, minutes) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {period_start, _} = Fountain.Billing.current_month_range()
      started = Enum.max([DateTime.add(now, -minutes, :minute), period_start], DateTime)

      insert_sandbox(
        user_id: user.id,
        provider: provider,
        status: "terminated",
        inserted_at: started,
        terminated_at: now
      )
    end

    test "names each provider and the tenants behind it", %{conn: conn} do
      admin = insert_admin()
      user = insert_active_user()
      sandbox_run(user, "e2b", 30)

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "Sandbox spend by provider"
      assert html =~ "e2b"
      assert html =~ "Billable to us"
      assert html =~ user.email
    end

    test "marks a self-hosted runner as not our bill", %{conn: conn} do
      admin = insert_admin()
      user = insert_active_user()
      sandbox_run(user, "runner", 30)

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "tenant hardware, not our bill"
    end

    test "reports how much of the paid time was idle", %{conn: conn} do
      # The number that says whether the bill is avoidable. A sandbox that
      # never took a turn is 100% idle.
      admin = insert_admin()
      user = insert_active_user()
      sandbox_run(user, "e2b", 30)

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "idle"
      assert html =~ "100%"
      assert html =~ "what a shorter idle timeout would remove"
    end

    test "renders with no sandbox time at all", %{conn: conn} do
      admin = insert_admin()

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "No sandbox time this month."
    end
  end
end

defmodule FountainWeb.AdminLiveErrorTest do
  use FountainWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  alias Fountain.Accounts

  defp insert_admin(overrides \\ %{}) do
    user = insert_active_user(overrides)
    {:ok, admin} = Accounts.update_user_role(user, "admin")
    admin
  end

  describe "AdminLive.Index — toggle_admin error path" do
    test "shows error flash when update_user_role fails", %{conn: conn} do
      admin = insert_admin()
      target = insert_active_user()
      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin")

      # Arity 3: the admin surface passes actor: "admin" through so the
      # context can attribute the event it now records itself (#552).
      stub(Accounts, :update_user_role, fn _user, _role, _opts ->
        {:error, %Ecto.Changeset{}}
      end)

      lv |> element("button[phx-value-id='#{target.id}']", "Make admin") |> render_click()

      html = render(lv)
      assert html =~ "Failed to update role"
    end
  end

  describe "AdminLive.Index — resync_stripe (#502)" do
    test "adopts Stripe's state and records an audit event", %{conn: conn} do
      admin = insert_admin()

      user =
        Fountain.Repo.update!(
          Ecto.Changeset.change(insert_active_user(),
            subscription_status: "past_due",
            stripe_customer_id: "cus_lv_resync",
            stripe_subscription_id: "sub_lv_resync"
          )
        )

      result =
        {:ok, %Stripe.Subscription{id: "sub_lv_resync", status: "active", trial_end: nil}}

      stub(Stripe.Subscription, :retrieve, fn "sub_lv_resync" -> result end)
      stub(Stripe.Subscription, :retrieve, fn "sub_lv_resync", _opts -> result end)

      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin")

      html =
        lv
        |> element("button[phx-value-id='#{user.id}'][phx-click='resync_stripe']")
        |> render_click()

      assert html =~ "Resynced from Stripe"
      assert Fountain.Repo.reload!(user).subscription_status == "active"

      assert Enum.any?(
               Fountain.Audit._unsafe_list_recent_admin(10),
               &(&1.event_type == "admin.stripe.resynced" and &1.target_user_id == user.id)
             )
    end

    test "a user with no subscription of record gets a customer sync enqueued", %{conn: conn} do
      admin = insert_admin()
      user = insert_active_user()

      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin")

      html =
        lv
        |> element("button[phx-value-id='#{user.id}'][phx-click='resync_stripe']")
        |> render_click()

      assert html =~ "customer sync enqueued"
    end
  end
end
