defmodule Fountain.Repo.Migrations.AddCompedContactsToUsers do
  use Ecto.Migration

  @moduledoc """
  How many of an account's teammate contacts Fountain does not charge for.

  Comping the whole account already zeroes contact billing
  (`Billing.sync_contact_addon/1` short-circuits on `comped`), but that is
  all-or-nothing: it also makes the plan free. This expresses the case the
  account comp cannot — a tenant who pays for their tier and holds a number
  Fountain eats the cost of.

  Zero, not null, is the default: "no free contacts" is a real answer and the
  common one, and a nullable column would make every read of it decide what
  null means.
  """

  def change do
    alter table(:users) do
      add :comped_contacts, :integer, null: false, default: 0
    end
  end
end
