defmodule Fountain.Workers.ClaimablePrincipalSweep do
  @moduledoc """
  Closes claimable principals whose time is up, and deletes them later
  (ADR 0044).

  Two stages, because they answer different questions.

  **Expire.** An unclaimed grant past `expires_at` has its credentials revoked,
  its sandboxes destroyed and its unspent introductory grant refunded to the
  application. This is the one that costs money to be late with, so it runs
  every five minutes: a principal whose visitor closed the tab is a sprite
  nobody is watching.

  **Purge.** A grant that closed more than `purge_after_days` ago has its
  principal deleted through `Accounts.Deletion.delete_user/2`. The delay is
  what makes `GET /api/claimable-users/:id` useful after the fact: an
  application that lost a response can still find out that the principal it
  opened expired, rather than reading a 404 that means nothing in particular.

  Never touches a claimed principal. Once an account owns it, it is that
  account's tenant and lives as long as any other.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  alias Fountain.Principals

  require Logger

  @impl Oban.Worker
  def perform(_job) do
    expired = Principals.expire_due(actor: "system:principal_sweep")
    purged = Principals.purge_closed()

    if expired > 0 or purged > 0 do
      Logger.info("claimable principal sweep: expired #{expired}, purged #{purged}")
    end

    :ok
  end
end
