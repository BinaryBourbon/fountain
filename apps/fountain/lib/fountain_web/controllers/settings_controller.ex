defmodule FountainWeb.SettingsController do
  @moduledoc false
  use FountainWeb, :controller

  alias Fountain.Accounts.User
  alias Fountain.Repo

  @doc """
  PATCH /api/settings/theme — persists the user's theme preference.
  Called by the ThemeToggle JS hook on every toggle; body is `{"theme": "light"|"dark"|"system"}`.
  """
  def update_theme(conn, %{"theme" => theme}) when theme in ~w(light dark system) do
    user = conn.assigns.current_user

    case Repo.update(User.theme_changeset(user, %{theme_preference: theme})) do
      {:ok, _updated} -> json(conn, %{ok: true})
      {:error, _cs} -> conn |> put_status(422) |> json(%{error: "could not update theme"})
    end
  end

  def update_theme(conn, _params) do
    conn |> put_status(422) |> json(%{error: "invalid theme value"})
  end
end
