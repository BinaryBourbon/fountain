defmodule FountainWeb.DocsController do
  @moduledoc """
  Serves the public documentation site (the same markdown GitHub Pages
  publishes) at `/docs`. Content is embedded at compile time by
  `Fountain.Docs`; rendering goes through the sanitizing
  `FountainWeb.Markdown` pipeline, same as `/help` (#323).

  Public, like the marketing pages — the GitHub Pages site has no auth, so
  the in-app mirror has none either.
  """
  use FountainWeb, :controller

  def show(conn, params) do
    slug = params |> Map.get("page", []) |> Enum.join("/")

    case Fountain.Docs.get(slug) do
      {:ok, page} ->
        render(conn, :show,
          layout: {FountainWeb.Layouts, :marketing},
          page_title: "Docs · " <> page.title,
          nav: Fountain.Docs.nav(),
          slug: slug,
          title: page.title,
          body_html: FountainWeb.Markdown.to_html(page.body)
        )

      :error ->
        conn
        |> put_status(:not_found)
        |> render(:not_found,
          layout: {FountainWeb.Layouts, :marketing},
          page_title: "Docs · Not found"
        )
    end
  end
end
