defmodule Managoat.OAuth.MigrationTest do
  @moduledoc """
  The migration a consumer runs, run for real: into a scratch Postgres
  schema inside this test's sandbox transaction (Postgres DDL is
  transactional, so it all rolls back at the end and no other test can see
  it), then driven through an instance configured with that prefix, then
  taken down again.
  """
  use Managoat.OAuth.Case, async: true

  alias Managoat.OAuth.PrefixedInstance

  @prefix "managoat_oauth_scratch"

  defmodule Scratch do
    @moduledoc false
    use Ecto.Migration

    def up, do: Managoat.OAuth.Migration.up(prefix: "managoat_oauth_scratch")
    def down, do: Managoat.OAuth.Migration.down(prefix: "managoat_oauth_scratch")
  end

  test "up creates tables the schemas load against; down removes them" do
    # The migrator keeps schema_migrations under the prefix too, before the
    # migration itself gets to create the schema.
    TestRepo.query!("CREATE SCHEMA IF NOT EXISTS #{@prefix}")
    assert oauth_tables(@prefix) == []

    migrate(:up)

    assert oauth_tables(@prefix) == ["oauth_authorization_codes", "oauth_device_grants"]
    assert "user_id" in columns(@prefix, "oauth_authorization_codes")
    assert "user_id" in columns(@prefix, "oauth_device_grants")
    assert foreign_keys(@prefix) == []

    # The whole state machine runs against the new tables.
    subject = subject()
    {verifier, challenge} = pkce()
    {:ok, code} = PrefixedInstance.authorize(subject, request(challenge))

    assert {:ok, %{access_token: token}} =
             PrefixedInstance.exchange(token_request(code, verifier))

    assert token == "tok-" <> subject

    {:ok, %{device_code: device_code, user_code: user_code}} =
      PrefixedInstance.start_device_grant()

    assert :ok = PrefixedInstance.approve_device_grant(user_code, subject)
    assert {:ok, %{access_token: ^token}} = PrefixedInstance.poll_device_grant(device_code)

    # And nothing landed in the default schema.
    assert TestRepo.aggregate(AuthorizationCode, :count) == 0
    assert TestRepo.aggregate(DeviceGrant, :count) == 0

    migrate(:down)
    assert oauth_tables(@prefix) == []
  end

  test "the default migration produced the tables the helper's instance runs on" do
    assert oauth_tables("public") == ["oauth_authorization_codes", "oauth_device_grants"]

    assert columns("public", "oauth_authorization_codes") == [
             "client_id",
             "code_challenge",
             "code_hash",
             "expires_at",
             "id",
             "inserted_at",
             "redirect_uri",
             "updated_at",
             "used_at",
             "user_id"
           ]

    assert columns("public", "oauth_device_grants") == [
             "approved_at",
             "denied_at",
             "device_code_hash",
             "expires_at",
             "id",
             "inserted_at",
             "last_polled_at",
             "updated_at",
             "used_at",
             "user_code",
             "user_id"
           ]
  end

  test "a prefix that is not a plain identifier is refused before it reaches SQL" do
    assert_raise ArgumentError, ~r/plain identifier/, fn ->
      Managoat.OAuth.Migration.up(prefix: "x; drop schema public")
    end
  end

  # Ecto.Migrator runs the migration in a Task, which inherits this test's
  # sandbox connection through $callers; the lock is off because it would
  # want a second connection the sandbox does not have.
  defp migrate(direction) do
    Ecto.Migrator.run(TestRepo, [{1, Scratch}], direction,
      all: true,
      log: false,
      migration_lock: false,
      prefix: @prefix
    )
  end

  # Ecto.Migrator keeps schema_migrations beside them, under the prefix too.
  defp oauth_tables(schema), do: tables(schema) -- ["schema_migrations"]

  defp tables(schema) do
    %{rows: rows} =
      TestRepo.query!(
        "SELECT table_name FROM information_schema.tables WHERE table_schema = $1 ORDER BY 1",
        [schema]
      )

    List.flatten(rows)
  end

  defp columns(schema, table) do
    %{rows: rows} =
      TestRepo.query!(
        "SELECT column_name FROM information_schema.columns " <>
          "WHERE table_schema = $1 AND table_name = $2 ORDER BY 1",
        [schema, table]
      )

    List.flatten(rows)
  end

  defp foreign_keys(schema) do
    %{rows: rows} =
      TestRepo.query!(
        "SELECT constraint_name FROM information_schema.table_constraints " <>
          "WHERE table_schema = $1 AND constraint_type = 'FOREIGN KEY'",
        [schema]
      )

    List.flatten(rows)
  end
end
