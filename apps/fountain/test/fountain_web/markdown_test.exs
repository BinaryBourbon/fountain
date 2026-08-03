defmodule FountainWeb.MarkdownTest do
  use ExUnit.Case, async: true

  alias FountainWeb.Markdown

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

    test "data: image sources are dropped" do
      html = Markdown.to_html("![i](data:image/svg+xml;base64,AAAA)")
      refute html =~ "src"
      assert html =~ "img"
    end

    test "mailto is not an allowed image scheme" do
      refute Markdown.to_html("![i](mailto:a@b.c)") =~ "src"
    end
  end

  describe "to_html/1 — raw HTML is neutralized" do
    test "block-level script tags are escaped, not emitted verbatim" do
      # Plain Earmark.as_html passes block-level raw HTML through unescaped —
      # this was live XSS from agent output before #323.
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

    test "non-binary input renders as empty" do
      assert Markdown.to_html(nil) == ""
      assert Markdown.to_html(123) == ""
    end
  end
end
