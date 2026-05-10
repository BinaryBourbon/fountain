defmodule Fountain.Repo.Migrations.ChangeAgentsSkillsToJsonbArray do
  @moduledoc """
  `agents.skills` was created as `text[]` in the initial schema, but the
  Ecto field declaration is `{:array, :map}` (each element is a SkillSpec
  map: `%{"source" => owner_repo}` or `%{"name" => n, "content" => md}`).
  On Postgres, `{:array, :map}` maps to `jsonb[]`, not `text[]`.

  The mismatch was masked on SQLite (both shapes are stored as TEXT JSON).
  On Postgres it surfaces as `Postgrex.Extensions.Array.encode/4` errors
  any time agent create/update tries to send a SkillSpec map — which is
  what `fountain apply` does for every agent doc.

  Existing rows hold `[]` (the post-rehydrate default; the rehydrate
  migration's legacy_skills branch can't have run on Postgres without
  hitting the same encode error). The USING clause defensively casts
  each text element through `::jsonb` so any hand-written valid-JSON
  data is preserved; non-JSON text would error loudly here rather than
  silently corrupt.

  Postgres disallows subqueries directly in `ALTER COLUMN ... USING`,
  so the cast goes through a temporary function that's dropped at the
  end of the migration.
  """
  use Ecto.Migration

  def up do
    # The initial migration set `default ARRAY[]::text[]` on the column;
    # the type change can't auto-cast the default, so drop it for the
    # ALTER and re-add it as `'{}'::jsonb[]` after.
    execute "ALTER TABLE agents ALTER COLUMN skills DROP DEFAULT"

    execute """
    CREATE FUNCTION fountain_text_to_jsonb_array(text[]) RETURNS jsonb[]
      LANGUAGE SQL IMMUTABLE AS $$
      SELECT COALESCE(
        array_agg(elem::jsonb),
        ARRAY[]::jsonb[]
      )
      FROM unnest($1) AS elem
    $$
    """

    execute """
    ALTER TABLE agents
      ALTER COLUMN skills TYPE jsonb[]
      USING fountain_text_to_jsonb_array(skills)
    """

    execute "DROP FUNCTION fountain_text_to_jsonb_array(text[])"

    execute "ALTER TABLE agents ALTER COLUMN skills SET DEFAULT ARRAY[]::jsonb[]"
  end

  def down do
    execute "ALTER TABLE agents ALTER COLUMN skills DROP DEFAULT"

    execute """
    CREATE FUNCTION fountain_jsonb_to_text_array(jsonb[]) RETURNS text[]
      LANGUAGE SQL IMMUTABLE AS $$
      SELECT COALESCE(
        array_agg(elem::text),
        ARRAY[]::text[]
      )
      FROM unnest($1) AS elem
    $$
    """

    execute """
    ALTER TABLE agents
      ALTER COLUMN skills TYPE text[]
      USING fountain_jsonb_to_text_array(skills)
    """

    execute "DROP FUNCTION fountain_jsonb_to_text_array(jsonb[])"

    execute "ALTER TABLE agents ALTER COLUMN skills SET DEFAULT ARRAY[]::text[]"
  end
end
