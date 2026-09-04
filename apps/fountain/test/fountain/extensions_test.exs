defmodule Fountain.ExtensionsTest do
  @moduledoc """
  The extension registry and its validation (ADR 0043, #1505).

  Everything here is `async: true` because nothing writes `:extensions`. The
  installed list comes from `config/test.exs` and the validation tests pass
  their list in as an argument, which is the whole reason `validate/2` takes
  one.
  """
  use ExUnit.Case, async: true

  alias Fountain.Extensions

  alias Fountain.ExtensionFixtures.{
    Disabled,
    Enabled,
    EnabledRaises,
    Exploding,
    Silent,
    WrongShape
  }

  import ExUnit.CaptureLog

  describe "configured/0 and installed/0" do
    test "configured/0 lists every extension named in config, enabled or not" do
      assert Extensions.configured() == [Enabled, Disabled, Silent, Exploding, WrongShape]
    end

    test "installed/0 drops the ones this deployment cannot run" do
      assert Extensions.installed() == [Enabled, Silent, Exploding, WrongShape]
      refute Disabled in Extensions.installed()
    end

    test "installed/0 preserves configured order" do
      # Ordering is a host decision and the MCP fan-out depends on it, so it is
      # asserted rather than left to Enum's incidental behaviour.
      assert Extensions.installed() == Enum.filter(Extensions.configured(), & &1.enabled?())
    end
  end

  describe "find_by_prefix/1" do
    test "finds an installed extension by its prefix" do
      assert Extensions.find_by_prefix("fixture") == Enabled
    end

    test "does not find a configured-but-disabled extension" do
      # Disabled declares "fixture-disabled" and is still in configured/0. If
      # this ever returns the module, a deployment that turned an extension off
      # would still be serving its routes.
      assert Disabled.api_prefix() == "fixture-disabled"
      assert Extensions.find_by_prefix("fixture-disabled") == nil
    end

    test "does not find an extension that declares no prefix" do
      assert Silent.api_prefix() == nil
      assert Extensions.find_by_prefix(nil) == nil
    end

    test "returns nil for an unknown prefix" do
      assert Extensions.find_by_prefix("nothing-serves-this") == nil
    end
  end

  describe "conversation_mcp_servers/2" do
    test "collects the claimed conversation's servers" do
      token = "cbk_test_token"

      assert [server] =
               Extensions.conversation_mcp_servers(Enabled.claimed_conversation_id(), token)

      assert server["name"] == "fixture"
      assert server["headers"]["authorization"] == "Bearer #{token}"
    end

    test "contributes nothing for a conversation no extension claims" do
      assert Extensions.conversation_mcp_servers(Ecto.UUID.generate(), "cbk_test_token") == []
    end

    test "never calls a disabled extension" do
      # Disabled returns a server unconditionally; if it were called, it would
      # show up here for every conversation in the system.
      servers = Extensions.conversation_mcp_servers(Ecto.UUID.generate(), "cbk_test_token")
      refute Enum.any?(servers, &(&1["name"] == "disabled-should-never-appear"))
    end

    test "contributes nothing without a conversation id or a callback token" do
      # The token gates the whole list: an extension's servers are authenticated
      # with the conversation-scoped credential or they are not served at all.
      assert Extensions.conversation_mcp_servers(nil, "cbk_test_token") == []
      assert Extensions.conversation_mcp_servers(Enabled.claimed_conversation_id(), nil) == []
    end
  end

  describe "conversation_mcp_servers/2 isolation" do
    # These go through the real function over the real installed list. The
    # misbehaving fixtures each fail for one conversation id only, which is
    # what makes that possible: installing them costs nothing anywhere else,
    # and the alternative — a hand-rolled `Enum.flat_map` with its own
    # try/rescue — would test a copy of the logic rather than the logic.

    test "a raising extension costs only its own servers" do
      # Enabled serves this conversation too, so the assertion is not merely
      # "no crash": it is that everyone else's contribution survived intact.
      log =
        capture_log(fn ->
          servers =
            Extensions.conversation_mcp_servers(Exploding.trigger_conversation_id(), "cbk_t")

          assert Enum.map(servers, & &1["name"]) == ["fixture"]
        end)

      assert log =~ "Exploding"
      assert log =~ "fixture extension exploded"
    end

    test "an extension returning a non-list contributes none and does not corrupt the list" do
      log =
        capture_log(fn ->
          assert Extensions.conversation_mcp_servers(WrongShape.trigger_conversation_id(), "t") ==
                   []
        end)

      assert log =~ "WrongShape"
      assert log =~ "expected a list"
    end

    test "an extension that cannot say whether it is enabled is not installed" do
      log =
        capture_log(fn ->
          assert Extensions.installed([EnabledRaises, Enabled]) == [Enabled]
        end)

      assert log =~ "EnabledRaises"
      assert log =~ "treating as not installed"
    end
  end

  describe "validate/2 accepts" do
    test "the list this suite actually runs" do
      assert Extensions.validate(Extensions.configured()) == :ok
    end

    test "an empty list" do
      assert Extensions.validate([]) == :ok
    end

    test "an extension with no HTTP surface at all" do
      assert Extensions.validate([Silent]) == :ok
    end
  end

  describe "validate/2 fails closed" do
    test "on a duplicate id" do
      defmodule DupeIdA do
        use Fountain.Extension, id: :same
      end

      defmodule DupeIdB do
        use Fountain.Extension, id: :same
      end

      assert {:error, message} = Extensions.validate([DupeIdA, DupeIdB])
      assert message =~ "id :same is declared by more than one extension"
    end

    test "on a duplicate API prefix" do
      defmodule DupePrefixA do
        use Fountain.Extension, id: :dupe_prefix_a
        @impl true
        def api_prefix, do: "shared"
        @impl true
        def api_plug, do: Fountain.ExtensionFixtures.Router
      end

      defmodule DupePrefixB do
        use Fountain.Extension, id: :dupe_prefix_b
        @impl true
        def api_prefix, do: "shared"
        @impl true
        def api_plug, do: Fountain.ExtensionFixtures.Router
      end

      assert {:error, message} = Extensions.validate([DupePrefixA, DupePrefixB])
      assert message =~ ~s(API prefix "shared" is declared by more than one extension)
    end

    test "on a prefix a core route already claims" do
      defmodule Shadower do
        use Fountain.Extension, id: :shadower
        @impl true
        def api_prefix, do: "agents"
        @impl true
        def api_plug, do: Fountain.ExtensionFixtures.Router
      end

      assert {:error, message} = Extensions.validate([Shadower])
      assert message =~ "already served by a core route at /api/agents"
    end

    test "on a prefix the browser scope claims (/api/settings/theme)" do
      # The one /api path that lives in the browser scope, declared after every
      # /api scope in the router. A hand-kept reserved list would have missed
      # it; reading __routes__/0 does not.
      defmodule SettingsShadower do
        use Fountain.Extension, id: :settings_shadower
        @impl true
        def api_prefix, do: "settings"
        @impl true
        def api_plug, do: Fountain.ExtensionFixtures.Router
      end

      assert {:error, message} = Extensions.validate([SettingsShadower])
      assert message =~ "already served by a core route at /api/settings"
    end

    test "on a prefix that is not one lowercase segment" do
      for bad <- ["Buzz", "/buzz", "buzz/agents", "buzz.thing", "", "9lives"] do
        defmodule_with_prefix = fn prefix ->
          {:module, mod, _, _} =
            Module.create(
              :"Elixir.BadPrefix#{System.unique_integer([:positive])}",
              quote do
                use Fountain.Extension, id: :bad_prefix
                @impl true
                def api_prefix, do: unquote(prefix)
                @impl true
                def api_plug, do: Fountain.ExtensionFixtures.Router
              end,
              Macro.Env.location(__ENV__)
            )

          mod
        end

        assert {:error, message} = Extensions.validate([defmodule_with_prefix.(bad)])
        assert message =~ "is not one lowercase path segment", "accepted #{inspect(bad)}"
      end
    end

    test "on a prefix with no plug behind it" do
      defmodule PrefixNoPlug do
        use Fountain.Extension, id: :prefix_no_plug
        @impl true
        def api_prefix, do: "orphan"
      end

      assert {:error, message} = Extensions.validate([PrefixNoPlug])
      assert message =~ "but no api_plug"
    end

    test "on a plug with no prefix in front of it" do
      defmodule PlugNoPrefix do
        use Fountain.Extension, id: :plug_no_prefix
        @impl true
        def api_plug, do: Fountain.ExtensionFixtures.Router
      end

      assert {:error, message} = Extensions.validate([PlugNoPrefix])
      assert message =~ "but no api_prefix"
    end

    test "on a module that is not an extension" do
      assert {:error, message} = Extensions.validate([Enum])
      assert message =~ "does not implement Fountain.Extension"
    end

    test "on a module that does not exist" do
      assert {:error, message} = Extensions.validate([NoSuchModuleAnywhere])
      assert message =~ "is not a loadable module"
    end
  end

  describe "validate!/1" do
    test "raises with the offending module named and the ADR pointed at" do
      assert_raise ArgumentError, ~r/does not implement Fountain.Extension/, fn ->
        Extensions.validate!([Enum])
      end

      assert_raise ArgumentError, ~r/0043-first-party-extensions/, fn ->
        Extensions.validate!([Enum])
      end
    end

    test "passes the configuration this VM booted with" do
      # If this fails, Fountain.Application.start/2 would have refused to boot.
      assert Extensions.validate!() == :ok
    end
  end

  describe "reserved_prefixes/0" do
    test "is read from the router rather than hand-kept" do
      reserved = Extensions.reserved_prefixes()

      for prefix <- ~w(agents vaults environments conversations audit search catalog admin) do
        assert MapSet.member?(reserved, prefix), "/api/#{prefix} should reserve #{prefix}"
      end
    end

    test "skips dynamic segments, which cannot collide with a static prefix" do
      refute Enum.any?(Extensions.reserved_prefixes(), &String.starts_with?(&1, ":"))
    end

    test "does not reserve a prefix nothing serves" do
      refute MapSet.member?(Extensions.reserved_prefixes(), "fixture")
    end
  end
end
