defmodule Managoat.Docs.CompilerTest do
  use ExUnit.Case, async: true

  alias Managoat.Docs.Compiler

  # A deliberately narrow parser for the two shapes a nav uses: `- Title:
  # file.md` entries at two indent levels and `- Title:` section headers.
  # Anything it does not recognise raises, which is the point: a new nav
  # shape needs a decision here, not silent skipping.
  describe "parse_nav/1" do
    test "a page and a section are told apart by indentation" do
      yaml = """
      nav:
        - Home: index.md
        - Section:
            - Child: a/b.md
        - Tail: t.md
      """

      assert Compiler.parse_nav(yaml) == [
               {"Home", "index.md"},
               {"Section", [{"Child", "a/b.md"}]},
               {"Tail", "t.md"}
             ]
    end

    test "blank lines and comments inside the block are ignored" do
      yaml = """
      nav:
        # a comment
        - Home: index.md

        - Tail: t.md
      extra:
      """

      assert Compiler.parse_nav(yaml) == [{"Home", "index.md"}, {"Tail", "t.md"}]
    end

    test "the block ends at the next top-level key" do
      yaml = """
      nav:
        - Home: index.md
      extra:
        - Not: a/page.md
      """

      assert Compiler.parse_nav(yaml) == [{"Home", "index.md"}]
    end

    test "an unparsable nav line raises rather than being dropped" do
      yaml = "nav:\n  - Home: index.md\n  this is not a nav entry\n"

      assert_raise ArgumentError, ~r{unparsed nav\.yml nav line}, fn ->
        Compiler.parse_nav(yaml)
      end
    end

    test "an indented entry with no section above it raises" do
      yaml = "nav:\n      - Orphan: a/b.md\n"

      assert_raise ArgumentError, ~r/no section above it/, fn ->
        Compiler.parse_nav(yaml)
      end
    end

    test "a section inside a section raises, naming the one-level limit" do
      yaml = """
      nav:
        - Section:
            - Subsection:
                - Child: a/b.md
      """

      assert_raise ArgumentError, ~r/sections are one level deep/, fn ->
        Compiler.parse_nav(yaml)
      end
    end

    test "a page indented past its siblings raises rather than being promoted" do
      yaml = """
      nav:
        - Section:
            - Child: a/b.md
                - Grandchild: a/c.md
      """

      assert_raise ArgumentError, ~r/sections are one level deep/, fn ->
        Compiler.parse_nav(yaml)
      end
    end

    test "a section's children may sit at any one indent, as long as it is one" do
      yaml = """
      nav:
        - Section:
          - First: a/b.md
          - Second: a/c.md
      """

      assert Compiler.parse_nav(yaml) ==
               [{"Section", [{"First", "a/b.md"}, {"Second", "a/c.md"}]}]
    end

    test "a file with no nav: block raises" do
      assert_raise ArgumentError, ~r/no `nav:` block/, fn ->
        Compiler.parse_nav("site_name: Fixture\n")
      end
    end

    test "flat_pages/1 flattens sections in order" do
      nav = [{"Home", "index.md"}, {"S", [{"A", "s/a.md"}, {"B", "s/b.md"}]}, {"T", "t.md"}]

      assert Compiler.flat_pages(nav) ==
               [{"Home", "index.md"}, {"A", "s/a.md"}, {"B", "s/b.md"}, {"T", "t.md"}]
    end
  end

  describe "slug_for/1" do
    test "strips .md and index" do
      assert Compiler.slug_for("index.md") == ""
      assert Compiler.slug_for("setup.md") == "setup"
      assert Compiler.slug_for("integrations/index.md") == "integrations"
      assert Compiler.slug_for("integrations/e2b.md") == "integrations/e2b"
    end
  end

  describe "path_for_slug/2" do
    test "the empty slug is the mount itself" do
      assert Compiler.path_for_slug("", "/docs") == "/docs"
      assert Compiler.path_for_slug("setup", "/docs") == "/docs/setup"
      assert Compiler.path_for_slug("a/b", "/manual") == "/manual/a/b"
    end
  end

  describe "rewrite_admonitions/1" do
    test "admonitions become blockquotes, custom title preferred" do
      md = """
      before

      !!! tip "In a hurry?"
          line one

          line two
      after
      """

      out = Compiler.rewrite_admonitions(md)
      assert out =~ "> **In a hurry?**\n>\n> line one\n>\n> line two\n\nafter"
      refute out =~ "!!!"
    end

    test "admonitions without a title use the capitalized type" do
      out = Compiler.rewrite_admonitions("!!! note\n    body\n")
      assert out =~ "> **Note**"
    end

    test "admonition-looking lines inside fences are left alone" do
      md = "```\n!!! note \"not one\"\n```\n"
      assert Compiler.rewrite_admonitions(md) == md
    end
  end

  describe "rewrite_links/3" do
    test "links resolve against the page's own directory" do
      assert Compiler.rewrite_links("[a](setup.md#backups)", "index.md", "/docs") ==
               "[a](/docs/setup#backups)"

      assert Compiler.rewrite_links(
               "[a](../architecture.md)",
               "integrations/sprites-contract.md",
               "/docs"
             ) ==
               "[a](/docs/architecture)"

      assert Compiler.rewrite_links("[a](index.md)", "integrations/e2b.md", "/docs") ==
               "[a](/docs/integrations)"

      assert Compiler.rewrite_links("[a](index.md)", "setup.md", "/docs") == "[a](/docs)"
    end

    test "the mount is whatever the host says it is" do
      assert Compiler.rewrite_links("[a](setup.md)", "index.md", "/manual") ==
               "[a](/manual/setup)"
    end

    test "absolute and anchor-only links are untouched" do
      md = "[a](https://example.com/x.md) [b](#section) [c](mailto:x@y.z)"
      assert Compiler.rewrite_links(md, "setup.md", "/docs") == md
    end
  end

  describe "preprocess/4" do
    test "expands snippets relative to root, then admonitions, then links" do
      root = Path.expand("../../..", __DIR__)

      md = """
      --8<-- "test/fixtures/snippets/CHANGELOG.md"

      !!! note
          See [setup](setup.md).
      """

      out = Compiler.preprocess(md, "index.md", root, mount: "/m")
      assert out =~ "## Unreleased"
      assert out =~ "> **Note**\n>\n> See [setup](/m/setup)."
    end

    test "the mount defaults to /docs" do
      root = Path.expand("../../..", __DIR__)
      assert Compiler.preprocess("[a](x.md)", "index.md", root) == "[a](/docs/x)"
    end
  end

  describe "extract_headings/1" do
    test "reads h2-h6 ids and text, skipping h1" do
      html = """
      <h1 id="page-title">Page title</h1>
      <p>intro</p>
      <h2 id="first-section">First section</h2>
      <p>body</p>
      <h3 id="a-sub-point">A sub-point</h3>
      """

      assert Compiler.extract_headings(html) == [
               %{id: "first-section", text: "First section"},
               %{id: "a-sub-point", text: "A sub-point"}
             ]
    end

    test "strips inline markup and decodes entities" do
      html = ~s(<h2 id="fountain-apply">Run <code>fountain apply</code> &amp; wait</h2>)

      assert Compiler.extract_headings(html) == [
               %{id: "fountain-apply", text: "Run fountain apply & wait"}
             ]
    end

    test "decodes an escaped entity once, not twice" do
      # A heading whose source holds a literal `&lt;` renders as `&amp;lt;`.
      # Decoding `&amp;` before `&lt;` would hand the second pass a live
      # `&lt;` and produce `<`: the escaping undone.
      html = ~s(<h2 id="entity">Write &amp;lt; to mean &amp;amp;</h2>)

      assert Compiler.extract_headings(html) == [
               %{id: "entity", text: "Write &lt; to mean &amp;"}
             ]
    end

    test "ignores a heading with no id" do
      assert Compiler.extract_headings("<h2>No id here</h2>") == []
    end

    test "tolerates extra attributes on the heading tag" do
      html = ~s(<h2 class="foo" id="bar" data-x="1">Text</h2>)
      assert Compiler.extract_headings(html) == [%{id: "bar", text: "Text"}]
    end
  end
end
