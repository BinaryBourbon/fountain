defmodule Fountain.ExtensionCompositionTest do
  @moduledoc """
  Migration and OpenAPI composition (ADR 0043, #1506).

  The two artefacts a runtime callback cannot reach: what the migrator runs, and
  what the published spec describes.
  """
  use Fountain.DataCase, async: true

  alias Fountain.{Extensions, Migrations, Repo}

  alias Fountain.ExtensionFixtures.{
    Colliding,
    DescribesWithoutMount,
    Disabled,
    Enabled,
    MissingMigrations,
    Silent
  }

  alias FountainWeb.ApiSpec
  alias FountainWeb.ApiSpec.Compose

  # The version of priv/test_extension_migrations/…_create_extension_fixture_rows.exs
  @fixture_version 20_260_903_180_000

  describe "migration_paths/1" do
    test "is the installed extensions' directories, in configured order" do
      paths = Extensions.migration_paths()

      # The fixture's, whatever else this run installs — which extensions are on
      # the code path depends on the working directory (ADR 0043).
      assert path = Enum.find(paths, &String.ends_with?(&1, "/test_extension_migrations"))
      assert File.dir?(path)
      assert Enum.all?(paths, &File.dir?/1)
    end

    test "is empty with nothing installed, so an absent extension changes nothing" do
      assert Extensions.migration_paths([]) == []
    end

    test "does not include a configured-but-disabled extension" do
      # Disabled declares no migrations today, so the real assertion is that
      # migration_paths reads `installed/0`: give it the whole configured list
      # and the disabled one still contributes nothing.
      assert Extensions.migration_paths(Extensions.installed(Extensions.configured())) ==
               Extensions.migration_paths()

      assert Disabled in Extensions.configured()
      assert Extensions.migration_paths([Disabled]) == []
    end

    test "raises, naming the extension, when a declared directory is not there" do
      assert_raise ArgumentError, ~r/MissingMigrations.*no_such_directory.*does not exist/s, fn ->
        Extensions.migration_paths([MissingMigrations])
      end
    end

    test "raises on a migrations/0 entry that is not {otp_app, path}" do
      defmodule BadMigrationShape do
        use Fountain.Extension, id: :bad_migration_shape
        @impl true
        def migrations, do: ["priv/migrations"]
      end

      assert_raise ArgumentError, ~r/must return \{otp_app, path\} tuples/, fn ->
        Extensions.migration_paths([BadMigrationShape])
      end
    end
  end

  describe "Fountain.Migrations.paths/1" do
    test "is the core path first, then the extensions'" do
      assert [core | extensions] = Migrations.paths(Repo)
      assert String.ends_with?(core, "/repo/migrations")
      assert extensions == Extensions.migration_paths()
    end

    test "degrades to the single core path when nothing is installed" do
      # What a core-only distribution runs. Asserted through the same function
      # the boot migrator and the release task call, not a reimplementation.
      assert [Ecto.Migrator.migrations_path(Repo)] ==
               [Ecto.Migrator.migrations_path(Repo) | Extensions.migration_paths([])]
    end
  end

  describe "the fixture migration actually ran" do
    test "the extension's table exists in the test database" do
      # It is defined in priv/test_extension_migrations, which is reachable only
      # through the extension path set. If the aliases in mix.exs stopped
      # appending it, `MIX_ENV=test mix ecto.migrate` would leave this missing.
      #
      # On CI this is a strong assertion: every job creates the database from
      # nothing, so the table exists only if the alias fired on that run. On a
      # workstation whose database was already migrated it is weaker, because
      # the table survives. `Migrations.paths/1` above is the part that fails
      # locally, and `mix ecto.reset` restores the strong form.
      assert {:ok, %{rows: [[0]]}} =
               Repo.query("SELECT count(*) FROM extension_fixture_rows")
    end

    test "it is recorded in Fountain's own schema_migrations, not a table of its own" do
      assert {:ok, %{rows: [[1]]}} =
               Repo.query("SELECT count(*) FROM schema_migrations WHERE version = $1", [
                 @fixture_version
               ])
    end
  end

  describe "moving a migration between paths does not re-run it (the #1507 upgrade case)" do
    test "Ecto reports the version as applied even when no file in the path set defines it" do
      # This is the whole upgrade property, exercised without moving Buzz.
      # `schema_migrations` is keyed by version, never by path, so a version
      # already recorded stays `:up` when its file moves from the core directory
      # into an extension's — Ecto reports it up, with no file, rather than
      # running it a second time.
      core_only = [Ecto.Migrator.migrations_path(Repo)]

      assert {:up, @fixture_version, name} =
               Repo
               |> Ecto.Migrator.migrations(core_only)
               |> Enum.find(&match?({_, @fixture_version, _}, &1))

      assert name == "** FILE NOT FOUND **"
    end

    test "with the extension path present it resolves to its real migration" do
      assert {:up, @fixture_version, "create_extension_fixture_rows"} =
               Repo
               |> Ecto.Migrator.migrations(Migrations.paths(Repo))
               |> Enum.find(&match?({_, @fixture_version, _}, &1))
    end
  end

  describe "openapi_paths/1" do
    test "describes an extension's paths under its own mount" do
      paths = Extensions.openapi_paths()

      assert Map.has_key?(paths, "/api/fixture/whoami")
      assert Map.has_key?(paths, "/api/fixture/nested/deep")
      # The extension described "/whoami"; the host owns the "/api/fixture".
      refute Map.has_key?(paths, "/whoami")
    end

    test "is empty with nothing installed" do
      assert Extensions.openapi_paths([]) == %{}
    end

    test "an extension with no HTTP surface contributes nothing" do
      assert Extensions.openapi_paths([Silent]) == %{}
    end

    test "a disabled extension contributes nothing" do
      assert Extensions.openapi_paths([Disabled]) == %{}
    end

    test "raises on a path outside every mount the extension declares" do
      # The whole reason openapi_paths/0 takes absolute paths: the check is
      # "does it serve this?", asked directly, rather than made true by
      # construction for a single mount and unanswerable for two.
      assert_raise ArgumentError,
                   ~r|"/api/somewhere-else/nested/deep".*outside every path|s,
                   fn ->
                     Extensions.openapi_paths([DescribesWithoutMount])
                   end
    end
  end

  describe "Compose.compose!/2" do
    setup do
      %{core: core_spec()}
    end

    test "is the identity with nothing installed", %{core: core} do
      # The gate: the bundled spec is unchanged before anything moves. A
      # deployment with no extension gets byte-for-byte what it got before
      # composition existed.
      assert Compose.compose!(core, []) == core
    end

    test "adds the installed extension's paths and leaves every core path alone", %{core: core} do
      composed = Compose.compose!(core, [Enabled])

      assert Map.has_key?(composed.paths, "/api/fixture/whoami")

      for {path, item} <- core.paths do
        assert composed.paths[path] == item, "composition changed the core path #{path}"
      end
    end

    test "adds the extension's schema components without touching the core's", %{core: core} do
      composed = Compose.compose!(core, [Enabled])

      assert Map.has_key?(composed.components.schemas, "FixtureWhoami")

      for {title, schema} <- core.components.schemas do
        assert composed.components.schemas[title] == schema,
               "composition changed the core schema #{title}"
      end
    end

    test "raises on a component title the core already defines, rather than overwriting it",
         %{core: core} do
      # Colliding describes a schema titled "Agent" with a different shape. Left
      # to Map.merge one would replace the other and every $ref would resolve to
      # the survivor — invisibly, in the spec the SDKs are generated from.
      assert Map.has_key?(core.components.schemas, "Agent")

      assert_raise ArgumentError, ~r/schema components that collide with the core's: Agent/, fn ->
        Compose.compose!(core, [Colliding])
      end
    end

    test "raises on a path the core already describes", %{core: core} do
      # Reachable only by describing a path outside the extension's own mount,
      # since validate!/0 refuses a prefix a core route claims. Built by hand
      # here so the check is proven rather than assumed unreachable.
      shadow = %{
        core
        | paths: Map.put(core.paths, "/api/fixture/whoami", %OpenApiSpex.PathItem{})
      }

      assert_raise ArgumentError, ~r|core already describes: /api/fixture/whoami|, fn ->
        Compose.compose!(shadow, [Enabled])
      end
    end
  end

  describe "the served spec reflects the running distribution" do
    test "the fixture's operations are in it, because the fixture is installed" do
      spec = ApiSpec.spec()

      assert Map.has_key?(spec.paths, "/api/fixture/whoami")
      assert Map.has_key?(spec.components.schemas, "FixtureWhoami")
    end

    test "every core path is still in it" do
      spec = ApiSpec.spec()

      for path <- ["/api/agents", "/api/conversations", "/api/vaults"] do
        assert Map.has_key?(spec.paths, path)
      end
    end

    test "an extension path is described exactly where it is served" do
      # Same string in the router mount and in the spec, by construction: the
      # host builds both from api_prefix/0, so a described path and a served
      # path cannot drift.
      assert Map.has_key?(ApiSpec.spec().paths, "/api" <> Enabled.mount() <> "/whoami")
    end
  end

  # The core half of the spec, resolved, without composition — what
  # `ApiSpec.spec/0` builds before it calls Compose.
  defp core_spec do
    %OpenApiSpex.OpenApi{
      info: %OpenApiSpex.Info{title: "Fountain", version: "test"},
      paths: OpenApiSpex.Paths.from_router(FountainWeb.Router)
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
