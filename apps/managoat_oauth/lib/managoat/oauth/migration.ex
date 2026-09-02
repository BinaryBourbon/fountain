defmodule Managoat.OAuth.Migration do
  @moduledoc """
  Creates the two tables `Managoat.OAuth` needs, from a migration of the
  host's own (the shape Oban uses; a hex package cannot run `mix
  ecto.migrate` for its host). In `MyApp.Repo.Migrations.AddOAuth`, say:

      use Ecto.Migration

      def up, do: Managoat.OAuth.Migration.up()
      def down, do: Managoat.OAuth.Migration.down()

  Options, the same for `up/1` and `down/1`:

    * `:subject_column` — the name of the column that holds the host's
      subject, `:user_id` by default. It is a `binary_id` with **no foreign
      key**; a host that wants one references its own table in the same
      migration (`alter table(:oauth_authorization_codes) do modify ...`).
    * `:prefix` — the Postgres schema to create the tables in, the default
      schema when nil. Pass the same value as `prefix:` in the instance's
      config. `up/1` creates the schema first unless `create_schema: false`.
  """
  use Ecto.Migration

  @codes :oauth_authorization_codes
  @grants :oauth_device_grants

  @doc "Create both tables and their indexes."
  @spec up(keyword()) :: :ok
  def up(opts \\ []) do
    prefix = prefix!(opts)
    subject = Keyword.get(opts, :subject_column, :user_id)

    if prefix && Keyword.get(opts, :create_schema, true) do
      execute("CREATE SCHEMA IF NOT EXISTS #{prefix}")
    end

    create table(@codes, primary_key: false, prefix: prefix) do
      add :id, :binary_id, primary_key: true
      add :code_hash, :string, null: false
      add subject, :binary_id, null: false
      add :client_id, :string, null: false
      add :redirect_uri, :string, null: false
      add :code_challenge, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(@codes, [:code_hash], prefix: prefix)
    create index(@codes, [:expires_at], prefix: prefix)

    create table(@grants, primary_key: false, prefix: prefix) do
      add :id, :binary_id, primary_key: true
      add :device_code_hash, :string, null: false
      add :user_code, :string, null: false
      # Null until a signed-in subject approves or denies.
      add subject, :binary_id
      add :approved_at, :utc_datetime
      add :denied_at, :utc_datetime
      add :used_at, :utc_datetime
      add :last_polled_at, :utc_datetime
      add :expires_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(@grants, [:device_code_hash], prefix: prefix)
    create unique_index(@grants, [:user_code], prefix: prefix)
    create index(@grants, [:expires_at], prefix: prefix)

    :ok
  end

  @doc "Drop both tables. The schema, if `:prefix` named one, is left in place."
  @spec down(keyword()) :: :ok
  def down(opts \\ []) do
    prefix = prefix!(opts)

    drop table(@grants, prefix: prefix)
    drop table(@codes, prefix: prefix)

    :ok
  end

  # The prefix is interpolated into CREATE SCHEMA, so it is a plain
  # identifier or nothing.
  defp prefix!(opts) do
    case Keyword.get(opts, :prefix) do
      nil ->
        nil

      prefix when is_binary(prefix) ->
        if Regex.match?(~r/^[a-z_][a-z0-9_]*$/, prefix),
          do: prefix,
          else: raise(ArgumentError, "prefix must be a plain identifier, got #{inspect(prefix)}")

      prefix when is_atom(prefix) ->
        prefix!(Keyword.put(opts, :prefix, Atom.to_string(prefix)))
    end
  end
end
