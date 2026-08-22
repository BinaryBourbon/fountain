defmodule Fountain.Docs.Compiler do
  @moduledoc """
  Pure functions `Fountain.Docs` runs at compile time to turn the MkDocs
  dialect in `docs/` into plain markdown. Split out because a module cannot
  call its own functions from its own body — and so the transforms can be
  tested directly.

  Covers exactly the dialect the docs use (see the `Fountain.Docs` moduledoc):
  snippet includes, admonitions, and relative `.md` links. Not a general
  MkDocs renderer.
  """

  @doc ~S(`"index.md"` → `""`, `"integrations/index.md"` → `"integrations"`, else the rootname.)
  @spec slug_for(String.t()) :: String.t()
  def slug_for(file) do
    case Path.rootname(file) do
      "index" -> ""
      other -> String.replace_suffix(other, "/index", "")
    end
  end

  @doc """
  Parses the `nav:` block of `mkdocs.yml` into the shape `Fountain.Docs`
  serves: `{title, file}` for a page and `{section_title, [{title, file}, ...]}`
  for a section, in document order.

  Deliberately not a YAML parser, and it does not need to be — the nav is a
  hand-written two-level list, and this reads the two line shapes it can take.
  What matters is the failure mode: a line it does not recognise **raises**
  rather than being skipped. A page silently missing from `/docs` is exactly
  the bug this parser exists to make impossible, so being unable to parse the
  nav has to fail the compile, not shrink the site.

  Two levels is the whole depth. MkDocs nests as deep as you like; the in-app
  sidebar at `/docs` renders exactly a section and its pages, so a third tier
  raises here with a message that says to flatten it. That includes a page
  indented past its siblings, which would otherwise be quietly promoted into
  its grandparent section — the one silent outcome this parser must not have.

  This replaced a hand-maintained copy of the nav in `Fountain.Docs`. Adding a
  page to `mkdocs.yml` is now the whole change.
  """
  @spec parse_nav(String.t()) :: [{String.t(), String.t() | [{String.t(), String.t()}]}]
  def parse_nav(yaml) do
    case String.split(yaml, ~r/^nav:\n/m, parts: 2) do
      [_before, block] -> block |> nav_lines() |> Enum.reduce([], &nav_entry/2) |> finish_nav()
      _ -> raise ArgumentError, "mkdocs.yml has no `nav:` block"
    end
  end

  # The block runs until the first line that is neither blank nor indented —
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
      # `  - Setup: setup.md` — a top-level page.
      [_, indent, title, file] when byte_size(indent) == 2 ->
        [{title, file} | acc]

      # `  - Sandbox providers:` — a section header; its children follow.
      [_, indent, title] when byte_size(indent) == 2 ->
        [{title, [], nil} | acc]

      # `      - Sprites: integrations/sprites.md` — a child of the section
      # currently being built.
      [_, indent, title, file] when byte_size(indent) > 2 ->
        add_child(acc, byte_size(indent), title, file, line)

      # `      - Sandbox providers:` — a section inside a section, which this
      # parser has no shape for.
      [_, indent, _title] when byte_size(indent) > 2 ->
        raise ArgumentError, one_level_message("nested nav section", line)

      _ ->
        raise ArgumentError, "unparsed mkdocs.yml nav line: #{inspect(line)}"
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

  # The one thing a reader of either raise needs to know: the limit is ours,
  # not MkDocs', and flattening is the fix. Without this they go looking for a
  # typo in a line that is perfectly good YAML.
  defp one_level_message(what, line) do
    """
    #{what}: #{inspect(line)}

    mkdocs.yml nav sections are one level deep. MkDocs itself nests freely, but
    Fountain.Docs embeds the nav for the in-app sidebar at /docs, which renders
    exactly two levels. Flatten this into a sibling top-level section, or make
    it headings on a hub page.
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
  @spec flat_pages(list()) :: [{String.t(), String.t()}]
  def flat_pages(nav) do
    Enum.flat_map(nav, fn
      {_section, children} when is_list(children) -> children
      {title, file} -> [{title, file}]
    end)
  end

  @doc "Snippets, then admonitions, then link rewriting."
  @spec preprocess(String.t(), String.t(), String.t()) :: String.t()
  def preprocess(text, file, root) do
    text
    |> expand_snippets(root)
    |> rewrite_admonitions()
    |> rewrite_links(file)
  end

  # `--8<-- "FILE"` on its own line → the file's contents, read relative to
  # the repo root — matching the `pymdownx.snippets` base_path in mkdocs.yml.
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
  def rewrite_links(text, file) do
    dir = Path.dirname(file)

    Regex.replace(~r/\]\((?!https?:)([^)\s#]+\.md)(#[^)]*)?\)/, text, fn _, target, anchor ->
      slug =
        target
        |> Path.expand("/" <> dir)
        |> String.trim_leading("/")
        |> slug_for()

      "](#{path_for_slug(slug)}#{anchor})"
    end)
  end

  @doc ~S(`""` → `"/docs"`, `"setup"` → `"/docs/setup"`.)
  @spec path_for_slug(String.t()) :: String.t()
  def path_for_slug(""), do: "/docs"
  def path_for_slug(slug), do: "/docs/" <> slug
end
