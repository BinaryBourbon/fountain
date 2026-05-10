defmodule FountainWeb.AdminController do
  @moduledoc false

  use FountainWeb, :controller

  alias Fountain.Upgrader

  def upgrade(conn, _params) do
    case Upgrader.perform() do
      :ok ->
        Upgrader.schedule_restart()
        json(conn, %{status: "restarting"})

      {:error, :no_update} ->
        conn
        |> put_status(:conflict)
        |> json(%{error: "no update available"})

      {:error, reason} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: inspect(reason)})
    end
  end
end
