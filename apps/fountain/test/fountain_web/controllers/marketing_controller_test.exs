defmodule FountainWeb.MarketingControllerTest do
  use FountainWeb.ConnCase, async: true

  # config/test.exs pins :legal, so these cover the configured-identity path;
  # the unpublished and placeholder paths live in MarketingLegalUnpublishedTest
  # (async: false — they mutate global app env).

  describe "GET / titling" do
    test "names the category in the title and both card titles", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      expected = "Serverless sandboxes for coding agents · #{Fountain.Brand.name()}"

      assert body =~ "<title>#{expected}</title>"
      assert body =~ ~s(<meta property="og:title" content="#{expected}")
      assert body =~ ~s(<meta name="twitter:title" content="#{expected}")
    end

    test "the title is not the bare brand name", %{conn: conn} do
      # The whole defect: `OpenGraph.title/1` falls back to the brand when a
      # page sets no `:page_title`, so this page announced only a word a new
      # reader cannot decode, in the tab, the bookmark and every unfurl.
      body = conn |> get(~p"/") |> html_response(200)

      refute body =~ "<title>#{Fountain.Brand.name()}</title>"
    end
  end

  describe "GET /terms" do
    test "renders the terms of service with the configured identity", %{conn: conn} do
      body = conn |> get(~p"/terms") |> html_response(200)
      assert body =~ "Terms of Service"
      assert body =~ "Limitation of liability"
      assert body =~ "Test Legal Entity LLC"
      assert body =~ "legal@example.com"
      assert body =~ "the State of Testing"
      refute body =~ "{{"
      assert body =~ ~p"/privacy"
    end
  end

  describe "GET /privacy" do
    test "renders the privacy policy with the configured identity", %{conn: conn} do
      body = conn |> get(~p"/privacy") |> html_response(200)
      assert body =~ "Privacy Policy"
      assert body =~ "Your rights"
      assert body =~ "Test Legal Entity LLC"
      refute body =~ "{{"
      assert body =~ ~p"/terms"
    end
  end

  describe "GET /integrations" do
    test "renders every protocol and what speaks it", %{conn: conn} do
      body = conn |> get(~p"/integrations") |> html_response(200)

      assert body =~ "It speaks what your stack already speaks."

      for name <- ~w(AG-UI ACP OpenAI-compatible MCP Nostr) do
        assert body =~ name, "missing protocol #{name}"
      end

      for name <- ["OpenBot", "Zed", "OpenClaw", "Hermes Agent", "LiteLLM", "LangChain", "Buzz"] do
        assert body =~ name, "missing integration #{name}"
      end

      # The snippets are kept out of the template so their braces are not HEEx.
      assert body =~ "@ag-ui/client"
      assert body =~ "fountain acp"
      assert body =~ "/v1/chat/completions"
      assert body =~ "@agentshit/fountain-sdk"
    end

    test "carries its own card", %{conn: conn} do
      body = conn |> get(~p"/integrations") |> html_response(200)
      assert body =~ ~s(<meta property="og:title" content="Integrations · Fountain")
      assert body =~ ~s(<meta name="description" content="Fountain speaks AG-UI)
      assert body =~ ~s(<meta property="og:url" content="http://localhost:4000/integrations")
    end

    test "every link into the manual resolves to a page", %{conn: conn} do
      body = conn |> get(~p"/integrations") |> html_response(200)

      links =
        ~r/href="\/docs\/([^"#]+)/
        |> Regex.scan(body)
        |> Enum.map(fn [_, slug] -> slug end)
        |> Enum.uniq()

      assert links != []

      for slug <- links do
        assert match?({:ok, _}, Fountain.Docs.get(slug)), "/docs/#{slug} is not a page"
      end
    end

    test "names a service only when the broker has a preset for it", %{conn: conn} do
      body = conn |> get(~p"/integrations") |> html_response(200)
      assert body =~ "Linear"
      assert body =~ "Notion"
      # Twilio is in the catalog but not usable as a binding, so it stays off.
      refute body =~ "Twilio"
    end

    test "every mark the page asks for exists", _ do
      slugs =
        (FountainWeb.MarketingHTML.protocols() |> Enum.flat_map(& &1.works_with)) ++
          (FountainWeb.MarketingHTML.inside() |> Enum.flat_map(& &1.items)) ++
          FountainWeb.MarketingHTML.brokered_services()

      for %{slug: slug, name: name} <- slugs, slug != nil do
        assert FountainWeb.MarketingIcons.has?(slug), "#{name} names a missing mark #{slug}"
      end
    end

    test "the marketing nav and the homepage link to it", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ ~p"/integrations"
    end
  end

  describe "GET /built-with" do
    test "renders every app, grouped", %{conn: conn} do
      body = conn |> get(~p"/built-with") |> html_response(200)

      assert body =~ "One API behind all of them."

      for group <- FountainWeb.MarketingHTML.built_apps() do
        assert body =~ group.title, "missing group #{group.title}"
      end

      for app <- FountainWeb.MarketingHTML.built_apps_flat() do
        assert body =~ app.name, "missing app #{app.name}"
        assert body =~ app.host, "missing host for #{app.name}"
        assert body =~ app.url, "missing live link for #{app.name}"
        assert body =~ app.source, "missing source link for #{app.name}"
      end
    end

    test "every app is live somewhere and open somewhere, exactly once", _ do
      apps = FountainWeb.MarketingHTML.built_apps_flat()

      # The page's whole claim is that each card is two working links, so an
      # entry with a relative or placeholder URL would sell something nobody
      # can click.
      for app <- apps do
        assert String.starts_with?(app.url, "https://"), "#{app.name} has no absolute URL"

        assert String.starts_with?(app.source, "https://github.com/"),
               "#{app.name} does not name a repository"

        assert app.shows != "" and app.blurb != ""
      end

      ids = Enum.map(apps, & &1.id)
      assert ids == Enum.uniq(ids), "an app is listed twice"

      group_ids = Enum.map(FountainWeb.MarketingHTML.built_apps(), & &1.id)
      assert group_ids == Enum.uniq(group_ids), "a group anchor is used twice"
    end

    test "every chip in the hero reaches a group on the page", %{conn: conn} do
      body = conn |> get(~p"/built-with") |> html_response(200)

      for group <- FountainWeb.MarketingHTML.built_apps() do
        assert body =~ ~s(href="##{group.id}"), "no chip for #{group.title}"
        assert body =~ ~s(id="#{group.id}"), "no anchor for #{group.title}"
      end
    end

    test "carries its own card", %{conn: conn} do
      body = conn |> get(~p"/built-with") |> html_response(200)
      assert body =~ ~s(<meta property="og:title" content="Built with Fountain · Fountain")
      assert body =~ ~s(<meta property="og:url" content="http://localhost:4000/built-with")
      # Derived, not restated: the roster's length is the number in the card, and
      # a literal here goes stale the next time an app joins or leaves it.
      count = FountainWeb.MarketingHTML.built_app_count()
      assert body =~ ~s(<meta name="description" content="#{count} open-source applications)
    end

    test "every link into the manual resolves to a page", %{conn: conn} do
      body = conn |> get(~p"/built-with") |> html_response(200)

      links =
        ~r/href="\/docs\/([^"#]+)/
        |> Regex.scan(body)
        |> Enum.map(fn [_, slug] -> slug end)
        |> Enum.uniq()

      assert links != []

      for slug <- links do
        assert match?({:ok, _}, Fountain.Docs.get(slug)), "/docs/#{slug} is not a page"
      end
    end

    test "the marketing nav and the homepage link to it", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ ~p"/built-with"
      assert body =~ "open-source apps are running on it now."
    end
  end

  describe "GET /self-hosted" do
    test "makes the case and shows the whole bring-up", %{conn: conn} do
      body = conn |> get(~p"/self-hosted") |> html_response(200)

      assert body =~ "Run #{Fountain.Brand.engine()} on your infrastructure."
      assert body =~ "Your database, your keys and your sandboxes."
      assert body =~ "Six commands and one provider token."
      assert body =~ "Prove the instance works before you expose it."
      assert body =~ "On your instance, every feature flag is yours to set."
      assert body =~ "What it costs you instead."

      # The bring-up is kept out of the template so its $(...) is not HEEx.
      assert body =~ "docker compose up -d"
      assert body =~ "MASTER_SECRETS_KEY"

      for licence <- ["AGPL-3.0-or-later", "Elastic 2.0", "Apache-2.0"] do
        assert body =~ licence, "missing licence #{licence}"
      end

      assert body =~ FountainWeb.MarketingHTML.repo_url()

      {ownership_at, _} = :binary.match(body, "Choose how much of the stack you own.")
      {prerequisites_at, _} = :binary.match(body, "Before you start")
      assert ownership_at < prerequisites_at

      {kubernetes_at, _} = :binary.match(body, "Using Kubernetes instead?")
      {first_boot_at, _} = :binary.match(body, "Prove the instance works before you expose it.")
      {readiness_at, _} = :binary.match(body, "Wait for readiness")
      {register_at, _} = :binary.match(body, "Register the first admin")
      {conversation_at, _} = :binary.match(body, "Start one conversation")

      assert kubernetes_at < first_boot_at
      assert readiness_at < register_at
      assert register_at < conversation_at

      # A connector belongs only between adjacent rungs. Drawing one as the
      # border of the whole list leaves a dangling line below the last node.
      assert length(Regex.scan(~r/data-role="ownership-connector"/, body)) == 3
    end

    test "the deploy guide follows the same first-boot order", %{conn: _conn} do
      {:ok, guide} = Fountain.Docs.get("guides/operate/deploy")

      {readiness_at, _} = :binary.match(guide.body, "## Verify the instance is ready")
      {register_at, _} = :binary.match(guide.body, "## Register the first account")
      {close_at, _} = :binary.match(guide.body, "## Close registration")
      {prove_at, _} = :binary.match(guide.body, "## Prove the whole path")

      assert readiness_at < register_at
      assert register_at < close_at
      assert close_at < prove_at
    end

    test "names every feature the manual says is rationed", %{conn: conn} do
      body = conn |> get(~p"/self-hosted") |> html_response(200)

      # The page's whole argument is that these three are an env var on an
      # instance of your own. A feature that comes off the manual's status
      # page has to come off this one, or the argument quotes a gate that no
      # longer exists.
      {:ok, status} = Fountain.Docs.get("reference/feature-status")

      for %{name: name} <- FountainWeb.MarketingHTML.rationed_features() do
        assert body =~ name, "missing feature #{name}"

        assert status.body =~ name,
               "#{name} is not on the manual's feature-status page any more"
      end
    end

    test "shows four app shapes over the same roster, and links every one", %{conn: conn} do
      body = conn |> get(~p"/self-hosted") |> html_response(200)

      # The cards show four shapes over the same API and roster, so each has to
      # be a working link into the same roster /built-with renders.
      showcase = FountainWeb.MarketingHTML.self_host_showcase()
      assert length(showcase) == 4

      for app <- showcase do
        assert body =~ app.name, "missing app #{app.name}"
        assert body =~ app.url, "missing live link for #{app.name}"
        assert app in FountainWeb.MarketingHTML.built_apps_flat(), "#{app.name} left the roster"
      end

      count = to_string(FountainWeb.MarketingHTML.built_app_count())
      assert body =~ "#{count} open-source apps already run on the API."
      assert body =~ ~p"/built-with"
    end

    test "carries its own card", %{conn: conn} do
      body = conn |> get(~p"/self-hosted") |> html_response(200)
      assert body =~ ~s(<meta property="og:title" content="Self-host Fountain · Fountain")

      assert body =~
               ~s(<meta name="description" content="Run #{Fountain.Brand.engine()} on your infrastructure)

      assert body =~ ~s(<meta property="og:url" content="http://localhost:4000/self-hosted")
    end

    test "every link into the manual resolves to a page", %{conn: conn} do
      body = conn |> get(~p"/self-hosted") |> html_response(200)

      links =
        ~r/href="\/docs\/([^"#]+)/
        |> Regex.scan(body)
        |> Enum.map(fn [_, slug] -> slug end)
        |> Enum.uniq()

      assert links != []

      for slug <- links do
        assert match?({:ok, _}, Fountain.Docs.get(slug)), "/docs/#{slug} is not a page"
      end
    end

    test "the marketing nav and the homepage link to it", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ ~p"/self-hosted"
    end
  end

  # One page for every question-shaped block the site used to scatter across
  # three. The point of the page is that it does not drift from the data the
  # old blocks rendered, so the tests walk `faq_sections/0` rather than
  # asserting sentences by hand.
  describe "GET /faq" do
    test "renders every section and every question in it", %{conn: conn} do
      body = conn |> get(~p"/faq") |> html_response(200)

      assert body =~ "Answers, with the limits attached."

      # No emptiness assertion: faq_sections/0 is a literal list, so Elixir's
      # type checker reads `!= []` as always true and warns.
      for section <- FountainWeb.MarketingHTML.faq_sections() do
        assert body =~ ~s(id="#{section.id}"), "the page drops section #{section.id}"
        assert body =~ escape(section.title)

        for item <- section.items do
          assert body =~ escape(item.q), "the page drops #{inspect(item.q)}"
          assert body =~ escape(item.a), "the page drops the answer to #{inspect(item.q)}"
        end
      end
    end

    test "carries the blocks it took off the other pages", %{conn: conn} do
      body = conn |> get(~p"/faq") |> html_response(200)

      # The homepage objections, now build_faq/0.
      for item <- FountainWeb.MarketingHTML.build_faq() do
        assert body =~ escape(item.q), "the page drops #{inspect(item.q)}"
      end

      # /self-hosted section 08, unchanged as a function.
      for item <- FountainWeb.MarketingHTML.self_host_faq() do
        assert body =~ escape(item.q), "the page drops #{inspect(item.q)}"
      end

      # The security block, questions and limits both.
      for item <- FountainWeb.MarketingHTML.security_answers() do
        assert body =~ escape(item.question)
        if item.limit, do: assert(body =~ escape(item.limit), "the page drops its limit")
      end
    end

    # The three pages that gave up their questions link back by anchor. A
    # renamed section id would leave those links pointing at nothing, and
    # nothing else in the suite would notice.
    test "the anchors the other pages link at all exist", %{conn: conn} do
      body = conn |> get(~p"/faq") |> html_response(200)
      ids = Enum.map(FountainWeb.MarketingHTML.faq_sections(), & &1.id)

      for anchor <- ~w(security self-hosting) do
        assert anchor in ids, "/faq has no ##{anchor} section to link at"
        assert body =~ ~s(id="#{anchor}")
      end

      home = conn |> get(~p"/") |> html_response(200)
      assert home =~ "/faq#security"

      self_hosted = conn |> get(~p"/self-hosted") |> html_response(200)
      assert self_hosted =~ "/faq#self-hosting"
    end

    test "carries its own card", %{conn: conn} do
      body = conn |> get(~p"/faq") |> html_response(200)
      assert body =~ ~s(<meta property="og:title" content="Questions · Fountain")

      assert body =~
               ~s(<meta name="description" content="What a developer, a buyer and a security reviewer ask)

      assert body =~ ~s(<meta property="og:url" content="http://localhost:4000/faq")
    end

    test "the footer and both pages that shed questions link to it", %{conn: conn} do
      for path <- [~p"/", ~p"/self-hosted"] do
        body = conn |> get(path) |> html_response(200)
        assert body =~ ~p"/faq", "#{path} does not link to the FAQ"
      end
    end
  end

  describe "GET /code-review-bot" do
    test "shows the whole program and every line it annotates", %{conn: conn} do
      body = conn |> get(~p"/code-review-bot") |> html_response(200)

      assert body =~ "A code review bot, whole, on one screen."

      # The page's claim is that the program is all there, so assert the
      # snippets themselves rather than a sentence about them. Both are kept
      # out of the template because HEEx would read their braces.
      webhook = FountainWeb.MarketingHTML.review_bot_webhook()
      assert body =~ "x-hub-signature-256"
      assert body =~ "/api/apply"
      assert body =~ "await run.conversationId"

      # The length is counted off the snippet, never typed. An edit that adds
      # a line and leaves the prose behind fails here.
      assert body =~ "#{FountainWeb.MarketingHTML.review_bot_length(webhook)} lines"

      for line <- FountainWeb.MarketingHTML.review_bot_anatomy() do
        assert body =~ line.title, "missing anatomy line #{line.title}"
      end

      # Every annotated line is a line of the file above it. A card that
      # explains code the page does not show is worse than no card.
      assert String.contains?(webhook, "ensureReviewer(fountain, repo)")
      assert String.contains?(webhook, ~s(vault: "github-bot"))
      assert String.contains?(webhook, "await run.conversationId")
    end

    test "keeps setup, the absent half and the one-field changes on the page", %{conn: conn} do
      body = conn |> get(~p"/code-review-bot") |> html_response(200)

      for step <- FountainWeb.MarketingHTML.review_bot_setup() do
        assert body =~ step.title, "missing setup step #{step.title}"
      end

      for row <- FountainWeb.MarketingHTML.review_bot_absent() do
        assert body =~ row.here, "missing absent row #{row.here}"
      end

      for row <- FountainWeb.MarketingHTML.review_bot_variations() do
        assert body =~ row.want, "missing variation #{row.want}"
      end
    end

    test "the reviewer it applies is one the API would accept", %{conn: conn} do
      body = conn |> get(~p"/code-review-bot") |> html_response(200)
      reviewer = FountainWeb.MarketingHTML.review_bot_reviewer()

      # The kinds the manifest endpoint reconciles, and the field names it
      # actually reads. `system`, not `system_prompt`; `environment`, which
      # Fountain.Manifest resolves to an environment_id by name.
      for kind <- ~w(Environment Agent) do
        assert kind in Fountain.Manifest.kinds()
        assert String.contains?(reviewer, ~s(kind: "#{kind}"))
      end

      assert String.contains?(reviewer, "system:")
      assert String.contains?(reviewer, "environment:")
      assert String.contains?(reviewer, "secret_key:")

      # The model has to satisfy the provider/model format the agent
      # changeset enforces, or the first pull request applies nothing.
      assert [[model]] = Regex.scan(~r/model: "([^"]+)"/, reviewer, capture: :all_but_first)
      assert model =~ ~r{^[a-z0-9_-]+/[a-z0-9._-]+$}

      assert body =~ "The reviewer, written down."
    end

    test "carries its own card", %{conn: conn} do
      body = conn |> get(~p"/code-review-bot") |> html_response(200)

      assert body =~ ~s(<meta property="og:title" content="A code review bot · Fountain")

      assert body =~
               ~s(<meta property="og:url" content="http://localhost:4000/code-review-bot")
    end

    test "every link into the manual resolves to a page", %{conn: conn} do
      body = conn |> get(~p"/code-review-bot") |> html_response(200)

      links =
        ~r/href="\/docs\/([^"#]+)/
        |> Regex.scan(body)
        |> Enum.map(fn [_, slug] -> slug end)
        |> Enum.uniq()

      assert links != []

      for slug <- links do
        assert match?({:ok, _}, Fountain.Docs.get(slug)), "/docs/#{slug} is not a page"
      end
    end

    # Unlisted on purpose: the page is reachable at its URL and nothing on the
    # site points at it, because the program it shows has never been run. The
    # assertion is the absence, so restoring a link is a deliberate edit here
    # rather than something that creeps back in beside an unrelated change.
    test "nothing on the marketing site links to it", %{conn: conn} do
      home = conn |> get(~p"/") |> html_response(200)
      refute home =~ ~p"/code-review-bot"
      refute home =~ "a code review bot in one file"

      # The footer and nav are the shared marketing layout, so any page that
      # renders it would relink the page. Check one that is not the homepage.
      refute conn |> get(~p"/built-with") |> html_response(200) =~ ~p"/code-review-bot"
    end

    test "the page itself still answers, for anyone holding the link", %{conn: conn} do
      assert conn |> get(~p"/code-review-bot") |> html_response(200) =~
               "A code review bot, whole, on one screen."
    end
  end

  describe "GET /case-studies/self-healing-infrastructure" do
    test "renders the loop, the guardrails and the incident", %{conn: conn} do
      body = conn |> get(~p"/case-studies/self-healing-infrastructure") |> html_response(200)

      assert body =~ "The pager still goes off at 06:58."

      # The headline quotes the incident's own clock. Assert it against the
      # timeline so editing one cannot leave the other behind: the hero would
      # otherwise keep advertising times the page below no longer tells.
      [alert | _] = timeline = FountainWeb.MarketingHTML.case_timeline()
      first_pr = Enum.find(timeline, &(&1.title == "The first pull request opens"))

      assert body =~ "goes off at #{String.slice(alert.time, 0, 5)}"
      assert body =~ "open by #{String.slice(first_pr.time, 0, 5)}"

      # Every step of the loop, and the human gate among them.
      for step <- FountainWeb.MarketingHTML.case_loop() do
        assert body =~ step.title, "missing loop step #{step.title}"
      end

      assert body =~ "422 on self-approval"
      assert body =~ "The sandbox has no kubectl and no kubeconfig."
      assert body =~ "install_members()"

      # The incident is told with its own timestamps, not rounded prose.
      for event <- FountainWeb.MarketingHTML.case_timeline() do
        assert body =~ event.time, "missing timeline entry #{event.time}"
      end

      # The snippet is kept out of the template so its braces are not HEEx.
      assert body =~ "POST"
      assert body =~ "/api/conversations"
    end

    test "every number names the window it was counted over", %{conn: conn} do
      body = conn |> get(~p"/case-studies/self-healing-infrastructure") |> html_response(200)

      for stat <- FountainWeb.MarketingHTML.case_stats() do
        assert body =~ stat.value, "missing headline number #{stat.value}"
      end

      assert body =~ FountainWeb.MarketingHTML.case_window()
    end

    test "carries its own card", %{conn: conn} do
      body = conn |> get(~p"/case-studies/self-healing-infrastructure") |> html_response(200)

      assert body =~
               ~s(<meta property="og:title" content="Self-healing infrastructure · Fountain")

      assert body =~
               ~s(<meta property="og:url" content="http://localhost:4000/case-studies/self-healing-infrastructure")
    end

    test "every link into the manual resolves to a page", %{conn: conn} do
      body = conn |> get(~p"/case-studies/self-healing-infrastructure") |> html_response(200)

      links =
        ~r/href="\/docs\/([^"#]+)/
        |> Regex.scan(body)
        |> Enum.map(fn [_, slug] -> slug end)
        |> Enum.uniq()

      assert links != []

      for slug <- links do
        assert match?({:ok, _}, Fountain.Docs.get(slug)), "/docs/#{slug} is not a page"
      end
    end

    test "the bare path is a shortcut to the one study", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/case-studies")) ==
               ~p"/case-studies/self-healing-infrastructure"
    end

    test "the homepage and the marketing footer link to it", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ ~p"/case-studies/self-healing-infrastructure"
      assert body =~ "A cluster that answers its own alerts."

      {proof_at, _} = :binary.match(body, ~s(data-role="case-study-callout"))
      {setup_at, _} = :binary.match(body, "You write this once.")
      assert proof_at < setup_at
    end
  end

  describe "legal links" do
    test "registration form links to terms and privacy", %{conn: conn} do
      body = conn |> get(~p"/auth/register") |> html_response(200)
      assert body =~ ~p"/terms"
      assert body =~ ~p"/privacy"
    end

    test "marketing footer links to terms and privacy", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ ~p"/terms"
      assert body =~ ~p"/privacy"
    end
  end

  # The footer used to be one row of ten links, which went cramped as pages
  # were added. It is groups now, so the test is that every destination the
  # single row carried is still reachable from one of them.
  describe "the marketing footer" do
    test "groups every link it used to carry in one row", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)

      for group <- ~w(product learn account) do
        assert body =~ ~s(data-role="footer-#{group}")
      end

      for path <- [
            ~p"/integrations",
            ~p"/built-with",
            ~p"/case-studies/self-healing-infrastructure",
            ~p"/self-hosted",
            ~p"/faq",
            "/docs",
            "/docs/open-source",
            ~p"/terms",
            ~p"/privacy",
            ~p"/auth/login"
          ] do
        assert body =~ path
      end
    end
  end

  # The three apps this project builds itself lead every page that shows the
  # roster (#1219). Each is one entry in built_apps/0 carrying a :flagship
  # key, so these tests are what stops a page naming them by hand and drifting.
  describe "the security answers on /faq" do
    test "renders every answer and every limit", %{conn: conn} do
      body = conn |> get(~p"/faq") |> html_response(200)

      assert body =~ "Security and data"
      assert body =~ ~s(id="security")

      for item <- FountainWeb.MarketingHTML.security_answers() do
        assert body =~ escape(item.question), "the page drops #{inspect(item.question)}"

        # A limit that never reaches the page is worse than no limit: the
        # answer above it then reads as unqualified.
        if item.limit, do: assert(body =~ escape(item.limit), "the page drops its limit")
      end
    end

    test "says out loud what the platform does not have", %{conn: conn} do
      body = conn |> get(~p"/faq") |> html_response(200)

      assert body =~ "What we do not have."

      for item <- FountainWeb.MarketingHTML.security_absent() do
        assert body =~ escape(item), "the page drops #{inspect(String.slice(item, 0, 40))}"
      end

      # The four a reviewer asks for first. If one of these ever ships, this
      # test is the reminder to delete its row rather than leave the page
      # disclaiming something the platform now has.
      assert body =~ "No SOC 2 report"
      assert body =~ "no published sub-processor list"
      assert body =~ "No single sign-on"
      assert body =~ "No independent penetration test"
    end

    test "claims nothing for the egress broker, which runs for one account", %{conn: conn} do
      body = conn |> get(~p"/faq") |> html_response(200)

      # ADR 0019 is Proposed and live for the maintainer alone. The page may
      # only name it among the things you cannot turn on.
      assert body =~ "It is not something you can turn on yet"
      refute body =~ "the sandbox never holds"
    end

    test "every link into the manual resolves to a page", %{conn: conn} do
      for path <- [~p"/", ~p"/faq"] do
        body = conn |> get(path) |> html_response(200)

        links =
          ~r/href="\/docs\/([^"#]+)/
          |> Regex.scan(body)
          |> Enum.map(fn [_, slug] -> slug end)
          |> Enum.uniq()

        assert links != [], "#{path} links into the manual nowhere"

        for slug <- links do
          assert match?({:ok, _}, Fountain.Docs.get(slug)), "/docs/#{slug} is not a page"
        end
      end
    end
  end

  describe "the flagship three" do
    test "the roster holds exactly three, each with the lines a featured card needs" do
      flagship = FountainWeb.MarketingHTML.flagship_apps()

      assert Enum.map(flagship, & &1.id) ==
               ~w(fountain-conversations fountain-team fountain-workbench)

      for app <- flagship do
        assert app.flagship.like != ""
        assert app.flagship.who != ""
        assert app in FountainWeb.MarketingHTML.built_apps_flat(), "#{app.name} left the roster"
      end

      # They are their own group, and it is the one the pages lift out.
      group = FountainWeb.MarketingHTML.flagship_group()
      assert group.apps == flagship
      assert group.id not in Enum.map(FountainWeb.MarketingHTML.other_app_groups(), & &1.id)

      rest = Enum.flat_map(FountainWeb.MarketingHTML.other_app_groups(), & &1.apps)

      assert length(rest) == length(FountainWeb.MarketingHTML.built_apps_flat()) - 3,
             "an app fell out of the roster when the three were lifted from it"

      assert rest -- flagship == rest, "a flagship app is in two groups"
    end

    test "the homepage opens each one and links its source", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)

      assert body =~ "Start from an app that already works."

      for app <- FountainWeb.MarketingHTML.flagship_apps() do
        assert body =~ app.name, "the homepage does not name #{app.name}"
        assert body =~ app.url, "the homepage does not open #{app.name}"
        assert body =~ app.source, "the homepage does not link #{app.name}'s source"
        assert body =~ app.flagship.like, "the homepage drops #{app.name}'s framing"
      end
    end

    test "/built-with features them above the rest of the roster", %{conn: conn} do
      body = conn |> get(~p"/built-with") |> html_response(200)

      assert body =~ FountainWeb.MarketingHTML.flagship_group().title

      for app <- FountainWeb.MarketingHTML.flagship_apps() do
        assert body =~ app.flagship.like, "no featured framing for #{app.name}"
        assert body =~ app.flagship.who, "no audience line for #{app.name}"
      end

      # Featured means once, not twice: the group is lifted out of the loop
      # that renders every other group, so its cards must not render again.
      assert body |> String.split(~s(data-role="app")) |> length() ==
               length(FountainWeb.MarketingHTML.built_apps_flat()) -
                 length(FountainWeb.MarketingHTML.flagship_apps()) + 1

      # The three lead the page: their section is the first group anchor in the
      # document, whatever order built_apps/0 happens to be read in.
      order =
        for group <- FountainWeb.MarketingHTML.built_apps() do
          {pos, _len} = :binary.match(body, ~s(id="#{group.id}"))
          {pos, group.id}
        end

      assert order |> Enum.sort() |> hd() |> elem(1) == "flagship"
    end

    test "/self-hosted shows them as the front ends an instance gets", %{conn: conn} do
      body = conn |> get(~p"/self-hosted") |> html_response(200)

      assert body =~ "Use the apps or host your own."
      assert body =~ "API_CORS_ORIGINS"
      assert body =~ "CONVERSATIONS_APP_URL"
      assert body =~ "TEAM_APP_URL"

      for app <- FountainWeb.MarketingHTML.flagship_apps() do
        assert body =~ app.url, "self-hosted does not open #{app.name}"
        assert body =~ app.source, "self-hosted does not link #{app.name}'s source"
      end

      # The showcase complements the three frontends above it, so it must not
      # repeat one of those cards.
      showcase = FountainWeb.MarketingHTML.self_host_showcase()
      assert showcase -- FountainWeb.MarketingHTML.flagship_apps() == showcase
    end

    test "/integrations names them under its own API", %{conn: conn} do
      body = conn |> get(~p"/integrations") |> html_response(200)

      for app <- FountainWeb.MarketingHTML.flagship_apps() do
        assert body =~ app.name, "/integrations does not name #{app.name}"
      end
    end
  end

  # Copy held in `marketing_html.ex` is plain text; the rendered page has been
  # through HEEx, so an apostrophe is `&#39;` by the time it lands. Compare
  # like with like rather than writing the entity into the expectation.
  defp escape(text) do
    text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
  end
end

defmodule FountainWeb.OpenGraphTest do
  use FountainWeb.ConnCase, async: true

  test "every public page carries an Open Graph card", %{conn: conn} do
    body = conn |> get(~p"/") |> html_response(200)

    # This asserted `content="Fountain"` and so was pinning `OpenGraph.title/1`'s
    # brand-name fallback, which is what a page with no `:page_title` gets. The
    # homepage has one now. What belongs here is that the card carries a title
    # ending in the brand; the phrase itself is owned by "GET / titling".
    assert body =~ ~s(<meta property="og:title" content=")
    assert body =~ ~s(· #{Fountain.Brand.name()}")

    assert body =~ ~s(<meta property="og:url" content="http://localhost:4000/")

    assert body =~
             ~s(<meta property="og:image" content="http://localhost:4000/images/og-card.png")

    assert body =~ ~s(<meta property="og:image:width" content="1200")
    assert body =~ ~s(<meta name="twitter:card" content="summary_large_image")
    assert body =~ ~s(<meta name="description" content="Fountain is a conversational API)
  end

  test "a docs page describes itself and names its own URL", %{conn: conn} do
    body = conn |> get(~p"/docs/cli") |> html_response(200)
    assert body =~ ~s(<meta property="og:url" content="http://localhost:4000/docs/cli")
    assert body =~ ~s(<meta property="og:title" content="Docs · )
    assert body =~ ~s(from the Fountain manual.)
  end

  test "the card image is served" do
    assert File.exists?(Application.app_dir(:fountain, "priv/static/images/og-card.png"))
  end

  describe "the homepage manifest" do
    alias FountainWeb.MarketingHTML

    # docs/cli.md is diffed against the real CLI by cli/internal/cmd/docs_test.go.
    # A marketing snippet has no such guard, which is how `run.output` and
    # `--external-id` reached the site. These are that guard.

    test "names only the kinds `fountain apply` supports" do
      kinds =
        Regex.scan(~r/^kind: (\w+)$/m, MarketingHTML.apply_example()) |> Enum.map(&List.last/1)

      assert kinds == MarketingHTML.apply_kinds(),
             "the manifest names a kind `fountain apply` does not reconcile, or dropped one"
    end

    test "is a multi-document file, which is the only reason one apply covers three" do
      assert MarketingHTML.apply_example() |> String.split("\n---\n") |> length() ==
               length(MarketingHTML.apply_kinds())
    end

    test "defines the agent the SDK call underneath starts" do
      [_, name] =
        Regex.run(~r/kind: Agent\nmetadata:\n  name: (\S+)/, MarketingHTML.apply_example())

      assert MarketingHTML.sdk_example() =~ ~s(agent: "#{name}"),
             "the manifest defines agent #{name} and the call beside it starts a different one"
    end

    test "carries no plaintext secret onto the page" do
      assert MarketingHTML.apply_example() =~ "op://",
             "the manifest should reference a secret manager, not inline a token"
    end

    test "the homepage renders it, and the command that applies it", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)

      assert body =~ "You write this once."
      assert body =~ "fountain apply -f fountain.yml"
      assert body =~ "kind: Environment"
    end
  end
end
