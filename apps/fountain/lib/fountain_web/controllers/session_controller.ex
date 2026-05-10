defmodule FountainWeb.SessionController do
  use FountainWeb, :controller

  def new(conn, _params) do
    render(conn, :new, error: nil, layout: false)
  end

  def create(conn, %{"token" => token}) do
    expected = Application.fetch_env!(:fountain, :admin_token)

    if Plug.Crypto.secure_compare(token, expected) do
      conn
      |> configure_session(renew: true)
      |> put_session(:admin, true)
      |> redirect(to: ~p"/")
    else
      conn
      |> put_status(:unauthorized)
      |> render(:new, error: "Invalid token", layout: false)
    end
  end

  def delete(conn, _) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: ~p"/login")
  end
end
