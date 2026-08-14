defmodule FountainWeb.DocsHTML do
  @moduledoc false
  use FountainWeb, :html

  embed_templates "docs_html/*"

  @doc "Route path for a docs slug (`\"\"` is the docs home)."
  def docs_path(""), do: "/docs"
  def docs_path(slug), do: "/docs/" <> slug
end
