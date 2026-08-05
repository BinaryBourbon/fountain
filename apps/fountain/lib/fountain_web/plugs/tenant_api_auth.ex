defmodule FountainWeb.Plugs.TenantAPIAuth do
  @moduledoc """
  API pipeline auth: extracts `Authorization: Bearer <key>`, SHA-256 hashes it,
  looks up the API key, loads the owning user, and sets
  `conn.assigns.current_user`.

  Updates `last_used_at` asynchronously via `Task.async` so it never blocks
  the request.

  Returns 401 JSON on failure. The response body includes a machine-readable
  `reason` so clients (especially in-sprite agents holding a rotated
  `$FOUNTAIN_TOKEN`) can tell a revoked key apart from one that never existed:

      {"error": "API key has been revoked", "reason": "api_key_revoked"}
      {"error": "Invalid or missing API key", "reason": "api_key_invalid"}

  An unverified account is refused with 403 and `email_unverified` (#533) —
  the one non-401 here, because the key itself is fine and the account, not
  the credential, is what needs fixing.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Fountain.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    with [auth_header] <- get_req_header(conn, "authorization"),
         "Bearer " <> raw_key <- auth_header,
         {:ok, user, api_key} <- Accounts.authenticate_api_key(raw_key) do
      Task.async(fn -> Accounts.touch_api_key(raw_key) end)

      conn
      |> assign(:current_user, user)
      # Scope lives on the key, so downstream guards need the record — a sandbox
      # token is otherwise indistinguishable from the tenant's own key.
      |> assign(:current_api_key, api_key)
    else
      {:error, :revoked} ->
        unauthorized(conn, "API key has been revoked", "api_key_revoked")

      {:error, :expired} ->
        unauthorized(conn, "API key has expired", "api_key_expired")

      # Neutral (#287): the key was valid — the holder already knows the
      # account exists; the response still doesn't say why it's unusable.
      {:error, :suspended} ->
        unauthorized(conn, "This account is currently unavailable", "account_unavailable")

      # 403, and named: same status and same `reason` as POST /api/auth/token
      # refusing to mint for this account, so a CLI holding a stale key reads
      # the same answer it would get from asking for a new one. Nothing is
      # leaked by being specific — the holder owns the key.
      {:error, :unverified} ->
        conn
        |> put_status(:forbidden)
        |> json(%{
          error: "Verify your email address before using the API",
          reason: "email_unverified"
        })
        |> halt()

      _ ->
        unauthorized(conn, "Invalid or missing API key", "api_key_invalid")
    end
  end

  defp unauthorized(conn, message, reason) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: message, reason: reason})
    |> halt()
  end
end
