defmodule FountainWeb.ApiKeyController do
  @moduledoc """
  API key issuance and revocation for the authenticated user.

  POST   /api/auth/api-keys      — create a new key (returns plaintext once)
  DELETE /api/auth/api-keys/:id  — revoke a key
  """

  use FountainWeb, :controller

  alias Fountain.Accounts

  def create(conn, %{"name" => name}) when is_binary(name) and name != "" do
    user = conn.assigns.current_user

    case Accounts.create_api_key(user.id, name) do
      {:ok, {key_record, raw_key}} ->
        conn
        |> put_status(:created)
        |> render(:created, key: key_record, raw_key: raw_key)

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(FountainWeb.ChangesetJSON)
        |> render(:error, changeset: changeset)
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "name is required"})
  end

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Accounts.revoke_api_key(user.id, id) do
      {:ok, _key} ->
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "API key not found"})
    end
  end
end
