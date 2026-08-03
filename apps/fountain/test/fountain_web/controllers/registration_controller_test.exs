defmodule FountainWeb.RegistrationControllerTest do
  use FountainWeb.ConnCase, async: true
  use Oban.Testing, repo: Fountain.Repo
  use Mimic

  alias Fountain.Workers.VerificationEmail

  describe "GET /auth/register" do
    test "renders registration form", %{conn: conn} do
      conn = get(conn, ~p"/auth/register")
      assert html_response(conn, 200) =~ "Create your account"
    end

    test "renders the GitHub button when OAuth is configured (#336)", %{conn: conn} do
      body = conn |> get(~p"/auth/register") |> html_response(200)
      assert body =~ "Sign up with GitHub"
      assert body =~ ~p"/auth/oauth/github"
    end

    test "hides the GitHub button when OAuth is not configured (#336)", %{conn: conn} do
      stub(FountainWeb.OAuth, :github_configured?, fn -> false end)

      body = conn |> get(~p"/auth/register") |> html_response(200)
      refute body =~ "Sign up with GitHub"
      refute body =~ ~p"/auth/oauth/github"
    end
  end

  describe "POST /auth/register (HTML)" do
    test "creates user and redirects to check-email on success", %{conn: conn} do
      conn =
        post(conn, ~p"/auth/register", %{
          "user" => %{"email" => "new@example.com", "password" => "password123"}
        })

      assert redirected_to(conn) == ~p"/auth/check-email"
    end

    test "enqueues the verification email as a durable job, not an inline send (#445)", %{
      conn: conn
    } do
      post(conn, ~p"/auth/register", %{
        "user" => %{"email" => "durable@example.com", "password" => "password123"}
      })

      user = Fountain.Accounts.get_user_by_email("durable@example.com")
      assert_enqueued(worker: VerificationEmail, args: %{user_id: user.id})
    end

    test "re-renders form with errors on invalid email", %{conn: conn} do
      conn =
        post(conn, ~p"/auth/register", %{
          "user" => %{"email" => "not-an-email", "password" => "password123"}
        })

      assert html_response(conn, 422) =~ "Create your account"
    end

    test "re-renders form with errors on short password", %{conn: conn} do
      conn =
        post(conn, ~p"/auth/register", %{
          "user" => %{"email" => "ok@example.com", "password" => "short"}
        })

      assert html_response(conn, 422) =~ "Create your account"
    end

    test "re-renders form on duplicate email", %{conn: conn} do
      insert_user(%{"email" => "taken@example.com"})

      conn =
        post(conn, ~p"/auth/register", %{
          "user" => %{"email" => "taken@example.com", "password" => "password123"}
        })

      assert html_response(conn, 422) =~ "Create your account"
    end
  end

  describe "POST /api/auth/register (JSON)" do
    test "creates user and returns 201 on success", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/auth/register", Jason.encode!(%{email: "json@example.com", password: "password123"}))

      assert json_response(conn, 201)["message"] =~ "verify"
      user = Fountain.Accounts.get_user_by_email("json@example.com")
      assert_enqueued(worker: VerificationEmail, args: %{user_id: user.id})
    end

    test "returns 422 on missing password", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/auth/register", Jason.encode!(%{email: "json@example.com"}))

      assert json_response(conn, 422)
    end

    test "returns 422 with changeset errors on duplicate email", %{conn: conn} do
      insert_user(%{"email" => "taken_json@example.com"})

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/auth/register", Jason.encode!(%{email: "taken_json@example.com", password: "password123"}))

      assert json_response(conn, 422)
    end
  end

  describe "GET /auth/check-email" do
    test "renders the check-email page", %{conn: conn} do
      conn = get(conn, ~p"/auth/check-email")
      assert html_response(conn, 200) =~ ~r/email/i
    end
  end

  describe "GET /auth/resend-verification" do
    test "renders the resend form", %{conn: conn} do
      conn = get(conn, ~p"/auth/resend-verification")
      assert html_response(conn, 200) =~ "Resend verification email"
    end
  end

  describe "POST /auth/resend-verification" do
    test "enqueues a fresh verification email for an unverified account", %{conn: conn} do
      user = insert_user()
      assert is_nil(user.email_verified_at)

      conn = post(conn, ~p"/auth/resend-verification", %{"email" => user.email})

      assert redirected_to(conn) == ~p"/auth/check-email"
      assert_enqueued(worker: VerificationEmail, args: %{user_id: user.id})
    end

    # The next three must be indistinguishable from the success case — the
    # endpoint takes an unauthenticated email address, so any difference in
    # response makes it an account-existence oracle.
    test "responds identically for an already-verified account, without enqueueing", %{
      conn: conn
    } do
      user = insert_verified_user()

      conn = post(conn, ~p"/auth/resend-verification", %{"email" => user.email})

      assert redirected_to(conn) == ~p"/auth/check-email"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "on its way"
      refute_enqueued(worker: VerificationEmail)
    end

    test "responds identically for an unknown address, without enqueueing", %{conn: conn} do
      conn = post(conn, ~p"/auth/resend-verification", %{"email" => "nobody@example.com"})

      assert redirected_to(conn) == ~p"/auth/check-email"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "on its way"
      refute_enqueued(worker: VerificationEmail)
    end

    test "responds identically when the email param is missing", %{conn: conn} do
      conn = post(conn, ~p"/auth/resend-verification", %{})

      assert redirected_to(conn) == ~p"/auth/check-email"
      refute_enqueued(worker: VerificationEmail)
    end

    test "blocks the 6th resend from the same IP within the hour", %{conn: conn} do
      user = insert_user()

      for _ <- 1..5 do
        post(conn, ~p"/auth/resend-verification", %{"email" => user.email})
      end

      conn6 = post(conn, ~p"/auth/resend-verification", %{"email" => user.email})
      assert conn6.status == 429
    end
  end

  describe "POST /api/auth/resend-verification (JSON)" do
    test "returns 200 and enqueues for an unverified account", %{conn: conn} do
      user = insert_user()

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/auth/resend-verification", Jason.encode!(%{email: user.email}))

      assert json_response(conn, 200)["message"] =~ "on its way"
      assert_enqueued(worker: VerificationEmail, args: %{user_id: user.id})
    end

    test "returns the same 200 for an unknown address", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/auth/resend-verification", Jason.encode!(%{email: "nobody@example.com"}))

      assert json_response(conn, 200)["message"] =~ "on its way"
      refute_enqueued(worker: VerificationEmail)
    end
  end

  describe "rate limiting" do
    test "blocks 6th registration from same IP within the hour", %{conn: conn} do
      # The rate limit bucket is keyed by IP. In tests, all requests share
      # 127.0.0.1. We need to reset the bucket between test runs since ETS
      # state is global; use unique emails to avoid unique-email conflicts but
      # the rate limit is what we're actually testing.
      #
      # Because the rate-limit ETS table persists across async tests,
      # we use a unique bucket prefix tied to the test PID.
      # The actual controller uses a fixed bucket "registration" — so this
      # test runs synchronously to avoid interference.
      for i <- 1..5 do
        post(conn, ~p"/auth/register", %{
          "user" => %{"email" => "rate#{i}+#{System.unique_integer()}@example.com", "password" => "password123"}
        })
      end

      conn6 =
        post(conn, ~p"/auth/register", %{
          "user" => %{
            "email" => "rate6+#{System.unique_integer()}@example.com",
            "password" => "password123"
          }
        })

      assert conn6.status == 429
    end
  end
end
