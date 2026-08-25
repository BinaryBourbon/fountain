defmodule Fountain.Legal do
  @moduledoc """
  The instance operator's legal identity for `/terms` and `/privacy` (#517).

  The pages' copy reads "an agreement between you and {entity}" — so the
  identity must be the *operator's*, not the upstream project's. It comes from
  the `LEGAL_ENTITY` / `LEGAL_CONTACT_EMAIL` / `LEGAL_JURISDICTION` /
  `LEGAL_EFFECTIVE_DATE` env vars (config/runtime.exs), never from source.

  When unconfigured, what happens depends on the billing gate:

    * billing disabled (the self-host default) — the pages are unpublished:
      links are hidden and the routes render a neutral 404. A self-hosted
      instance must never serve someone else's terms.
    * billing enabled — the pages stay up and render the deliberately-loud
      `{{COMPANY_LEGAL_NAME}}` placeholders from #506. An instance charging
      money with no published terms should be embarrassing in the browser,
      not silent.
  """

  # The loud fallback for a billing-enabled instance that has not set its
  # legal identity. Deliberately unmistakable in rendered copy (#506).
  @placeholders %{
    entity: "{{COMPANY_LEGAL_NAME}}",
    contact_email: "{{CONTACT_EMAIL}}",
    jurisdiction: "{{JURISDICTION}}",
    updated: "{{EFFECTIVE_DATE}}"
  }

  @doc """
  The operator-configured legal identity, or `nil` when unset.
  """
  def configured, do: Application.get_env(:fountain, :legal)

  @doc """
  Whether `/terms` and `/privacy` should be linked and served.

  True when the operator configured a legal identity, or when billing is
  enabled (placeholders stay loud rather than the pages going dark).
  """
  def published?, do: configured() != nil or Fountain.Credits.enabled?()

  @doc """
  The map the legal templates render: the configured identity, the loud
  placeholders on a billing-enabled instance, or `nil` (pages unpublished).
  """
  def content do
    configured() || if Fountain.Credits.enabled?(), do: @placeholders
  end
end
