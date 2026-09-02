defmodule FountainWeb.CatalogController do
  @moduledoc """
  `GET /api/catalog`: the instance's vocabulary a client needs to build the
  agent and environment forms — runtimes and their model suggestions,
  the sandbox providers usable here and the default, the package managers
  an environment accepts, the avatar generator's bases and moods (#815),
  where this instance's browser apps live (#866), and the remote MCP
  servers verified to complete connection discovery (#1322).

  Everything here is already public through the forms; this is the same
  lists over the API so a client on another origin does not hard-code them
  and drift from the server.
  """
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Agents.Agent
  alias Fountain.Runtimes.Model
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  tags(["Catalog"])

  operation(:show,
    summary: "The instance's form vocabulary",
    description:
      "Runtimes with model suggestions per runtime (suggestions, not an allowlist — " <>
        "any `provider/model` under a known provider is accepted), sandbox providers " <>
        "usable on this instance and the default, package managers an environment " <>
        "accepts, the avatar generator's bases and moods, the URLs of the " <>
        "browser apps this instance sends people to for conversations and the team, " <>
        "and remote MCP servers verified to complete connection discovery " <>
        "(again suggestions — any URL can be discovered), each with the date " <>
        "it was last verified.",
    responses: [ok: {"Catalog", "application/json", Schemas.CatalogResponse}]
  )

  def show(conn, _params) do
    runtimes = Agent.runtimes()

    json(conn, %{
      data: %{
        runtimes: runtimes,
        models: Map.new(runtimes, &{&1, Model.suggestions(&1)}),
        model_providers: Model.providers(),
        sandbox_providers: %{
          enabled: Enum.map(Fountain.SandboxProviders.enabled_providers(), &Atom.to_string/1),
          default: Atom.to_string(Fountain.SandboxProviders.default_provider())
        },
        package_managers: Fountain.Conversations.Provisioning.package_managers(),
        avatar: %{
          bases: Fountain.AvatarGenerator.bases(),
          moods: Fountain.AvatarGenerator.moods()
        },
        # Where a human is sent to watch a conversation or message a teammate.
        # Null for an app this deployment does not have.
        apps: %{
          conversations: Fountain.Apps.conversations(),
          team: Fountain.Apps.team()
        },
        # Remote MCP servers whose authorization chain is known to complete
        # (dated, re-checked by scripts/mcp-catalog-probe.exs) — so a client
        # can render "Connect Sentry"-style rows without hard-coding URLs.
        mcp_servers: Fountain.Connections.McpServerCatalog.entries()
      }
    })
  end
end
