defmodule Fountain.OAuth do
  @moduledoc """
  Fountain as the OAuth 2.0 authorization server for its own first-party
  apps — the standalone team and conversations clients on another origin
  (#818) and the CLI's device login (#1305) — as an instance of
  `Managoat.OAuth` (ADR 0037, #1343).

  The problem it solves: those apps authenticate every API call with a
  bearer API key, and until now the key had to be pasted in. This turns a
  Fountain *session* (however it was opened — password or GitHub) into an
  API key for the app, with the user's consent, without the app ever seeing
  credentials.

  The grant is **authorization code + PKCE (S256), public clients only** —
  what a browser app can do safely — plus the device grant for a terminal
  that cannot hold a password. There is no client secret; the redirect URI
  allowlist and the PKCE verifier are what bind a code to the app that
  started the flow. The state machine, the two tables' schemas and the
  client registry's shape are the library's; what the library asks of the
  platform is `Fountain.OAuth.Host`: whether a user may hold a key, minting
  the key, and the audit trail.

  ## Clients

  A registry in application config, not a table: there are two of them and
  they are ours. `config :fountain, Fountain.OAuth, clients: [%{id, name,
  redirect_uris}]` (runtime.exs reads `OAUTH_CLIENTS` as JSON). Redirect
  URIs match **exactly**.

  ## Tokens are API keys

  A successful exchange mints an ordinary API key (`Accounts.create_api_key/3`)
  named `oauth:<client_id>`, full scope, with an expiry — so it lists and
  revokes under Account → API keys, `TenantAPIAuth` needs no change, and the
  audit trail already knows the shape. No refresh tokens (yet): the app
  signs in again when the key expires. That is a Fountain decision, made in
  the host, not the library's.
  """

  use Managoat.OAuth, otp_app: :fountain, host: Fountain.OAuth.Host

  alias Fountain.Accounts

  @doc """
  Revoke the token (an API key) presented by an app that is signing out.

  Fountain's own, not the library's: the library never learns what a token
  is, so revoking one is revoking an API key.
  """
  @spec revoke(Accounts.ApiKey.t(), keyword()) ::
          {:ok, Accounts.ApiKey.t()} | {:error, :not_found}
  def revoke(%Accounts.ApiKey{} = key, opts \\ []) do
    Accounts.revoke_api_key(key.user_id, key.id, opts)
  end
end
