defmodule Fountain.Repo.Migrations.CreateExtensionFixtureRows do
  use Ecto.Migration

  # Owned by `Fountain.ExtensionFixtures.Enabled` (ADR 0043, #1506), not by
  # Fountain. It lives outside priv/repo/migrations precisely so that running
  # it proves the extension path set is in use: nothing reaches this file
  # unless a caller appended the fixture's directory to the core's.
  #
  # It ships in the image, which costs a few hundred bytes and buys the release
  # path being exercised by the same mechanism dev and test use. It runs only
  # where the fixture is installed, which is the test VM and nowhere else.
  def change do
    create table(:extension_fixture_rows, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :note, :string
      timestamps(type: :utc_datetime)
    end
  end
end
