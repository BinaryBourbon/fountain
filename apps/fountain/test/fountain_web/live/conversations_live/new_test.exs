defmodule FountainWeb.ConversationsLive.NewTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "mount" do
    test "renders new conversation form for authenticated user", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)

      {:ok, _view, html} = live(conn, ~p"/conversations/new")

      assert html =~ "phx-submit"
      assert html =~ "<textarea"
    end

    test "redirects unauthenticated user to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/conversations/new")
      assert path =~ "/auth/login"
    end

    test "redirects canceled subscription user to billing", %{conn: conn} do
      user = insert_verified_user()

      {:ok, updated} =
        user
        |> Fountain.Accounts.User.billing_changeset(%{subscription_status: "canceled"})
        |> Fountain.Repo.update()

      conn = login_user(conn, updated)

      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/conversations/new")
      assert path == "/account/billing"
    end
  end

  describe "navigation idempotency" do
    # Regression: the sidebar '+ New Conversation' button previously used
    # navigate= which is a no-op when already on /conversations/new.
    # This test ensures the page mounts fresh each time (the href= fix
    # is on the client side, but we verify mount is side-effect free).
    test "mounting /conversations/new twice in a row succeeds both times", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)

      {:ok, _view1, html1} = live(conn, ~p"/conversations/new")
      {:ok, _view2, html2} = live(conn, ~p"/conversations/new")

      assert html1 =~ "<textarea"
      assert html2 =~ "<textarea"
    end
  end
end
