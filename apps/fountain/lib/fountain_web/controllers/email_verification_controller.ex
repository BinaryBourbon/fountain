defmodule FountainWeb.EmailVerificationController do
  @moduledoc """
  Handles the email verification link: GET /users/confirm/:token

  Validates a Phoenix.Token (24 h TTL), marks the user verified, sets
  the session cookie, and redirects to onboarding or dashboard.
  """

  use FountainWeb, :controller

  alias Fountain.Accounts

  # 24 hours in seconds
  @token_max_age 86_400

  def confirm(conn, %{"token" => token}) do
    case Phoenix.Token.verify(conn, "email_verification", token, max_age: @token_max_age) do
      {:ok, user_id} ->
        case Accounts.get_user(user_id) do
          nil ->
            conn
            |> put_flash(:error, "That verification link is invalid.")
            |> redirect(to: ~p"/auth/login")

          user when not is_nil(user.email_verified_at) ->
            # Already verified — log in and redirect
            conn
            |> log_in_user(user)
            |> put_flash(:info, "Your email is already verified.")
            |> redirect(to: destination(user))

          user ->
            case Accounts.verify_email(user) do
              {:ok, verified_user} ->
                conn
                |> log_in_user(verified_user)
                |> redirect(to: "/onboarding/step/1")

              {:error, _changeset} ->
                conn
                |> put_flash(:error, "Something went wrong. Please try again.")
                |> redirect(to: ~p"/auth/login")
            end
        end

      {:error, :expired} ->
        conn
        |> put_flash(:error, "This verification link has expired.")
        |> redirect(to: ~p"/auth/login")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "This verification link is invalid.")
        |> redirect(to: ~p"/auth/login")
    end
  end

  ## Helpers

  defp log_in_user(conn, user) do
    conn
    |> configure_session(renew: true)
    |> put_session(:user_id, user.id)
    |> put_session(:session_version, user.session_version)
  end

  defp destination(user) do
    if user.onboarding_completed_at do
      ~p"/"
    else
      "/onboarding/step/1"
    end
  end
end
