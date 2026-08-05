defmodule FountainWeb.EmailVerificationController do
  @moduledoc """
  Handles the email verification link: GET /users/confirm/:token, and its
  JSON twin POST /api/auth/verify.

  Validates a Phoenix.Token (24 h TTL), marks the user verified, sets
  the session cookie (browser route only), and redirects to onboarding or
  dashboard.

  The API route exists so account activation does not require a browser
  (#522): the emailed link keeps pointing at the browser route, and a CLI
  prompts for the token from that URL. Both routes accept the same token —
  there is one verification secret, not two.

  After a successful verification, a Stripe Customer record is created
  via the `Fountain.Workers.StripeCustomerSync` job so that
  the Stripe Customer exists before the trial ends, avoiding a race at
  upgrade time.
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
                FountainWeb.Audited.from_conn(conn, "auth.email.verified", "user",
                  user_id: verified_user.id,
                  resource_id: verified_user.id
                )

                # Durable job rather than a linked Task: this used to be a bare
                # Task.async with no await, so it could be killed when the
                # request process finished and a Stripe error vanished silently,
                # leaving an account with no customer id.
                Fountain.Workers.StripeCustomerSync.enqueue(verified_user)

                # Only on this branch, never the already-verified one below —
                # the welcome fires on the verification transition (#449).
                Fountain.Workers.WelcomeEmail.enqueue(verified_user)

                conn
                |> log_in_user(verified_user)
                |> redirect(to: ~p"/onboarding/step_1")

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

  @doc """
  JSON completion of the same flow. Returns 200 on success (and on an
  already-verified account, which is the idempotent case a CLI retrying a
  request needs), 422 on an expired or invalid token.

  No session is issued: an API client wants a key, which it mints at
  `POST /api/auth/token` once the account is live.
  """
  def api_verify(conn, %{"token" => token}) do
    case Phoenix.Token.verify(conn, "email_verification", token, max_age: @token_max_age) do
      {:ok, user_id} -> verify_user(conn, Accounts.get_user(user_id))
      {:error, :expired} -> token_error(conn, "expired", "This verification link has expired.")
      {:error, _} -> token_error(conn, "invalid_token", "This verification link is invalid.")
    end
  end

  def api_verify(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "token is required"})
  end

  defp verify_user(conn, nil),
    do: token_error(conn, "invalid_token", "This verification link is invalid.")

  defp verify_user(conn, %{email_verified_at: %DateTime{}} = user) do
    json(conn, %{
      user_id: user.id,
      email_verified: true,
      message: "Your email is already verified."
    })
  end

  defp verify_user(conn, user) do
    case Accounts.verify_email(user) do
      {:ok, verified} ->
        FountainWeb.Audited.from_conn(conn, "auth.email.verified", "user",
          user_id: verified.id,
          resource_id: verified.id
        )

        # Same follow-on work the browser route does — the account must not
        # end up in a different state depending on which surface finished it.
        Fountain.Workers.StripeCustomerSync.enqueue(verified)
        Fountain.Workers.WelcomeEmail.enqueue(verified)

        json(conn, %{
          user_id: verified.id,
          email_verified: true,
          message: "Email verified. You can sign in now."
        })

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "verification_failed"})
    end
  end

  defp token_error(conn, error, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: error, message: message})
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
      ~p"/onboarding/step_1"
    end
  end
end
