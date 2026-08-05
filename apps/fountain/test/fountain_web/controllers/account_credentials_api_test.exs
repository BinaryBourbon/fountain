defmodule FountainWeb.AccountCredentialsApiTest do
  @moduledoc """
  Password change and email change over a bearer token (#521).

  Both existed only as browser POSTs with session auth and CSRF, so an
  API-driven account could never rotate its own credentials.
  """

  use FountainWeb.ConnCase, async: true

  alias Fountain.Accounts

  setup do
    user = insert_verified_user(%{"password" => "old-password-123"})
    {_rec, key} = insert_api_key(user)
    {:ok, user: user, key: key}
  end

  describe "POST /api/auth/password" do
    test "changes the password when the current one is supplied", %{
      conn: conn,
      user: user,
      key: key
    } do
      body =
        conn
        |> authed_with_key(key)
        |> post_json("/api/auth/password", %{
          "current_password" => "old-password-123",
          "new_password" => "a-brand-new-password"
        })
        |> json_response(200)

      assert body["sessions_invalidated"] == true
      assert {:ok, _} = Accounts.authenticate_user(user.email, "a-brand-new-password")
    end

    test "refuses without the current password — a stolen key is not enough", %{
      conn: conn,
      user: user,
      key: key
    } do
      body =
        conn
        |> authed_with_key(key)
        |> post_json("/api/auth/password", %{
          "current_password" => "not-the-password",
          "new_password" => "attacker-chosen"
        })
        |> json_response(403)

      assert body["error"] == "invalid_current_password"
      assert {:ok, _} = Accounts.authenticate_user(user.email, "old-password-123")
    end

    test "the response states that API keys survive, because they do", %{
      conn: conn,
      key: key
    } do
      # The asymmetry that makes this endpoint sensitive: session_version is
      # bumped (browser sessions die) but API keys are separate credentials
      # and keep working. Documented in the response rather than left for a
      # caller rotating a leaked password to discover.
      body =
        conn
        |> authed_with_key(key)
        |> post_json("/api/auth/password", %{
          "current_password" => "old-password-123",
          "new_password" => "another-new-password"
        })
        |> json_response(200)

      assert body["api_keys_revoked"] == false
      assert {:ok, _user, _key} = Accounts.authenticate_api_key(key)
    end

    test "a weak new password is a changeset error and changes nothing", %{
      conn: conn,
      user: user,
      key: key
    } do
      body =
        conn
        |> authed_with_key(key)
        |> post_json("/api/auth/password", %{
          "current_password" => "old-password-123",
          "new_password" => "short"
        })
        |> json_response(422)

      assert body["errors"]["password"]
      assert {:ok, _} = Accounts.authenticate_user(user.email, "old-password-123")
    end

    test "missing params are 422", %{conn: conn, key: key} do
      conn
      |> authed_with_key(key)
      |> post_json("/api/auth/password", %{"new_password" => "only-one-field"})
      |> json_response(422)
    end

    test "records the same audit event the browser path does", %{conn: conn, user: user, key: key} do
      conn
      |> authed_with_key(key)
      |> post_json("/api/auth/password", %{
        "current_password" => "old-password-123",
        "new_password" => "audited-new-password"
      })
      |> json_response(200)

      actions = Fountain.Audit.list_recent_for_user(user.id, 50) |> Enum.map(& &1.action)
      assert "auth.password.changed" in actions
    end

    test "a sprite token cannot rotate the password", %{conn: conn, user: user} do
      {_rec, sprite_key} = insert_sprite_api_key(user)

      body =
        conn
        |> authed_with_key(sprite_key)
        |> post_json("/api/auth/password", %{
          "current_password" => "old-password-123",
          "new_password" => "sandbox-chosen-password"
        })
        |> json_response(403)

      assert body["reason"] == "insufficient_scope"
      assert {:ok, _} = Accounts.authenticate_user(user.email, "old-password-123")
    end
  end

  describe "POST /api/auth/email" do
    test "starts the change without applying it", %{conn: conn, user: user, key: key} do
      conn
      |> authed_with_key(key)
      |> post_json("/api/auth/email", %{
        "new_email" => "moved@example.com",
        "current_password" => "old-password-123"
      })
      |> json_response(200)

      # The address changes only when the emailed token comes back.
      assert Accounts.get_user(user.id).email == user.email
    end

    test "is not an availability oracle", %{conn: conn, user: user, key: key} do
      taken = insert_verified_user()

      free =
        conn
        |> authed_with_key(key)
        |> post_json("/api/auth/email", %{
          "new_email" => "definitely-free@example.com",
          "current_password" => "old-password-123"
        })
        |> json_response(200)

      used =
        build_conn()
        |> authed_with_key(key)
        |> post_json("/api/auth/email", %{
          "new_email" => taken.email,
          "current_password" => "old-password-123"
        })
        |> json_response(200)

      assert free == used
      assert Accounts.get_user(user.id).email == user.email
    end

    test "refuses a wrong current password", %{conn: conn, key: key} do
      body =
        conn
        |> authed_with_key(key)
        |> post_json("/api/auth/email", %{
          "new_email" => "moved@example.com",
          "current_password" => "wrong"
        })
        |> json_response(403)

      assert body["error"] == "invalid_current_password"
    end

    test "refuses a malformed address", %{conn: conn, key: key} do
      body =
        conn
        |> authed_with_key(key)
        |> post_json("/api/auth/email", %{
          "new_email" => "not-an-email",
          "current_password" => "old-password-123"
        })
        |> json_response(422)

      assert body["error"] == "invalid_email"
    end

    test "refuses the address the account already has", %{conn: conn, user: user, key: key} do
      body =
        conn
        |> authed_with_key(key)
        |> post_json("/api/auth/email", %{
          "new_email" => user.email,
          "current_password" => "old-password-123"
        })
        |> json_response(422)

      assert body["error"] == "same_email"
    end

    test "a sprite token cannot start an email change", %{conn: conn, user: user} do
      {_rec, sprite_key} = insert_sprite_api_key(user)

      conn
      |> authed_with_key(sprite_key)
      |> post_json("/api/auth/email", %{
        "new_email" => "sandbox@example.com",
        "current_password" => "old-password-123"
      })
      |> json_response(403)
    end

    test "requires authentication", %{conn: conn} do
      conn
      |> put_req_header("accept", "application/json")
      |> post_json("/api/auth/email", %{
        "new_email" => "x@example.com",
        "current_password" => "y"
      })
      |> json_response(401)
    end
  end
end
