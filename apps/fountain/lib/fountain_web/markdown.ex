defmodule FountainWeb.Markdown do
  @moduledoc """
  Markdown → HTML for untrusted input (agent output), fixing two holes in a
  plain `Earmark.as_html/2` pipeline (#323):

  1. Block-level raw HTML passes through Earmark **unescaped** (inline HTML
     is escaped, block HTML is not) — so agent output containing
     `<img src=x onerror=...>` as its own paragraph was live XSS.
  2. Markdown link/image syntax accepts any URL scheme —
     `[x](javascript:...)` rendered as a live link.

  `to_html/1` renders through the Earmark AST: block-HTML (`verbatim`)
  nodes are re-serialized and emitted as text — `Earmark.Transform` escapes
  text nodes, so raw HTML displays as code rather than executing, matching
  how Earmark already treats inline HTML. Link/image URLs are dropped unless
  their scheme is on the allowlist — http/https/mailto for links, http/https
  for images, relative URLs for both. The element itself is kept so the text
  still reads; only the URL is removed.

  Scheme checks run on a normalized copy of the URL: character references
  decoded and the whitespace/control characters browsers ignore stripped, so
  `java&#115;cript:` or `java\\tscript:` cannot smuggle a scheme past the
  check. Normalization is deliberately generous — over-decoding can only
  make the filter stricter.
  """

  @doc """
  Renders untrusted markdown to HTML with raw HTML neutralized and unsafe
  link/image URLs removed.

  Both Earmark outcomes carry usable AST — the :error tuple still renders,
  just with warnings. There is deliberately no catch-all: as_ast/2 returns
  nothing else.
  """
  def to_html(text) when is_binary(text) do
    case Earmark.as_ast(text, smartypants: false) do
      {:ok, ast, _warnings} -> render(ast)
      {:error, ast, _warnings} -> render(ast)
    end
  end

  def to_html(_), do: ""

  defp render(ast) do
    ast
    |> sanitize()
    |> Earmark.transform(compact_output: true)
  end

  defp sanitize(nodes) when is_list(nodes), do: Enum.map(nodes, &sanitize/1)

  # Block-level raw HTML. Re-serialized to a plain string so Transform
  # escapes it as text instead of emitting it verbatim into the DOM.
  defp sanitize({_tag, _attrs, _children, %{verbatim: true}} = node), do: reserialize(node)

  defp sanitize({"a", attrs, children, meta}),
    do: {"a", filter_url(attrs, "href", ~w(http https mailto)), sanitize(children), meta}

  defp sanitize({"img", attrs, children, meta}),
    do: {"img", filter_url(attrs, "src", ~w(http https)), sanitize(children), meta}

  defp sanitize({tag, attrs, children, meta}), do: {tag, attrs, sanitize(children), meta}

  # Text nodes (escaped by Transform) and comment nodes.
  defp sanitize(other), do: other

  # Verbatim children are the raw source lines as strings; nested markup
  # arrives inside those strings, so joining them reconstructs the block.
  defp reserialize({tag, attrs, children, _meta}) do
    attrs_src = Enum.map_join(attrs, "", fn {k, v} -> ~s( #{k}="#{v}") end)
    open = "<#{tag}#{attrs_src}>"

    case children do
      [] -> open
      lines -> Enum.join([open | lines], "\n") <> "</#{tag}>"
    end
  end

  defp filter_url(attrs, name, allowed_schemes) do
    Enum.reject(attrs, fn
      {^name, url} -> not safe_url?(url, allowed_schemes)
      _ -> false
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
