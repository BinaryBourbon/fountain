defmodule FountainWeb.AuditLiveTest do
  @moduledoc """
  Regression tests for per-tenant scoping on /audit. Pre-fix, every
  authenticated user saw every event in the system.
  """

  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.Audit

  describe "AuditLive.Index — tenant scoping" do
    test "regular user only sees their own events", %{conn: conn} do
      user_a = insert_verified_user()
      user_b = insert_verified_user()

      # The template renders String.slice(resource_id, 0, 8). Distinct
      # 8-char prefixes keep the assertion sharp.
      Audit.record!(%{
        action: "POST /api/agents",
        resource_type: "agent",
        resource_id: "aaaaaaaa-belongs-to-a",
        actor: "api",
        user_id: user_a.id,
        metadata: %{"status" => 201}
      })

      Audit.record!(%{
        action: "POST /api/agents",
        resource_type: "agent",
        resource_id: "bbbbbbbb-belongs-to-b",
        actor: "api",
        user_id: user_b.id,
        metadata: %{"status" => 201}
      })

      conn = login_user(conn, user_b)
      {:ok, _lv, html} = live(conn, ~p"/audit")

      assert html =~ "bbbbbbbb"
      refute html =~ "aaaaaaaa"
    end

    test "regular user does not see system events (user_id nil)", %{conn: conn} do
      user = insert_verified_user()

      Audit.record!(%{
        action: "POST /api/agents",
        resource_type: "agent",
        resource_id: "system-event",
        actor: "system",
        user_id: nil,
        metadata: %{"status" => 200}
      })

      conn = login_user(conn, user)
      {:ok, _lv, html} = live(conn, ~p"/audit")

      refute html =~ "system-e"
    end

    test "admin sees every tenant's events", %{conn: conn} do
      admin = insert_verified_user(%{"role" => "admin"})
      other = insert_verified_user()

      Audit.record!(%{
        action: "POST /api/agents",
        resource_type: "agent",
        resource_id: "other-tenant",
        actor: "api",
        user_id: other.id,
        metadata: %{"status" => 201}
      })

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/audit")

      assert html =~ "other-te"
    end

    test "unauthenticated user redirected to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/audit")
      assert path =~ "/auth/login"
    end
  end

  describe "Plugs.Audit — user_id capture" do
    test "API requests record the authenticated user's id", %{conn: conn} do
      user = insert_verified_user()
      {_, key} = insert_api_key(user)

      conn
      |> authed_with_key(key)
      |> post("/api/agents", %{
        "name" => "audit-capture-#{System.unique_integer([:positive])}",
        "runtime" => "claude",
        "model" => "anthropic/claude-sonnet-4-6"
      })

      events = Audit.list_recent_for_user(user.id, 10)
      refute Enum.empty?(events)
      assert Enum.all?(events, &(&1.user_id == user.id))
    end
  end

  describe "AuditLive.Index — :tick refresh" do
    test ":tick message reloads events without crashing", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/audit")

      send(lv.pid, :tick)
      html = render(lv)
      assert html =~ "Audit log"
    end

    test ":tick picks up new events since mount", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)
      {:ok, lv, html_before} = live(conn, ~p"/audit")

      # Create an event after mount
      Audit.record!(%{
        action: "POST /api/agents",
        resource_type: "agent",
        resource_id: Ecto.UUID.generate(),
        actor: "api",
        request_ip: "1.2.3.4",
        metadata: %{"status" => 201},
        user_id: user.id
      })

      send(lv.pid, :tick)
      html_after = render(lv)

      refute html_before =~ "1.2.3.4"
      assert html_after =~ "1.2.3.4"
    end
  end
end

# format_ts(nil) is unreachable from the DB (inserted_at is NOT NULL), so we
# stub Audit.list_recent_for_user to return a synthetic event with nil
# inserted_at. Mimic stubs must be visible to the LiveView process, so this
# non-async module uses global mode.
defmodule FountainWeb.AuditLiveFormatTsTest do
  use FountainWeb.ConnCase, async: false
  use Mimic

  import Phoenix.LiveViewTest

  setup :set_mimic_global

  test "event with nil inserted_at renders an empty timestamp cell", %{conn: conn} do
    user = insert_verified_user()

    synthetic_event = %Fountain.Audit.Event{
      id: 1,
      action: "GET /nil-ts-test",
      resource_type: "agent",
      resource_id: "niltstest",
      actor: "api",
      user_id: user.id,
      inserted_at: nil,
      metadata: %{}
    }

    stub(Fountain.Audit, :list_recent_for_user, fn _id, _limit -> [synthetic_event] end)

    conn = login_user(conn, user)
    {:ok, _lv, html} = live(conn, ~p"/audit")

    assert html =~ "GET /nil-ts-test"
    # The nil inserted_at renders as an empty string — no date visible in the cell
    assert html =~ ~r|<td class="px-3 py-1\.5 text-zinc-500 text-xs">\s*</td>|
  end
end
