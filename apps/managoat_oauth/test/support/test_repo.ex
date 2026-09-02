defmodule Managoat.OAuth.TestRepo do
  @moduledoc "The library's own repo, on its own database. Configured by test/test_helper.exs."
  use Ecto.Repo, otp_app: :managoat_oauth, adapter: Ecto.Adapters.Postgres
end

defmodule Managoat.OAuth.TestMigration do
  @moduledoc "The migration a host writes, as the suite's database setup."
  use Ecto.Migration

  def up, do: Managoat.OAuth.Migration.up()
  def down, do: Managoat.OAuth.Migration.down()
end
