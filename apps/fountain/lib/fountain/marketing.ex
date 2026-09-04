defmodule Fountain.Marketing do
  @moduledoc """
  Whether this deployment is the Fountain project's own marketing site.

  `/` serves one of two pages. The hosted deployment serves the product pitch:
  a hero, the prices, the opening credit. Every other deployment serves a plain front
  door — the instance, a way in, and a link to the manual.

  The reasoning is `Fountain.Legal`'s (#517), one page over. A self-hosted
  instance must never serve the upstream project's legal terms, and it has no
  more business serving the upstream project's sales copy: nobody running
  Fountain for their own team is selling credit for it.

  Off unless `MARKETING_SITE=true` (config/runtime.exs), so a self-host is
  right by default and the hosted deployment opts in — the same shape, for the
  same reason, as `CREDITS_ENABLED` (#336).

  Deliberately *not* `Fountain.Credits.enabled?/0`, the closest existing flag.
  Billing says "this instance charges money", which an operator running
  Fountain commercially inside their own company may well turn on. That must
  not hand them a homepage selling somebody else's product.
  """

  @doc "Whether `/` serves the product pitch rather than a plain front door."
  @spec site?() :: boolean()
  def site?, do: Application.get_env(:fountain, :marketing_site, false)

  @doc """
  Whether marketing that needs an extension has one to talk about (#1525).

  The pitch describes what a deployment can do, and a core distribution
  (`BUNDLE_EXTENSIONS=false`) can do less: `/buzz-launch` sells hosted Nostr
  identities, and the `POST /api/buzz/agents` on the integrations page is a
  path that answers 404 there. A page selling an endpoint the image does not
  serve is marketing that lies.

  So the copy carries a requirement and this answers it. `nil` means the
  content needs nothing and is always shown, which is nearly all of it.

  The argument is an **extension id** — a value out of
  `config :fountain, :extensions`, not a module — so core still names no
  extension code and `Fountain.ExtensionGuardTest` stays green. That is the
  whole reason `Fountain.Extension` has an `id/0` at all.

  Contrast `FountainWeb.Plugs.ExtensionDispatch`, which answers one uniform
  404 for every unknown `/api` path precisely so a client cannot learn the
  installed set from a status code. The opposite is right here: marketing is
  public copy about this deployment, and what it must not do is claim a
  capability that is absent.
  """
  @spec available?(atom() | nil) :: boolean()
  def available?(nil), do: true
  def available?(id) when is_atom(id), do: Fountain.Extensions.installed?(id)
end
