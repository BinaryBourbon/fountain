defmodule FountainWeb.MarketingController do
  @moduledoc """
  The public pages: `/`, `/launch`, `/oss-launch`, `/integrations`, `/built-with`,
  `/self-hosted`, `/faq`, `/code-review-bot`, `/case-studies/*`, `/terms`
  and `/privacy`.

  None of them is the same page on every deployment. `/` serves the
  product pitch on the marketing site and a plain front door everywhere else
  (`Fountain.Marketing`); `/launch`, `/oss-launch`, `/integrations`, `/built-with`,
  `/self-hosted`, `/faq`, `/code-review-bot` and the case studies are the
  pitch's other pages and redirect into the manual on any other instance;
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

  # Search results name the runtimes and the API. The visible homepage leads
  # with the apps; an ordinary self-hosted instance keeps its own front door.
  @site_title "Claude Code, Codex and Gemini CLI behind one API"

  def home(conn, _params) do
    if Fountain.Marketing.site?() do
      conn
      |> assign(:page_title, "#{@site_title} · #{Fountain.Brand.name()}")
      |> render(:home, layout: {FountainWeb.Layouts, :marketing})
    else
      render(conn, :instance, layout: {FountainWeb.Layouts, :marketing})
    end
  end

  # A focused campaign page for readers arriving from a launch announcement.
  # It is intentionally absent from the navigation: the homepage is the
  # canonical product page, while this page makes one shorter argument and
  # asks for one action. Another deployment gets the executable tour rather
  # than sales copy for the hosted product.
  def launch(conn, _params) do
    if Fountain.Marketing.site?() do
      render(conn, :launch,
        layout: {FountainWeb.Layouts, :marketing},
        page_title: "Run coding agents on ready machines · #{Fountain.Brand.name()}",
        meta_description:
          "Give your product a coding agent on a ready machine. Repositories, packages " <>
            "and credentials arrive with it, and you pay only while the agent works."
      )
    else
      redirect(conn, to: ~p"/docs/tour")
    end
  end

  # The Fountain project launch page. Managoat's `/launch` sells the hosted
  # instance; this page shows builders what they can make with the open-source
  # engine, then proves they can own and reshape the whole stack. It is a
  # campaign destination rather than a second homepage, so it stays out of the
  # permanent navigation.
  def oss_launch(conn, _params) do
    if Fountain.Marketing.site?() do
      render(conn, :oss_launch,
        layout: {FountainWeb.Layouts, :marketing},
        page_title: "A conversational API to a computer · #{Fountain.Brand.engine()}",
        meta_description:
          "Give your app a computer it can talk to. Build on #{Fountain.Brand.engine()}, " <>
            "run the open-source stack yourself, and keep your data, keys and agents " <>
            "under your control."
      )
    else
      redirect(conn, to: ~p"/docs/open-source")
    end
  end

  # The Buzz campaign page: hosted Buzz agents, for readers arriving from a
  # launch announcement in that community. Like the other campaign pages it
  # makes one argument (the agent should outlive the laptop) and asks for one
  # action, and stays out of the permanent navigation. Another deployment gets
  # the integration manual, which is the page that tells an operator the same
  # story without selling the hosted product.
  def buzz_launch(conn, _params) do
    # The one marketing page that is entirely about an optional extension, so
    # the only one whose whole route is gated (#1525). Every other page either
    # needs nothing or drops a section. `Fountain.Marketing.available?/1` reads
    # the installed set from configuration, so a bundled image serves this and
    # a `-core` one has never heard of it — including the redirect below, whose
    # target moved into the extension's manual in #1510.
    unless Fountain.Marketing.available?(:buzz) do
      raise Phoenix.Router.NoRouteError, conn: conn, router: FountainWeb.Router
    end

    if Fountain.Marketing.site?() do
      render(conn, :buzz_launch,
        layout: {FountainWeb.Layouts, :marketing},
        page_title: "Hosted Buzz agents · #{Fountain.Brand.name()}",
        meta_description:
          "Keep your Buzz agent on the relay without keeping your laptop open. " <>
            "#{Fountain.Brand.name()} wakes a sandbox for accepted mentions and keeps " <>
            "the Nostr key on the server."
      )
    else
      redirect(conn, to: ~p"/docs/integrations/buzz")
    end
  end

  # The protocols Fountain speaks and what already speaks them. Sales copy,
  # so it follows `/`: a self-hosted instance gets the manual's version of
  # the same list rather than a page selling the hosted product.
  def integrations(conn, _params) do
    if Fountain.Marketing.site?() do
      render(conn, :integrations,
        layout: {FountainWeb.Layouts, :marketing},
        page_title: "Coding agent integrations · #{Fountain.Brand.name()}",
        meta_description:
          "Run coding agents from your editor, chat app, framework, gateway or code. " <>
            "#{Fountain.Brand.name()} manages ready sandboxes and charges only while agents work."
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
            "applications built on the #{Fountain.Brand.name()} API. Explore chat, " <>
            "research, data analysis, code work, infrastructure operations and " <>
            "multi-agent workflows."
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
          "A pull request opens, GitHub posts a webhook, and one API call starts " <>
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
          "Run #{Fountain.Brand.engine()} on your infrastructure with the same API, " <>
            "SDK and CLI. Own the database, keys and sandboxes. Start with Docker " <>
            "Compose or Kubernetes, with no license key or seat count."
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

  # A cluster that pages an agent as well as a person, and what stops the
  # agent from merging its own work. Sales copy, so it follows `/`: another
  # deployment gets the manual's tour of the same shape.
  def case_study(conn, _params) do
    if Fountain.Marketing.site?() do
      render(conn, :case_study_self_healing,
        layout: {FountainWeb.Layouts, :marketing},
        page_title: "Kubernetes alert to pull request in 4m 27s · #{Fountain.Brand.name()}",
        meta_description:
          "A real Kubernetes incident from alert to pull request in 4m 27s. The agent " <>
            "held no cluster credentials, and a human kept the only approval."
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
