defmodule Fountain.DocsTest do
  @moduledoc """
  The embedded docs site against `mkdocs.yml` and against itself.

  The nav in `Fountain.Docs` is a hand-maintained mirror of the `nav:`
  section in `mkdocs.yml` — the sync test parses that file so adding a page
  to one and not the other fails here rather than shipping a `/docs` that
  silently lags the GitHub Pages site. The preprocessing tests pin the small
  MkDocs dialect the docs are allowed to use: if a page introduces syntax
  the compiler doesn't rewrite, the leftover-syntax checks catch it.
  """

  use ExUnit.Case, async: true

  alias Fountain.Docs
  alias Fountain.Docs.Compiler

  @mkdocs_yml Path.expand("../../../../mkdocs.yml", __DIR__)

  describe "nav ↔ mkdocs.yml" do
    test "matches the nav: section of mkdocs.yml exactly, order included" do
      assert Docs.nav_source() == mkdocs_nav()
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

    test "no MkDocs syntax survives preprocessing" do
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

    test "the changelog page carries the repo-root CHANGELOG" do
      {:ok, %{body: body}} = Docs.get("changelog")
      assert body =~ "Keep a Changelog"
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
  end

  # A deliberately narrow parser for the two shapes mkdocs.yml's nav uses:
  # `- Title: file.md` entries at two indent levels and `- Title:` section
  # headers. Anything it doesn't recognize fails the test, which is the point —
  # a new nav shape needs a decision here, not silent skipping.
  defp mkdocs_nav do
    [_before, nav_block] = @mkdocs_yml |> File.read!() |> String.split(~r/^nav:\n/m, parts: 2)

    nav_block
    |> String.split("\n")
    |> Enum.take_while(&(&1 == "" or String.starts_with?(&1, " ")))
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.reduce([], fn line, acc ->
      case Regex.run(~r/^(\s+)- ([^:]+):\s*(\S+)?\s*$/, line) do
        [_, indent, title, file] when byte_size(indent) == 2 ->
          [{title, file} | acc]

        [_, indent, title] when byte_size(indent) == 2 ->
          [{title, []} | acc]

        [_, indent, title, file] when byte_size(indent) > 2 ->
          [{section, children} | rest] = acc
          [{section, [{title, file} | children]} | rest]

        _ ->
          flunk("unparsed mkdocs.yml nav line: #{inspect(line)}")
      end
    end)
    |> Enum.map(fn
      {section, children} when is_list(children) -> {section, Enum.reverse(children)}
      entry -> entry
    end)
    |> Enum.reverse()
  end
end
