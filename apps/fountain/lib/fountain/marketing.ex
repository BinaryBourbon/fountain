defmodule Fountain.Marketing do
  @moduledoc """
  Whether this deployment is the Fountain project's own marketing site.

  `/` serves one of two pages. The hosted deployment serves the product pitch:
  a hero, a price, a free trial. Every other deployment serves a plain front
  door — the instance, a way in, and a link to the manual.

  The reasoning is `Fountain.Legal`'s (#517), one page over. A self-hosted
  instance must never serve the upstream project's legal terms, and it has no
  more business serving the upstream project's sales copy: nobody running
  Fountain for their own team is selling a 14-day trial of it.

  Off unless `MARKETING_SITE=true` (config/runtime.exs), so a self-host is
  right by default and the hosted deployment opts in — the same shape, for the
  same reason, as `BILLING_ENABLED` (#336).

  Deliberately *not* `Fountain.Billing.enabled?/0`, the closest existing flag.
  Billing says "this instance charges money", which an operator running
  Fountain commercially inside their own company may well turn on. That must
  not hand them a homepage selling somebody else's product.
  """

  @doc "Whether `/` serves the product pitch rather than a plain front door."
  @spec site?() :: boolean()
  def site?, do: Application.get_env(:fountain, :marketing_site, false)
end
