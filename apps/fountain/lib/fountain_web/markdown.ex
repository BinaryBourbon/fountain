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

  alias MDEx.{CodeBlock, Document, HtmlBlock, HtmlInline, Image, Link, Paragraph, Text}

  @extension [table: true, strikethrough: true, tasklist: true]

  # Syntax highlighting theme for fenced code on the trusted path. Its near-black
  # background (#0a0c10) is within a hair of the console's `--color-code-bg`, so
  # a highlighted block sits on the same ground as the log viewer's.
  @theme "github_dark_high_contrast"

  # Lumis fetches a language's tree-sitter parser from a CDN the first time it
  # sees one and caches it under its own `priv/`. A release can do neither: the
  # deployment runs with `readOnlyRootFilesystem: true`, so the first request
  # for a highlighted block fails to load the parser and the code renders
  # plain — which is exactly what shipped in #879 and reached production.
  #
  # So the parsers are baked into the image instead: the Dockerfile caches this
  # list into `deps/lumis/priv/lumis` before `mix release`, which copies it in
  # like any other dependency's priv. Nothing is fetched at runtime.
  #
  # `markdown_test.exs` fails if the docs corpus grows a fence in a language
  # this list does not name — a highlighter that quietly degrades is worse than
  # one that is off, because nobody notices. Its `@unhighlightable` names the
  # fences exempt from that rule, and why each one cannot be baked.
  #
  # `python` and `javascript` joined the list with the webhooks reference
  # (#700), which carries a signature verifier in each. A receiver author
  # reading an unhighlighted wall of HMAC code is the case this guard exists
  # for. `toml` joined with the Fly guide, which is the first page here to
  # quote a `fly.toml`; `ini` is a near miss for it and highlights the wrong
  # things, so the fence names the real language and this list grew instead.
  @languages ~w(bash typescript javascript python json json5 yaml toml elixir ini)

  @doc """
  The languages whose parsers are baked into the image — see `@languages`.

  Called by the Dockerfile, before `mix release`.
  """
  def languages, do: @languages

  @doc """
  Renders untrusted markdown to HTML with raw HTML neutralized and unsafe
  link/image URLs removed.
  """
  def to_html(text) when is_binary(text) do
    # No syntax highlighting here: untrusted input gets the smallest renderer
    # surface that does the job, and agent output is read as prose, not code.
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

  Fenced code is syntax highlighted here too, for the same reason: the fences
  are authored, and a docs page whose whole job is showing code should show it
  highlighted.

  This is only ever fed authored documentation. Never pass agent- or
  user-supplied markdown here; use `to_html/1` for that.
  """
  def to_trusted_html(text) when is_binary(text) do
    # `unsafe: true` is what lets the kept figure/svg block through; every
    # other raw-HTML node has already been turned into text by the walk.
    # `header_id_prefix` gives every heading a GFM-style id (plus GitHub's
    # empty self-link) so the docs' `#anchor` cross-links resolve (#765).
    # `docs_test.exs` checks every one of them against these ids. Trusted path
    # only: ids on agent output would be surface with no reader.
    render(text, &trusted_nodes/1, [header_id_prefix: ""], unsafe: true)
  end

  def to_trusted_html(_), do: ""

  defp trusted_nodes(nodes), do: nodes |> sanitize_trusted() |> highlight_code()

  # `sanitizer` is `&sanitize/1` (untrusted) or `&trusted_nodes/1` (the docs
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

  # --- trusted docs corpus: fenced code, highlighted ---
  #
  # MDEx can highlight during rendering, but only through a build of its NIF
  # that bundles every tree-sitter grammar — 147 MB unpacked, against 12 MB for
  # calling Lumis directly. So the walk swaps each code block for the
  # highlighter's own markup instead.
  #
  # `:html_inline` writes the colours as `style` attributes rather than class
  # names, so no stylesheet has to be kept in step with the theme; the CSP
  # allows inline styles (`style-src 'self' 'unsafe-inline'`). Lumis escapes
  # the source it is given, and this runs on the trusted path only — but the
  # result is still raw HTML, so an unknown language or a highlighter error
  # leaves the code block exactly as comrak parsed it.
  defp highlight_code(nodes) when is_list(nodes), do: Enum.map(nodes, &highlight_code/1)

  defp highlight_code(%CodeBlock{literal: source, info: info} = block) do
    opts = [formatter: {:html_inline, theme: @theme, language: language(info)}]

    # Comrak keeps the fence's closing newline; Lumis would render it as a
    # trailing blank line inside every block.
    case Lumis.highlight(String.trim_trailing(source, "\n"), opts) do
      {:ok, html} -> %HtmlBlock{literal: html}
      {:error, _} -> block
    end
  end

  defp highlight_code(%{nodes: children} = node), do: %{node | nodes: highlight_code(children)}

  defp highlight_code(other), do: other

  # An info string can carry more than the language (```bash title="x"), and
  # an empty one means an unlabelled fence — plaintext, which still gets the
  # theme's background and foreground.
  defp language(info) when is_binary(info) do
    case String.split(info, ~r/\s+/, parts: 2) do
      ["" | _] -> "plaintext"
      [lang | _] -> lang
    end
  end

  defp language(_), do: "plaintext"

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
