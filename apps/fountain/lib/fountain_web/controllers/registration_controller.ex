defmodule FountainWeb.RegistrationController do
  @moduledoc """
  Handles user registration via:
  - HTML form: GET/POST /auth/register
  - JSON API:  POST /api/auth/register

  Rate-limited to 5 registrations per IP per hour.
  """

  use FountainWeb, :controller

  alias Fountain.Accounts
  alias Fountain.Emails.UserEmails

  plug FountainWeb.Plugs.RateLimit,
       [bucket: "registration", max: 5, window_ms: 3_600_000]
       when action in [:create, :api_create]

  ## HTML path

  def new(conn, _params) do
    render(conn, :new, errors: %{}, layout: false)
  end

  def check_email(conn, _params) do
    render(conn, :check_email, layout: false)
  end

  def create(conn, %{"user" => user_params}) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        token = generate_verification_token(conn, user)
        Task.async(fn -> UserEmails.deliver_verification_email(user, token) end)

        conn
        |> put_flash(:info, "Account created! Check your email to verify your address.")
        |> redirect(to: ~p"/auth/check-email")

      {:error, changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)

        conn
        |> put_status(:unprocessable_entity)
        |> render(:new, errors: errors, layout: false)
    end
  end

  ## JSON path

  def api_create(conn, %{"email" => _, "password" => _} = params) do
    case Accounts.register_user(params) do
      {:ok, user} ->
        token = generate_verification_token(conn, user)
        Task.async(fn -> UserEmails.deliver_verification_email(user, token) end)

        conn
        |> put_status(:created)
        |> json(%{
          user_id: user.id,
          message: "Check your email to verify your account."
        })

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(FountainWeb.ChangesetJSON)
        |> render(:error, changeset: changeset)
    end
  end

  def api_create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "email and password are required"})
  end

  ## Helpers

  defp generate_verification_token(conn, user) do
    Phoenix.Token.sign(conn, "email_verification", user.id)
  end
end
