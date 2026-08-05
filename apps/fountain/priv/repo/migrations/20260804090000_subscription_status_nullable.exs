defmodule Fountain.Repo.Migrations.SubscriptionStatusNullable do
  use Ecto.Migration

  @moduledoc """
  On a billing-disabled instance registration stamps neither a trial end nor a
  subscription status (#480) — nil means "billing has never applied to this
  account" and keeps trial residue out of the admin list, /api/auth/me and
  GDPR exports. The column keeps its 'trialing' default for raw inserts; only
  the NOT NULL constraint goes.
  """

  def up do
    execute "ALTER TABLE users ALTER COLUMN subscription_status DROP NOT NULL"
  end

  def down do
    # Restore the constraint the way it was created; rows minted while billing
    # was disabled must be given a status first or this fails — which is
    # correct, silently inventing one would misstate what those accounts are.
    execute "ALTER TABLE users ALTER COLUMN subscription_status SET NOT NULL"
  end
end
