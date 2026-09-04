defmodule FountainBuzz.UpgradeTest do
  @moduledoc """
  Upgrading a database that was migrated before the move (ADR 0043, #1507).

  Every production deployment applied `buzz_identities` and its two ALTERs from
  Fountain's own `priv/repo/migrations`. #1507 moved those three files into
  `apps/fountain_buzz/priv/repo/migrations` without renumbering them. This is
  the test that the move is a no-op for such a database: Ecto matches a version
  in `schema_migrations` and never a path, so the rows stay applied, the table
  is not recreated, and existing identities keep working.

  This is not a simulation. The test database *is* a database that applied these
  versions before the move — the rows in `schema_migrations` were written when
  the files still lived in core — so what it asserts is the real upgrade.
  """
  use Fountain.DataCase, async: true

  import FountainBuzz.Factory

  alias Fountain.{Migrations, Repo}

  @moved_versions [20_260_816_120_000, 20_260_817_030_000, 20_260_824_030_000]

  test "the moved versions are recorded, and Ecto sees them as applied" do
    applied =
      Repo
      |> Ecto.Migrator.migrations(Migrations.paths(Repo))
      |> Enum.filter(fn {_status, version, _name} -> version in @moved_versions end)

    assert length(applied) == 3

    for {status, version, name} <- applied do
      assert status == :up, "version #{version} is not applied"
      # Resolved to its real file, from the extension's path.
      refute name == "** FILE NOT FOUND **"
    end
  end

  test "a core-only path set still reports them applied, so nothing re-runs" do
    # What a deployment looks like the instant before the extension's migration
    # path is added: the versions are in schema_migrations, the files are not in
    # the path being scanned. Ecto reports them up with no file rather than
    # pending — which is exactly why moving the files re-runs nothing.
    core_only = [Ecto.Migrator.migrations_path(Repo)]

    for version <- @moved_versions do
      assert {:up, ^version, "** FILE NOT FOUND **"} =
               Repo
               |> Ecto.Migrator.migrations(core_only)
               |> Enum.find(&match?({_, ^version, _}, &1))
    end
  end

  test "nothing is pending across the composed path set" do
    pending =
      Repo
      |> Ecto.Migrator.migrations(Migrations.paths(Repo))
      |> Enum.filter(fn {status, _version, _name} -> status == :down end)

    assert pending == [], "pending after the move: #{inspect(pending)}"
  end

  test "an identity created before the move still reads and writes" do
    # The table was not recreated, so a row is a row: the schema the extension
    # now owns is the schema core wrote.
    identity = insert_buzz_identity()

    assert {:ok, updated} = FountainBuzz.update_identity(identity, %{"display_name" => "after"})
    assert updated.display_name == "after"

    assert FountainBuzz.get_identity(identity.id, identity.user_id).id == identity.id
  end

  test "the table still carries the columns both ALTERs added" do
    {:ok, %{columns: columns}} = Repo.query("SELECT * FROM buzz_identities LIMIT 0")

    for column <- ["respond_to", "respond_to_allowlist", "sandbox_mode"] do
      assert column in columns, "buzz_identities lost #{column} in the move"
    end
  end
end
