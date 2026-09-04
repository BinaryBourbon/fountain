defmodule FountainSupport.BoundaryTest do
  @moduledoc """
  What the extension owes the host, asserted from the extension's side
  (ADR 0043, #1528).

  `Fountain.ExtensionGuardTest` checks that core names nothing here. This checks
  the other things the move promised: the contract is implemented and no wider
  than three callbacks, the audit event survived, the enums still match the
  domain, the published titles are unchanged, and the one path this extension
  mounts is the path the API always served.
  """
  use Fountain.DataCase, async: true

  alias Fountain.Audit
  alias FountainSupport.Extension

  describe "the extension contract" do
    test "implements every Fountain.Extension callback" do
      assert Extension.id() == :support

      for {fun, arity} <- Fountain.Extension.behaviour_info(:callbacks) do
        assert function_exported?(Extension, fun, arity),
               "FountainSupport.Extension is missing #{fun}/#{arity}"
      end
    end

    test "uses three callbacks and widens the seam with none" do
      # #1528 exists to prove the seam against a second feature *without*
      # widening it. Everything else must still be the `use Fountain.Extension`
      # default, so a review notices the day one of them stops being one.
      assert Extension.enabled?() == true
      assert Extension.conversation_mcp_servers("whatever", "token") == []
      assert Extension.admin_overview() == []
      assert Extension.admin_user_columns() == []

      # In particular: no cron. The forwarder is enqueued by this app's own
      # context, so core config never names a worker a core-only release lacks.
      assert Extension.oban_cron() == []
    end

    test "mounts exactly the path the API has always served" do
      assert Extension.api_mounts() == [{"/support", FountainSupport.Router}]
    end

    test "is installed in this VM, so the suite exercises it through the seam" do
      assert Extension in Fountain.Extensions.installed()
    end

    test "its migrations resolve to a real directory in its own priv" do
      assert [path] = Fountain.Extensions.migration_paths([Extension])
      assert File.dir?(path)
      assert String.contains?(path, "fountain_support")

      # The version that MOVED is unchanged, which is what makes the move a
      # no-op for a database that already applied it through the core path.
      # `FountainSupport.UpgradeTest` is where that is proved.
      assert path |> File.ls!() |> Enum.map(&String.slice(&1, 0, 14)) == ["20260819130000"]
    end

    test "describes only paths it serves" do
      # Would raise otherwise; asserting the value keeps the check honest.
      paths = Fountain.Extensions.openapi_paths([Extension])

      assert paths |> Map.keys() |> Enum.sort() == [
               "/api/support/reports",
               "/api/support/reports/{id}"
             ]
    end
  end

  describe "every route this extension serves is described" do
    # `FountainWeb.ApiSpecTest`'s "every /api/ route is in the spec" walks
    # `FountainWeb.Router.__routes__/0`, which stopped including these when they
    # moved. Without this the extension's routes would have escaped that guard
    # entirely — the API would be free to grow an undocumented operation and no
    # check anywhere would notice.

    test "every mounted route has an OpenAPI operation" do
      described = Fountain.Extensions.openapi_paths([Extension]) |> Map.keys() |> MapSet.new()

      undocumented =
        for {mount, router} <- Extension.api_mounts(),
            route <- router.__routes__(),
            path = open_api_path(mount <> route.path),
            not MapSet.member?(described, "/api" <> path),
            do: {path, route.verb}

      assert undocumented == [],
             "these extension routes have no OpenAPI operation: #{inspect(undocumented)}"
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

  describe "the audit event survived the move" do
    # This used to be a row in `Fountain.AuditGuardrailTest`'s table. ADR 0013's
    # rule is unchanged by the extraction: a context records its own event,
    # through the host's `Fountain.Audit`, with the host's closed actor
    # vocabulary. An extension gets no trail of its own.

    test "create records support.report.created, with keys and never content" do
      user = insert_verified_user()

      {:ok, report} =
        FountainSupport.create_report(user.id, %{
          "category" => "bug",
          "message" => "it broke in a memorable way",
          "context" => %{"conversation_id" => "x"}
        })

      event =
        user.id
        |> Audit.list_recent_for_user(50)
        |> Enum.find(&(&1.action == "support.report.created"))

      assert event, "no support.report.created was recorded"
      assert event.resource_type == "support_report"
      assert event.resource_id == report.id
      assert event.actor == "self"
      assert event.metadata["category"] == "bug"
      assert event.metadata["context_keys"] == ["conversation_id"]
      assert event.metadata["screenshot"] == false
      refute Jason.encode!(event.metadata) =~ "memorable"
    end
  end

  describe "the schema enums still match the domain" do
    # The core registry in `FountainWeb.SchemaEnumGuardrailTest` used to carry
    # four entries for these. They moved with the schemas; the property is the
    # same one, checked over this app's modules.
    @derived %{
      {FountainSupport.Schemas.SupportReport, "category"} =>
        {FountainSupport.Report, :categories},
      {FountainSupport.Schemas.SupportReport, "status"} => {FountainSupport.Report, :statuses},
      {FountainSupport.Schemas.SupportReportCreateRequest, "category"} =>
        {FountainSupport.Report, :categories}
    }

    test "every declared enum equals the domain list it is derived from" do
      for {{schema_mod, path}, {domain_mod, fun}} <- @derived do
        assert enum_at(schema_mod, path) == apply(domain_mod, fun, []),
               "#{inspect(schema_mod)}.#{path} has drifted from #{inspect(domain_mod)}.#{fun}/0"
      end
    end

    test "the registry names no enum that has gone" do
      for {{schema_mod, path}, _} <- @derived do
        assert enum_at(schema_mod, path) != nil,
               "#{inspect(schema_mod)}.#{path} is in the registry but not in the schema"
      end
    end

    test "the screenshot media types the request advertises are the ones core decodes" do
      # This was a fifth row in the core registry, against
      # `Fountain.Images.valid_media_types/0`. Image decoding stays the host's
      # (ADR 0043: the extension consumes it), so this is the one enum here
      # derived from a core list rather than from this app's own.
      declared =
        FountainSupport.Schemas.SupportReportCreateRequest.schema().properties.screenshot.properties.media_type.enum

      assert declared == Fountain.Images.valid_media_types()
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

  describe "the published contract is unchanged" do
    test "every schema keeps the title it had as a core module" do
      # A title is the component key in the published document, and the four
      # SDKs are generated from it. The module names moved; these did not.
      for {mod, title} <- [
            {FountainSupport.Schemas.SupportReport, "SupportReport"},
            {FountainSupport.Schemas.SupportReportCreateRequest, "SupportReportCreateRequest"},
            {FountainSupport.Schemas.SupportReportResponse, "SupportReportResponse"},
            {FountainSupport.Schemas.SupportReportListResponse, "SupportReportListResponse"}
          ] do
        assert mod.schema().title == title
      end
    end

    test "every operationId still spells the core controller it used to be" do
      # OpenApiSpex derives an operationId from module + action, so the rename
      # would have changed all three in the document the SDKs generate from.
      paths = Fountain.Extensions.openapi_paths([Extension])

      ids =
        for {_path, item} <- paths,
            {_verb, operation} <- Map.from_struct(item),
            match?(%OpenApiSpex.Operation{}, operation),
            do: operation.operationId

      assert Enum.sort(ids) == [
               "FountainWeb.SupportReportController.create",
               "FountainWeb.SupportReportController.index",
               "FountainWeb.SupportReportController.show"
             ]
    end
  end
end
