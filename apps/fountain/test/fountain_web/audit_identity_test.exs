defmodule FountainWeb.AuditIdentityTest do
  @moduledoc """
  Registration and logout leave a trail (#544).

  Identity events were recorded unevenly: OAuth signup wrote
  `auth.oauth.signup`, but email+password registration wrote nothing from
  either the browser form or `POST /api/auth/register` — the latter sits on
  `:api_public`, which carries no audit plug. Login was recorded and logout
  was not, so the trail could show sessions opening and never closing.
  """

  use FountainWeb.ConnCase, async: true

  alias Fountain.{Accounts, Audit}

  defp events_for(user_id), do: Audit.list_recent_for_user(user_id, 100)

  defp find_action(user_id, action) do
    Enum.find(events_for(user_id), &(&1.action == action))
  end

  describe "registration" do
    test "through the browser form", %{conn: conn} do
      email = "browser#{System.unique_integer([:positive])}@example.com"

      conn =
        post(conn, ~p"/auth/register", %{
          "user" => %{"email" => email, "password" => "password123"}
        })

      assert redirected_to(conn)

      user = Accounts.get_user_by_email(email)
      event = find_action(user.id, "account.registered")

      assert event, "a browser registration must be audited"
      assert event.resource_type == "user"
      assert event.resource_id == user.id
      assert event.actor == "ui"
      assert event.metadata["email"] == email
    end

    test "through POST /api/auth/register", %{conn: conn} do
      # The door with no audit plug on its pipeline — the gap this closes.
      email = "api#{System.unique_integer([:positive])}@example.com"

      conn = post_json(conn, "/api/auth/register", %{email: email, password: "password123"})
      assert %{"user_id" => user_id} = json_response(conn, 201)

      event = find_action(user_id, "account.registered")
      assert event, "an API registration must be audited"
      assert event.actor == "api"
      assert event.metadata["email"] == email
    end

    test "the password never reaches the trail", %{conn: conn} do
      email = "secret#{System.unique_integer([:positive])}@example.com"

      post_json(conn, "/api/auth/register", %{email: email, password: "hunter2-very-secret"})
      user = Accounts.get_user_by_email(email)

      events = events_for(user.id)

      # Guard the guard (#406): an empty list would pass the refute vacuously.
      assert Enum.any?(events, &(&1.action == "account.registered"))

      for event <- events do
        refute inspect(event) =~ "hunter2-very-secret"
      end
    end

    test "a rejected registration records nothing", %{conn: conn} do
      # The factory registers through the same function, so this user already
      # has exactly one `account.registered`. The duplicate-address attempt
      # below fails its changeset — no account is created, so the count must
      # not move.
      user = insert_verified_user()
      before = Enum.count(events_for(user.id), &(&1.action == "account.registered"))
      assert before == 1

      post(conn, ~p"/auth/register", %{
        "user" => %{"email" => user.email, "password" => "password123"}
      })

      assert Enum.count(events_for(user.id), &(&1.action == "account.registered")) == 1
    end
  end

  describe "logout" do
    test "is recorded, so a session has both ends", %{conn: conn} do
      user = insert_verified_user()

      conn = get(login_user(conn, user), ~p"/auth/logout")
      assert redirected_to(conn) == ~p"/auth/login"

      event = find_action(user.id, "auth.logout")
      assert event, "logging out must be audited"
      assert event.resource_type == "session"
      assert event.actor == "ui"
      assert event.user_id == user.id
    end

    test "a logout with no session records nothing", %{conn: conn} do
      # The route is public; hitting it signed-out is not a session ending.
      conn = get(conn, ~p"/auth/logout")

      assert redirected_to(conn) == ~p"/auth/login"
      assert Audit._unsafe_list_recent(50) |> Enum.filter(&(&1.action == "auth.logout")) == []
    end

    test "the post-deletion redirect does not write an orphan row", %{conn: conn} do
      # Account deletion redirects here to drop the cookie. The user row is
      # already gone, so a logout event would claim a user that no longer
      # exists — `account.deleted` already covers that path.
      user = insert_verified_user()

      conn = get(login_user(conn, user), ~p"/auth/logout?deleted=1")

      assert redirected_to(conn) == ~p"/auth/login"
      refute find_action(user.id, "auth.logout")
    end
  end
end
