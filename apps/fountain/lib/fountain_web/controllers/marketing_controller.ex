defmodule FountainWeb.MarketingController do
  @moduledoc """
  The public pages: `/`, `/integrations`, `/built-with`, `/self-hosted`,
  `/faq`, `/code-review-bot`, `/case-studies/*`, `/terms` and `/privacy`.

  None of them is the same page on every deployment. `/` serves the
  product pitch on the marketing site and a plain front door everywhere else
  (`Fountain.Marketing`); `/integrations`, `/built-with`, `/self-hosted`,
  `/faq`, `/code-review-bot` and the case studies are the pitch's other pages
  and redirect into the manual on any other instance;
  the legal pages render the operator's identity, or nothing at all
  (`Fountain.Legal`). A deployment is not the Fountain project, and these
  pages are the ones that would claim otherwise.
  """
  use FountainWeb, :controller

  # The paper skin, on every page this controller serves and nowhere else.
  # The root layout turns the assign into `data-skin` on <html> plus one
  # stylesheet (`FountainWeb.StaticVersion.paper_css/0`).
  #
  # A controller plug rather than a router one, because the marketing routes
  # share their scope with `/docs`, and the manual and the console keep the
  # console's tokens. It is also why this is not on the marketing *layout*:
  # the instance front door and a self-hoster's legal pages render through
  # that layout too, and a deployment that is not the marketing site is not
  # the one this look belongs to.
  #
  # `?skin=classic` is the way back while the skin is being decided. An
  # unknown value is paper rather than an error: this is a look, not a route.
  plug :put_skin

  defp put_skin(conn, _opts) do
    if Fountain.Marketing.site?() and conn.params["skin"] != "classic" do
      assign(conn, :skin, "paper")
    else
      conn
    end
  end

  # The one page on the site that set no `:page_title`, so `<title>` and both
  # card titles were the bare brand name — the only word a reader who has
  # never heard it learns nothing from. Every other page here carries
  # "<what it is> · <brand>" and the homepage now does too.
  #
  # It is the slot a category label is for. The h1 makes a claim ("A
  # conversational API to a computer"), which is the right job for a headline
  # and the wrong one for a tab, a bookmark and a search result, where a
  # reader is deciding whether this is even the kind of thing they want.
  # standards/voice-and-style.md is explicit that the audience has no prior
  # model for the category, and they arrive searching for how to run a coding
  # agent on a server, not for a phrase from the hero.
  #
  # Only on the marketing site. An instance keeps the bare brand: it is a
  # front door, not the project, and a title selling a category would be this
  # module's whole objection (#517) in the `<head>`.
  @site_title "Serverless sandboxes for coding agents"

  def home(conn, _params) do
    if Fountain.Marketing.site?() do
      conn
      |> assign(:page_title, "#{@site_title} · #{Fountain.Brand.name()}")
      |> render(:home, layout: {FountainWeb.Layouts, :marketing})
    else
      render(conn, :instance, layout: {FountainWeb.Layouts, :marketing})
    end
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

  # Every question-shaped block on the site, in one place. The homepage keeps
  # its six-question grid, which is the problem statement rather than an FAQ;
  # the security answers and the self-hosting objections moved here whole and
  # those pages link in by anchor. Sales copy, so it follows `/`.
  def faq(conn, _params) do
    if Fountain.Marketing.site?() do
      render(conn, :faq,
        layout: {FountainWeb.Layouts, :marketing},
        page_title: "Questions · #{Fountain.Brand.name()}",
        meta_description:
          "What a developer, a buyer and a security reviewer ask before building " <>
            "on #{Fountain.Brand.name()}: model keys, what a sandbox does between " <>
            "messages, tenant isolation, what it costs, what we do not have, and " <>
            "what it takes to run the whole thing yourself."
      )
    else
      redirect(conn, to: ~p"/docs")
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

  # The shortest useful program anybody writes on this API, shown whole. Sales
  # copy like the rest, so another deployment gets the manual's longer version
  # of the same job rather than a page selling the hosted product.
  #
  # UNLISTED. Nothing on the site links here, and that is deliberate rather
  # than an oversight: the handler the page shows has never been run against a
  # live webhook. The page says so and claims no measurement, but an unrun
  # program is not something to put in the footer. Relink it once somebody has
  # smoked it end to end. `marketing_controller_test.exs` asserts the absence,
  # so a link cannot creep back beside an unrelated edit.
  def code_review_bot(conn, _params) do
    if Fountain.Marketing.site?() do
      render(conn, :code_review_bot,
        layout: {FountainWeb.Layouts, :marketing},
        page_title: "A code review bot · #{Fountain.Brand.name()}",
        meta_description:
          "A pull request opens, GitHub posts a webhook, and one API call hires " <>
            "an agent that already has the checkout. The whole program is on the " <>
            "page: no runner pool, no queue, no container image per repository."
      )
    else
      redirect(conn, to: ~p"/docs/tour")
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
            "manifests, on your hardware, under your own keys, with no license key " <>
            "and no seat count."
      )
    else
      redirect(conn, to: ~p"/docs/self-hosting")
    end
  end

  # There is one case study, so `/case-studies` is a shortcut to it rather
  # than an index of one. It becomes a real index when there is a second.
  def case_studies(conn, _params) do
    if Fountain.Marketing.site?() do
      redirect(conn, to: ~p"/case-studies/self-healing-infrastructure")
    else
      redirect(conn, to: ~p"/docs")
    end
  end

  # An estate that pages an agent instead of a person, and what stops the
  # agent from merging its own work. Sales copy, so it follows `/`: another
  # deployment gets the manual's tour of the same shape.
  def case_study(conn, _params) do
    if Fountain.Marketing.site?() do
      render(conn, :case_study_self_healing,
        layout: {FountainWeb.Layouts, :marketing},
        page_title: "Self-healing infrastructure · #{Fountain.Brand.name()}",
        meta_description:
          "A Kubernetes estate that answers its own alerts. Prometheus fires, " <>
            "#{Fountain.Brand.name()} hires an agent, the agent finds the commit that " <>
            "broke the cluster and opens one pull request. A human still approves every " <>
            "merge, because the agent is built so that it cannot."
      )
    else
      redirect(conn, to: ~p"/docs/tour")
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
