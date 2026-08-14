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
