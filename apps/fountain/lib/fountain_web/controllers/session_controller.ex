defmodule FountainWeb.SessionController do
  @moduledoc """
  Multi-tenant session management.

  HTML routes (email + password):
    GET  /auth/login   — render login form
    POST /auth/login   — authenticate, set session cookie
    GET  /auth/logout  — clear session, redirect to login

  Legacy single-tenant admin token routes are preserved at /login and /logout
  for backward compatibility with the operations runbook.
  """

  use FountainWeb, :controller

  alias Fountain.Accounts

  # The JSON sibling POST /api/auth/token has been limited to 10/hour since
  # launch; this form had no limit at all, so credential stuffing simply used
  # the HTML endpoint instead. Same bucket name as the JSON path so an attacker
  # cannot get a second allowance by switching surface.
  plug FountainWeb.Plugs.RateLimit,
       [bucket: "auth_token", max: 10, window_ms: 3_600_000]
       when action in [:create]

  # The legacy admin form brute-forces a single shared secret, so it gets a
  # tighter budget than a per-account login.
  plug FountainWeb.Plugs.RateLimit,
       [bucket: "admin_login", max: 5, window_ms: 3_600_000]
       when action in [:legacy_create]

  ## Multi-tenant email/password login

  def new(conn, _params) do
    render(conn, :new, error: nil, layout: false)
  end

  def create(conn, %{"email" => email, "password" => password}) do
    case Accounts.authenticate_user(email, password) do
      {:ok, user} ->
        FountainWeb.Audited.from_conn(conn, "auth.login", "session",
          user_id: user.id,
          actor: "ui",
          metadata: %{"result" => "ok"}
        )

        conn
        |> configure_session(renew: true)
        |> put_session(:user_id, user.id)
        |> put_session(:session_version, user.session_version)
        |> redirect(to: after_login_path(user))

      {:error, reason} ->
        # Failures matter more than successes here: a run of them against one
        # account is the signal you want, and there was no record of any.
        FountainWeb.Audited.from_conn(conn, "auth.login.failed", "session",
          actor: "ui",
          metadata: %{"email" => email, "reason" => to_string(reason)}
        )

        conn
        |> put_status(:unauthorized)
        |> render(:new, error: "Invalid email or password.", layout: false)
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> render(:new, error: "Email and password are required.", layout: false)
  end

  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/auth/login")
  end

  ## Legacy single-tenant admin token (kept for ops runbook compat)

  def legacy_new(conn, _params) do
    render(conn, :legacy_new, error: nil, layout: false)
  end

  def legacy_create(conn, %{"token" => token}) do
    expected = Application.fetch_env!(:fountain, :admin_token)

    if Plug.Crypto.secure_compare(token, expected) do
      conn
      |> configure_session(renew: true)
      |> put_session(:admin, true)
      |> redirect(to: ~p"/conversations")
    else
      conn
      |> put_status(:unauthorized)
      |> render(:legacy_new, error: "Invalid token", layout: false)
    end
  end

  def legacy_delete(conn, _) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/login")
  end

  ## Private

  defp after_login_path(user) do
    if user.onboarding_completed_at do
      ~p"/conversations"
    else
      ~p"/onboarding/step_1"
    end
  end
end
