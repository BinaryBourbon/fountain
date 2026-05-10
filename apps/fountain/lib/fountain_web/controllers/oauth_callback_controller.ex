defmodule FountainWeb.OAuthCallbackController do
  @moduledoc """
  Handles GitHub OAuth via Ueberauth.

  GET /auth/oauth/github           — Ueberauth redirects to GitHub
  GET /auth/oauth/github/callback  — GitHub redirects back here

  On success:
  - Upserts the user by primary verified email from GitHub.
  - New users: skip email verification; redirect to /onboarding/step/1.
  - Existing users: redirect to / (dashboard).
  - Creates/upserts an `oauth_identities` row either way.

  On failure: redirects to login with an error flash.
  """

  use FountainWeb, :controller

  alias Fountain.Accounts

  # Ueberauth sets `conn.assigns.ueberauth_auth` on success
  # and `conn.assigns.ueberauth_failure` on failure.

  def callback(%{assigns: %{ueberauth_failure: failure}} = conn, _params) do
    reason =
      failure.errors
      |> List.first()
      |> case do
        nil -> "Authentication failed."
        err -> err.message || "Authentication failed."
      end

    conn
    |> put_flash(:error, reason)
    |> redirect(to: ~p"/auth/login")
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    provider = to_string(auth.provider)
    provider_uid = to_string(auth.uid)

    email =
      case auth.info do
        %{email: email} when is_binary(email) and email != "" -> email
        _ -> nil
      end

    if is_nil(email) do
      conn
      |> put_flash(:error, "GitHub did not return a verified email. Please add a public email to your GitHub account.")
      |> redirect(to: ~p"/auth/login")
    else
      attrs = %{"email" => email}

      case Accounts.upsert_oauth_user(provider, provider_uid, attrs) do
        {:ok, user, :new} ->
          conn
          |> log_in_user(user)
          |> redirect(to: "/onboarding/step/1")

        {:ok, user, :existing} ->
          conn
          |> log_in_user(user)
          |> redirect(to: ~p"/")

        {:error, _changeset} ->
          conn
          |> put_flash(:error, "Could not sign in with GitHub. Please try again.")
          |> redirect(to: ~p"/auth/login")
      end
    end
  end

  defp log_in_user(conn, user) do
    conn
    |> configure_session(renew: true)
    |> put_session(:user_id, user.id)
    |> put_session(:session_version, user.session_version)
  end
end
