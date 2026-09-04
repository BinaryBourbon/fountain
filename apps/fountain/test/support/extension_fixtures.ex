defmodule Fountain.ExtensionFixtures do
  @moduledoc """
  Fixture extensions that prove the `Fountain.Extension` contract without Buzz
  (ADR 0043, #1505).

  The gate on #1505 is that the seam works before anything moves through it, so
  these are the only extensions the suite installs. They are named in
  `config/test.exs` rather than set per test on purpose: `:extensions` is
  global application state, and a test that wrote it would collide with every
  other async test in the VM the way the fleet-ceiling seed flake did (#1214).
  Everything a test needs to vary is therefore a *different fixture*, not a
  different configuration.

    * `Enabled` — the full contract: a prefix, a Phoenix router behind it, and
      an MCP contribution keyed on the conversation id.
    * `Disabled` — configured, `enabled?/0` false. Proves an installed-but-off
      extension is indistinguishable from an absent one.
    * `Silent` — enabled, no HTTP surface at all. Proves `nil`/`nil` is a
      supported shape and not a validation failure.
    * `Exploding` and `WrongShape` — misbehave from
      `conversation_mcp_servers/2`, but only for one conversation id each, so
      they are safe to install alongside the others. That is what makes the
      isolation tests exercise `Fountain.Extensions.conversation_mcp_servers/2`
      itself rather than a copy of its logic.
  """

  defmodule Router do
    @moduledoc """
    The fixture extension's own Phoenix router, mounted at `/api/fixture`.

    Its routes are written relative to that mount, which is the property
    `ExtensionDispatch` has to provide: the extension does not know or repeat
    its own prefix.
    """
    use Phoenix.Router

    pipeline :fixture do
      plug :accepts, ["json"]
    end

    scope "/", Fountain.ExtensionFixtures do
      pipe_through :fixture

      get "/whoami", Controller, :whoami
      get "/nested/deep", Controller, :deep
    end
  end

  defmodule Controller do
    @moduledoc """
    Answers with what the host handed the extension, so a test can assert on
    the seam itself rather than on the fixture's own behaviour.
    """
    use Phoenix.Controller, formats: [:json]

    def whoami(conn, _params) do
      json(conn, %{
        user_id: conn.assigns.current_user.id,
        email: conn.assigns.current_user.email,
        # The prefix moved out of path_info and into script_name, so the
        # extension sees its own mount and can still build correct URLs.
        path_info: conn.path_info,
        script_name: conn.script_name
      })
    end

    def deep(conn, _params), do: json(conn, %{path_info: conn.path_info})
  end

  defmodule Enabled do
    @moduledoc "A fully-featured fixture extension. Installed in the test VM."
    use Fountain.Extension, id: :fixture

    @doc "The conversation id this fixture claims. Any other gets `[]`."
    def claimed_conversation_id, do: "11111111-1111-1111-1111-111111111111"

    @impl true
    def api_prefix, do: "fixture"

    @impl true
    def api_plug, do: Fountain.ExtensionFixtures.Router

    @impl true
    def conversation_mcp_servers(conversation_id, callback_token) do
      # Also serves the conversation `Exploding` blows up on, so the isolation
      # test can assert that a failing extension costs its own servers and
      # nobody else's.
      if conversation_id in [
           claimed_conversation_id(),
           Fountain.ExtensionFixtures.Exploding.trigger_conversation_id()
         ] do
        [
          %{
            "name" => "fixture",
            "type" => "http",
            "url" => "http://localhost/api/fixture/mcp/#{conversation_id}",
            "headers" => %{"authorization" => "Bearer #{callback_token}"}
          }
        ]
      else
        []
      end
    end
  end

  defmodule Disabled do
    @moduledoc "Configured but off here. Installed in the test VM."
    use Fountain.Extension, id: :fixture_disabled

    @impl true
    def enabled?, do: false

    @impl true
    def api_prefix, do: "fixture-disabled"

    @impl true
    def api_plug, do: Fountain.ExtensionFixtures.Router

    @impl true
    def conversation_mcp_servers(_conversation_id, _callback_token) do
      [%{"name" => "disabled-should-never-appear"}]
    end
  end

  defmodule Silent do
    @moduledoc "Enabled, contributes nothing. Installed in the test VM."
    use Fountain.Extension, id: :fixture_silent
  end

  defmodule Exploding do
    @moduledoc """
    Raises from `conversation_mcp_servers/2`, but only for one conversation.
    Installed in the test VM: a fixture that raised on every turn kick would be
    a landmine in every unrelated test, and one that was never installed could
    only be tested against a copy of the host's isolation logic.
    """
    use Fountain.Extension, id: :fixture_exploding

    @doc "The one conversation this fixture explodes on."
    def trigger_conversation_id, do: "22222222-2222-2222-2222-222222222222"

    @impl true
    def conversation_mcp_servers(conversation_id, _callback_token) do
      if conversation_id == trigger_conversation_id() do
        raise "fixture extension exploded"
      else
        []
      end
    end
  end

  defmodule WrongShape do
    @moduledoc "Returns a non-list, for one conversation. Installed."
    use Fountain.Extension, id: :fixture_wrong_shape

    @doc "The one conversation this fixture answers wrongly for."
    def trigger_conversation_id, do: "33333333-3333-3333-3333-333333333333"

    @impl true
    def conversation_mcp_servers(conversation_id, _callback_token) do
      if conversation_id == trigger_conversation_id(), do: :not_a_list, else: []
    end
  end

  defmodule EnabledRaises do
    @moduledoc """
    Raises from `enabled?/0`. Deliberately NOT configured — it would take every
    call to `installed/0` with it. `Extensions.installed/1` takes a list so this
    can still be tested against the real function.
    """
    use Fountain.Extension, id: :fixture_enabled_raises

    @impl true
    def enabled?, do: raise("fixture cannot decide whether it is enabled")
  end
end
