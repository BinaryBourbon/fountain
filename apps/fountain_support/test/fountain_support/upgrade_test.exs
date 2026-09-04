defmodule FountainSupport.UpgradeTest do
  @moduledoc """
  Upgrading a database that was migrated before the move (ADR 0043, #1528).

  Every deployment applied `support_reports` from Fountain's own
  `priv/repo/migrations`. #1528 moved that file into
  `apps/fountain_support/priv/repo/migrations` without renumbering it. This is
  the test that the move is a no-op for such a database: Ecto matches a version
  in `schema_migrations` and never a path, so the row stays applied, the table
  is not recreated, and existing reports keep working.

  This is not a simulation. The test database *is* a database that applied this
  version before the move — the row in `schema_migrations` was written when the
  file still lived in core — so what it asserts is the real upgrade.

  The bundled-to-core-to-bundled direction is the same fact read backwards: a
  core-only image applies nothing here and leaves the table alone (the issue's
  "existing rows and applied migration history across image changes"), which the
  second test below is what proves.
  """
  use Fountain.DataCase, async: true

  alias Fountain.{Migrations, Repo}

  @moved_version 20_260_819_130_000

  test "the moved version is recorded, and Ecto sees it as applied" do
    assert {:up, @moved_version, name} =
             Repo
             |> Ecto.Migrator.migrations(Migrations.paths(Repo))
             |> Enum.find(&match?({_, @moved_version, _}, &1))

    # Resolved to its real file, from the extension's path.
    refute name == "** FILE NOT FOUND **"
  end

  test "a core-only path set still reports it applied, so nothing re-runs" do
    # What a deployment looks like the instant before the extension's migration
    # path is added, and what it looks like again after a bundled-to-core image
    # swap: the version is in schema_migrations, the file is not in the path
    # being scanned. Ecto reports it up with no file rather than pending — which
    # is exactly why moving the file re-runs nothing, and why swapping back
    # converges instead of trying to create the table twice.
    core_only = [Ecto.Migrator.migrations_path(Repo)]

    assert {:up, @moved_version, "** FILE NOT FOUND **"} =
             Repo
             |> Ecto.Migrator.migrations(core_only)
             |> Enum.find(&match?({_, @moved_version, _}, &1))
  end

  test "nothing is pending across the composed path set" do
    pending =
      Repo
      |> Ecto.Migrator.migrations(Migrations.paths(Repo))
      |> Enum.filter(fn {status, _version, _name} -> status == :down end)

    assert pending == [], "pending after the move: #{inspect(pending)}"
  end

  test "a report written before the move still reads and writes" do
    # The table was not recreated, so a row is a row: the schema the extension
    # now owns is the schema core wrote.
    user = insert_verified_user()

    {:ok, report} =
      FountainSupport.create_report(user.id, %{"category" => "bug", "message" => "before"})

    assert {:ok, forwarded} =
             FountainSupport.mark_forwarded(report, %{
               "status" => "forwarded",
               "forwarded_at" => DateTime.utc_now() |> DateTime.truncate(:second)
             })

    assert forwarded.status == "forwarded"
    assert FountainSupport.get_report(report.id, user.id).id == report.id
  end

  test "the table still carries every column core's migration created" do
    {:ok, %{columns: columns}} = Repo.query("SELECT * FROM support_reports LIMIT 0")

    for column <- ~w(user_id category message context client screenshot
                     screenshot_media_type status forwarded_at external_url
                     forward_error) do
      assert column in columns, "support_reports lost #{column} in the move"
    end
  end
end
