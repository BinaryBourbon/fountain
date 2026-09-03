defmodule Fountain.Extension do
  @moduledoc """
  The behaviour a first-party Fountain extension implements (ADR 0043, #1505).

  An extension is an OTP application that depends on `:fountain`, is compiled
  into the release, and is switched on by naming its extension module in
  configuration:

      config :fountain, :extensions, [FountainBuzz.Extension]

  The host reaches an extension **only** through the callbacks below. Nothing
  in `apps/fountain` names an extension module, and an extension never
  registers itself with the host at runtime: the configured list is the whole
  truth, read at boot by `Fountain.Extensions.validate!/0` and per call
  everywhere else.

  ## The callbacks

    * `c:id/0` — a stable atom. Namespaces logs and error payloads, and is what
      an operator sees when configuration is wrong.
    * `c:enabled?/0` — whether this deployment has what the extension needs
      (a binary on disk, a credential, a flag). An installed extension that
      answers `false` contributes nothing and is never called again; that is a
      supported state, not an error.
    * `c:api_prefix/0` and `c:api_plug/0` — one `/api/<prefix>` segment and the
      Plug that serves it. Mounted **inside** the host's `:api` pipeline by
      `FountainWeb.Plugs.ExtensionDispatch`, so authentication, the rate limit,
      `conn.assigns.current_user` and the request audit are host-owned and an
      extension cannot opt out of them by choosing a prefix.
    * `c:conversation_mcp_servers/2` — the MCP servers this extension serves
      back to a conversation's sandbox. The one callback on the turn's hot
      path. Return `[]` for a conversation the extension does not claim.

  ## Supervision is not a callback

  An extension starts its own processes from its own `Application.start/2`.
  Because it depends on `:fountain`, OTP starts the host first and stops it
  last, so the Repo is up before the extension's tree and the extension's tree
  is down before the Repo goes away. The host aggregates no extension children
  and a crash in an extension's supervisor cannot reach the host's. ADR 0043
  originally gave this a `children/1` callback; #1505 replaced it with the
  application dependency, which buys the same ordering for free and one
  strictly better thing: an extension's tree starts *after* the Endpoint, which
  is what a harness talking HTTP back to this server actually needs.

  ## Defaults

  `use Fountain.Extension, id: :thing` implements every callback with a
  contribute-nothing default, so an extension writes only the ones it uses:

      defmodule MyExt.Extension do
        use Fountain.Extension, id: :my_ext

        @impl true
        def api_prefix, do: "my-ext"

        @impl true
        def api_plug, do: MyExt.Router
      end

  The behaviour stays total on purpose — there are no optional callbacks to
  check for at a call site.
  """

  @typedoc "A Plug module, or a Plug module with its options."
  @type plug :: module() | {module(), term()}

  @doc "A stable identifier for this extension. Never changes once shipped."
  @callback id() :: atom()

  @doc """
  Whether this deployment can run the extension. Asked before every dispatch,
  so keep it cheap; anything that touches the filesystem or the network belongs
  behind a value read once at the extension's own boot.
  """
  @callback enabled?() :: boolean()

  @doc """
  The single `/api` path segment this extension serves, or `nil` for an
  extension with no HTTP surface.

  Lowercase, and one segment: `"buzz"`, not `"buzz/agents"` and not `"/buzz"`.
  `Fountain.Extensions.validate!/0` refuses a prefix that is malformed,
  duplicated, or already claimed by a core route, and refuses it at boot rather
  than at the first request.
  """
  @callback api_prefix() :: String.t() | nil

  @doc """
  The Plug serving `c:api_prefix/0` — usually the extension's own
  `Phoenix.Router`. Called with the prefix already trimmed from `path_info`
  and appended to `script_name`, so the extension's routes are written
  relative to its own mount point and its path helpers still generate correct
  URLs.
  """
  @callback api_plug() :: plug() | nil

  @doc """
  The MCP servers to serve back to this conversation's sandbox, in the shape
  `Managoat.Runtimes` puts on `session/new`.

  `callback_token` is the conversation-scoped credential
  (`Fountain.Conversations.CallbackKey`) the sandbox will authenticate the tool
  calls with. It is not a standing user key, and an extension must not mint or
  substitute one.

  Called on every turn kick, for every conversation, once per installed
  extension. Return `[]` — cheaply — for a conversation this extension has
  nothing to do with. A raise here is contained by
  `Fountain.Extensions.conversation_mcp_servers/2` and costs this extension's
  servers only, never the host's.
  """
  @callback conversation_mcp_servers(conversation_id :: String.t(), callback_token :: String.t()) ::
              [map()]

  @doc false
  defmacro __using__(opts) do
    id = Keyword.fetch!(opts, :id)

    quote do
      @behaviour Fountain.Extension

      @impl Fountain.Extension
      def id, do: unquote(id)

      @impl Fountain.Extension
      def enabled?, do: true

      @impl Fountain.Extension
      def api_prefix, do: nil

      @impl Fountain.Extension
      def api_plug, do: nil

      @impl Fountain.Extension
      def conversation_mcp_servers(_conversation_id, _callback_token), do: []

      defoverridable enabled?: 0, api_prefix: 0, api_plug: 0, conversation_mcp_servers: 2
    end
  end
end
