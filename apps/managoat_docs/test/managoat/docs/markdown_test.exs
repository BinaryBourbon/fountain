defmodule Managoat.Docs.MarkdownTest do
  use ExUnit.Case, async: true

  alias Managoat.Docs.Markdown

  describe "to_html/1 — safe URLs pass through" do
    test "https, http and mailto links survive" do
      html = Markdown.to_html("[a](https://x.com) [b](http://x.com) [c](mailto:a@b.c)")
      assert html =~ ~s(href="https://x.com")
      assert html =~ ~s(href="http://x.com")
      assert html =~ ~s(href="mailto:a@b.c")
    end

    test "relative and fragment links survive" do
      html = Markdown.to_html("[a](/docs) [b](docs/page.md) [c](#section) [d](?q=a:b)")
      assert html =~ ~s(href="/docs")
      assert html =~ ~s(href="docs/page.md")
      assert html =~ ~s(href="#section")
      assert html =~ ~s(href="?q=a:b")
    end

    test "a colon later in a relative path is not treated as a scheme" do
      html = Markdown.to_html("[a](/search?q=foo:bar)")
      assert html =~ ~s(href="/search?q=foo:bar")
    end

    test "http images survive" do
      html = Markdown.to_html("![i](https://x.com/i.png)")
      assert html =~ ~s(src="https://x.com/i.png")
    end

    # safe_url?/2 is an allowlist, so normalization is only *observable* in
    # the allow direction: JAVASCRIPT: is off the allowlist with or without
    # the downcase, but HTTPS: is on it only because of the downcase. These
    # are the tests that fail if normalize/1 loses a step (#406).

    test "case-folding is for the check only: uppercase safe schemes keep their href" do
      assert Markdown.to_html("[x](HTTPS://x.com)") =~ ~s(href="HTTPS://x.com")
      assert Markdown.to_html("[x](MailTo:a@b.c)") =~ ~s(href="MailTo:a@b.c")
    end

    test "whitespace stripping is for the check only: a ref-encoded tab inside a safe scheme keeps the href" do
      # Browsers strip tabs anywhere in a URL, so an href of ht&#9;tps://…
      # is a live https link and must survive. Without the strip the scheme
      # normalizes to "ht\ttps" — off the allowlist — and a safe link dies.
      assert Markdown.to_html("[x](ht&#9;tps://x.com)") =~ "href"
    end
  end

  describe "to_html/1 — unsafe URLs are dropped" do
    test "javascript: links lose their href but keep their text" do
      html = Markdown.to_html("[click](javascript:alert&#40;1&#41;)")
      refute html =~ "javascript"
      refute html =~ "href"
      assert html =~ "click"
    end

    test "uppercase and mixed-case schemes are caught" do
      refute Markdown.to_html("[x](JAVASCRIPT:alert(1))") =~ "href"
      refute Markdown.to_html("[x](JaVaScRiPt:alert(1))") =~ "href"
    end

    test "numeric character references cannot smuggle a scheme" do
      # &#106; = j, &#x6A; = j, &colon; = :
      refute Markdown.to_html("[x](&#106;avascript:alert(1))") =~ "href"
      refute Markdown.to_html("[x](&#x6A;avascript:alert(1))") =~ "href"
      refute Markdown.to_html("[x](javascript&colon;alert(1))") =~ "href"
    end

    test "double-encoded references cannot smuggle a scheme" do
      refute Markdown.to_html("[x](javascript&amp;colon;alert(1))") =~ "href"
    end

    test "embedded whitespace cannot split the scheme" do
      # Deny-direction: these are dropped with or without the whitespace
      # strip ("java\tscript" is off the allowlist either way). The second
      # line pins char-ref decoding: undecoded, "&#9;javascript" contains
      # "#" and would be classified relative — and *kept*. The strip itself
      # is pinned by the allow-direction test above.
      refute Markdown.to_html("[x](java\tscript:alert(1))") =~ "href"
      refute Markdown.to_html("[x](&#9;javascript:alert(1))") =~ "href"
    end

    test "data: and vbscript: links are dropped" do
      refute Markdown.to_html("[x](data:text/html;base64,PHNjcmlwdD4=)") =~ "href"
      refute Markdown.to_html("[x](vbscript:msgbox)") =~ "href"
    end

    test "data: image sources are dropped, leaving the alt text" do
      html = Markdown.to_html("![diagram](data:image/svg+xml;base64,AAAA)")
      refute html =~ "src"
      refute html =~ "<img"
      assert html =~ "diagram"
    end

    test "mailto is not an allowed image scheme" do
      refute Markdown.to_html("![i](mailto:a@b.c)") =~ "src"
    end
  end

  describe "to_html/1 — raw HTML is neutralized" do
    test "block-level script tags are escaped, not emitted verbatim" do
      # A plain markdown-to-HTML call passes block-level raw HTML through
      # unescaped: this was live XSS from agent output before Fountain #323.
      html = Markdown.to_html("<script>alert(1)</script>")
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "block-level event-handler HTML is escaped" do
      html = Markdown.to_html("para\n\n<img src=x onerror=alert(1)>\n\nend")
      refute html =~ "<img"
      assert html =~ "&lt;img"
    end

    test "block-level HTML with nested elements and attributes is escaped" do
      html = Markdown.to_html(~s(<div class="x"><span onclick=x>hi</span></div>))
      refute html =~ "<div"
      refute html =~ "<span"
      assert html =~ "&lt;div"
      assert html =~ "hi"
    end

    test "inline HTML stays escaped" do
      html = Markdown.to_html("text <b onclick=x>bold</b> end")
      refute html =~ "<b "
      assert html =~ "&lt;b"
    end

    test "ordinary markdown renders" do
      html = Markdown.to_html("# Title\n\nSome **bold** text")
      assert html =~ "<h1>"
      assert html =~ "<strong>"
    end

    test "GFM tables and strikethrough render" do
      html = Markdown.to_html("| a | b |\n|---|---|\n| 1 | ~~2~~ |")
      assert html =~ "<table>"
      assert html =~ "<td>1</td>"
      assert html =~ "<del>2</del>"
    end

    test "an HTML comment block is dropped, not shown as text" do
      html = Markdown.to_html("before\n\n<!-- authored note -->\n\nafter")
      refute html =~ "authored note"
      assert html =~ "<p>before</p>"
      assert html =~ "<p>after</p>"
    end

    test "markup trailing a comment on the same line is still escaped" do
      html = Markdown.to_html("<!-- x --><script>alert(1)</script>")
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "non-binary input renders as empty" do
      assert Markdown.to_html(nil) == ""
      assert Markdown.to_html(123) == ""
    end
  end

  describe "to_trusted_html/1 — the docs corpus keeps a sanitized SVG subset" do
    test "a clean figure/svg block renders as real markup, not escaped text" do
      md = ~s|intro

