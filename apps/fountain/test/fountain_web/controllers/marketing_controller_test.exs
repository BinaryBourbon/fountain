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
