defmodule FountainWeb.Plugs.RequireKeyManagement do
  @moduledoc """
  Restricts API key issuance, listing and revocation to keys scoped for it.

  Every conversation hands its sprite a tenant API key so the agent can stream,
  prompt, and spawn sub-agents. Before scoping existed those tokens were
  unrestricted, so code running in a sandbox could call
  `POST /api/auth/api-keys` and mint a second key — one that the
  conversation-scoped revoke at teardown knows nothing about, and which
  therefore outlives the conversation as standing tenant access.

  Sandboxes run untrusted code by design, so that path has to be closed at the
  boundary rather than trusted not to be walked.

  Session-authenticated browser routes never reach this plug; it guards the
  bearer-token API pipeline only.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Fountain.Accounts.ApiKey

  def init(opts), do: opts

  def call(%{assigns: %{current_api_key: %ApiKey{} = key}} = conn, _opts) do
    if ApiKey.may_manage_keys?(key) do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> json(%{
        error: "This API key is not permitted to manage API keys",
        reason: "insufficient_scope",
        required_scope: "full"
      })
      |> halt()
    end
  end

  # No key on the connection means this ran outside the bearer-token pipeline.
  # Fail closed rather than assume the caller is privileged.
  def call(conn, _opts) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "API key scope could not be determined", reason: "insufficient_scope"})
    |> halt()
  end
end
