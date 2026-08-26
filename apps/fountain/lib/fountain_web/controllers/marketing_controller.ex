defmodule FountainWeb.MarketingController do
  @moduledoc """
  The public pages: `/`, `/integrations`, `/built-with`, `/self-hosted`, `/terms`
  and `/privacy`.

  None of the four is the same page on every deployment. `/` serves the
  product pitch on the marketing site and a plain front door everywhere else
  (`Fountain.Marketing`); `/integrations`, `/built-with` and `/self-hosted` are
  the pitch's other three pages and redirect into the manual on any other
  instance;
  the legal pages render the operator's identity, or nothing at all
  (`Fountain.Legal`). A deployment is not the Fountain project, and these
  pages are the ones that would claim otherwise.
  """
  use FountainWeb, :controller

  def home(conn, _params) do
    page = if Fountain.Marketing.site?(), do: :home, else: :instance
    render(conn, page, layout: {FountainWeb.Layouts, :marketing})
  end

  # The protocols Fountain speaks and what already speaks them. Sales copy,
  # so it follows `/`: a self-hosted instance gets the manual's version of
  # the same list rather than a page selling the hosted product.
  def integrations(conn, _params) do
    if Fountain.Marketing.site?() do
      render(conn, :integrations,
        layout: {FountainWeb.Layouts, :marketing},
        page_title: "Integrations · #{Fountain.Brand.name()}",
        meta_description:
          "#{Fountain.Brand.name()} speaks AG-UI, the Agent Client Protocol, " <>
            "OpenAI chat completions, MCP and its own REST API, so the editor, " <>
            "chat app, gateway or framework you already use can hire an agent " <>
            "on a sandbox."
      )
    else
      redirect(conn, to: ~p"/docs/integrations/clients")
    end
  end

  # The applications people have built on the API. Sales copy again, so a
  # self-hosted instance gets the manual's build guide rather than a page
  # selling somebody else's hosted product with somebody else's apps.
  def built_with(conn, _params) do
    if Fountain.Marketing.site?() do
      render(conn, :built_with,
        layout: {FountainWeb.Layouts, :marketing},
        page_title: "Built with #{Fountain.Brand.name()} · #{Fountain.Brand.name()}",
        meta_description:
          "#{length(FountainWeb.MarketingHTML.built_apps_flat())} open-source " <>
            "applications built on the #{Fountain.Brand.name()} API: research briefs, " <>
            "CSV analysis, repository Q&A, agent fleets, DNS and infrastructure " <>
            "patrols, model bake-offs and the team clients. Most have no backend " <>
            "of their own."
      )
    else
      redirect(conn, to: ~p"/docs/build")
    end
  end

  # The case for running it yourself. Sales copy for the other choice, which
  # is still sales copy, so it follows the same rule: an instance that is not
  # the marketing site sends the reader to the manual, where the operator's
  # own answer lives.
  def self_hosted(conn, _params) do
    if Fountain.Marketing.site?() do
      render(conn, :self_hosted,
        layout: {FountainWeb.Layouts, :marketing},
        page_title: "Self-host #{Fountain.Brand.engine()} · #{Fountain.Brand.name()}",
        meta_description:
          "Define an agent once and every app you build can hire it over one API. " <>
            "#{Fountain.Brand.engine()} is open source and the whole platform is in " <>
            "the repo. Bring an instance up with Docker Compose or plain Kubernetes " <>
            "manifests, on your hardware, under your own keys, with no licence key " <>
            "and no seat count."
      )
    else
      redirect(conn, to: ~p"/docs/self-hosting")
    end
  end

  def terms(conn, _params) do
    render_legal(conn, :terms)
  end

  def privacy(conn, _params) do
    render_legal(conn, :privacy)
  end

  # The legal identity is the operator's, set via LEGAL_* env vars (#517) —
  # see Fountain.Legal for the unconfigured behaviour (neutral 404 on a
  # billing-disabled instance, loud placeholders on a billing-enabled one).
  defp render_legal(conn, page) do
    case Fountain.Legal.content() do
      nil ->
        conn
        |> put_status(:not_found)
        |> render(:legal_unpublished, layout: {FountainWeb.Layouts, :marketing})

      legal ->
        render(conn, page, layout: {FountainWeb.Layouts, :marketing}, legal: legal)
    end
  end
end
