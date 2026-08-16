defmodule FountainWeb.Markdown do
  @moduledoc """
  Markdown → HTML for untrusted input (agent output), rendered through
  [MDEx](https://hexdocs.pm/mdex) (comrak) with two holes closed that a plain
  markdown-to-HTML call leaves open (#323):

  1. Raw HTML — an agent emitting `<img src=x onerror=...>` as its own
     paragraph must not become live markup.
  2. Markdown link/image syntax accepts any URL scheme —
     `[x](javascript:...)` must not render as a live link.

  `to_html/1` walks the parsed document before rendering: every raw-HTML node
  (block and inline) is replaced by a text node carrying its source, so the
  renderer escapes it and the HTML displays as text rather than executing.
  Links and images are dropped unless their URL scheme is on the allowlist —
  http/https/mailto for links, http/https for images, relative URLs for both
  — and a dropped link or image is unwrapped to its text/alt so the content
  still reads. The untrusted path additionally renders with comrak's
  `unsafe: false` + `escape: true`, so even a raw-HTML node the walk missed
  would be escaped rather than emitted.

  Scheme checks run on a normalized copy of the URL: character references
  decoded and the whitespace/control characters browsers ignore stripped, so
  `java&#115;cript:` or `java\\tscript:` cannot smuggle a scheme past the
  check. Normalization is deliberately generous — over-decoding can only
  make the filter stricter.
  """

  alias MDEx.{Document, HtmlBlock, HtmlInline, Image, Link, Paragraph, Text}

  @extension [table: true, strikethrough: true, tasklist: true]

  @doc """
  Renders untrusted markdown to HTML with raw HTML neutralized and unsafe
  link/image URLs removed.
  """
  def to_html(text) when is_binary(text) do
    render(text, &sanitize/1, [], unsafe: false, escape: true)
  end

  def to_html(_), do: ""

  @doc """
  Renders **trusted** markdown (the in-repo docs corpus, compiled from
  `docs/*.md` and reviewed in a PR) exactly like `to_html/1`, with one
  addition: a `<figure>`/`<svg>` block is kept as real markup so hand-authored
  diagrams render, after scrubbing the script-bearing subset (`<script>`,
  `<style>`, `<foreignObject>`, `on*` handlers, and `javascript:`/`data:`/
  `vbscript:` URLs). Everything else — every other raw-HTML block — is still
  neutralized to text, and the untrusted `to_html/1` path is untouched.

  This is only ever fed authored documentation. Never pass agent- or
  user-supplied markdown here; use `to_html/1` for that.
  """
  def to_trusted_html(text) when is_binary(text) do
    # `unsafe: true` is what lets the kept figure/svg block through; every
    # other raw-HTML node has already been turned into text by the walk.
    # `header_id_prefix` gives every heading a GFM-style id (plus GitHub's
    # empty self-link) so the docs' `#anchor` cross-links resolve in-app the
    # way they do on the MkDocs site (#765). Trusted path only: ids on agent
    # output would be surface with no reader.
    render(text, &sanitize_trusted/1, [header_id_prefix: ""], unsafe: true)
  end

  def to_trusted_html(_), do: ""

  # `sanitizer` is `&sanitize/1` (untrusted) or `&sanitize_trusted/1` (the docs
  # corpus). Each recurses through its own direct capture rather than
  # threading the mode as a parameter, which keeps Dialyzer's success typing of
  # the recursive walk intact.
  defp render(text, sanitizer, extra_extensions, render_opts) do
    extension = @extension ++ extra_extensions

    case MDEx.parse_document(text, extension: extension) do
      {:ok, %Document{nodes: nodes} = doc} ->
        MDEx.to_html!(%{doc | nodes: sanitizer.(nodes)},
          extension: extension,
          render: render_opts
        )

      # comrak does not fail on markdown input; this is a defensive fallback
      # that still never emits the input as markup.
      {:error, _} ->
        text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
    end
  end

  # --- untrusted: every raw-HTML node is neutralized to text (#323) ---

  defp sanitize(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &sanitize/1)

  defp sanitize(%HtmlBlock{literal: literal}), do: neutralize_block(literal)
  defp sanitize(%HtmlInline{literal: literal}), do: neutralize_inline(literal)

  defp sanitize(%Link{url: url, nodes: children} = link) do
    keep_or_unwrap(link, url, ~w(http https mailto), sanitize(children))
  end

  defp sanitize(%Image{url: url, nodes: children} = image) do
    keep_or_unwrap(image, url, ~w(http https), sanitize(children))
  end

  defp sanitize(%{nodes: children} = node), do: [%{node | nodes: sanitize(children)}]

  # Leaf nodes: text, code, breaks…
  defp sanitize(other), do: [other]

  # --- trusted docs corpus: identical, except a <figure>/<svg> block is kept
  # as real markup after scrubbing its script-bearing subset ---

  defp sanitize_trusted(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &sanitize_trusted/1)

  # The one difference from `sanitize/1`: a figure/svg block is kept (its raw
  # source scrubbed) so the renderer emits the diagram into the DOM.
  defp sanitize_trusted(%HtmlBlock{literal: literal} = block) do
    if String.match?(literal, ~r/\A\s*<(figure|svg)\b/i),
      do: [%{block | literal: scrub_svg(literal)}],
      else: neutralize_block(literal)
  end

  defp sanitize_trusted(%HtmlInline{literal: literal}), do: neutralize_inline(literal)

  defp sanitize_trusted(%Link{url: url, nodes: children} = link) do
    keep_or_unwrap(link, url, ~w(http https mailto), sanitize_trusted(children))
  end

  defp sanitize_trusted(%Image{url: url, nodes: children} = image) do
    keep_or_unwrap(image, url, ~w(http https), sanitize_trusted(children))
  end

  defp sanitize_trusted(%{nodes: children} = node),
    do: [%{node | nodes: sanitize_trusted(children)}]

  defp sanitize_trusted(other), do: [other]

  # A raw-HTML block becomes a paragraph of text — the renderer escapes text
  # nodes, so the source displays instead of executing. A block that is
  # nothing but HTML comments is dropped: authored notes such as the one at
  # the top of CHANGELOG.md are not content, and a comment carries nothing to
  # neutralize. Anything trailing a comment on the same line (comrak folds it
  # into the same block) fails the whole-literal match and is escaped.
  defp neutralize_block(literal) do
    if comment_only?(literal),
      do: [],
      else: [%Paragraph{nodes: [%Text{literal: String.trim_trailing(literal, "\n")}]}]
  end

  defp neutralize_inline(literal) do
    if comment_only?(literal), do: [], else: [%Text{literal: literal}]
  end

  defp comment_only?(literal), do: String.match?(literal, ~r/\A(\s*<!--.*?-->)+\s*\z/s)

  # A link/image with a safe URL is kept (children already sanitized); one
  # with an unsafe URL is unwrapped to its children so the text/alt still
  # reads without any element carrying the URL.
  defp keep_or_unwrap(node, url, allowed_schemes, children) do
    if safe_url?(url, allowed_schemes), do: [%{node | nodes: children}], else: children
  end

  # Belt-and-suspenders scrub of an authored SVG block: the corpus is trusted,
  # but the executable surface is removed anyway so a bad paste can't become
  # live script. Element removals run before the on*/URL passes so their
  # contents cannot re-introduce a handler.
  defp scrub_svg(str) do
    str
    |> drop_elements(~w(script style foreignObject))
    |> String.replace(~r/\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)/i, "")
    |> String.replace(
      ~r/(href|xlink:href|src)\s*=\s*("(?:javascript|data|vbscript):[^"]*"|'(?:javascript|data|vbscript):[^']*')/i,
      ""
    )
  end

  defp drop_elements(str, tags) do
    Enum.reduce(tags, str, fn tag, acc ->
      acc
      |> String.replace(~r/<#{tag}\b[^>]*>.*?<\/#{tag}\s*>/is, "")
      |> String.replace(~r/<#{tag}\b[^>]*\/?>/is, "")
    end)
  end

  defp safe_url?(url, allowed_schemes) do
    normalized = normalize(url)

    case String.split(normalized, ":", parts: 2) do
      [_no_scheme] ->
        true

      [scheme, _rest] ->
        # A ":" after a path/query/fragment delimiter is not a scheme
        # separator (e.g. "/docs?q=a:b" or "#sec:1" are relative).
        String.contains?(scheme, ["/", "?", "#"]) or scheme in allowed_schemes
    end
  end

  defp normalize(url) do
    url
    |> decode_char_refs()
    # Browsers strip tab/CR/LF anywhere in a URL and ignore leading control
    # characters and spaces, so the check must too.
    |> String.replace(~r/[\x00-\x20]/, "")
    |> String.downcase()
  end

  # Decodes numeric character references (&#106; / &#x6A;) and the handful of
  # named ones that could obfuscate a scheme. Two passes, so a reference that
  # decodes into another reference (&amp;#58;) cannot survive normalization.
  defp decode_char_refs(url) do
    url |> decode_pass() |> decode_pass()
  end

  defp decode_pass(url) do
    Regex.replace(~r/&(?:#x([0-9a-f]+)|#([0-9]+)|([a-z]+));?/i, url, fn whole, hex, dec, named ->
      cond do
        hex != "" -> codepoint(String.to_integer(hex, 16))
        dec != "" -> codepoint(String.to_integer(dec))
        true -> named_ref(String.downcase(named), whole)
      end
    end)
  end

  defp codepoint(n) when n > 0 and n < 0x110000 and not (n >= 0xD800 and n <= 0xDFFF),
    do: <<n::utf8>>

  defp codepoint(_), do: ""

  @named_refs %{
    "colon" => ":",
    "sol" => "/",
    "amp" => "&",
    "tab" => "\t",
    "newline" => "\n",
    "num" => "#",
    "quest" => "?"
  }

  defp named_ref(name, whole), do: Map.get(@named_refs, name, whole)
end
