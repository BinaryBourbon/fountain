defmodule FountainWeb.Plugs.AnalyticsIdentityTest do
  @moduledoc """
  The seam between the visitor and the account.

  A person's history before they signed up lives under an anonymous id the
  browser generated; everything after lives under `user.id`. Without the merge
  these are two people, the acquisition funnel has no top, and no report can
  say where a converting account came from. These tests hold the merge to the
  one property that matters: it fires on the *transition*, so a new sign-in
  door is covered without being edited.
  """

  use FountainWeb.ConnCase, async: false

  alias Fountain.Analytics

  @anon_id "0198c0de-anon-4b0d-9c1e-000000000001"

  setup do
    previous = Application.get_env(:fountain, :posthog_project_api_key)
    Application.put_env(:fountain, :posthog_project_api_key, "phc_test")
    Fountain.FeatureFlags.reset()

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:fountain, :posthog_project_api_key)
        key -> Application.put_env(:fountain, :posthog_project_api_key, key)
      end

      Fountain.FeatureFlags.reset()
    end)

    test = self()

    Req.Test.stub(Analytics, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:posthog, Jason.decode!(body)})
      Req.Test.json(conn, %{"status" => 1})
    end)

    :ok
  end

  defp captured do
    receive do
      {:posthog, %{"batch" => batch}} -> batch ++ captured()
    after
      0 -> []
    end
  end

  defp merges do
    Enum.filter(captured(), &Map.has_key?(&1["properties"], "$anon_distinct_id"))
  end

  # Drain whatever registering the account produced, so the assertions below
  # only see what the request under test sent.
  defp forget_setup, do: captured()

  defp with_anon_cookie(conn, id) do
    put_req_cookie(conn, "ph_phc_test_posthog", Jason.encode!(%{"distinct_id" => id}))
  end

  describe "a browser session beginning" do
    test "merges the anonymous visitor into the account on password login", %{conn: conn} do
      user = insert_verified_user(password: "correct-horse-battery")
      forget_setup()

      conn =
        conn
        |> with_anon_cookie(@anon_id)
        |> post(~p"/auth/login", %{
          "email" => user.email,
          "password" => "correct-horse-battery"
        })

      assert redirected_to(conn)

      assert [merge] = merges()
      assert merge["event"] == "$identify"
      assert merge["distinct_id"] == user.id
      assert merge["properties"]["$anon_distinct_id"] == @anon_id
    end

    test "the signup funnel merges at verification, because that is where the session starts",
         %{conn: conn} do
      # Registration itself does not sign anyone in — it redirects to
      # check-email — so there is nothing to merge into yet. The merge lands
      # one step later, on the verification link, and it still carries the
      # anonymous id because the cookie is the same browser's. This is the
      # whole acquisition path: landing page to account, one person.
      forget_setup()

      conn =
        conn
        |> with_anon_cookie(@anon_id)
        |> post(~p"/auth/register", %{
          "user" => %{
            "email" => "brand-new@example.com",
            "password" => "correct-horse-battery",
            "password_confirmation" => "correct-horse-battery"
          }
        })

      assert redirected_to(conn) == ~p"/auth/check-email"
      assert merges() == []

      user = Fountain.Accounts.get_user_by_email("brand-new@example.com")
      token = Phoenix.Token.sign(FountainWeb.Endpoint, "email_verification", user.id)
      forget_setup()

      build_conn()
      |> with_anon_cookie(@anon_id)
      |> get(~p"/users/confirm/#{token}")

      assert [merge] = merges()
      assert merge["distinct_id"] == user.id
      assert merge["properties"]["$anon_distinct_id"] == @anon_id
    end

    test "merges on email verification, which signs the account in too", %{conn: conn} do
      user = insert_user()
      token = Phoenix.Token.sign(FountainWeb.Endpoint, "email_verification", user.id)
      forget_setup()

      conn = conn |> with_anon_cookie(@anon_id) |> get(~p"/users/confirm/#{token}")

      assert redirected_to(conn)
      assert [merge] = merges()
      assert merge["distinct_id"] == user.id
    end
  end

  describe "requests that are not a session beginning" do
    test "an already-signed-in request merges nothing", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)
      forget_setup()

      conn = conn |> with_anon_cookie(@anon_id) |> get(~p"/")

      assert conn.status == 200
      assert merges() == []
    end

    test "a failed login merges nothing", %{conn: conn} do
      user = insert_verified_user(password: "correct-horse-battery")
      forget_setup()

      conn =
        conn
        |> with_anon_cookie(@anon_id)
        |> post(~p"/auth/login", %{"email" => user.email, "password" => "wrong-password"})

      refute get_session(conn, :user_id)
      assert merges() == []
    end

    test "an anonymous page view merges nothing", %{conn: conn} do
      forget_setup()

      conn = conn |> with_anon_cookie(@anon_id) |> get(~p"/")

      assert conn.status == 200
      assert merges() == []
    end
  end

  describe "when the merge cannot be made" do
    test "no PostHog cookie signs in normally and sends no merge", %{conn: conn} do
      user = insert_verified_user(password: "correct-horse-battery")
      forget_setup()

      conn =
        post(conn, ~p"/auth/login", %{
          "email" => user.email,
          "password" => "correct-horse-battery"
        })

      assert redirected_to(conn)
      assert get_session(conn, :user_id) == user.id
      assert merges() == []
    end

    test "a cookie from a different PostHog project is ignored", %{conn: conn} do
      user = insert_verified_user(password: "correct-horse-battery")
      forget_setup()

      conn =
        conn
        |> put_req_cookie(
          "ph_phc_someone_elses_project_posthog",
          Jason.encode!(%{"distinct_id" => @anon_id})
        )
        |> post(~p"/auth/login", %{
          "email" => user.email,
          "password" => "correct-horse-battery"
        })

      assert redirected_to(conn)
      assert merges() == []
    end

    test "an unparseable cookie never breaks the sign-in", %{conn: conn} do
      user = insert_verified_user(password: "correct-horse-battery")
      forget_setup()

      conn =
        conn
        |> put_req_cookie("ph_phc_test_posthog", "{not json at all")
        |> post(~p"/auth/login", %{
          "email" => user.email,
          "password" => "correct-horse-battery"
        })

      assert redirected_to(conn)
      assert get_session(conn, :user_id) == user.id
      assert merges() == []
    end

    test "a cookie with no distinct_id never breaks the sign-in", %{conn: conn} do
      user = insert_verified_user(password: "correct-horse-battery")
      forget_setup()

      conn =
        conn
        |> put_req_cookie("ph_phc_test_posthog", Jason.encode!(%{"something" => "else"}))
        |> post(~p"/auth/login", %{
          "email" => user.email,
          "password" => "correct-horse-battery"
        })

      assert redirected_to(conn)
      assert get_session(conn, :user_id) == user.id
      assert merges() == []
    end

    test "with no project key nothing is read and nothing is sent", %{conn: conn} do
      Application.delete_env(:fountain, :posthog_project_api_key)
      user = insert_verified_user(password: "correct-horse-battery")

      conn =
        conn
        |> with_anon_cookie(@anon_id)
        |> post(~p"/auth/login", %{
          "email" => user.email,
          "password" => "correct-horse-battery"
        })

      assert redirected_to(conn)
      assert get_session(conn, :user_id) == user.id
    end
  end
end
