defmodule FountainWeb.OnboardingControllerTest do
  @moduledoc """
  Onboarding completion over the API (#525).

  `complete_onboarding/1` had one caller, the wizard LiveView, so an account
  driven entirely through the API stayed permanently un-onboarded and a later
  browser visit re-entered a wizard the user had no reason to see.
  """

  use FountainWeb.ConnCase, async: true

  alias Fountain.Accounts

  setup do
    user = insert_verified_user()
    {_rec, key} = insert_api_key(user)
    {:ok, user: user, key: key}
  end

  describe "GET /api/account/onboarding" do
    test "reports an un-onboarded account", %{conn: conn, key: key} do
      body =
        conn
        |> authed_with_key(key)
        |> get("/api/account/onboarding")
        |> json_response(200)

      assert body["data"]["completed"] == false
      assert body["data"]["completed_at"] == nil
    end
  end

  describe "POST /api/account/onboarding/complete" do
    test "completes onboarding", %{conn: conn, user: user, key: key} do
      body =
        conn
        |> authed_with_key(key)
        |> post("/api/account/onboarding/complete")
        |> json_response(200)

      assert body["data"]["completed"] == true
      assert body["data"]["state"] == "completed"

      reloaded = Accounts.get_user(user.id)
      assert reloaded.onboarding_completed_at
      assert reloaded.onboarding_state == "completed"
    end

    test "is idempotent and does not move the original timestamp", %{
      conn: conn,
      user: user,
      key: key
    } do
      conn
      |> authed_with_key(key)
      |> post("/api/account/onboarding/complete")
      |> json_response(200)

      first_at = Accounts.get_user(user.id).onboarding_completed_at

      build_conn()
      |> authed_with_key(key)
      |> post("/api/account/onboarding/complete")
      |> json_response(200)

      assert Accounts.get_user(user.id).onboarding_completed_at == first_at
    end

    test "a sprite token cannot complete onboarding for the account", %{conn: conn, user: user} do
      {_rec, sprite_key} = insert_sprite_api_key(user)

      conn
      |> authed_with_key(sprite_key)
      |> post("/api/account/onboarding/complete")
      |> json_response(403)

      refute Accounts.get_user(user.id).onboarding_completed_at
    end

    test "requires authentication", %{conn: conn} do
      conn
      |> put_req_header("accept", "application/json")
      |> post("/api/account/onboarding/complete")
      |> json_response(401)
    end
  end

  describe "GET /api/auth/me" do
    test "carries onboarding and verification state", %{conn: conn, key: key} do
      body = conn |> authed_with_key(key) |> get("/api/auth/me") |> json_response(200)

      assert body["email_verified"] == true
      assert body["onboarding_completed"] == false

      build_conn()
      |> authed_with_key(key)
      |> post("/api/account/onboarding/complete")
      |> json_response(200)

      after_body =
        build_conn() |> authed_with_key(key) |> get("/api/auth/me") |> json_response(200)

      assert after_body["onboarding_completed"] == true
      assert after_body["onboarding_state"] == "completed"
    end
  end
end
