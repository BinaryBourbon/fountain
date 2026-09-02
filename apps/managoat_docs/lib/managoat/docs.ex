defmodule Managoat.Docs do
  @moduledoc """
  A documentation manual embedded at compile time, so a Phoenix app can serve
  it at a path of its own (`/docs`) instead of publishing a second site.

  The host keeps a module (`MyApp.Docs`, say) whose body is nothing but this:

      use Managoat.Docs,
        root: Path.expand("../..", __DIR__),   # where snippet includes resolve
        docs_dir: "docs",                       # the pages, relative to root
        nav: "docs/nav.yml",                    # the nav, relative to root
        mount: "/docs",                         # the path the manual is served at
        extra_resources: ["CHANGELOG.md"],      # other files a page includes
        languages: ~w(bash elixir json)         # parsers the image bakes

  Every option has the default shown except `root`, which is required. The
  macro reads the nav and every page it names in the host module's body, so
  each of them is an `@external_resource` **of the host module**, which is
  where recompilation has to be triggered when a page changes. It generates:

  | Function | Returns |
  |---|---|
  | `nav/0` | the sidebar: `{title, slug}` for a page, `{section, [{title, slug}]}` for a section |
  | `nav_source/0` | the same nav in source shape, `{title, file}`, for the guardrails |
  | `slugs/0` | every page slug (the home page is `""`) |
  | `get/1` | `{:ok, %{title: t, body: markdown}}` or `:error` |
  | `search_index/0` | one entry per page with its `h2`–`h6` headings and their ids |
  | `search_index_json/0` | the index pre-encoded, safe to inline in a `<script>` |
  | `path_for_slug/1` | `""` → the mount, `"setup"` → `mount <> "/setup"` |
  | `external_resources/0` | every file read at compile time, relative to root |
  | `root/0`, `docs_dir/0`, `mount/0`, `languages/0` | the options, resolved |

  A page's `body` is plain markdown: the compile step (`Managoat.Docs.Compiler`)
  has expanded snippet includes, turned admonitions into blockquotes and
  rewritten relative `.md` links to paths under the mount. The host renders it
  with `Managoat.Docs.Markdown.to_trusted_html/1` and wraps the result in
  `Phoenix.HTML.raw/1`.

  ## The dialect

  The markdown a manual may use beyond CommonMark and GFM tables is
  deliberately small, inherited from the MkDocs Material site Fountain's
  pages were published as before they moved in-app:

  - `--8<-- "path/to/file"` on a line of its own inlines that file, read
    relative to `root`;
  - `!!! note "Title"` followed by a four-space-indented body becomes a
    blockquote with a bold title line;
  - `[text](other-page.md#anchor)` is rewritten to `mount/other-page#anchor`,
    resolved against the linking page's own directory.

  Nothing else is rewritten. If a page starts using something beyond that,
  check it as served; there is no second renderer to disagree with.

  ## The nav

  `nav.yml` has a `nav:` block that is a hand-written list two levels deep:

      nav:
        - Home: index.md
        - Setup: setup.md
        - Guides:
            - Deploy: guides/deploy.md
            - Operate: guides/operate.md

  `Managoat.Docs.Compiler.parse_nav/1` reads exactly those two line shapes
  and **raises at compile time** on anything else, a nested section
  included: a page silently missing from the manual is the bug the parser
  exists to make impossible, so an unreadable nav fails the compile rather
  than shrinking the site.

  ## The guardrails

  What makes the manual safe to change is `Managoat.Docs.GuardrailCase`, a
  case template the host `use`s in a test of its own. Each check exists
  because of an incident in Fountain's history: every page the nav names
  exists and every page on disk is named; every internal link and every
  `#anchor` resolves against the rendered heading ids; every file read at
  compile time is `COPY`d into the image's build stage, because a missing
  one does not break a link, it kills `mix release` while CI stays green.
  """

  @doc false
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      root = Keyword.fetch!(opts, :root)
      docs_dir = Path.join(root, Keyword.get(opts, :docs_dir, "docs"))
      nav_file = Path.join(root, Keyword.get(opts, :nav, "docs/nav.yml"))
      mount = Keyword.get(opts, :mount, "/docs")
      languages = Keyword.get(opts, :languages, Managoat.Docs.Markdown.languages())
      extra = Enum.map(Keyword.get(opts, :extra_resources, []), &Path.join(root, &1))

      @managoat_docs_root root
      @managoat_docs_dir docs_dir
      @managoat_docs_mount mount
      @managoat_docs_languages languages

      # The nav, parsed from the file itself. `{title, file}` for a page,
      # `{section_title, [{title, file}]}` for a section.
      compiled = Managoat.Docs.Compiler.compile(root, docs_dir, nav_file, mount)

      @managoat_docs_nav compiled.nav
      @managoat_docs_pages compiled.pages
      @managoat_docs_search_index compiled.search_index

      # `</` → `<\/` so a heading that ever contains a literal `</script`
      # cannot close the `<script>` tag this gets inlined into early; the HTML
      # tokenizer looks for that byte sequence regardless of the tag's `type`.
      # Valid inside a JSON string either way; `\/` and `/` decode to the same
      # character.
      @managoat_docs_search_index_json Jason.encode!(compiled.search_index)
                                       |> String.replace("</", "<\\/")

      # Everything read at compile time is declared here, so an edit
      # recompiles this module in dev, and so the guardrails can assert the
      # Dockerfile COPYs it into the build stage. That second job is the
      # load-bearing one: the release image never contains these files, only
      # the strings baked out of them, so a path outside what the Dockerfile
      # COPYs does not degrade to a broken link. It kills `mix release`, no
      # image is produced, CI stays green, and the deploy silently never
      # happens (Fountain #884).
      pages_on_disk =
        for {_title, file} <- Managoat.Docs.Compiler.flat_pages(compiled.nav),
            do: Path.join(docs_dir, file)

      @managoat_docs_resources [nav_file | extra] ++ pages_on_disk

      for path <- @managoat_docs_resources do
        @external_resource path
      end

      @doc """
      Sidebar structure, in nav order: `{title, slug}` for pages,
      `{section_title, [{title, slug}, ...]}` for sections.
      """
      @spec nav() :: [{String.t(), String.t() | [{String.t(), String.t()}]}]
      def nav do
        Enum.map(@managoat_docs_nav, fn
          {section, children} when is_list(children) ->
            {section,
             Enum.map(children, fn {title, file} ->
               {title, Managoat.Docs.Compiler.slug_for(file)}
             end)}

          {title, file} ->
            {title, Managoat.Docs.Compiler.slug_for(file)}
        end)
      end

      @doc """
      The compiled nav in *source* shape, `{title, file}` rather than
      `{title, slug}`, so the guardrails can check the pages the nav names
      against what is on disk. This is what the module embedded, not a
      re-read of the file.
      """
      @spec nav_source() :: [{String.t(), String.t() | [{String.t(), String.t()}]}]
      def nav_source, do: @managoat_docs_nav

      @doc "All page slugs (the home page is `\"\"`)."
      @spec slugs() :: [String.t()]
      def slugs, do: Map.keys(@managoat_docs_pages)

      @doc "Fetch a page by slug: `{:ok, %{title: ..., body: markdown}}` or `:error`."
      @spec get(String.t()) :: {:ok, %{title: String.t(), body: String.t()}} | :error
      def get(slug) when is_binary(slug), do: Map.fetch(@managoat_docs_pages, slug)

      @doc """
      The search index: one entry per page, each with the headings found on
      it. A heading's `id` is a fragment on that page's own path
      (`path_for_slug/1` + `"#" <> id`), which is how a search result
      deep-links to it.
      """
      @spec search_index() :: [
              %{
                title: String.t(),
                slug: String.t(),
                headings: [%{id: String.t(), text: String.t()}]
              }
            ]
      def search_index, do: @managoat_docs_search_index

      @doc """
      `search_index/0`, pre-encoded as JSON at compile time so a layout can
      inline it without paying to encode it on every request.
      """
      @spec search_index_json() :: String.t()
      def search_index_json, do: @managoat_docs_search_index_json

      @doc "The served path for a slug: `\"\"` is the mount itself."
      @spec path_for_slug(String.t()) :: String.t()
      def path_for_slug(slug),
        do: Managoat.Docs.Compiler.path_for_slug(slug, @managoat_docs_mount)

      @doc """
      Every file this module read at compile time, relative to `root/0`: the
      nav, every page it names, and the `extra_resources:` the `use` line
      declared. The Dockerfile guardrail reads this.
      """
      @spec external_resources() :: [String.t()]
      def external_resources do
        @managoat_docs_resources
        |> Enum.map(&Path.relative_to(&1, @managoat_docs_root))
        |> Enum.uniq()
      end

      @doc "The `root:` the manual was compiled from, absolute."
      @spec root() :: String.t()
      def root, do: @managoat_docs_root

      @doc "The directory the pages live in, absolute."
      @spec docs_dir() :: String.t()
      def docs_dir, do: @managoat_docs_dir

      @doc "The path the manual is served at."
      @spec mount() :: String.t()
      def mount, do: @managoat_docs_mount

      @doc """
      The languages whose tree-sitter parsers the image bakes in, for
      `Lumis.Languages.cache/1` in the Dockerfile before `mix release`. The
      `languages:` option, or `Managoat.Docs.Markdown.languages/0` without it.
      """
      @spec languages() :: [String.t()]
      def languages, do: @managoat_docs_languages
    end
  end
end
