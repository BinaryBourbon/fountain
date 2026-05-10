defmodule FountainWeb.AuthTokenController do
  @moduledoc """
  POST /api/auth/token

  Exchanges email + password for a fresh API key. Used by `fountain auth login`.
  Rate-limited to 10 attempts per IP per hour.
  """

  use FountainWeb, :controller

  alias Fountain.Accounts

  plug FountainWeb.Plugs.RateLimit,
       [bucket: "auth_token", max: 10, window_ms: 3_600_000]
       when action in [:create]

  def create(conn, %{"email" => email, "password" => password})
      when is_binary(email) and is_binary(password) do
    case Accounts.authenticate_user(email, password) do
      {:ok, user} ->
        name = "CLI login \u2014 #{DateTime.utc_now() |> DateTime.to_date()}"

        {:ok, {api_key, raw_key}} = Accounts.create_api_key(user.id, name)

        conn
        |> put_status(:created)
        |> json(%{api_key: raw_key, key_id: api_key.id, prefix: api_key.key_prefix})

      {:error, _} ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid email or password"})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "email and password are required"})
  end
end
