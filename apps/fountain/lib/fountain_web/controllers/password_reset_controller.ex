defmodule FountainWeb.PasswordResetController do
  @moduledoc """
  Password reset flow.

  POST /api/auth/forgot          — request a reset email (rate-limited, always 200)
  POST /api/auth/reset           — apply the reset over JSON (#522)
  GET  /auth/reset/:token        — render the new-password form
  POST /auth/reset               — apply the reset, invalidate sessions
  GET  /auth/forgot-password     — render the "forgot password" request form

  The API and browser completions accept the same token: the emailed link
  keeps pointing at the browser route, and a CLI can prompt for the token
  out of that URL rather than shelling out to a browser.
  """

  use FountainWeb, :controller

  alias Fountain.Accounts
  alias Fountain.Emails.UserEmails

  # 1 hour TTL for reset tokens
  @token_max_age 3_600

  plug FountainWeb.Plugs.RateLimit,
       [bucket: "password_reset", max: 5, window_ms: 3_600_000]
       when action in [:api_forgot]

  # Submitting a reset was the one auth endpoint with no limit. The token is
  # Phoenix.Token-signed so it is not practically guessable, but an unlimited
  # endpoint that does bcrypt work on every call is a cheap way to burn CPU.
  plug FountainWeb.Plugs.RateLimit,
       [bucket: "password_reset_submit", max: 10, window_ms: 3_600_000]
       when action in [:reset, :api_reset]

  ## HTML — "forgot password" form

  def forgot_form(conn, _params) do
    render(conn, :forgot_form, layout: false)
  end

  ## API — request a reset email

  def api_forgot(conn, %{"email" => email}) do
    # Always return 200 to prevent email enumeration
    user = Accounts.get_user_by_email(email)

    if user do
      # session_version rides inside the token (#325): reset_password/2
      # bumps it, so a successful reset invalidates every outstanding reset
      # token for the user — without this, a used link stayed live for the
      # rest of its hour (shared inbox, forwarded mail, proxy log).
      token = Phoenix.Token.sign(conn, "password_reset", {user.id, user.session_version})
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

  ## API — apply the reset

  def api_reset(conn, %{"token" => token, "password" => password}) do
    case verify_reset_token(conn, token) do
      {:ok, user} ->
        apply_api_reset(conn, user, password)

      {:error, :expired} ->
        reset_token_error(conn, "expired", "This reset link has expired. Request a new one.")

      {:error, _} ->
        reset_token_error(conn, "invalid_token", "This reset link is invalid.")
    end
  end

  def api_reset(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "token and password are required"})
  end

  defp apply_api_reset(conn, user, password) do
    case Accounts.reset_password(user, password) do
      {:ok, _user} ->
        # session_version is bumped, so every session and every other
        # outstanding reset token dies here too — the same security-relevant
        # event the browser path records.
        FountainWeb.Audited.from_conn(conn, "auth.password.reset", "user",
          user_id: user.id,
          resource_id: user.id
        )

        json(conn, %{message: "Password updated. Sign in with your new password."})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(FountainWeb.ChangesetJSON)
        |> render(:error, changeset: changeset)
    end
  end

  defp reset_token_error(conn, error, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: error, message: message})
  end

  ## HTML — render reset form

  def reset_form(conn, %{"token" => token}) do
    case verify_reset_token(conn, token) do
      {:ok, _user} ->
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
    case verify_reset_token(conn, token) do
      {:ok, user} ->
        case Accounts.reset_password(user, password) do
              {:ok, _user} ->
                # Also invalidates every existing session, so this is a
                # security-relevant event even when the user initiated it.
                FountainWeb.Audited.from_conn(conn, "auth.password.reset", "user",
                  user_id: user.id,
                  resource_id: user.id
                )

                conn
                |> configure_session(drop: true)
                |> put_flash(:info, "Password updated. Please sign in with your new password.")
                |> redirect(to: ~p"/auth/login")

              {:error, changeset} ->
                errors =
                  Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)

                password_error = errors |> Map.get(:password, []) |> List.first()

                conn
                |> put_status(:unprocessable_entity)
                |> render(:reset_form,
                  token: token,
                  error: password_error || "Could not update password.",
                  layout: false
                )
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

  # Single-use check (#325): the token carries the session_version it was
  # issued against; reset_password/2 bumps it, so a token issued before the
  # last successful reset — including the one just used — no longer matches
  # and is treated as invalid. Legacy bare-user_id tokens (issued before
  # this shipped) fail the tuple match and die at most one TTL after deploy.
  defp verify_reset_token(conn, token) do
    with {:ok, {user_id, session_version}} <-
           Phoenix.Token.verify(conn, "password_reset", token, max_age: @token_max_age),
         %{session_version: ^session_version} = user <- Accounts.get_user(user_id) do
      {:ok, user}
    else
      {:error, :expired} -> {:error, :expired}
      _ -> {:error, :invalid}
    end
  end
end
