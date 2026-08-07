defmodule FountainWeb.AuditLiveTest do
  @moduledoc """
  Regression tests for per-tenant scoping on /audit. Pre-fix, every
  authenticated user saw every event in the system.
  """

  use FountainWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
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

  # #572: /api/audit got these filters in #526 and the page did not, so the
  # API was better than the UI at the thing the UI is for.
  describe "AuditLive.Index — filters" do
    setup %{conn: conn} do
      user = insert_verified_user()

      Audit.record!(%{
        action: "vault.secret.write",
        resource_type: "vault_secret",
        resource_id: "vaultvault-secret",
        actor: "ui",
        user_id: user.id,
        metadata: %{"status" => 200}
      })

      Audit.record!(%{
        action: "agent.created",
        resource_type: "agent",
        resource_id: "agentagent-created",
        actor: "api",
        user_id: user.id,
        metadata: %{"status" => 201}
      })

      %{conn: login_user(conn, user), user: user}
    end

    test "an action prefix in the URL narrows the table", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/audit?action=vault.")

      assert html =~ "vaultvau"
      refute html =~ "agentage"
    end

    test "a resource type in the URL narrows the table", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/audit?resource=agent")

      assert html =~ "agentage"
      refute html =~ "vaultvau"
    end

    test "changing the form pushes the filters into the URL", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/audit")

      html =
        lv
        |> form("#audit-filters", %{
          "action" => "vault.",
          "resource" => "",
          "since" => "",
          "until" => ""
        })
        |> render_change()

      assert html =~ "vaultvau"
      refute html =~ "agentage"
      assert_patched(lv, ~p"/audit?action=vault.")
    end

    test "filters survive the 5s tick", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/audit?action=vault.")

      send(lv.pid, :tick)
      html = render(lv)

      assert html =~ "vaultvau"
      refute html =~ "agentage"
    end

    test "a filter that matches nothing says so, distinctly from an empty trail", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/audit?action=nothing.matches.this")

      assert html =~ "No events match these filters"
      refute html =~ "No events yet"
    end

    test "an empty trail says 'no events yet', not 'no matches'", %{conn: conn} do
      # Emptied explicitly, because since #544 a fresh account is not empty —
      # registration is itself the first row in every trail. The state this
      # branch renders is now reached one way in production: an old account
      # whose events have all aged out of the retention window.
      user = insert_verified_user()
      Fountain.Repo.delete_all(from(e in Fountain.Audit.Event, where: e.user_id == ^user.id))

      conn = login_user(conn, user)
      {:ok, _lv, html} = live(conn, ~p"/audit")

      assert html =~ "No events yet"
      refute html =~ "No events match these filters"
    end

    test "the resource-type select offers only this tenant's types", %{conn: conn} do
      other = insert_verified_user()

      Audit.record!(%{
        action: "environment.created",
        resource_type: "environment",
        resource_id: Ecto.UUID.generate(),
        actor: "ui",
        user_id: other.id
      })

      {:ok, _lv, html} = live(conn, ~p"/audit")

      assert html =~ ~s(<option value="agent")
      assert html =~ ~s(<option value="vault_secret")
      refute html =~ ~s(<option value="environment")
    end

    test "a half-typed date filters nothing and stays in the box", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/audit?since=2026-08")

      # Both events still listed — an unparseable bound is not applied...
      assert html =~ "vaultvau"
      assert html =~ "agentage"
      # ...and the input still shows what was typed rather than blanking it.
      assert html =~ ~s(value="2026-08")
    end

    test "a since bound excludes older events", %{conn: conn, user: user} do
      Audit.record!(%{
        action: "ancient.event",
        resource_type: "agent",
        resource_id: "ancientancient",
        actor: "ui",
        user_id: user.id,
        inserted_at: ~U[2020-01-01 00:00:00Z]
      })

      {:ok, _lv, html} = live(conn, ~p"/audit?since=2021-01-01T00:00")

      refute html =~ "ancienta"
      assert html =~ "vaultvau"
    end

    test "the clear link only appears when a filter is active", %{conn: conn} do
      {:ok, _lv, unfiltered} = live(conn, ~p"/audit")
      refute unfiltered =~ "clear filters"

      {:ok, _lv, filtered} = live(conn, ~p"/audit?action=vault.")
      assert filtered =~ "clear filters"
    end
  end

  describe "AuditLive.Index — admin filters" do
    test "an admin gets the same filters over the cross-tenant trail", %{conn: conn} do
      admin = insert_verified_user(%{"role" => "admin"})
      other = insert_verified_user()

      # Distinct 8-char prefixes: the table renders String.slice(id, 0, 8).
      Audit.record!(%{
        action: "vault.secret.write",
        resource_type: "vault_secret",
        resource_id: "vvvvvvvv-other-tenant",
        actor: "api",
        user_id: other.id
      })

      Audit.record!(%{
        action: "agent.created",
        resource_type: "agent",
        resource_id: "gggggggg-other-tenant",
        actor: "api",
        user_id: other.id
      })

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/audit?action=vault.")

      # Still cross-tenant — and now filtered, which it was not before #572.
      assert html =~ "vvvvvvvv"
      refute html =~ "gggggggg"
    end

    test "the admin resource-type select spans tenants", %{conn: conn} do
      admin = insert_verified_user(%{"role" => "admin"})
      other = insert_verified_user()

      Audit.record!(%{
        action: "environment.created",
        resource_type: "environment",
        resource_id: Ecto.UUID.generate(),
        actor: "ui",
        user_id: other.id
      })

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/audit")

      assert html =~ ~s(<option value="environment")
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

    stub(Fountain.Audit, :list_for_user, fn _id, _opts -> [synthetic_event] end)

    conn = login_user(conn, user)
    {:ok, _lv, html} = live(conn, ~p"/audit")

    assert html =~ "GET /nil-ts-test"
    # The nil inserted_at renders as an empty string — no date visible in the cell
    assert html =~ ~r|<td class="px-3 py-1\.5 text-zinc-500 text-xs">\s*</td>|
  end
end
