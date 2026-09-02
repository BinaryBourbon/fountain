# Managoat.OAuth

An OAuth 2.0 authorization server for public clients, small on purpose: the
**authorization code grant with PKCE (S256)** for browser apps on another
origin, and the **device authorization grant** (RFC 8628 shape) for a CLI
that cannot hold a password. No client secrets, no confidential clients, no
refresh tokens, no scopes. Boruta and ExOauth2Provider exist for the
heavyweight case, which is the reason to keep this one small.

The library owns the grant state machine and nothing about who the user is
or what a token is. The host mints the token, decides whether a subject may
hold one, and writes the audit trail, through a three-callback behaviour.

```elixir
defmodule MyApp.OAuth do
  use Managoat.OAuth, otp_app: :my_app, host: MyApp.OAuth.Host
end

# config/config.exs
config :my_app, MyApp.OAuth,
  repo: MyApp.Repo,
  clients: [
    %{id: "my-spa", name: "My SPA", redirect_uris: ["https://spa.example/"]}
  ]

defmodule MyApp.OAuth.Host do
  @behaviour Managoat.OAuth.Host

  # May this subject collect a token right now? Asked before a device grant
  # is consumed; a refusal leaves the grant approved and unconsumed.
  def subject_allowed?(user_id), do: if(MyApp.Accounts.active?(user_id), do: :ok, else: {:error, :suspended})

  # Mint whatever a token is here. `grant` says which kind and its lifetime.
  def issue_token(user_id, %{client_id: client_id, expires_at: expires_at}, _opts) do
    {:ok, {key, raw}} = MyApp.Accounts.create_api_key(user_id, "oauth:#{client_id}", expires_at: expires_at)
    {:ok, %{access_token: raw, token: key}}
  end

  # :authorized, :device_approved or :device_denied, with what happened.
  def audit(event, meta, opts), do: MyApp.Audit.record(event, meta, opts)
end
```

The tables come from a migration of your own that calls the library's:

```elixir
defmodule MyApp.Repo.Migrations.AddOAuth do
  use Ecto.Migration

  def up, do: Managoat.OAuth.Migration.up()
  def down, do: Managoat.OAuth.Migration.down()
end
```

## The flows

**Code + PKCE.** The app sends the browser to your consent page with
`client_id`, `redirect_uri`, `code_challenge` and `state`. Your page calls
`validate_request/1` first: an error here must **render**, never redirect,
because a redirect to an unregistered URI is the open redirector the
allowlist exists to prevent. On consent, `authorize/3` returns a one-time
code (five minutes, stored hashed) for the redirect. The app posts the code
and its `code_verifier` to your token endpoint, which calls `exchange/2` and
gets `{:ok, %{access_token, expires_in, api_key}}` built from what your
host minted. Every way a grant can be wrong is one answer,
`{:error, :invalid_grant}`, so the response says nothing about which.

**Device.** Your unauthenticated start endpoint calls `start_device_grant/0`
and shows the human the `user_code`; the poller keeps the `device_code`.
Your signed-in approval page calls `get_device_grant_for_approval/1` with
what the human typed (case, dashes and spaces are normalised), then
`approve_device_grant/3` or `deny_device_grant/3`. Your poll endpoint calls
`poll_device_grant/2` and maps `authorization_pending`, `slow_down`,
`access_denied`, `expired_token` and `invalid_grant` onto the RFC 8628
error strings.

## What the host decides

| Callback | Called | Why it is the host's |
|---|---|---|
| `subject_allowed?(subject)` | before a device grant is consumed | only the host knows what suspended or unverified means |
| `issue_token(subject, grant, opts)` | after a code is consumed; after a device grant is consumed | tokens are the host's (Fountain's are API keys); the library only decides the lifetime |
| `audit(event, meta, opts)` | on `:authorized`, `:device_approved`, `:device_denied` | the trail is the host's; the library cannot complete any of the three without calling it |

`subject` is an opaque binary. The library stores it in the `user_id`
column, hands it back, and never joins it. The column has no foreign key;
add one in your migration if you want the database to enforce it. `opts` is
whatever your caller passed to the instance function, untouched, so
attribution can travel from your web layer to your audit trail.

## Two orderings, kept on purpose

- `poll_device_grant/2` asks `subject_allowed?/1` **before** marking the
  grant used. A refused subject gets `access_denied` and the grant stays
  approved and pollable, so a state that changes back (an unsuspension) does
  not cost the human a second approval.
- `exchange/2` marks the code used **before** calling `issue_token/3`. A
  failed mint answers `server_error` with the code spent, because a code is
  proof of exactly one consent.

Both are tests in this package, not conventions.

## Redirect URIs match exactly

`https://spa.example/` is not `https://spa.example/callback` and not
`https://spa.example/?x=1`. There is no wildcard and no prefix match, and no
client secret to make one safe. `redirect_origins/0` gives the distinct
origins of every registered URI, which is what a consent page's
`form-action` CSP has to allow for the post-consent redirect.

## Running the tests

The suite needs Postgres. It drops and recreates its own database on every
run (`managoat_oauth_test` on `postgres:postgres@localhost` by default; set
`MANAGOAT_OAUTH_TEST_DATABASE_URL` to point elsewhere), migrates it with
`Managoat.OAuth.Migration`, and runs under the SQL sandbox against a host
that records what the library asked of it.

```bash
mix test --cover
```

## Licence

Apache-2.0. See `LICENSE`.
