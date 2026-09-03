defmodule FountainWeb.AccountDataControllerTest do
  @moduledoc """
  Account data export and account deletion over the API (#523).

  Both were browser-only — export through `AccountLive` with PubSub progress
  and a session-scoped download, deletion behind a typed-email confirmation —
  which left the two flows closest to GDPR undriveable by an API consumer.
  """

  use FountainWeb.ConnCase, async: true
  use Oban.Testing, repo: Fountain.Repo

  alias Fountain.Accounts
  alias Fountain.Exports
  alias Fountain.Exports.Export
  alias Fountain.Repo
  alias Fountain.Workers.AccountExport

  setup do
    # No starter agent (ADR 0038), so an export's `agents` list holds exactly
    # what a test seeded into it.
    user = insert_user_without_agents()
    {_rec, key} = insert_api_key(user)
    {:ok, user: user, key: key}
  end

  defp complete_export(user, export) do
    :ok = perform_job(AccountExport, %{export_id: export.id, user_id: user.id})
    Repo.get!(Export, export.id)
  end

  describe "POST /api/account/exports" do
    test "accepts the request and returns the pending row", %{conn: conn, user: user, key: key} do
      body =
        conn
        |> authed_with_key(key)
        |> post("/api/account/exports")
        |> json_response(202)

      assert body["data"]["status"] == "pending"
      assert body["data"]["downloadable"] == false
      assert Exports.latest_export(user.id)
    end

    test "a second request inside the window is 429 with Retry-After", %{
      conn: conn,
      key: key
    } do
      conn |> authed_with_key(key) |> post("/api/account/exports") |> json_response(202)

      conn = build_conn() |> authed_with_key(key) |> post("/api/account/exports")
      body = json_response(conn, 429)

      assert body["error"] == "rate_limited"
      assert body["retry_after"] > 0
      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) > 0
    end

    test "a sprite token cannot request an export of the whole account", %{
      conn: conn,
      user: user
    } do
      {_rec, sprite_key} = insert_sprite_api_key(user)

      conn
      |> authed_with_key(sprite_key)
      |> post("/api/account/exports")
      |> json_response(403)

      refute Exports.latest_export(user.id)
    end
  end

  describe "GET /api/account/exports" do
    test "is an empty list before anything is requested", %{conn: conn, key: key} do
      body = conn |> authed_with_key(key) |> get("/api/account/exports") |> json_response(200)
      assert body["data"] == []
    end

    test "reports status as the build progresses", %{conn: conn, user: user, key: key} do
      {:ok, export} = Exports.request_export(user)

      pending =
        conn |> authed_with_key(key) |> get("/api/account/exports") |> json_response(200)

      assert hd(pending["data"])["status"] == "pending"
      assert hd(pending["data"])["downloadable"] == false

      complete_export(user, export)

      done =
        build_conn() |> authed_with_key(key) |> get("/api/account/exports") |> json_response(200)

      assert hd(done["data"])["status"] == "completed"
      assert hd(done["data"])["downloadable"] == true
      assert hd(done["data"])["byte_size"] > 0
    end

    test "never carries the payload itself", %{conn: conn, user: user, key: key} do
      {:ok, export} = Exports.request_export(user)
      insert_agent(user_id: user.id, name: "in-the-export")
      complete_export(user, export)

      conn = conn |> authed_with_key(key) |> get("/api/account/exports")

      assert json_response(conn, 200)
      refute conn.resp_body =~ "in-the-export"
      refute conn.resp_body =~ "payload"
    end

    test "another tenant's export id is 404", %{conn: conn, key: key} do
      other = insert_verified_user()
      {:ok, export} = Exports.request_export(other)

      conn
      |> authed_with_key(key)
      |> get("/api/account/exports/#{export.id}")
      |> json_response(404)
    end
  end

  describe "GET /api/account/exports/:id/download" do
    test "serves the gzipped payload to the owner", %{conn: conn, user: user, key: key} do
      insert_agent(user_id: user.id, name: "download-me")
      {:ok, export} = Exports.request_export(user)
      complete_export(user, export)

      conn =
        conn
        |> authed_with_key(key)
        |> get("/api/account/exports/#{export.id}/download")

      assert conn.status == 200
      assert get_resp_header(conn, "content-encoding") == ["gzip"]

      doc = conn.resp_body |> :zlib.gunzip() |> Jason.decode!()
      assert doc["account"]["email"] == user.email
      assert [%{"name" => "download-me"}] = doc["agents"]
    end

    test "is audit-recorded like the session route", %{conn: conn, user: user, key: key} do
      {:ok, export} = Exports.request_export(user)
      complete_export(user, export)

      conn
      |> authed_with_key(key)
      |> get("/api/account/exports/#{export.id}/download")

      actions = user.id |> Fountain.Audit.list_recent_for_user(20) |> Enum.map(& &1.action)
      assert "account.export_downloaded" in actions
    end

    test "a pending export is 404, not a partial file", %{conn: conn, user: user, key: key} do
      {:ok, export} = Exports.request_export(user)

      conn
      |> authed_with_key(key)
      |> get("/api/account/exports/#{export.id}/download")
      |> json_response(404)
    end

    test "another tenant's completed export is 404", %{conn: conn, key: key} do
      owner = insert_verified_user()
      {:ok, export} = Exports.request_export(owner)
      complete_export(owner, export)

      conn
      |> authed_with_key(key)
      |> get("/api/account/exports/#{export.id}/download")
      |> json_response(404)
    end
  end

  describe "DELETE /api/account" do
    test "deletes the account when the email is confirmed", %{conn: conn, user: user, key: key} do
      body =
        conn
        |> authed_with_key(key)
        |> delete_json("/api/account", %{"confirm" => user.email})
        |> json_response(200)

      assert body["deleted"] == true
      assert body["user_id"] == user.id
      refute Accounts.get_user(user.id)
    end

    test "refuses without the confirmation and deletes nothing", %{
      conn: conn,
      user: user,
      key: key
    } do
      # `confirm` is required by the schema, so this one is refused before the
      # action runs; the empty-string case below is the controller's own check.
      conn
      |> authed_with_key(key)
      |> delete_json("/api/account", %{})
      |> json_response(422)

      body =
        build_conn()
        |> authed_with_key(key)
        |> delete_json("/api/account", %{"confirm" => ""})
        |> json_response(422)

      assert body["error"] == "confirmation_required"
      assert Accounts.get_user(user.id)
    end

    test "refuses a mismatched confirmation", %{conn: conn, user: user, key: key} do
      conn
      |> authed_with_key(key)
      |> delete_json("/api/account", %{"confirm" => "someone-else@example.com"})
      |> json_response(422)

      assert Accounts.get_user(user.id)
    end

    test "a sprite token cannot delete the account it is running inside", %{
      conn: conn,
      user: user
    } do
      # The escalation this gate exists for: untrusted sandbox code holding a
      # conversation token must not be able to destroy the tenant.
      {_rec, sprite_key} = insert_sprite_api_key(user)

      body =
        conn
        |> authed_with_key(sprite_key)
        |> delete_json("/api/account", %{"confirm" => user.email})
        |> json_response(403)

      assert body["reason"] == "insufficient_scope"
      assert Accounts.get_user(user.id)
    end

    test "one tenant cannot delete another by naming their email", %{conn: conn, key: key} do
      victim = insert_verified_user()

      conn
      |> authed_with_key(key)
      |> delete_json("/api/account", %{"confirm" => victim.email})
      |> json_response(422)

      assert Accounts.get_user(victim.id)
    end

    test "requires authentication", %{conn: conn, user: user} do
      conn
      |> put_req_header("accept", "application/json")
      |> delete_json("/api/account", %{"confirm" => user.email})
      |> json_response(401)

      assert Accounts.get_user(user.id)
    end
  end
end
