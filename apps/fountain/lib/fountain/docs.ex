defmodule Fountain.Docs do
  @moduledoc """
  The public documentation manual (`docs/` at the repo root), embedded at
  compile time so the app can serve it at `/docs`.

  `/docs` is the only place this manual is published. It used to be built as a
  static MkDocs Material site and deployed to GitHub Pages as well; that second
  copy was retired once `/docs` served the same markdown from the same nav,
  because two publishing paths for one set of pages is two things to keep
  green (#1008).

  Pages are read at compile time (`@external_resource`, so edits recompile in
  dev), preprocessed to plain markdown by `Fountain.Docs.Compiler`, and served
  through the same `FountainWeb.Markdown` pipeline as `/help`. Compile-time
  embedding is also what ships the content — the release image never contains
  `docs/` itself, only these strings in the beam file — ~525 KB of markdown,
  ~737 KB once snippet includes (the changelog pulls in the repo-root
  `CHANGELOG.md`) are expanded.

  This is distinct from `Fountain.Help`, the curated in-app help under
  `priv/help/` — that stays as it is; `/docs` is the full public manual.

  The nav is **read from `docs/nav.yml` at compile time**, not mirrored here.
  It used to be a hand-maintained copy that `docs_test.exs` diffed against the
  real file, and the diff is what people hit: adding a page without editing
  this module failed a test in CI partition 3, which looks entirely unrelated
  to the docs. Adding a page to `docs/nav.yml` is now the whole change.

  The markdown dialect the preprocessing covers is deliberately small (snippet
  includes, admonitions, relative `.md` links) — if a doc page starts using
  something beyond that, check the page at `/docs`, don't assume. Nothing
  renders these pages but this module, so there is no second renderer to
  disagree with.
  """

  alias Fountain.Docs.Compiler

  @root Path.expand("../../../..", __DIR__)
  @docs_dir Path.join(@root, "docs")

  @nav_yml Path.join(@docs_dir, "nav.yml")

  # The nav, parsed from docs/nav.yml itself. `{title, file}` for a page,
  # `{section_title, [{title, file}]}` for a section — the same shape the
  # hand-maintained copy had, minus the maintaining.
  @nav @nav_yml |> File.read!() |> Compiler.parse_nav()

  # Everything read at compile time is listed here, so an edit recompiles the
  # module in dev — AND so `docs_test.exs` can assert the Dockerfile COPYs it
  # into the build stage. That second job is the load-bearing one: the release
  # image never contains these files, only the strings baked out of them, so a
  # path outside what the Dockerfile COPYs does not degrade to a broken link.
  # It kills `mix release`, no image is produced, CI stays green, and the
  # deploy silently never happens (#884).
  @external_resource @nav_yml

  # docs/changelog.md pulls the repo-root CHANGELOG.md in via a snippet.
  @external_resource Path.join(@root, "CHANGELOG.md")

  for {_title, file} <- Compiler.flat_pages(@nav) do
    @external_resource Path.join(@docs_dir, file)
  end

  @pages Map.new(Compiler.flat_pages(@nav), fn {title, file} ->
           body = @docs_dir |> Path.join(file) |> File.read!() |> Compiler.preprocess(file, @root)
           {Compiler.slug_for(file), %{title: title, body: body}}
         end)

  # The client-side search index for `/docs` (#1009): one pass over `@pages`,
  # done at compile time like the rest of this module. Headings only, not
  # full text — the description settled that as the safer starting point,
  # since the embedded bodies run ~737 KB after snippet expansion and this
  # index has to be small enough to inline.
  #
  # Reuses `FountainWeb.Markdown.to_trusted_html/1` — the same rendering
  # `docs_test.exs` already treats as ground truth for anchor ids — so a
  # heading's id here is guaranteed to be the id its own page renders, with
  # no second slugging pass to drift from it.
  @search_index (for {slug, %{title: title, body: body}} <- @pages do
                   headings =
                     body
                     |> FountainWeb.Markdown.to_trusted_html()
                     |> Compiler.extract_headings()

                   %{title: title, slug: slug, headings: headings}
                 end)

  # `</` → `<\/` so a heading that ever contains a literal `</script` cannot
  # close the `<script>` tag this gets inlined into early — the HTML
  # tokenizer looks for that byte sequence regardless of the tag's `type`.
  # Valid inside a JSON string either way; `\/` and `/` decode to the same
  # character.
  @search_index_json Jason.encode!(@search_index) |> String.replace("</", "<\\/")

  @doc """
  Sidebar structure, in nav.yml order: `{title, slug}` for pages,
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
  `{title, slug}` — so tests can check the pages nav.yml names against
  what is on disk. This is what the module actually embedded, not a re-read
  of the file.
  """
  @spec nav_source() :: [{String.t(), String.t() | [{String.t(), String.t()}]}]
  def nav_source, do: @nav

  @doc "Fetch a page by slug: `{:ok, %{title: ..., body: markdown}}` or `:error`."
  @spec get(String.t()) :: {:ok, %{title: String.t(), body: String.t()}} | :error
  def get(slug) when is_binary(slug), do: Map.fetch(@pages, slug)

  @doc """
  The `/docs` search index: one entry per page, each with the headings found
  on it. A heading's `id` is a fragment on that page's own path
  (`Compiler.path_for_slug/1` + `"#" <> id`), which is how a search result
  deep-links to it.
  """
  @spec search_index() :: [
          %{title: String.t(), slug: String.t(), headings: [%{id: String.t(), text: String.t()}]}
        ]
  def search_index, do: @search_index

  @doc """
  `search_index/0`, pre-encoded as JSON at compile time so the docs layout
  can inline it without paying to encode it on every request.
  """
  @spec search_index_json() :: String.t()
  def search_index_json, do: @search_index_json
end
