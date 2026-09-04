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
