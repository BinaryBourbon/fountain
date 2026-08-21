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

  The nav is **read from `mkdocs.yml` at compile time**, not mirrored here.
  It used to be a hand-maintained copy that `docs_test.exs` diffed against the
  real file, and the diff is what people hit: adding a page to `mkdocs.yml`
  without editing this module failed a test in CI partition 3, which looks
  entirely unrelated to the docs. Adding a page to `mkdocs.yml` is now the
  whole change.

  Because `mkdocs.yml` is read at compile time it is also an
  `@external_resource`, which means it must be COPYed into the Docker build
  stage — see the note on the `@external_resource` list below.

  The MkDocs dialect the preprocessing covers is deliberately small (snippet
  includes, admonitions, relative `.md` links) — if a doc page starts using an
  extension beyond that, check the page at `/docs`, don't assume.
  """

  alias Fountain.Docs.Compiler

  @root Path.expand("../../../..", __DIR__)
  @docs_dir Path.join(@root, "docs")

  @mkdocs_yml Path.join(@root, "mkdocs.yml")

  # The nav, parsed from mkdocs.yml itself. `{title, file}` for a page,
  # `{section_title, [{title, file}]}` for a section — the same shape the
  # hand-maintained copy had, minus the maintaining.
  @nav @mkdocs_yml |> File.read!() |> Compiler.parse_nav()

  # Everything read at compile time is listed here, so an edit recompiles the
  # module in dev — AND so `docs_test.exs` can assert the Dockerfile COPYs it
  # into the build stage. That second job is the load-bearing one: the release
  # image never contains these files, only the strings baked out of them, so a
  # path outside what the Dockerfile COPYs does not degrade to a broken link.
  # It kills `mix release`, no image is produced, CI stays green, and the
  # deploy silently never happens (#884).
  @external_resource @mkdocs_yml

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

  @doc """
  The compiled nav in *source* shape — `{title, file}` rather than
  `{title, slug}` — so tests can check the pages mkdocs.yml names against
  what is on disk. This is what the module actually embedded, not a re-read
  of the file.
  """
  @spec nav_source() :: [{String.t(), String.t() | [{String.t(), String.t()}]}]
  def nav_source, do: @nav

  @doc "Fetch a page by slug: `{:ok, %{title: ..., body: markdown}}` or `:error`."
  @spec get(String.t()) :: {:ok, %{title: String.t(), body: String.t()}} | :error
  def get(slug) when is_binary(slug), do: Map.fetch(@pages, slug)
end
