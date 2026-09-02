# Run from this directory the library has no config at all (mix.exs sets no
# config_path on purpose), and the one thing an instance needs, its repo, has
# no default. The suite runs two instances against a repo of its own, on a
# database of its own: never the host's. At the umbrella root every app's
# tests run in one VM, so a repo pointed at Fountain's `fountain_test` would
# be a second sandbox owner on the same tables, colliding with Fountain's rows.
#
# The database is dropped and recreated on every run, then migrated with
# Managoat.OAuth.Migration itself, so the schema under test is always the one
# the code describes. Override the URL with MANAGOAT_OAUTH_TEST_DATABASE_URL;
# DATABASE_URL is deliberately not read, because on a developer machine it
# names Fountain's database.
url =
  System.get_env("MANAGOAT_OAUTH_TEST_DATABASE_URL") ||
    "postgres://postgres:postgres@localhost:5432/managoat_oauth_test"

Application.put_env(:managoat_oauth, Managoat.OAuth.TestRepo,
  url: url,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10
)

# The instance most tests use, with the clients the request fixtures name.
# One string-keyed client, the way a JSON registry decodes, so normalisation
# is exercised on every read.
Application.put_env(:managoat_oauth, Managoat.OAuth.TestInstance,
  repo: Managoat.OAuth.TestRepo,
  clients: [
    %{
      id: "test-app",
      name: "Test App",
      redirect_uris: ["https://app.test/callback", "http://localhost:5173/"]
    },
    %{"id" => "json-app", "redirect_uris" => ["https://json.test:8443/cb"]}
  ]
)

# An instance over the tables the migration test creates in a scratch
# schema; nothing outside that test can see them.
Application.put_env(:managoat_oauth, Managoat.OAuth.PrefixedInstance,
  repo: Managoat.OAuth.TestRepo,
  prefix: "managoat_oauth_scratch",
  clients: [%{id: "test-app", name: "Test App", redirect_uris: ["https://app.test/callback"]}]
)

repo_config = Managoat.OAuth.TestRepo.config()
_ = Ecto.Adapters.Postgres.storage_down(repo_config)

case Ecto.Adapters.Postgres.storage_up(repo_config) do
  :ok ->
    :ok

  {:error, :already_up} ->
    :ok

  {:error, reason} ->
    raise "could not create the library's test database at #{url}: #{inspect(reason)}. " <>
            "Postgres must be reachable; set MANAGOAT_OAUTH_TEST_DATABASE_URL to point elsewhere."
end

{:ok, _} = Managoat.OAuth.TestRepo.start_link()

Ecto.Migrator.run(
  Managoat.OAuth.TestRepo,
  [{20_260_901_000_000, Managoat.OAuth.TestMigration}],
  :up,
  all: true,
  log: false
)

Ecto.Adapters.SQL.Sandbox.mode(Managoat.OAuth.TestRepo, :manual)

# No config means no logger config: quiet the per-query debug lines.
Logger.configure(level: :warning)

ExUnit.start()
