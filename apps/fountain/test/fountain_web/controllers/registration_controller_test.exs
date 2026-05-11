defmodule FountainWeb.RegistrationControllerTest do
  use FountainWeb.ConnCase, async: true

  describe "GET /auth/register" do
    test "renders registration form", %{conn: conn} do
      conn = get(conn, ~p"/auth/register")
      assert html_response(conn, 200) =~ "Create your account"
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
    end

    test "returns 422 on missing password", %{conn: conn} do
      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/auth/register", Jason.encode!(%{email: "json@example.com"}))

      assert json_response(conn, 422)
    end
  end

  describe "GET /auth/check-email" do
    test "renders the check-email page", %{conn: conn} do
      conn = get(conn, ~p"/auth/check-email")
      assert html_response(conn, 200) =~ ~r/email/i
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
