defmodule Fountain.DocsTest do
  @moduledoc """
  The embedded docs manual against `docs/nav.yml` and against itself.

  Since #1008 retired the GitHub Pages build, this file is the *whole*
  structural gate on `docs/`. `mkdocs build --strict` used to run on main and
  catch a relative link that did not resolve; nothing else renders these pages
  now, so the checks that replaced it live here: every page the nav names
  exists, every page on disk is in the nav, and every internal `/docs` link
  and anchor resolves. The anchor check is the one MkDocs never had.

  The preprocessing tests pin the small dialect the docs are allowed to use:
  if a page introduces syntax the compiler doesn't rewrite, the leftover-syntax
  checks catch it.
  """

  use ExUnit.Case, async: true

  alias Fountain.Docs
  alias Fountain.Docs.Compiler

  @repo_root Path.expand("../../../..", __DIR__)
  @dockerfile Path.join(@repo_root, "Dockerfile")

  describe "snippet includes ↔ Dockerfile" do
    @doc """
    `Fountain.Docs` inlines `--8<-- "path"` at *compile time*, reading from the
    repo root. Inside the image that root is whatever the Dockerfile COPYed, so
    a snippet pointing outside it does not degrade — `mix release` dies on
    `File.read!` and no image is produced at all. That is a silent failure in
    the worst place: CI is green, the PR merges, and the deploy simply never
    happens. It has happened once (docs/tour.md including the SDK example).
    """
    test "every snippet path is copied into the image" do
      copied =
        @dockerfile
        |> File.read!()
        |> then(&Regex.scan(~r/^COPY\s+(?!--)(\S+)\s+\S+$/m, &1))
        |> Enum.map(fn [_, source] -> source end)

      for {page, path} <- snippet_paths() do
        assert File.exists?(Path.join(@repo_root, path)),
               "#{page} includes #{path}, which does not exist"

        assert Enum.any?(copied, &covers?(&1, path)),
               """
               #{page} includes #{path}, which the Dockerfile does not COPY into
               the build stage. The docs are embedded at compile time, so this
               does not break a link — it breaks `mix release`, and no image is
               built. Add a COPY for it beside `COPY docs ./docs`.
               """
      end
    end

    @doc """
    The generalisation of the test above. Snippets are found by scanning
    markdown; this one asks the module itself what it read, so a *new kind* of
    compile-time dependency is covered without anyone remembering to extend a
    scanner. The nav file is the case that motivated it — it is parsed at
    compile time, and nothing about a snippet scan would ever have noticed it
    was missing from the Dockerfile. (It sat at the repo root as `mkdocs.yml`
    then, so it needed its own COPY; `docs/nav.yml` is inside `COPY docs`.)
    """
    test "every file Fountain.Docs reads at compile time is copied into the image" do
      copied = dockerfile_copies()

      for path <- external_resources() do
        assert File.exists?(Path.join(@repo_root, path)),
               "Fountain.Docs reads #{path}, which does not exist"

        assert Enum.any?(copied, &covers?(&1, path)),
               """
               Fountain.Docs reads #{path} at compile time, and the Dockerfile
               does not COPY it into the build stage. This does not break a
               link — it breaks `mix release`, so no image is built, CI stays
               green and the deploy never happens. Add a COPY for it beside
               `COPY docs ./docs`.
               """
      end
    end

    defp external_resources do
      :attributes
      |> Fountain.Docs.__info__()
      |> Keyword.get_values(:external_resource)
      |> List.flatten()
      |> Enum.map(&to_string/1)
      |> Enum.map(&Path.relative_to(&1, @repo_root))
      |> Enum.uniq()
    end

    defp dockerfile_copies do
      @dockerfile
      |> File.read!()
      |> then(&Regex.scan(~r/^COPY\s+(?!--)(\S+)\s+\S+$/m, &1))
      |> Enum.map(fn [_, source] -> source end)
    end

    defp snippet_paths do
      Path.join(@repo_root, "docs/**/*.md")
      |> Path.wildcard()
      |> Enum.flat_map(fn file ->
        ~r/^--8<--\s+"([^"]+)"\s*$/m
        |> Regex.scan(File.read!(file))
        |> Enum.map(fn [_, path] -> {Path.relative_to(file, @repo_root), path} end)
      end)
    end

    # `COPY docs ./docs` covers `docs/x.md`; `COPY CHANGELOG.md ./` covers itself.
    defp covers?(source, path) do
      path == source or String.starts_with?(path, source <> "/")
    end
  end

  describe "nav ← docs/nav.yml" do
    @doc """
    The nav is parsed from docs/nav.yml rather than mirrored in Elixir, so there
    is no longer a drift test to write — drift is unrepresentable. What is
    worth pinning is the parser's contract, and above all that it REFUSES a
    line it does not understand. Silently dropping one would quietly shrink
    /docs, which is the failure this whole arrangement exists to prevent.
    """
    test "parses the real docs/nav.yml into pages and one-level sections" do
      nav = Docs.nav_source()

      assert {"Home", "index.md"} in nav
      assert {"Setup", "setup.md"} in nav

      assert {"Sandbox providers", children} =
               Enum.find(nav, &match?({"Sandbox providers", _}, &1))

      assert {"Sprites", "integrations/sprites.md"} in children
    end

    test "keeps docs/nav.yml's order" do
      titles = Enum.map(Docs.nav_source(), &elem(&1, 0))
      assert Enum.take(titles, 3) == ["Home", "Guided tour, a pull request", "Concepts"]
      assert List.last(titles) == "Changelog"
    end

    # The tutorial sits second and the concepts tree third, ahead of every
    # reference page. It was position 15 of 34 and unlinked from the home page,
    # so a newcomer met three reference pages before the lesson.
    test "the tutorial and the concepts tree come before reference" do
      titles = Enum.map(Docs.nav_source(), &elem(&1, 0))

      tour = Enum.find_index(titles, &(&1 == "Guided tour, a pull request"))
      concepts = Enum.find_index(titles, &(&1 == "Concepts"))
      reference = Enum.find_index(titles, &(&1 == "Reference"))

      assert tour < concepts
      assert concepts < reference
    end

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

      assert_raise ArgumentError, ~r{unparsed docs/nav\.yml nav line}, fn ->
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
        Compiler.parse_nav("site_name: Fountain\n")
      end
    end

    test "every page the nav names exists on disk" do
      for {_title, file} <- Compiler.flat_pages(Docs.nav_source()) do
        assert File.exists?(Path.join([@repo_root, "docs", file])),
               "docs/nav.yml lists #{file}, which does not exist"
      end
    end

    @doc """
    The other direction, and the one that had no gate before #1008. MkDocs
    built every page under `docs/` whether the nav named it or not, so a page
    left out of the nav was still reachable on the GitHub Pages site and its
    absence from `/docs` looked like a rendering quirk rather than a mistake.
    Four such pages had accumulated (`docs/superpowers/`, since deleted).

    With Pages gone, `/docs` is the only reader of `docs/`, so a page missing
    from the nav is a page that is published nowhere at all — written, merged,
    and invisible. There is no allowlist on purpose: somewhere else in the repo
    is the right home for a markdown file nobody should read here.
    """
    test "every page on disk is named in the nav" do
      named = MapSet.new(Compiler.flat_pages(Docs.nav_source()), fn {_title, file} -> file end)

      on_disk =
        [@repo_root, "docs", "**", "*.md"]
        |> Path.join()
        |> Path.wildcard()
        |> Enum.map(&Path.relative_to(&1, Path.join(@repo_root, "docs")))

      orphans = Enum.reject(on_disk, &MapSet.member?(named, &1))

      assert orphans == [],
             """
             These pages are under docs/ but not in docs/nav.yml:

             #{Enum.map_join(orphans, "\n", &("  docs/" <> &1))}

             /docs is the only place docs/ is published, so a page the nav does
             not name is published nowhere. Add it to docs/nav.yml, or move it
             out of docs/ — decisions/ and standards/ are deliberately
             unpublished.
             """
    end
  end

  describe "pages" do
    test "every nav entry resolves and the home slug is empty" do
      assert {:ok, %{title: "Home", body: body}} = Docs.get("")
      assert body =~ "multi-tenant"

      for slug <- Docs.slugs() do
        assert {:ok, %{title: title, body: page_body}} = Docs.get(slug)
        assert is_binary(title)
        assert String.trim(page_body) != ""
      end
    end

    test "the section index page lives at the section slug" do
      assert {:ok, %{title: "Overview"}} = Docs.get("integrations")
    end

    test "unknown slugs miss" do
      assert :error = Docs.get("nope")
      assert :error = Docs.get("integrations/index")
      assert :error = Docs.get("../../etc/passwd")
    end

    test "no unsupported syntax survives preprocessing" do
      for slug <- Docs.slugs() do
        {:ok, %{body: body}} = Docs.get(slug)

        # Relative .md links must all have been rewritten to /docs paths.
        assert Regex.scan(~r/\]\((?!https?:)[^)]*\.md/, body) == [],
               "unrewritten .md link in #{inspect(slug)}"

        refute body =~ ~r/^!!!/m, "unrewritten admonition in #{inspect(slug)}"
        refute body =~ "--8<--", "unexpanded snippet include in #{inspect(slug)}"
      end
    end

    test "every internal /docs link targets a page that exists" do
      for slug <- Docs.slugs() do
        {:ok, %{body: body}} = Docs.get(slug)

        for [_, target] <- Regex.scan(~r{\]\(/docs(/[^)#]+)?(?:#[^)]*)?\)}, body) do
          target_slug = String.trim_leading(target, "/")

          assert target_slug in Docs.slugs(),
                 "#{inspect(slug)} links to /docs/#{target_slug}, which is not a page"
        end
      end
    end

    # The rendered target must carry the anchor as a heading id — MDEx emits
    # them on the trusted path (#765). Comrak's slug is now the only one that
    # matters: the MkDocs build that slugged the same headings differently for
    # *duplicate* headings (comrak `-1`, python-markdown `_1`) is gone (#1008).
    test "every internal /docs anchor link targets a heading on that page" do
      rendered =
        Map.new(Docs.slugs(), fn slug ->
          {:ok, %{body: body}} = Docs.get(slug)
          {slug, FountainWeb.Markdown.to_trusted_html(body)}
        end)

      for {slug, _html} <- rendered,
          {:ok, %{body: body}} = Docs.get(slug),
          [_, target, anchor] <- Regex.scan(~r{\]\(/docs(/[^)#]+)?#([^)]+)\)}, body) do
        target_slug = String.trim_leading(target, "/")
        target_html = Map.fetch!(rendered, if(target == "", do: slug, else: target_slug))

        assert target_html =~ ~s( id="#{anchor}"),
               "#{inspect(slug)} links to /docs/#{target_slug}##{anchor}, but that page has no heading with that id"
      end
    end

    test "the changelog page carries the repo-root CHANGELOG" do
      {:ok, %{body: body}} = Docs.get("changelog")
      assert body =~ "Keep a Changelog"
    end
  end

  describe "search index (#1009)" do
    test "has one entry per page, matching Docs.slugs/0" do
      slugs = Docs.search_index() |> Enum.map(& &1.slug) |> Enum.sort()
      assert slugs == Enum.sort(Docs.slugs())
    end

    test "every heading id resolves on its own page" do
      # Same ground truth `docs_test.exs` uses for anchor links above: the
      # rendered HTML is what an id has to match, not a re-derivation of it.
      rendered =
        Map.new(Docs.slugs(), fn slug ->
          {:ok, %{body: body}} = Docs.get(slug)
          {slug, FountainWeb.Markdown.to_trusted_html(body)}
        end)

      for %{slug: slug, headings: headings} <- Docs.search_index(),
          %{id: id, text: text} <- headings do
        assert text != "", "#{inspect(slug)} has a heading with empty text"

        assert Map.fetch!(rendered, slug) =~ ~s( id="#{id}"),
               "#{inspect(slug)}'s search index has heading #{inspect(id)}, but the page has no such id"
      end
    end

    test "skips the page's own <h1>" do
      {:ok, %{body: body}} = Docs.get("setup")
      headings = Docs.search_index() |> Enum.find(&(&1.slug == "setup")) |> Map.fetch!(:headings)

      refute Enum.any?(headings, &(&1.text == "Local setup")),
             "the page title (h1) should not also appear as a heading"

      assert body =~ "# Local setup"
    end

    test "search_index_json/0 round-trips through JSON and matches search_index/0" do
      decoded = Jason.decode!(Docs.search_index_json())

      assert length(decoded) == length(Docs.search_index())

      assert Enum.find(decoded, &(&1["slug"] == "setup"))["title"] == "Setup"
    end

    test "search_index_json/0 has no unescaped </ that could close a <script> tag early" do
      refute Docs.search_index_json() =~ "</"
    end
  end

  describe "Compiler" do
    test "slug_for strips .md and index" do
      assert Compiler.slug_for("index.md") == ""
      assert Compiler.slug_for("setup.md") == "setup"
      assert Compiler.slug_for("integrations/index.md") == "integrations"
      assert Compiler.slug_for("integrations/e2b.md") == "integrations/e2b"
    end

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

    test "links resolve against the page's own directory" do
      assert Compiler.rewrite_links("[a](setup.md#backups)", "index.md") ==
               "[a](/docs/setup#backups)"

      assert Compiler.rewrite_links("[a](../architecture.md)", "integrations/sprites-contract.md") ==
               "[a](/docs/architecture)"

      assert Compiler.rewrite_links("[a](index.md)", "integrations/e2b.md") ==
               "[a](/docs/integrations)"

      assert Compiler.rewrite_links("[a](index.md)", "setup.md") == "[a](/docs)"
    end

    test "absolute and anchor-only links are untouched" do
      md = "[a](https://example.com/x.md) [b](#section) [c](mailto:x@y.z)"
      assert Compiler.rewrite_links(md, "setup.md") == md
    end

    test "extract_headings reads h2-h6 ids and text, skipping h1" do
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

    test "extract_headings strips inline markup and decodes entities" do
      html = ~s(<h2 id="fountain-apply">Run <code>fountain apply</code> &amp; wait</h2>)

      assert Compiler.extract_headings(html) == [
               %{id: "fountain-apply", text: "Run fountain apply & wait"}
             ]
    end

    test "extract_headings ignores a heading with no id" do
      html = "<h2>No id here</h2>"
      assert Compiler.extract_headings(html) == []
    end

    test "extract_headings tolerates extra attributes on the heading tag" do
      html = ~s(<h2 class="foo" id="bar" data-x="1">Text</h2>)
      assert Compiler.extract_headings(html) == [%{id: "bar", text: "Text"}]
    end
  end

  # A deliberately narrow parser for the two shapes docs/nav.yml's nav uses:
  # `- Title: file.md` entries at two indent levels and `- Title:` section
  # headers. Anything it doesn't recognize fails the test, which is the point —
  # a new nav shape needs a decision here, not silent skipping.
end
