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
