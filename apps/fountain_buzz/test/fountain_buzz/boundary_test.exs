defmodule FountainBuzz.BoundaryTest do
  @moduledoc """
  What the extension owes the host, asserted from the extension's side
  (ADR 0043, #1507).

  `Fountain.ExtensionGuardTest` checks that core names nothing here. This
  checks the other things the move promised: the contract is implemented, the
  audit events survived, the enums still match the domain, and the two paths
  ADR 0043 decision 6 keeps are the two paths it mounts.
  """
  use Fountain.DataCase, async: true

  import FountainBuzz.Factory

  alias Fountain.Audit
  alias FountainBuzz.Extension

  describe "the extension contract" do
    test "implements every Fountain.Extension callback" do
      assert Extension.id() == :buzz

      for {fun, arity} <- Fountain.Extension.behaviour_info(:callbacks) do
        assert function_exported?(Extension, fun, arity),
               "FountainBuzz.Extension is missing #{fun}/#{arity}"
      end
    end

    test "mounts exactly the two paths ADR 0043 decision 6 keeps" do
      assert Extension.api_mounts() == [
               {"/buzz", FountainBuzz.Router},
               {"/mcp/buzz", FountainBuzz.McpRouter}
             ]
    end

    test "is installed in this VM, so the suite exercises it through the seam" do
      assert Extension in Fountain.Extensions.installed()
    end

    test "its migrations resolve to a real directory in its own priv" do
      assert [path] = Fountain.Extensions.migration_paths([Extension])
      assert File.dir?(path)
      assert String.contains?(path, "fountain_buzz")

      # The three versions that MOVED are unchanged, which is what makes the
      # move a no-op for a database that already applied them through the core
      # path. 20260904020000 was added by the move rather than moved by it —
      # `FountainBuzz.UpgradeTest` covers what it is for.
      versions = path |> File.ls!() |> Enum.map(&String.slice(&1, 0, 14)) |> Enum.sort()

      assert ["20260816120000", "20260817030000", "20260824030000"] --
               versions == []
    end

    test "describes only paths it serves" do
      # Would raise otherwise; asserting the value keeps the check honest.
      paths = Fountain.Extensions.openapi_paths([Extension])

      assert Map.keys(paths) |> Enum.sort() == ["/api/buzz/agents", "/api/buzz/agents/{id}"]
    end
  end

  describe "every route this extension serves is described, or excepted" do
    # `FountainWeb.ApiSpecTest`'s "every /api/ route is in the spec" walks
    # `FountainWeb.Router.__routes__/0`, which stopped including these when they
    # moved (#1507). Without this the extension's routes would have escaped that
    # guard entirely — the API would be free to grow an undocumented operation
    # and no check anywhere would notice.

    # `/api/mcp/buzz/:conversation_id` is not in the spec and was not before the
    # move either (it was an `@exceptions` entry in core's test): it is a
    # JSON-RPC transport the sandbox posts to with a conversation-scoped token,
    # not an operation a client codes against.
    @excepted_routes [{"/mcp/buzz/{conversation_id}", :post}]

    test "every mounted route has an OpenAPI operation" do
      described = Fountain.Extensions.openapi_paths([Extension]) |> Map.keys() |> MapSet.new()

      undocumented =
        for {mount, router} <- Extension.api_mounts(),
            route <- router.__routes__(),
            path = open_api_path(mount <> route.path),
            not MapSet.member?(described, "/api" <> path),
            {path, route.verb} not in @excepted_routes,
            do: {path, route.verb}

      assert undocumented == [],
             "these extension routes have no OpenAPI operation: #{inspect(undocumented)}"
    end

    test "every exception is still a live route" do
      live =
        for {mount, router} <- Extension.api_mounts(),
            route <- router.__routes__(),
            do: {open_api_path(mount <> route.path), route.verb}

      assert Enum.reject(@excepted_routes, &(&1 in live)) == [],
             "an exception names a route this extension no longer serves"
    end

    defp open_api_path(path) do
      path
      |> String.split("/")
      |> Enum.map_join("/", fn
        ":" <> segment -> "{#{segment}}"
        segment -> segment
      end)
    end
  end

  describe "audit events survived the move" do
    # These three used to be rows in `Fountain.AuditGuardrailTest`'s table.
    # ADR 0013's rule is unchanged by the extraction: a context records its own
    # event, through the host's `Fountain.Audit`, with the host's closed actor
    # vocabulary. An extension gets no trail of its own.

    setup do
      %{user: insert_verified_user()}
    end

    for {label, event} <- [
          {"create", "buzz_identity.created"},
          {"update", "buzz_identity.updated"},
          {"delete", "buzz_identity.deleted"}
        ] do
      test "#{label} records #{event}", %{user: user} do
        identity = insert_buzz_identity(%{"user_id" => user.id})

        case unquote(event) do
          "buzz_identity.updated" ->
            {:ok, _} = FountainBuzz.update_identity(identity, %{"display_name" => "x"})

          "buzz_identity.deleted" ->
            {:ok, _} = FountainBuzz.delete_identity(identity)

          _created ->
            :ok
        end

        events = Audit.list_recent_for_user(user.id, 50)

        assert Enum.any?(events, &(&1.action == unquote(event))),
               "no #{unquote(event)} in #{inspect(Enum.map(events, & &1.action))}"
      end
    end
  end

  describe "the schema enums still match the domain" do
    # The core registry in `FountainWeb.SchemaEnumGuardrailTest` used to carry
    # five entries for these. They moved with the schemas; the property is the
    # same one, checked over this app's modules.
    @derived %{
      {FountainBuzz.Schemas.BuzzIdentity, "respond_to"} =>
        {FountainBuzz.Identity, :respond_to_modes},
      {FountainBuzz.Schemas.BuzzProvisionRequest, "respond_to"} =>
        {FountainBuzz.Identity, :respond_to_modes},
      {FountainBuzz.Schemas.BuzzAccessUpdateRequest, "respond_to"} =>
        {FountainBuzz.Identity, :respond_to_modes},
      {FountainBuzz.Schemas.BuzzIdentity, "sandbox_mode"} =>
        {Fountain.Agents.Agent, :sandbox_modes},
      {FountainBuzz.Schemas.BuzzProvisionRequest, "sandbox_mode"} =>
        {Fountain.Agents.Agent, :sandbox_modes}
    }

    test "every declared enum equals the domain list it is derived from" do
      for {{schema_mod, path}, {domain_mod, fun}} <- @derived do
        values = enum_at(schema_mod, path)

        assert values == apply(domain_mod, fun, []),
               "#{inspect(schema_mod)}.#{path} has drifted from #{inspect(domain_mod)}.#{fun}/0"
      end
    end

    test "the registry names no enum that has gone" do
      for {{schema_mod, path}, _} <- @derived do
        assert enum_at(schema_mod, path) != nil,
               "#{inspect(schema_mod)}.#{path} is in the registry but not in the schema"
      end
    end

    defp enum_at(schema_mod, property) do
      schema_mod.schema().properties
      |> Map.get(String.to_existing_atom(property))
      |> case do
        %OpenApiSpex.Schema{enum: enum} -> enum
        _other -> nil
      end
    end
  end

  describe "the published titles are unchanged" do
    test "every schema keeps the title it had as a core module" do
      # A title is the component key in the published document, and the four
      # SDKs are generated from it. The module names moved; these did not.
      for {mod, title} <- [
            {FountainBuzz.Schemas.BuzzIdentity, "BuzzIdentity"},
            {FountainBuzz.Schemas.BuzzProvisionRequest, "BuzzProvisionRequest"},
            {FountainBuzz.Schemas.BuzzAccessUpdateRequest, "BuzzAccessUpdateRequest"}
          ] do
        assert mod.schema().title == title
      end
    end
  end
end
