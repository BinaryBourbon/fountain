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

      assert body =~ "There is no Enterprise edition. There is the repo."
      assert body =~ "Five commands and a token."
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

    test "carries its own card", %{conn: conn} do
      body = conn |> get(~p"/self-hosted") |> html_response(200)
      assert body =~ ~s(<meta property="og:title" content="Self-host Fountain · Fountain")
      assert body =~ ~s(<meta name="description" content="Fountain is open source)
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