<figure>
<svg viewBox="0 0 10 10"><rect fill="#b3760f"/><text fill="currentColor">hi</text></svg>
<figcaption>cap</figcaption>
</figure>

end|
      html = Markdown.to_trusted_html(md)

      assert html =~ ~s|<svg viewBox="0 0 10 10">|
      assert html =~ ~s|<rect fill="#b3760f"/>|
      assert html =~ "<figcaption>cap</figcaption>"
      refute html =~ "&lt;svg"
    end

    test "script, style and foreignObject are stripped from a trusted svg" do
      md =
        ~s|<figure><svg><script>alert(1)</script><style>x{}</style><foreignObject><b>y</b></foreignObject><rect/></svg></figure>|

      html = Markdown.to_trusted_html(md)

      refute html =~ "<script"
      refute html =~ "<style"
      refute html =~ "foreignObject"
      assert html =~ "<rect/>"
    end

    test "event handlers and javascript/data URLs are stripped from a trusted svg" do
      md =
        ~s|<figure><svg onload="steal()"><a xlink:href="javascript:alert(1)">x</a><image href="data:text/html,evil"/></svg></figure>|

      html = Markdown.to_trusted_html(md)

      refute html =~ "onload"
      refute html =~ "javascript:"
      refute html =~ "data:text/html"
      assert html =~ "<svg>"
    end

    test "raw HTML that is not a figure/svg is still neutralized on the trusted path" do
      html = Markdown.to_trusted_html("para\n\n<img src=x onerror=alert(1)>\n\nend")

      refute html =~ "<img"
      assert html =~ "&lt;img"
    end

    test "headings carry GFM-style ids so #anchor links resolve" do
      html = Markdown.to_trusted_html("## Back up `MASTER_SECRETS_KEY`\n\n## Crons: alerting")
      assert html =~ ~s(<h2 id="back-up-master_secrets_key">)
      assert html =~ ~s(<h2 id="crons-alerting">)
      # comrak also emits GitHub's self-link inside the heading; it is empty
      # and invisible, but pin its shape so a change shows up here.
      assert html =~ ~s(<a href="#crons-alerting" aria-label="Link to heading 'Crons: alerting'")
    end

    test "the untrusted path emits no heading ids" do
      refute Markdown.to_html("## Title") =~ "id="
    end

    test "an HTML comment block is dropped on the trusted path too" do
      html =
        Markdown.to_trusted_html("<!-- The changelog lives in the repo root -->\n\n# Changelog")

      refute html =~ "changelog lives"
      assert html =~ ~s(<h1 id="changelog">Changelog)
    end

    test "the untrusted path never renders svg, even the same clean block" do
      md = ~s|<figure><svg><rect fill="#000"/></svg></figure>|
      html = Markdown.to_html(md)

      refute html =~ "<svg>"
      assert html =~ "&lt;svg&gt;"
    end

    test "non-binary input renders as empty" do
      assert Markdown.to_trusted_html(nil) == ""
    end
  end

  describe "to_trusted_html/1 — fenced code is highlighted" do
    test "a labelled fence is coloured and keeps its language" do
      html = Markdown.to_trusted_html("```elixir\ndef run(x), do: x\n```")

      assert html =~ ~s(class="language-elixir")
      assert html =~ "style=\"color:"
      assert html =~ "run"
    end

    test "an unlabelled fence still renders, as plaintext" do
      html = Markdown.to_trusted_html("```\njust some output\n```")

      assert html =~ ~s(class="language-plaintext")
      assert html =~ "just some output"
    end

    test "an unknown language falls back rather than dropping the block" do
      html = Markdown.to_trusted_html("```notalanguage\nkeep me\n```")

      assert html =~ "keep me"
    end

    test "an info string with more than a language uses the first word" do
      html = Markdown.to_trusted_html(~s(```bash title="setup"\necho hi\n```))

      assert html =~ ~s(class="language-bash")
    end

    test "the closing fence does not leave a trailing blank line" do
      html = Markdown.to_trusted_html("```ts\nconst x = 1;\n```")

      assert html =~ ~s(data-line="1")
      refute html =~ ~s(data-line="2")
    end

    test "code is escaped, so a fence cannot break out of its own block" do
      html = Markdown.to_trusted_html("```html\n</code></pre><script>alert(1)</script>\n```")

      # The highlighter colours per token, so the escaped source arrives split
      # across spans — what matters is that no live tag is emitted and the
      # block is still a single <pre>.
      refute html =~ "<script"
      assert html =~ "&lt;"
      assert html =~ "alert"
      assert length(String.split(html, "<pre")) == 2
    end

    test "the untrusted path leaves code blocks unhighlighted" do
      html = Markdown.to_html("```elixir\ndef run(x), do: x\n```")

      assert html =~ ~s(<code class="language-elixir">)
      refute html =~ "style=\"color:"
    end
  end

  describe "languages/0" do
    test "every default language name is one Lumis knows, by id" do
      ids = MapSet.new(Lumis.available_languages(), & &1.id)

      for name <- Markdown.languages() do
        assert MapSet.member?(ids, name),
               "#{name} is not a Lumis language id; a host's Dockerfile cache step would fail"
      end
    end
  end
end
