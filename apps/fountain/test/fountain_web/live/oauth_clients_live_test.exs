defmodule FountainWeb.OAuthClientsLiveTest do
  @moduledoc "Account → OAuth apps (#1125)."
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.OAuth

  test "registers an app and shows its generated client_id", %{conn: conn} do
    user = insert_verified_user()
    {:ok, view, _html} = conn |> login_user(user) |> live(~p"/account/oauth-apps")

    html =
      view
      |> element("button", "Register an app")
      |> render_click()

    assert html =~ "Redirect URIs"

    html =
      view
      |> form("form[phx-submit=save]", %{
        "name" => "Notes",
        "redirect_uris" => "https://abc.sprites.app/callback\nhttp://localhost:5173/callback"
      })
      |> render_submit()

    assert [client] = OAuth.list_clients(user.id)

    assert client.redirect_uris == [
             "https://abc.sprites.app/callback",
             "http://localhost:5173/callback"
           ]

    assert html =~ client.client_id
    assert html =~ "In development"
  end

  test "shows the validation error rather than saving", %{conn: conn} do
    user = insert_verified_user()
    {:ok, view, _html} = conn |> login_user(user) |> live(~p"/account/oauth-apps")

    view |> element("button", "Register an app") |> render_click()

    html =
      view
      |> form("form[phx-submit=save]", %{
        "name" => "Notes",
        "redirect_uris" => "http://notes.test/callback"
      })
      |> render_submit()

    assert html =~ "must be https, unless loopback"
    assert OAuth.list_clients(user.id) == []
  end

  test "edits and deletes, and never shows another account's app", %{conn: conn} do
    user = insert_verified_user()
    mine = insert_oauth_client(user_id: user.id, name: "Mine")
    theirs = insert_oauth_client(name: "Theirs")

    {:ok, view, html} = conn |> login_user(user) |> live(~p"/account/oauth-apps")

    assert html =~ "Mine"
    refute html =~ theirs.client_id

    view |> element("button[phx-value-id='#{mine.id}'][phx-click=edit]") |> render_click()

    view
    |> form("form[phx-submit=save]", %{
      "name" => "Renamed",
      "redirect_uris" => "https://new.test/callback"
    })
    |> render_submit()

    assert OAuth.get_client_record(mine.id, user.id).name == "Renamed"

    view |> element("button[phx-value-id='#{mine.id}'][phx-click=delete]") |> render_click()

    assert OAuth.list_clients(user.id) == []
  end
end
