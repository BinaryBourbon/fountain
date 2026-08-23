defmodule FountainWeb.AdminFinanceLiveTest do
  @moduledoc """
  `/admin/finance`.

  The behaviour worth guarding is what the page does when it has *not* been
  told what things cost. A finance page that renders `$0.00` over an unset
  rate card is worse than one that renders nothing: it reads as a free tenant,
  and it reads that way most convincingly on the accounts costing the most.
  """
  use FountainWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fountain.Accounts
  alias Fountain.Conversations
  alias Fountain.Plans
  alias Fountain.Repo

  @rate_keys [
    :provider_hourly_cents,
    :agentmail_inbox_cents,
    :agentphone_number_cents,
    :agentmail_message_cents,
    :agentphone_message_cents,
    :cost_basis
  ]

  setup do
    original = Map.new(@rate_keys, &{&1, Application.get_env(:fountain, &1)})

    on_exit(fn ->
      Enum.each(original, fn
        {key, nil} -> Application.delete_env(:fountain, key)
        {key, value} -> Application.put_env(:fountain, key, value)
      end)
    end)

    Enum.each(@rate_keys, &Application.delete_env(:fountain, &1))
    :ok
  end

  defp insert_admin do
    {:ok, admin} = Accounts.update_user_role(insert_verified_user(), "admin")
    admin
  end

  defp subscriber(plan) do
    insert_verified_user()
    |> Ecto.Changeset.change(
      plan: plan,
      subscription_status: "active",
      stripe_subscription_id: "sub_#{System.unique_integer([:positive])}"
    )
    |> Repo.update!()
  end

  # A sandbox in the current month, awake for `hours` with a prompt in flight
  # for `busy_hours`. Anchored to the start of this month so the page's default
  # window contains it whatever day the suite runs.
  defp ran(user, hours, busy_hours) do
    now = DateTime.utc_now()
    started = %DateTime{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 0}}
    ended = DateTime.add(started, hours * 3600, :second)

    sandbox =
      insert_sandbox(
        user_id: user.id,
        provider: "sprites",
        status: "terminated",
        inserted_at: started,
        terminated_at: ended
      )

    if busy_hours > 0 do
      agent = insert_agent(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent_id: agent.id, sandbox: sandbox)

      {:ok, _} =
        Conversations._unsafe_create_turn(%{
          conversation_id: conv.id,
          turn_number: System.unique_integer([:positive]),
          prompt: "hello",
          status: "completed",
          started_at: started,
          ended_at: DateTime.add(started, busy_hours * 3600, :second)
        })
    end

    sandbox
  end

  describe "access control" do
    test "a regular user is pushed back to the dashboard", %{conn: conn} do
      conn = login_user(conn, insert_verified_user())
      assert {:error, {:live_redirect, _}} = live(conn, ~p"/admin/finance")
    end

    test "an anonymous visitor goes to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/finance")
      assert path =~ "/auth/login"
    end
  end

  describe "with no rate card" do
    test "says so, and shows no dollar cost at all", %{conn: conn} do
      admin = insert_admin()
      user = subscriber("solo")
      ran(user, 10, 4)

      {:ok, _lv, html} = live(login_user(conn, admin), ~p"/admin/finance")

      assert html =~ "No rate card is configured"
      assert html =~ "PROVIDER_HOURLY_CENTS"
      # Revenue is known regardless — it comes from the plan catalog.
      assert html =~ Plans.format_usd(Plans.monthly_cents("solo"))
      # ...and the hours are real even with nothing priced.
      assert html =~ "10.0"
      assert html =~ user.email
    end
  end

  describe "with a rate card" do
    test "prices the hours and shows the margin", %{conn: conn} do
      Application.put_env(:fountain, :provider_hourly_cents, %{"sprites" => 100})

      admin = insert_admin()
      user = subscriber("solo")
      ran(user, 10, 4)

      {:ok, _lv, html} = live(login_user(conn, admin), ~p"/admin/finance")

      refute html =~ "No rate card is configured"
      # Ten active hours at $1 — active, not the four turn hours: the provider
      # charges for the idle six.
      assert html =~ "$10.00"
      assert html =~ "Gross margin"
    end

    test "a tenant costing more than they pay renders in red", %{conn: conn} do
      Application.put_env(:fountain, :provider_hourly_cents, %{"sprites" => 500})

      admin = insert_admin()
      user = subscriber("solo")
      ran(user, 100, 100)

      {:ok, _lv, html} = live(login_user(conn, admin), ~p"/admin/finance")

      assert html =~ "text-red-700"
      assert html =~ "-$471.00"
      assert html =~ user.email
    end
  end

  describe "contacts that nothing bills for" do
    test "says why the add-on column is zero", %{conn: conn} do
      admin = insert_admin()
      subscriber("team")

      {:ok, _lv, html} = live(login_user(conn, admin), ~p"/admin/finance")

      assert html =~ "Teammate contacts are not billed on this deployment"
      assert html =~ "STRIPE_PRICE_ID_CONTACT"
    end

    test "no such note once a contact price exists", %{conn: conn} do
      Application.put_env(:fountain, :stripe_price_ids, %{"contact" => "price_contact_test"})
      on_exit(fn -> Application.delete_env(:fountain, :stripe_price_ids) end)

      admin = insert_admin()
      subscriber("team")

      {:ok, _lv, html} = live(login_user(conn, admin), ~p"/admin/finance")

      refute html =~ "not billed on this deployment"
    end
  end

  describe "fractional rates" do
    # The gap that took /admin/finance down in prod the moment a rate card was
    # configured: every rate here was a whole number, and `money/1` only
    # matched integers. The context tests covered fractional arithmetic; none
    # of them *rendered* the provider card that shows the rate.
    test "renders the provider card at the rates prod actually runs", %{conn: conn} do
      Application.put_env(:fountain, :provider_hourly_cents, %{
        "sprites" => 10.76,
        "e2b" => 5.45,
        "daytona" => 5.45
      })

      Application.put_env(:fountain, :agentmail_message_cents, 0.2)

      admin = insert_admin()
      user = subscriber("solo")
      ran(user, 10, 4)

      {:ok, _lv, html} = live(login_user(conn, admin), ~p"/admin/finance")

      # A rate is shown in cents keeping its fraction — rounded to whole cents
      # 10.76 and 5.45 would both collapse and stop being comparable.
      assert html =~ "10.76c/hour"
      refute html =~ "no rate configured"
    end

    test "a whole fractional rate does not grow a decimal point", %{conn: conn} do
      Application.put_env(:fountain, :provider_hourly_cents, %{"sprites" => 12.0})

      admin = insert_admin()
      user = subscriber("solo")
      ran(user, 5, 5)

      {:ok, _lv, html} = live(login_user(conn, admin), ~p"/admin/finance")

      assert html =~ "12c/hour"
      refute html =~ "12.0c/hour"
    end
  end

  describe "the cost basis" do
    test "the toggle reprices the same hours", %{conn: conn} do
      Application.put_env(:fountain, :provider_hourly_cents, %{"sprites" => 100})

      admin = insert_admin()
      user = subscriber("solo")
      ran(user, 10, 2)

      conn = login_user(conn, admin)

      {:ok, lv, html} = live(conn, ~p"/admin/finance")
      assert html =~ "active hours"
      # Ten awake hours at $1.
      assert html =~ "$10.00"

      html =
        lv
        |> element(~s{a[href="/admin/finance?months_ago=0&basis=turn"]})
        |> render_click()

      # The same two turn hours, now the thing being charged for.
      assert html =~ "$2.00"
      assert html =~ "turn hours"
      assert html =~ "at nothing on this basis"
    end

    test "PROVIDER_COST_BASIS sets what the page opens on", %{conn: conn} do
      Application.put_env(:fountain, :cost_basis, :turn)
      Application.put_env(:fountain, :provider_hourly_cents, %{"sprites" => 100})

      admin = insert_admin()
      user = subscriber("solo")
      ran(user, 10, 2)

      {:ok, _lv, html} = live(login_user(conn, admin), ~p"/admin/finance")

      assert html =~ "$2.00"
    end
  end

  describe "the window" do
    test "defaults to this month and can look back", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)

      {:ok, lv, html} = live(conn, ~p"/admin/finance")
      assert html =~ Calendar.strftime(DateTime.utc_now(), "%B %Y")
      assert html =~ "The month so far"

      html =
        lv
        |> element(~s{a[href="/admin/finance?months_ago=1&basis=active"]})
        |> render_click()

      assert html =~ "A closed month"
    end

    test "changing the month keeps the basis you chose", %{conn: conn} do
      # Otherwise comparing two months on the turn basis silently switches one
      # of them back to active, and the comparison is between two things.
      Application.put_env(:fountain, :provider_hourly_cents, %{"sprites" => 100})
      conn = login_user(conn, insert_admin())

      {:ok, lv, _html} = live(conn, ~p"/admin/finance?basis=turn")

      html =
        lv
        |> element(~s{a[href="/admin/finance?months_ago=1&basis=turn"]})
        |> render_click()

      assert html =~ "A closed month"
      assert html =~ "turn hours"
    end

    test "a nonsense months_ago falls back to this month rather than erroring", %{conn: conn} do
      conn = login_user(conn, insert_admin())

      {:ok, _lv, html} = live(conn, ~p"/admin/finance?months_ago=nope")
      assert html =~ "The month so far"

      {:ok, _lv, html} = live(conn, ~p"/admin/finance?months_ago=999")
      assert html =~ "The month so far"
    end
  end

  describe "/admin" do
    test "the MRR tile links here and is priced per plan", %{conn: conn} do
      admin = insert_admin()
      subscriber("scale")

      {:ok, _lv, html} = live(login_user(conn, admin), ~p"/admin")

      assert html =~ "/admin/finance"
      # $199, not the legacy $29 the tile used to charge everybody.
      assert html =~ "$199.00/mo"
    end
  end
end
