defmodule FountainWeb.MarketingControllerTest do
  use FountainWeb.ConnCase, async: true

  # config/test.exs pins :legal, so these cover the configured-identity path;
  # the unpublished and placeholder paths live in MarketingLegalUnpublishedTest
  # (async: false — they mutate global app env).

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
      assert body =~ ~s(<meta name="description" content="13 open-source applications)
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
      assert body =~ "People build whole products on it."
    end
  end

  describe "GET /self-hosted" do
    test "makes the case and shows the whole bring-up", %{conn: conn} do
      body = conn |> get(~p"/self-hosted") |> html_response(200)

      assert body =~ "Define your agents once. Let every app you build hire them."
      assert body =~ "Six commands and a token."
      assert body =~ "The features we ration, you switch on."
      assert body =~ "What it costs you instead."

      # The bring-up is kept out of the template so its $(...) is not HEEx.
      assert body =~ "docker compose up -d"
      assert body =~ "MASTER_SECRETS_KEY"

      for licence <- ["AGPL-3.0-or-later", "Elastic 2.0", "Apache-2.0"] do
        assert body =~ licence, "missing licence #{licence}"
      end

      assert body =~ FountainWeb.MarketingHTML.repo_url()
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

    test "shows apps that already hire from the roster, and links every one", %{conn: conn} do
      body = conn |> get(~p"/self-hosted") |> html_response(200)

      # The hero's claim is that an agent defined once gets hired by anything.
      # The cards are the evidence, so each has to be a working pair of links
      # into the same roster /built-with renders.
      showcase = FountainWeb.MarketingHTML.self_host_showcase()
      assert length(showcase) == 4

      for app <- showcase do
        assert body =~ app.name, "missing app #{app.name}"
        assert body =~ app.url, "missing live link for #{app.name}"
        assert app in FountainWeb.MarketingHTML.built_apps_flat(), "#{app.name} left the roster"
      end

      count = to_string(FountainWeb.MarketingHTML.built_app_count())
      assert body =~ "#{count} applications already hire from one roster."
      assert body =~ ~p"/built-with"
    end

    test "carries its own card", %{conn: conn} do
      body = conn |> get(~p"/self-hosted") |> html_response(200)
      assert body =~ ~s(<meta property="og:title" content="Self-host Fountain · Fountain")

      assert body =~
               ~s(<meta name="description" content="Define an agent once and every app)

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

  describe "GET /case-studies/self-healing-infrastructure" do
    test "renders the loop, the guardrails and the incident", %{conn: conn} do
      body = conn |> get(~p"/case-studies/self-healing-infrastructure") |> html_response(200)

      assert body =~ "The alert stopped waking him up."

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
      assert body =~ "An estate that answers its own alerts."
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

  # The three apps this project builds itself lead every page that shows the
  # roster (#1219). Each is one entry in built_apps/0 carrying a :flagship
  # key, so these tests are what stops a page naming them by hand and drifting.
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

      assert body =~ "Or use the apps we built on it."

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

      assert body =~ "The apps come with it."
      assert body =~ "API_CORS_ORIGINS"
      assert body =~ "CONVERSATIONS_APP_URL"
      assert body =~ "TEAM_APP_URL"

      for app <- FountainWeb.MarketingHTML.flagship_apps() do
        assert body =~ app.url, "self-hosted does not open #{app.name}"
        assert body =~ app.source, "self-hosted does not link #{app.name}'s source"
      end

      # The showcase above the bring-up argues that other people build on this,
      # so it must not spend one of its four cards on an app of ours.
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
end

defmodule FountainWeb.OpenGraphTest do
  use FountainWeb.ConnCase, async: true

  test "every public page carries an Open Graph card", %{conn: conn} do
    body = conn |> get(~p"/") |> html_response(200)
    assert body =~ ~s(<meta property="og:title" content="Fountain")
    assert body =~ ~s(<meta property="og:url" content="http://localhost:4000/")

    assert body =~
             ~s(<meta property="og:image" content="http://localhost:4000/images/og-card.png")

    assert body =~ ~s(<meta property="og:image:width" content="1200")
    assert body =~ ~s(<meta name="twitter:card" content="summary_large_image")
    assert body =~ ~s(<meta name="description" content="Fountain runs a coding agent)
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
end
