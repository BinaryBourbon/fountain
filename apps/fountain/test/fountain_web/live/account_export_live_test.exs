defmodule FountainWeb.AccountExportLiveTest do
  @moduledoc """
  The account-page surface of data export (#288): the card, its promise about
  secrets, the request flow, the rate-limit message, and the download link.
  """

  use FountainWeb.ConnCase, async: true
  use Oban.Testing, repo: Fountain.Repo

  import Phoenix.LiveViewTest

  alias Fountain.Exports
  alias Fountain.Exports.Export
  alias Fountain.Repo
  alias Fountain.Workers.AccountExport

  test "the card states that secret values are excluded", %{conn: conn} do
    user = insert_verified_user()

    {:ok, _lv, html} = live(login_user(conn, user), ~p"/account")

    assert html =~ "Export your data"
    assert html =~ "secret values are deliberately excluded"
    assert html =~ "write-only on the way in"
  end

  test "requesting an export enqueues the job and shows pending status", %{conn: conn} do
    user = insert_verified_user()

    {:ok, lv, _html} = live(login_user(conn, user), ~p"/account")

    html = render_click(lv, "request_export")
    assert html =~ "Export started"
    assert html =~ "generating"

    assert [export] = Repo.all(Export)
    assert export.user_id == user.id
    assert_enqueued(worker: AccountExport, args: %{export_id: export.id, user_id: user.id})
  end

  test "a second request within the hour is refused", %{conn: conn} do
    user = insert_verified_user()

    {:ok, lv, _html} = live(login_user(conn, user), ~p"/account")

    render_click(lv, "request_export")
    html = render_click(lv, "request_export")

    assert html =~ "one export per hour"
    assert Repo.aggregate(Export, :count) == 1
  end

  test "a completed export shows the download link and its expiry", %{conn: conn} do
    user = insert_verified_user()
    {:ok, export} = Exports.request_export(user)
    :ok = perform_job(AccountExport, %{export_id: export.id, user_id: user.id})

    {:ok, _lv, html} = live(login_user(conn, user), ~p"/account")

    assert html =~ "Export ready"
    assert html =~ ~p"/account/exports/#{export.id}/download"
    assert html =~ "link expires"
  end

  test "the completion broadcast flips pending to ready without a reload", %{conn: conn} do
    user = insert_verified_user()

    {:ok, lv, _html} = live(login_user(conn, user), ~p"/account")
    assert render_click(lv, "request_export") =~ "generating"

    [export] = Repo.all(Export)
    :ok = perform_job(AccountExport, %{export_id: export.id, user_id: user.id})

    assert render(lv) =~ "Export ready"
  end
end
