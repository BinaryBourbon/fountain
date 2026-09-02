defmodule Managoat.Docs.Compiler do
  @moduledoc """
  Pure functions `use Managoat.Docs` runs at compile time to turn the
  authoring dialect of a manual into plain markdown. Split out because a
  module cannot call its own functions from its own body, and so the
  transforms can be tested directly.

  Covers exactly the dialect a manual may use (see the `Managoat.Docs`
  moduledoc): snippet includes, admonitions, and relative `.md` links. The
  syntax is inherited from the MkDocs Material site Fountain's pages were
  published as until they moved in-app; this is not, and never was, a
  general MkDocs renderer.

  Every function that produces a served path takes the manual's `mount`
  (`"/docs"` for a manual served at `/docs`), because the only place that
  path is known is the host's `use` line.
  """

  @typedoc "`{title, file}` for a page, `{section_title, [{title, file}]}` for a section."
  @type nav_entry :: {String.t(), String.t() | [{String.t(), String.t()}]}

  @typedoc "One compiled page: its nav title and its preprocessed markdown."
  @type page :: %{title: String.t(), body: String.t()}

  @typedoc "One search-index entry: the page and the `h2`-`h6` headings on it."
  @type index_entry :: %{
          title: String.t(),
          slug: String.t(),
          headings: [%{id: String.t(), text: String.t()}]
        }

  @doc ~S(`"index.md"` → `""`, `"integrations/index.md"` → `"integrations"`, else the rootname.)
  @spec slug_for(String.t()) :: String.t()
  def slug_for(file) do
    case Path.rootname(file) do
      "index" -> ""
      other -> String.replace_suffix(other, "/index", "")
    end
  end

  @doc """
  Parses the `nav:` block of a `nav.yml` into the shape `use Managoat.Docs`
  serves: `{title, file}` for a page and `{section_title, [{title, file}, ...]}`
  for a section, in document order.

  Deliberately not a YAML parser, and it does not need to be: the nav is a
  hand-written two-level list, and this reads the two line shapes it can take.
  What matters is the failure mode: a line it does not recognise **raises**
  rather than being skipped. A page silently missing from the manual is
  exactly the bug this parser exists to make impossible, so being unable to
  parse the nav has to fail the compile, not shrink the site.

  Two levels is the whole depth. A sidebar that embeds this nav renders
  exactly a section and its pages, so a third tier raises here with a message
  that says to flatten it. That includes a page indented past its siblings,
  which would otherwise be quietly promoted into its grandparent section, the
  one silent outcome this parser must not have.

  This replaced a hand-maintained copy of the nav in Fountain's docs module.
  Adding a page to `nav.yml` is now the whole change.
  """
  @spec parse_nav(String.t()) :: [nav_entry()]
  def parse_nav(yaml) do
    case String.split(yaml, ~r/^nav:\n/m, parts: 2) do
      [_before, block] -> block |> nav_lines() |> Enum.reduce([], &nav_entry/2) |> finish_nav()
      _ -> raise ArgumentError, "nav.yml has no `nav:` block"
    end
  end

  # The block runs until the first line that is neither blank nor indented,
  # the next top-level key. Comments inside it are ignored rather than fatal.
  defp nav_lines(block) do
    block
    |> String.split("\n")
    |> Enum.take_while(&(&1 == "" or String.starts_with?(&1, " ")))
    |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(String.trim(&1), "#")))
  end

  # A section accumulates as `{title, reversed_children, child_indent}`; the
  # indent is remembered so a deeper line is caught rather than promoted, and
  # dropped again by `finish_nav/1`.
  defp nav_entry(line, acc) do
    case Regex.run(~r/^(\s+)- ([^:]+):\s*(\S+)?\s*$/, line) do
      # `  - Setup: setup.md`, a top-level page.
      [_, indent, title, file] when byte_size(indent) == 2 ->
        [{title, file} | acc]

      # `  - Sandbox providers:`, a section header; its children follow.
      [_, indent, title] when byte_size(indent) == 2 ->
        [{title, [], nil} | acc]

      # `      - Sprites: integrations/sprites.md`, a child of the section
      # currently being built.
      [_, indent, title, file] when byte_size(indent) > 2 ->
        add_child(acc, byte_size(indent), title, file, line)

      # `      - Sandbox providers:`, a section inside a section, which this
      # parser has no shape for.
      [_, indent, _title] when byte_size(indent) > 2 ->
        raise ArgumentError, one_level_message("nested nav section", line)

      _ ->
        raise ArgumentError, "unparsed nav.yml nav line: #{inspect(line)}"
    end
  end

  defp add_child([{section, children, indent} | rest], indent, title, file, _line) do
    [{section, [{title, file} | children], indent} | rest]
  end

  defp add_child([{section, children, nil} | rest], indent, title, file, _line) do
    [{section, [{title, file} | children], indent} | rest]
  end

  defp add_child([{_section, _children, _sibling_indent} | _rest], _indent, _title, _file, line) do
    raise ArgumentError, one_level_message("nav entry indented past its siblings", line)
  end

  defp add_child(_acc, _indent, _title, _file, line) do
    raise ArgumentError, "indented nav entry with no section above it: #{inspect(line)}"
  end

  # The one thing a reader of either raise needs to know: the limit is the
  # sidebar's, and flattening is the fix. Without this they go looking for a
  # typo in a line that is perfectly good YAML.
  defp one_level_message(what, line) do
    """
    #{what}: #{inspect(line)}

    nav.yml sections are one level deep. The manual embeds this nav for an
    in-app sidebar that renders exactly two levels. Flatten this into a
    sibling top-level section, or make it headings on a hub page.
    """
  end

  defp finish_nav(acc) do
    acc
    |> Enum.map(fn
      {section, children, _child_indent} -> {section, Enum.reverse(children)}
      entry -> entry
    end)
    |> Enum.reverse()
  end

  @doc "Flattens a nav (sections one level deep) to `{title, file}` pairs in order."
  @spec flat_pages([nav_entry()]) :: [{String.t(), String.t()}]
  def flat_pages(nav) do
    Enum.flat_map(nav, fn
      {_section, children} when is_list(children) -> children
      {title, file} -> [{title, file}]
    end)
  end

  @doc """
  Snippets, then admonitions, then link rewriting. `file` is the page's path
  relative to the docs directory (links resolve against its directory),
  `root` is where snippet includes are read from, and `mount:` is the path
  the manual is served at (default `"/docs"`).
  """
  @spec preprocess(String.t(), String.t(), String.t(), mount: String.t()) :: String.t()
  def preprocess(text, file, root, opts \\ []) do
    mount = Keyword.get(opts, :mount, "/docs")

    text
    |> expand_snippets(root)
    |> rewrite_admonitions()
    |> rewrite_links(file, mount)
  end

  # `--8<-- "FILE"` on its own line → the file's contents, read relative to
  # the root.
  #
  # sobelow_skip ["Traversal.FileModule"] — runs at compile time only, on
  # snippet paths written in repo-controlled markdown; there is no user input.
  @doc false
  def expand_snippets(text, root) do
    Regex.replace(~r/^--8<--\s+"([^"]+)"\s*$/m, text, fn _, path ->
      root |> Path.join(path) |> File.read!()
    end)
  end

  # `!!! note "Title"` + 4-space-indented body → a blockquote with a bold
  # title line. Fenced code at the top level is left alone; fences inside an
  # admonition body arrive indented, so they are consumed as body.
  @doc false
  def rewrite_admonitions(text) do
    text |> String.split("\n") |> admonition_lines(false) |> Enum.join("\n")
  end

  defp admonition_lines([], _in_fence), do: []

  defp admonition_lines([line | rest], in_fence) do
    cond do
      String.starts_with?(line, "```") ->
        [line | admonition_lines(rest, not in_fence)]

      in_fence ->
        [line | admonition_lines(rest, true)]

      match = Regex.run(~r/^!!!\s+(\w+)(?:\s+"([^"]*)")?\s*$/, line) ->
        title =
          case match do
            [_, type] -> String.capitalize(type)
            [_, _type, custom] -> custom
          end

        {body, remaining} = take_indented_body(rest, [])

        quoted =
          Enum.map(body, fn
            "" -> ">"
            content -> "> " <> content
          end)

        ["> **#{title}**", ">"] ++ quoted ++ [""] ++ admonition_lines(remaining, false)

      true ->
        [line | admonition_lines(rest, in_fence)]
    end
  end

  defp take_indented_body([line | rest] = lines, acc) do
    cond do
      String.trim(line) == "" ->
        take_indented_body(rest, ["" | acc])

      String.starts_with?(line, "    ") ->
        take_indented_body(rest, [String.slice(line, 4..-1//1) | acc])

      true ->
        {trim_trailing_blanks(acc), lines}
    end
  end

  defp take_indented_body([], acc), do: {trim_trailing_blanks(acc), []}

  defp trim_trailing_blanks(reversed_acc) do
    reversed_acc |> Enum.drop_while(&(&1 == "")) |> Enum.reverse()
  end

  # `[x](setup.md#backups)` → `[x](/docs/setup#backups)`, resolved against the
  # page's own directory so `../architecture.md` works from integrations/.
  @doc false
  def rewrite_links(text, file, mount) do
    dir = Path.dirname(file)

    Regex.replace(~r/\]\((?!https?:)([^)\s#]+\.md)(#[^)]*)?\)/, text, fn _, target, anchor ->
      slug =
        target
        |> Path.expand("/" <> dir)
        |> String.trim_leading("/")
        |> slug_for()

      "](#{path_for_slug(slug, mount)}#{anchor})"
    end)
  end

  @doc ~S(With mount `"/docs"`: `""` → `"/docs"`, `"setup"` → `"/docs/setup"`.)
  @spec path_for_slug(String.t(), String.t()) :: String.t()
  def path_for_slug("", mount), do: mount
  def path_for_slug(slug, mount), do: mount <> "/" <> slug

  @doc """
  Reads a nav file and every page it names into the shape `use Managoat.Docs`
  stores: the parsed nav, the `slug => page` map, and the search index over
  the rendered headings. Runs in the host module's body at compile time; the
  host declares every path here as an `@external_resource`.
  """
  @spec compile(String.t(), String.t(), String.t(), String.t()) :: %{
          nav: [nav_entry()],
          pages: %{String.t() => page()},
          search_index: [index_entry()]
        }
  def compile(root, docs_dir, nav_file, mount) do
    nav = nav_file |> File.read!() |> parse_nav()

    pages =
      Map.new(flat_pages(nav), fn {title, file} ->
        body = docs_dir |> Path.join(file) |> File.read!() |> preprocess(file, root, mount: mount)
        {slug_for(file), %{title: title, body: body}}
      end)

    # The client-side search index: one pass over the pages, done at compile
    # time like the rest. Headings only, not full text, since the embedded
    # bodies can run to hundreds of KB after snippet expansion and this index
    # has to be small enough to inline.
    #
    # Reuses `Managoat.Docs.Markdown.to_trusted_html/1`, the same rendering
    # the guardrails treat as ground truth for anchor ids, so a heading's id
    # here is guaranteed to be the id its own page renders, with no second
    # slugging pass to drift from it.
    search_index =
      for {slug, %{title: title, body: body}} <- pages do
        headings = body |> Managoat.Docs.Markdown.to_trusted_html() |> extract_headings()
        %{title: title, slug: slug, headings: headings}
      end

    %{nav: nav, pages: pages, search_index: search_index}
  end

  @doc """
  Pulls `{id, text}` for every `<h2>`–`<h6>` out of a page's **rendered**
  HTML, in document order. The input is `Managoat.Docs.Markdown.to_trusted_html/1`
  output, not markdown. `<h1>` is skipped; every page has exactly one, and it
  duplicates the nav title a search result already shows next to it.

  Reads the id comrak already assigned rather than re-deriving one from the
  heading text. Slugging headings a second time is a known trap: the MkDocs
  build Fountain's pages came from and comrak's `header_id_prefix`
  extension picked different ids for *duplicate* headings on the same page
  (`-1` vs `_1`), and a search result is only useful if its anchor is the one
  the page actually renders. The anchor guardrail leans on the same rendered
  output, for the same reason.
  """
  @spec extract_headings(String.t()) :: [%{id: String.t(), text: String.t()}]
  def extract_headings(html) do
    ~r/<h[2-6]([^>]*)>(.*?)<\/h[2-6]>/s
    |> Regex.scan(html)
    |> Enum.map(fn [_, attrs, inner] -> %{id: heading_id(attrs), text: heading_text(inner)} end)
    |> Enum.reject(&(&1.id == nil or &1.text == ""))
  end

  defp heading_id(attrs) do
    case Regex.run(~r/\sid="([^"]*)"/, attrs) do
      [_, id] -> id
      nil -> nil
    end
  end

  # Strips the inner markup a heading can carry (`## \`fountain apply\``
  # renders as `<code>` inside the `<h2>`) and unescapes the handful of
  # entities comrak emits in text content. Not a general HTML-entity decoder:
  # manual headings are plain prose plus inline code, and nothing needs more
  # than this (see the "small dialect" note in `Managoat.Docs`).
  #
  # `&amp;` is decoded **last**, and the order is load-bearing: a heading
  # holding a literal `&lt;` renders as `&amp;lt;`, so decoding the ampersand
  # first would leave `&lt;` for the next pass to turn into `<`, the one
  # thing the escaping was there to prevent.
  defp heading_text(inner) do
    inner
    |> String.replace(~r/<[^>]*>/s, "")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
    |> String.trim()
  end
end
