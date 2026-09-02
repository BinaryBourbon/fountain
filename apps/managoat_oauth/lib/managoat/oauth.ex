defmodule Managoat.OAuth do
  @moduledoc """
  An OAuth 2.0 authorization server for public clients, as a `use` macro.

  Two grants, and only these two:

    * **authorization code + PKCE (S256)** for browser apps on another
      origin. There is no client secret; the exact-match redirect-URI
      allowlist and the PKCE verifier are what bind a code to the app that
      started the flow.
    * **device authorization** (RFC 8628 shape) for a CLI that cannot hold
      a password: a high-entropy device code the polling machine keeps and
      a short `XXXX-XXXX` user code a human types into the host's approval
      page.

  This library owns the grant state machine and nothing about who the user
  is or what a token is. The host mints the token, decides whether a
  subject may hold one, and writes the audit trail, through the four
  callbacks of `Managoat.OAuth.Host`. That split is what keeps it small
  enough to be worth having beside Boruta.

  ## Defining an instance

  In a module of the host's own (`MyApp.OAuth`, say):

      use Managoat.OAuth, otp_app: :my_app, host: MyApp.OAuth.Host

      # config/config.exs
      config :my_app, MyApp.OAuth,
        repo: MyApp.Repo,
        clients: [%{id: "my-spa", name: "My SPA", redirect_uris: ["https://spa.example/"]}]

  The instance reads `repo:`, `clients:` and an optional `prefix:` from the
  host's own otp_app under its own module name, the way an `Ecto.Repo`
  does, so the library never reads configuration that is not its own.
  There is no default repo: `Managoat.OAuth.Config` raises a message naming
  the key. `clients` may be atom- or string-keyed maps (a JSON registry
  decodes straight into it) and defaults to none, which refuses every
  authorization request.

  ## The tables

  Two tables, `oauth_authorization_codes` and `oauth_device_grants`, created
  by `Managoat.OAuth.Migration` from a migration of the host's own whose
  `up/0` calls `Managoat.OAuth.Migration.up/1` and whose `down/0` calls
  `Managoat.OAuth.Migration.down/1` (the README shows one).

  The subject column is `user_id` by default and has no foreign key; a host
  that wants one adds it in the same migration.

  ## The functions an instance gets

  Every function below is generated on the instance module, with the
  arities shown. `subject` is an opaque binary the host understands (a user
  id); the library stores it and hands it back, never joins it.

    * `clients/0`, `redirect_origins/0`, `get_client/1`
    * `validate_request/1`, `authorize/2,3`, `exchange/1,2`, `pkce_verify/2`
    * `start_device_grant/0`, `format_user_code/1`, `normalize_user_code/1`,
      `get_device_grant_for_approval/1`, `approve_device_grant/2,3`,
      `deny_device_grant/2,3`, `poll_device_grant/1,2`
    * `prune_expired/0`, `token_ttl_seconds/0`, `device_interval_seconds/0`

  The `opts` keyword on the mutating functions is passed through to the
  host untouched, so a host can carry attribution (`actor`, `request_ip`)
  from its web layer to its audit trail without the library knowing what
  those keys mean.

  ## The two orderings the state machine keeps

  A grant is consumed only if the host accepts the subject and issues the
  token, in this precise sense:

    * `poll_device_grant/2` asks `c:Managoat.OAuth.Host.subject_allowed?/1`
      **before** marking the grant used; a refused subject leaves the grant
      approved and unconsumed, and the poll answers `{:error, :access_denied}`.
    * `exchange/2` marks the code used **before** calling
      `c:Managoat.OAuth.Host.issue_token/3`; a failed mint answers
      `{:error, :server_error}` with the code consumed. A code is proof of
      one consent, and a retry after a server-side failure is a second
      consent's job.
  """

  alias Managoat.OAuth.{Clients, Codes, Config, Device}

  @doc false
  defmacro __using__(opts) do
    otp_app = Keyword.get(opts, :otp_app)
    host = opts |> Keyword.get(:host) |> Macro.expand(__CALLER__)

    unless is_atom(otp_app) and not is_nil(otp_app) do
      raise ArgumentError,
            "use Managoat.OAuth needs `otp_app: :my_app`, the application whose " <>
              "config holds `repo:` and `clients:` for this instance"
    end

    unless is_atom(host) and not is_nil(host) do
      raise ArgumentError,
            "use Managoat.OAuth needs `host: Module`, a module implementing " <>
              "Managoat.OAuth.Host (it mints the token, checks the subject and audits)"
    end

    quote bind_quoted: [otp_app: otp_app, host: host] do
      @managoat_oauth_otp_app otp_app
      @managoat_oauth_host host

      @doc false
      @spec __managoat_oauth__() :: Managoat.OAuth.Config.t()
      def __managoat_oauth__,
        do: Managoat.OAuth.Config.load!(@managoat_oauth_otp_app, __MODULE__, @managoat_oauth_host)

      @doc "The registered public clients, normalised."
      @spec clients() :: [Managoat.OAuth.Clients.client()]
      def clients, do: Managoat.OAuth.clients(__managoat_oauth__())

      @doc "The distinct origins of every client's redirect URIs."
      @spec redirect_origins() :: [String.t()]
      def redirect_origins, do: Managoat.OAuth.redirect_origins(__managoat_oauth__())

      @doc "The client with `id`, or nil."
      @spec get_client(term()) :: Managoat.OAuth.Clients.client() | nil
      def get_client(id), do: Managoat.OAuth.get_client(__managoat_oauth__(), id)

      @doc "See `Managoat.OAuth.validate_request/2`."
      def validate_request(params),
        do: Managoat.OAuth.validate_request(__managoat_oauth__(), params)

      @doc "See `Managoat.OAuth.authorize/4`."
      def authorize(subject, params, opts \\ []),
        do: Managoat.OAuth.authorize(__managoat_oauth__(), subject, params, opts)

      @doc "See `Managoat.OAuth.exchange/3`."
      def exchange(params, opts \\ []),
        do: Managoat.OAuth.exchange(__managoat_oauth__(), params, opts)

      @doc "See `Managoat.OAuth.pkce_verify/2`."
      def pkce_verify(verifier, challenge), do: Managoat.OAuth.pkce_verify(verifier, challenge)

      @doc "See `Managoat.OAuth.start_device_grant/1`."
      def start_device_grant, do: Managoat.OAuth.start_device_grant(__managoat_oauth__())

      @doc "See `Managoat.OAuth.format_user_code/1`."
      def format_user_code(code), do: Managoat.OAuth.format_user_code(code)

      @doc "See `Managoat.OAuth.normalize_user_code/1`."
      def normalize_user_code(input), do: Managoat.OAuth.normalize_user_code(input)

      @doc "See `Managoat.OAuth.get_device_grant_for_approval/2`."
      def get_device_grant_for_approval(input),
        do: Managoat.OAuth.get_device_grant_for_approval(__managoat_oauth__(), input)

      @doc "See `Managoat.OAuth.approve_device_grant/4`."
      def approve_device_grant(input, subject, opts \\ []),
        do: Managoat.OAuth.approve_device_grant(__managoat_oauth__(), input, subject, opts)

      @doc "See `Managoat.OAuth.deny_device_grant/4`."
      def deny_device_grant(input, subject, opts \\ []),
        do: Managoat.OAuth.deny_device_grant(__managoat_oauth__(), input, subject, opts)

      @doc "See `Managoat.OAuth.poll_device_grant/3`."
      def poll_device_grant(device_code, opts \\ []),
        do: Managoat.OAuth.poll_device_grant(__managoat_oauth__(), device_code, opts)

      @doc "See `Managoat.OAuth.prune_expired/1`."
      def prune_expired, do: Managoat.OAuth.prune_expired(__managoat_oauth__())

      @doc "Seconds a token minted by `exchange/2` lives."
      @spec token_ttl_seconds() :: pos_integer()
      def token_ttl_seconds, do: Managoat.OAuth.token_ttl_seconds()

      @doc "Seconds a device-grant poller must wait between polls."
      @spec device_interval_seconds() :: pos_integer()
      def device_interval_seconds, do: Managoat.OAuth.device_interval_seconds()
    end
  end

  ## ── Clients ───────────────────────────────────────────────────────────────

  @doc "The instance's registered public clients, normalised."
  @spec clients(Config.t()) :: [Clients.client()]
  def clients(%Config{clients: clients}), do: clients

  @doc """
  The distinct origins (`scheme://host[:port]`) of every registered client's
  redirect URIs — what a consent page's `form-action` CSP must allow, since
  a successful consent POST redirects the browser to the app's origin.
  """
  @spec redirect_origins(Config.t()) :: [String.t()]
  def redirect_origins(%Config{clients: clients}), do: Clients.redirect_origins(clients)

  @doc "The client with `id`, or nil."
  @spec get_client(Config.t(), term()) :: Clients.client() | nil
  def get_client(%Config{clients: clients}, id), do: Clients.get_client(clients, id)

  @doc """
  Validate an authorization request's identity part — the bits that decide
  whether the host may redirect at all. `{:ok, client}` or `{:error, reason}`:
  `:unknown_client`, `:redirect_uri_mismatch`, `:invalid_code_challenge`,
  `:unsupported_code_challenge_method`.

  An error here must render, never redirect: a redirect to an unregistered
  URI is exactly the open redirector the allowlist exists to prevent.
  """
  @spec validate_request(Config.t(), map()) :: {:ok, Clients.client()} | {:error, atom()}
  def validate_request(%Config{clients: clients}, params),
    do: Clients.validate_request(clients, params)

  ## ── Authorization code + PKCE ─────────────────────────────────────────────

  @doc """
  The subject consented: issue a code for this request. Returns
  `{:ok, raw_code}`; the raw code goes to the redirect and is never stored,
  only its hash is. Calls the host's `audit/3` with `:authorized`.
  """
  @spec authorize(Config.t(), binary(), map(), keyword()) ::
          {:ok, String.t()} | {:error, atom() | Ecto.Changeset.t()}
  def authorize(%Config{} = config, subject, params, opts \\ []),
    do: Codes.authorize(config, subject, params, opts)

  @doc """
  Exchange a code for a token. `params` is the token request: `code`,
  `code_verifier`, `client_id`, `redirect_uri`. Returns
  `{:ok, %{access_token: token, expires_in: seconds, api_key: host_token}}`,
  `{:error, :invalid_grant}` for every way a grant can be wrong (unknown,
  used, expired, wrong client, wrong redirect, wrong verifier), or
  `{:error, :server_error}` when the host could not mint — with the code
  consumed, see the moduledoc.
  """
  @spec exchange(Config.t(), map(), keyword()) ::
          {:ok, %{access_token: String.t(), expires_in: pos_integer(), api_key: term()}}
          | {:error, :invalid_grant | :server_error}
  def exchange(%Config{} = config, params, opts \\ []), do: Codes.exchange(config, params, opts)

  @doc "S256: base64url(sha256(verifier)) == challenge, constant-time."
  @spec pkce_verify(term(), term()) :: boolean()
  def pkce_verify(verifier, challenge), do: Codes.pkce_verify(verifier, challenge)

  @doc "Seconds a token minted by `exchange/3` lives."
  @spec token_ttl_seconds() :: pos_integer()
  def token_ttl_seconds, do: Codes.token_ttl_seconds()

  ## ── Device authorization ──────────────────────────────────────────────────

  @doc """
  Start a device grant. Returns `{:ok, %{device_code, user_code, expires_in,
  interval}}`: `device_code` is raw (only its hash is stored) and stays on
  the polling machine; `user_code` is formatted `XXXX-XXXX` for a human to
  type. Deliberately unaudited: nothing has happened to any subject yet.
  """
  @spec start_device_grant(Config.t()) ::
          {:ok,
           %{
             device_code: String.t(),
             user_code: String.t(),
             expires_in: pos_integer(),
             interval: pos_integer()
           }}
          | {:error, :server_error}
  def start_device_grant(%Config{} = config), do: Device.start(config)

  @doc ~S(Format a stored user code for humans: "BCDFGHJK" → "BCDF-GHJK".)
  @spec format_user_code(String.t()) :: String.t()
  def format_user_code(code), do: Device.format_user_code(code)

  @doc "Normalize what a human typed: case, the display dash, stray spaces."
  @spec normalize_user_code(String.t()) :: String.t()
  def normalize_user_code(input), do: Device.normalize_user_code(input)

  @doc """
  The pending, unexpired grant for a typed user code — what an approval page
  shows before the subject decides. `{:ok, grant}` or `{:error, :not_found}`
  (one answer for unknown, expired and decided alike).
  """
  @spec get_device_grant_for_approval(Config.t(), String.t()) ::
          {:ok, Managoat.OAuth.DeviceGrant.t()} | {:error, :not_found}
  def get_device_grant_for_approval(%Config{} = config, input),
    do: Device.get_for_approval(config, input)

  @doc """
  The signed-in subject approves the grant behind a typed user code: binds
  the subject to it so the next poll mints a token. Conditional on the grant
  still being pending and unexpired, so approve/deny/expiry cannot race.
  Calls the host's `audit/3` with `:device_approved`.
  """
  @spec approve_device_grant(Config.t(), String.t(), binary(), keyword()) ::
          :ok | {:error, :not_found}
  def approve_device_grant(%Config{} = config, input, subject, opts \\ []),
    do: Device.approve(config, input, subject, opts)

  @doc """
  The signed-in subject denies the grant: the poller gets `access_denied`.
  Calls the host's `audit/3` with `:device_denied`.
  """
  @spec deny_device_grant(Config.t(), String.t(), binary(), keyword()) ::
          :ok | {:error, :not_found}
  def deny_device_grant(%Config{} = config, input, subject, opts \\ []),
    do: Device.deny(config, input, subject, opts)

  @doc """
  The poller asks with its device code. One of:

    * `{:ok, %{access_token, api_key}}` — approved, the subject accepted by
      the host, the grant consumed and a token minted (once: the conditional
      update that marks the grant used means two concurrent polls cannot
      both win)
    * `{:error, :authorization_pending}` — nobody has decided yet
    * `{:error, :slow_down}` — polled faster than the advertised interval
    * `{:error, :access_denied}` — denied, or the host refused the subject
      (the grant stays approved and unconsumed)
    * `{:error, :expired_token}` — the grant timed out
    * `{:error, :invalid_grant}` — unknown or already-consumed code
    * `{:error, :server_error}` — the host could not mint
  """
  @spec poll_device_grant(Config.t(), String.t(), keyword()) ::
          {:ok, %{access_token: String.t(), api_key: term()}}
          | {:error,
             :authorization_pending
             | :slow_down
             | :access_denied
             | :expired_token
             | :invalid_grant
             | :server_error}
  def poll_device_grant(%Config{} = config, device_code, opts \\ []),
    do: Device.poll(config, device_code, opts)

  @doc "Seconds a device-grant poller must wait between polls."
  @spec device_interval_seconds() :: pos_integer()
  def device_interval_seconds, do: Device.interval_seconds()

  ## ── Hygiene ───────────────────────────────────────────────────────────────

  @doc "Delete codes and device grants past their expiry (a sweep). Returns the count."
  @spec prune_expired(Config.t()) :: non_neg_integer()
  def prune_expired(%Config{} = config),
    do: Codes.prune_expired(config) + Device.prune_expired(config)
end
