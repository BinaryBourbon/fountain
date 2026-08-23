defmodule FountainWeb.DocsControllerTest do
  use FountainWeb.ConnCase, async: true

  # All requests here are unauthenticated on purpose: /docs is the public
  # manual, so it sits in the public marketing scope. Since #1008 it is the
  # only place that manual is published, which makes the anonymous case the
  # one that matters most — nobody reading setup.md has an account yet.

  describe "GET /docs" do
    test "serves the home page with the sidebar nav", %{conn: conn} do
      body = conn |> get(~p"/docs") |> html_response(200)
      assert body =~ "multi-tenant"
      # One entry from each nav shape: a top-level page and a section child.
      assert body =~ "Self-host Fountain"
      assert body =~ "Sprites transport reference"
      assert body =~ ~s(href="/docs/integrations/sprites-contract")
    end

    test "renders the admonition as a blockquote, not its raw source syntax", %{conn: conn} do
      body = conn |> get(~p"/docs") |> html_response(200)
      assert body =~ "In a hurry?"
      refute body =~ "!!!"
    end
  end

  describe "GET /docs/:page" do
    test "serves a top-level page", %{conn: conn} do
      body = conn |> get(~p"/docs/setup") |> html_response(200)
      assert body =~ "Setup"
    end

    test "serves a nested integrations page", %{conn: conn} do
      body = conn |> get(~p"/docs/integrations/sprites-contract") |> html_response(200)
      assert body =~ "Sprites"
    end

    test "rewrites internal links to /docs paths", %{conn: conn} do
      body = conn |> get(~p"/docs/architecture") |> html_response(200)
      assert body =~ ~s(href="/docs/primitives")
      refute body =~ ~s(.md")
    end

    test "serves the changelog with the repo-root CHANGELOG inlined", %{conn: conn} do
      body = conn |> get(~p"/docs/changelog") |> html_response(200)
      assert body =~ "Keep a Changelog"
    end

    test "404s on unknown pages", %{conn: conn} do
      assert conn |> get(~p"/docs/nope") |> html_response(404) =~ "Page not found"

      assert conn |> get("/docs/integrations/nope/deeper") |> html_response(404) =~
               "Page not found"
    end
  end
end
