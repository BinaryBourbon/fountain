defmodule FountainWeb.CatalogController do
  @moduledoc """
  `GET /api/catalog`: the instance's vocabulary a client needs to build the
  agent and environment forms — runtimes and their model suggestions,
  the sandbox providers usable here and the default, the package managers
  an environment accepts, the avatar generator's bases and moods (#815).

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
        "accepts, and the avatar generator's bases and moods.",
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
          enabled: Enum.map(Fountain.Sandbox.enabled_providers(), &Atom.to_string/1),
          default: Atom.to_string(Fountain.Sandbox.default_provider())
        },
        package_managers: Fountain.Conversations.Provisioning.package_managers(),
        avatar: %{
          bases: Fountain.AvatarGenerator.bases(),
          moods: Fountain.AvatarGenerator.moods()
        }
      }
    })
  end
end
