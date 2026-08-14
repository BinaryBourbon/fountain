defmodule Fountain.Docs do
  @moduledoc """
  The public documentation site (`docs/` at the repo root), embedded at compile
  time so the app can serve it at `/docs`.

  The same markdown is published to GitHub Pages by `.github/workflows/docs.yml`
  (MkDocs Material). This module is the in-app rendering path: pages are read at
  compile time (`@external_resource`, so edits recompile in dev), preprocessed
  from MkDocs dialect to plain markdown by `Fountain.Docs.Compiler`, and served
  through the same `FountainWeb.Markdown` pipeline as `/help`. Compile-time
  embedding is also what ships the content — the release image never contains
  `docs/` itself, only these ~230 KB of strings in the beam file.

  This is distinct from `Fountain.Help`, the curated in-app help under
  `priv/help/` — that stays as it is; `/docs` is the full public manual.

  `@nav` mirrors the `nav:` section of `mkdocs.yml`; `docs_test.exs` parses
  that file and fails on any drift, in either direction. The MkDocs dialect
  the preprocessing covers is deliberately small (snippet includes,
  admonitions, relative `.md` links) — if a doc page starts using an extension
  beyond that, check the page at `/docs`, don't assume.
  """

  alias Fountain.Docs.Compiler

  @root Path.expand("../../../..", __DIR__)
  @docs_dir Path.join(@root, "docs")

  # Mirrors mkdocs.yml `nav:` — {title, file} or {section_title, [{title, file}]}.
  @nav [
    {"Home", "index.md"},
    {"Setup", "setup.md"},
    {"Self-hosting", "self-hosting.md"},
    {"Architecture", "architecture.md"},
    {"Operations", "operations.md"},
    {"Configuration reference", "configuration.md"},
    {"Integrations",
     [
       {"Overview", "integrations/index.md"},
       {"Sprites", "integrations/sprites.md"},
       {"The Sprites contract", "integrations/sprites-contract.md"},
       {"E2B", "integrations/e2b.md"},
       {"Daytona", "integrations/daytona.md"},
       {"Adding a provider", "integrations/adding-a-sandbox-provider.md"},
       {"GitHub OAuth", "integrations/github-oauth.md"},
       {"Stripe", "integrations/stripe.md"},
       {"Sentry", "integrations/sentry.md"},
       {"Mail", "integrations/mail.md"}
     ]},
    {"The four primitives", "primitives.md"},
    {"CLI reference", "cli.md"},
    {"API reference", "api.md"},
    {"LLM integration", "llm-integration.md"},
    {"Changelog", "changelog.md"}
  ]

  # docs/changelog.md pulls the repo-root CHANGELOG.md in via a snippet.
  @external_resource Path.join(@root, "CHANGELOG.md")

  for {_title, file} <- Compiler.flat_pages(@nav) do
    @external_resource Path.join(@docs_dir, file)
  end

  @pages Map.new(Compiler.flat_pages(@nav), fn {title, file} ->
           body = @docs_dir |> Path.join(file) |> File.read!() |> Compiler.preprocess(file, @root)
           {Compiler.slug_for(file), %{title: title, body: body}}
         end)

  @doc """
  Sidebar structure, in mkdocs.yml order: `{title, slug}` for pages,
  `{section_title, [{title, slug}, ...]}` for sections.
  """
  @spec nav() :: [{String.t(), String.t() | [{String.t(), String.t()}]}]
  def nav do
    Enum.map(@nav, fn
      {section, children} when is_list(children) ->
        {section, Enum.map(children, fn {title, file} -> {title, Compiler.slug_for(file)} end)}

      {title, file} ->
        {title, Compiler.slug_for(file)}
    end)
  end

  @doc "All page slugs (the home page is `\"\"`)."
  @spec slugs() :: [String.t()]
  def slugs, do: Map.keys(@pages)

  @doc "Fetch a page by slug: `{:ok, %{title: ..., body: markdown}}` or `:error`."
  @spec get(String.t()) :: {:ok, %{title: String.t(), body: String.t()}} | :error
  def get(slug) when is_binary(slug), do: Map.fetch(@pages, slug)

  @doc "The nav source as `{title, file}` pairs — for the mkdocs.yml sync test."
  @spec nav_source() :: [{String.t(), String.t() | [{String.t(), String.t()}]}]
  def nav_source, do: @nav
end
