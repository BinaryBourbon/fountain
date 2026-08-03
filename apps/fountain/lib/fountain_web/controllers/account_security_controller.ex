defmodule FountainWeb.AccountSecurityController do
  @moduledoc """
  Credential management for a logged-in user (#448).

  The forms live on `AccountSecurityLive`, but the actions are controller
  POSTs, for two reasons a LiveView handler can't satisfy: `change_password/2`
  must rewrite the session cookie (the password change bumps
  `session_version`, and only a controller can re-issue the session so the
  *current* browser survives while every other session dies), and both
  actions want `FountainWeb.Plugs.RateLimit`, which is a plug.

  `confirm_email_change/2` is public (no session): the link lands from an
  inbox, possibly in a browser that has never seen this app.
  """

  use FountainWeb, :controller

  alias Fountain.Accounts

  plug FountainWeb.Plugs.RateLimit,
       [bucket: "account_security", max: 10, window_ms: 3_600_000]
       when action in [:change_password, :request_email_change]

  def change_password(conn, %{"current_password" => current, "new_password" => new}) do
    user = conn.assigns.current_user

    case Accounts.change_password(user, current, new) do
      {:ok, updated} ->
        FountainWeb.Audited.from_conn(conn, "auth.password.changed", "user",
          user_id: updated.id,
          resource_id: updated.id
        )

        conn
        # Re-issue this session against the bumped session_version: the
        # change kills every OTHER session, not the one that made it.
        |> configure_session(renew: true)
        |> put_session(:user_id, updated.id)
        |> put_session(:session_version, updated.session_version)
        |> put_flash(:info, "Password updated. Other sessions have been signed out.")
        |> redirect(to: ~p"/account/security")

      {:error, :invalid_current_password} ->
        conn
        |> put_flash(:error, "Current password is incorrect.")
        |> redirect(to: ~p"/account/security")

      {:error, :no_password} ->
        conn
        |> put_flash(:error, "This account signs in with GitHub and has no password.")
        |> redirect(to: ~p"/account/security")

      {:error, %Ecto.Changeset{} = changeset} ->
        msg =
          changeset
          |> Ecto.Changeset.traverse_errors(fn {m, _} -> m end)
          |> Map.get(:password, ["Could not update password."])
          |> List.first()

        conn
        |> put_flash(:error, "New password: #{msg}")
        |> redirect(to: ~p"/account/security")
    end
  end

  def change_password(conn, _params) do
    conn
    |> put_flash(:error, "Current and new password are required.")
    |> redirect(to: ~p"/account/security")
  end

  def request_email_change(conn, %{"new_email" => new_email, "current_password" => current}) do
    user = conn.assigns.current_user

    case Accounts.request_email_change(user, new_email, current) do
      :ok ->
        FountainWeb.Audited.from_conn(conn, "auth.email.change_requested", "user",
          user_id: user.id,
          resource_id: user.id,
          metadata: %{"new_email" => String.downcase(String.trim(new_email))}
        )

        conn
        # Same phrasing whether or not the address was free — this endpoint
        # must not be an availability oracle.
        |> put_flash(
          :info,
          "If that address is available, a confirmation link is on its way to it. " <>
            "Your email only changes when the link is clicked."
        )
        |> redirect(to: ~p"/account/security")

      {:error, :invalid_current_password} ->
        conn
        |> put_flash(:error, "Current password is incorrect.")
        |> redirect(to: ~p"/account/security")

      {:error, :no_password} ->
        conn
        |> put_flash(:error, "This account signs in with GitHub and has no password.")
        |> redirect(to: ~p"/account/security")

      {:error, :invalid_email} ->
        conn
        |> put_flash(:error, "That doesn't look like an email address.")
        |> redirect(to: ~p"/account/security")

      {:error, :same_email} ->
        conn
        |> put_flash(:error, "That is already your email address.")
        |> redirect(to: ~p"/account/security")
    end
  end

  def request_email_change(conn, _params) do
    conn
    |> put_flash(:error, "New email and current password are required.")
    |> redirect(to: ~p"/account/security")
  end

  def confirm_email_change(conn, %{"token" => token}) do
    case Accounts.apply_email_change(token) do
      {:ok, updated, old_email} ->
        FountainWeb.Audited.from_conn(conn, "auth.email.changed", "user",
          user_id: updated.id,
          resource_id: updated.id,
          metadata: %{"from" => old_email, "to" => updated.email}
        )

        conn
        # apply_email_change bumped session_version — every session is dead,
        # including any in this browser. A clean sign-in is the honest next
        # step.
        |> configure_session(drop: true)
        |> put_flash(:info, "Email updated to #{updated.email}. Please sign in.")
        |> redirect(to: ~p"/auth/login")

      {:error, :email_taken} ->
        conn
        |> put_flash(:error, "That address is no longer available.")
        |> redirect(to: ~p"/auth/login")

      {:error, :expired} ->
        conn
        |> put_flash(:error, "This confirmation link has expired. Request the change again.")
        |> redirect(to: ~p"/auth/login")

      {:error, :invalid} ->
        conn
        |> put_flash(:error, "This confirmation link is invalid.")
        |> redirect(to: ~p"/auth/login")
    end
  end
end
