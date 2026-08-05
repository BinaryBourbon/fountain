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

  The rule itself now lives in `FountainWeb.Plugs.RequireFullScope`, which other
  account-level writes reuse; this plug is the key-management wording of it.

  Session-authenticated browser routes never reach this plug; it guards the
  bearer-token API pipeline only.
  """

  alias FountainWeb.Plugs.RequireFullScope

  @error "This API key is not permitted to manage API keys"

  def init(opts), do: opts

  def call(conn, _opts), do: RequireFullScope.call(conn, error: @error)
end
