defmodule FountainWeb.PasswordResetController do
  @moduledoc """
  Password reset flow.

  POST /api/auth/forgot          — request a reset email (rate-limited, always 200)
  GET  /auth/reset/:token        — render the new-password form
  POST /auth/reset               — apply the reset, invalidate sessions
  GET  /auth/forgot-password     — render the "forgot password" request form
  """

  use FountainWeb, :controller

  alias Fountain.Accounts
  alias Fountain.Emails.UserEmails

  # 1 hour TTL for reset tokens
  @token_max_age 3_600

  plug FountainWeb.Plugs.RateLimit,
       [bucket: "password_reset", max: 5, window_ms: 3_600_000]
       when action in [:api_forgot]

  ## HTML — "forgot password" form

  def forgot_form(conn, _params) do
    render(conn, :forgot_form, layout: false)
  end

  ## API — request a reset email

  def api_forgot(conn, %{"email" => email}) do
    # Always return 200 to prevent email enumeration
    user = Accounts.get_user_by_email(email)

    if user do
      token = Phoenix.Token.sign(conn, "password_reset", user.id)
      Task.async(fn -> UserEmails.deliver_password_reset_email(user, token) end)
    end

    conn
    |> put_status(:ok)
    |> json(%{message: "If that address is registered, a reset email is on its way."})
  end

  def api_forgot(conn, _params) do
    conn
    |> put_status(:ok)
    |> json(%{message: "If that address is registered, a reset email is on its way."})
  end

  ## HTML — render reset form

  def reset_form(conn, %{"token" => token}) do
    case Phoenix.Token.verify(conn, "password_reset", token, max_age: @token_max_age) do
      {:ok, _user_id} ->
        render(conn, :reset_form, token: token, error: nil, layout: false)

      {:error, :expired} ->
        conn
        |> put_flash(:error, "This reset link has expired. Please request a new one.")
        |> redirect(to: ~p"/auth/forgot-password")

      {:error, _} ->
        conn
        |> put_flash(:error, "This reset link is invalid.")
        |> redirect(to: ~p"/auth/forgot-password")
    end
  end

  ## HTML — apply the reset

  def reset(conn, %{"token" => token, "password" => password}) do
    case Phoenix.Token.verify(conn, "password_reset", token, max_age: @token_max_age) do
      {:ok, user_id} ->
        case Accounts.get_user(user_id) do
          nil ->
            conn
            |> put_flash(:error, "That reset link is invalid.")
            |> redirect(to: ~p"/auth/forgot-password")

          user ->
            case Accounts.reset_password(user, password) do
              {:ok, _user} ->
                conn
                |> configure_session(drop: true)
                |> put_flash(:info, "Password updated. Please sign in with your new password.")
                |> redirect(to: ~p"/auth/login")

              {:error, changeset} ->
                errors =
                  Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)

                password_error = errors |> Map.get(:password, []) |> List.first()

                render(conn, :reset_form,
                  token: token,
                  error: password_error || "Could not update password.",
                  layout: false
                )
            end
        end

      {:error, :expired} ->
        conn
        |> put_flash(:error, "This reset link has expired. Please request a new one.")
        |> redirect(to: ~p"/auth/forgot-password")

      {:error, _} ->
        conn
        |> put_flash(:error, "This reset link is invalid.")
        |> redirect(to: ~p"/auth/forgot-password")
    end
  end

  def reset(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "token and password are required"})
  end
end
