defmodule FountainWeb.UeberauthController do
  @moduledoc """
  Handles Ueberauth OAuth requests and callbacks.

  Routes:
    GET /auth/oauth/:provider           — request (Ueberauth redirects to provider)
    GET /auth/oauth/:provider/callback  — callback (Ueberauth populates assigns)

  Currently only GitHub is wired (ueberauth_github strategy).
  """

  use FountainWeb, :controller

  # Ueberauth's plug handles the request phase (redirect to the provider)
  # and the callback phase (parse the response into assigns). It MUST be
  # in the controller's plug pipeline — otherwise `request/2` is hit
  # directly and falls through to the "Unknown OAuth provider" branch.
  # The `base_path` in config/config.exs must match the route prefix
  # (`/auth/oauth`) for the plug to recognize the path.
  plug Ueberauth

  # Only fires if Ueberauth passes through (unknown / unconfigured provider).
  def request(conn, _params) do
    conn
    |> put_flash(:error, "Unknown OAuth provider.")
    |> redirect(to: ~p"/auth/login")
  end

  # On success Ueberauth sets `conn.assigns.ueberauth_auth`.
  # On failure it sets `conn.assigns.ueberauth_failure`.
  def callback(%{assigns: %{ueberauth_failure: failure}} = conn, _params) do
    reason =
      case failure.errors do
        [%{message: msg} | _] when is_binary(msg) -> msg
        _ -> "Authentication failed."
      end

    conn
    |> put_flash(:error, reason)
    |> redirect(to: ~p"/auth/login")
  end

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    provider = to_string(auth.provider)
    provider_uid = to_string(auth.uid)
    email = get_in(auth.info, [Access.key(:email)])

    if is_nil(email) or email == "" do
      conn
      |> put_flash(
        :error,
        "GitHub did not return a verified email address. " <>
          "Please add a public email to your GitHub account and try again."
      )
      |> redirect(to: ~p"/auth/login")
    else
      attrs = %{"email" => email}

      case Fountain.Accounts.upsert_oauth_user(provider, provider_uid, attrs) do
        {:ok, user, :new} ->
          conn
          |> configure_session(renew: true)
          |> put_session(:user_id, user.id)
          |> put_session(:session_version, user.session_version)
          |> redirect(to: ~p"/onboarding/step_1")

        {:ok, user, :existing} ->
          conn
          |> configure_session(renew: true)
          |> put_session(:user_id, user.id)
          |> put_session(:session_version, user.session_version)
          |> redirect(to: ~p"/")

        {:error, _changeset} ->
          conn
          |> put_flash(:error, "Could not sign in with GitHub. Please try again.")
          |> redirect(to: ~p"/auth/login")
      end
    end
  end
end
