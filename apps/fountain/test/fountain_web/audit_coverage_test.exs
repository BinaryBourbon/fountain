defmodule FountainWeb.AuditCoverageTest do
  @moduledoc """
  Audit coverage across the surfaces that had none.

  There was exactly one `Audit.record` call site in the codebase — a plug on the
  `:api` pipeline. So writing a secret through the API produced a record and
  writing the identical secret through the UI produced nothing, which is the
  wrong way round for a product whose job is holding tenant secrets. Login,
  logout, password reset and admin role changes were likewise invisible, and
  `actor` was hardcoded to `"api"`, making a human, a CI job and an agent inside
  a sandbox indistinguishable.
  """

  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.Audit
  alias Fountain.Audit.AdminEvent
  alias Fountain.Repo

  defp events_for(user_id) do
    Audit.list_recent_for_user(user_id, 100)
  end

  defp find_action(user_id, action) do
    Enum.find(events_for(user_id), &(&1.action == action))
  end

  describe "secret writes through the UI" do
    test "a vault secret write is recorded", %{conn: conn} do
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)

      {:ok, lv, _html} = live(login_user(conn, user), ~p"/vaults/#{vault.id}/edit")

      lv
      |> element("form[phx-submit='add_secret']")
      |> render_submit(%{"secret" => %{"key" => "API_TOKEN", "value" => "s3cret"}})

      event = find_action(user.id, "vault.secret.write")
      assert event, "writing a vault secret through the UI must be audited"
      assert event.actor == "ui"
      assert event.resource_id == vault.id
      assert event.metadata["key"] == "API_TOKEN"
    end

    test "the secret value is never written to the audit log", %{conn: conn} do
      # The key is the useful part; the value is the thing that must not leak
      # into a second table.
      user = insert_verified_user()
      vault = insert_vault(user_id: user.id)

      {:ok, lv, _html} = live(login_user(conn, user), ~p"/vaults/#{vault.id}/edit")

      lv
      |> element("form[phx-submit='add_secret']")
      |> render_submit(%{"secret" => %{"key" => "K", "value" => "super-secret-value"}})

      for event <- events_for(user.id) do
        refute inspect(event.metadata) =~ "super-secret-value"
      end
    end

    test "an environment secret write is recorded", %{conn: conn} do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)

      {:ok, lv, _html} = live(login_user(conn, user), ~p"/environments/#{env.id}/edit")

      lv
      |> element("form[phx-submit='add_secret']")
      |> render_submit(%{"secret" => %{"key" => "DB_URL", "value" => "postgres://x"}})

      event = find_action(user.id, "environment.secret.write")
      assert event
      assert event.metadata["key"] == "DB_URL"
    end
  end

  describe "authentication events" do
    test "a successful login is recorded", %{conn: conn} do
      user = insert_verified_user(%{"password" => "password12345"})

      post(conn, ~p"/auth/login", %{"email" => user.email, "password" => "password12345"})

      event = find_action(user.id, "auth.login")
      assert event
      assert event.actor == "ui"
      assert event.metadata["result"] == "ok"
    end

    test "a failed login is recorded, which is the one that matters", %{conn: conn} do
      user = insert_verified_user(%{"password" => "password12345"})

      post(conn, ~p"/auth/login", %{"email" => user.email, "password" => "wrong-password"})

      # Attributed to no tenant, since the attempt failed — visible in the
      # admin view rather than the user's own trail.
      event = Enum.find(Audit._unsafe_list_recent(50), &(&1.action == "auth.login.failed"))
      assert event, "failed logins must leave a record — a run of them is the signal"
      assert event.metadata["email"] == user.email
      refute event.metadata["password"]
    end

    test "a password reset is recorded" do
      user = insert_verified_user()
      token =
        Phoenix.Token.sign(FountainWeb.Endpoint, "password_reset", {user.id, user.session_version})

      build_conn()
      |> post(~p"/auth/reset", %{"token" => token, "password" => "new-password-123"})

      assert find_action(user.id, "auth.password.reset")
    end
  end

  describe "admin actions" do
    setup do
      admin = insert_verified_user()
      {:ok, admin} = Fountain.Accounts.update_user_role(admin, "admin")
      {:ok, admin: admin}
    end

    test "granting the admin role is recorded with actor and target", %{conn: conn, admin: admin} do
      target = insert_verified_user()

      {:ok, lv, _html} = live(login_user(conn, admin), ~p"/admin")
      render_click(lv, "toggle_admin", %{"id" => target.id})

      assert [event] = Repo.all(AdminEvent)
      assert event.event_type == "admin.role.granted"
      assert event.actor_user_id == admin.id
      assert event.target_user_id == target.id
      assert event.metadata["to"] == "admin"
    end

    test "revoking the admin role is recorded distinctly", %{conn: conn, admin: admin} do
      target = insert_verified_user()
      {:ok, target} = Fountain.Accounts.update_user_role(target, "admin")

      {:ok, lv, _html} = live(login_user(conn, admin), ~p"/admin")
      render_click(lv, "toggle_admin", %{"id" => target.id})

      assert [event] = Repo.all(AdminEvent)
      assert event.event_type == "admin.role.revoked"
    end

    test "a quota change is recorded", %{conn: conn, admin: admin} do
      target = insert_verified_user()

      {:ok, lv, _html} = live(login_user(conn, admin), ~p"/admin")

      lv
      |> element("#sandbox-limit-#{target.id}")
      |> render_submit(%{"user_id" => target.id, "limit" => "42"})

      assert [event] = Repo.all(AdminEvent)
      assert event.event_type == "admin.sandbox_limit.changed"
      assert event.metadata["to"] == 42
    end

    test "the admin view surfaces the trail", %{conn: conn, admin: admin} do
      target = insert_verified_user()

      {:ok, lv, _html} = live(login_user(conn, admin), ~p"/admin")
      render_click(lv, "toggle_admin", %{"id" => target.id})

      {:ok, _lv2, html} = live(login_user(conn, admin), ~p"/admin")
      assert html =~ "admin.role.granted"
      assert html =~ target.email
    end
  end

  describe "actor attribution" do
    test "a sprite callback token is distinguished from a human's key", %{conn: conn} do
      # "the agent did this" and "the account owner did this" are very different
      # claims, and were indistinguishable when actor was hardcoded.
      user = insert_verified_user()
      {_rec, sprite_key} = insert_sprite_api_key(user)

      conn
      |> authed_with_key(sprite_key)
      |> post_json("/api/environments", %{"name" => "from-a-sandbox"})
      |> json_response(201)

      event = Enum.find(events_for(user.id), &(&1.actor == "sprite"))
      assert event, "a sandbox-originated write must be attributable to the sandbox"
    end

    test "an ordinary API key is recorded as api", %{conn: conn} do
      user = insert_verified_user()
      {_rec, key} = insert_api_key(user)

      conn
      |> authed_with_key(key)
      |> post_json("/api/environments", %{"name" => "from-cli"})
      |> json_response(201)

      assert Enum.any?(events_for(user.id), &(&1.actor == "api"))
      refute Enum.any?(events_for(user.id), &(&1.actor == "sprite"))
    end
  end

  describe "API key lifecycle through the UI" do
    test "creation and revocation are both recorded", %{conn: conn} do
      user = insert_verified_user()

      {:ok, lv, _html} = live(login_user(conn, user), ~p"/api-keys")
      render_submit(lv, "create_key", %{"label" => "ci-deploy"})

      created = find_action(user.id, "api_key.created")
      assert created
      assert created.metadata["name"] == "ci-deploy"

      key_id = created.resource_id
      render_click(lv, "revoke", %{"id" => key_id})

      assert find_action(user.id, "api_key.revoked")
    end
  end
end
