defmodule Managoat.DocsTest do
  @moduledoc """
  The guardrails against the fixture manual, then what the `use` macro
  generated for it: the nav, the pages, the dialect after preprocessing,
  the search index and the options.
  """

  use Managoat.Docs.GuardrailCase,
    docs: Managoat.Docs.Fixture,
    dockerfile: "test/fixtures/Dockerfile"

  alias Managoat.Docs.Fixture

  describe "the generated nav" do
    test "is nav.yml in source shape" do
      assert Fixture.nav_source() == [
               {"Home", "index.md"},
               {"Setup", "setup.md"},
               {"Guides", [{"Overview", "guides/index.md"}, {"Deploy", "guides/deploy.md"}]},
               {"Changelog", "changelog.md"}
             ]
    end

    test "is slugged for the sidebar, with a section index at the section slug" do
      assert Fixture.nav() == [
               {"Home", ""},
               {"Setup", "setup"},
               {"Guides", [{"Overview", "guides"}, {"Deploy", "guides/deploy"}]},
               {"Changelog", "changelog"}
             ]
    end

    test "slugs/0 is every page, the home page at the empty slug" do
      assert Enum.sort(Fixture.slugs()) == ["", "changelog", "guides", "guides/deploy", "setup"]
      assert {:ok, %{title: "Home"}} = Fixture.get("")
      assert {:ok, %{title: "Overview"}} = Fixture.get("guides")
      assert :error = Fixture.get("guides/index")
    end
  end

  describe "the compiled pages" do
    test "relative links are rewritten under the mount, resolved against the page's directory" do
      {:ok, %{body: home}} = Fixture.get("")
      assert home =~ "[setup](/manual/setup)"
      assert home =~ "[deploy guide](/manual/guides/deploy#first-run)"

      {:ok, %{body: deploy}} = Fixture.get("guides/deploy")
      assert deploy =~ "[setup page](/manual/setup#install)"

      {:ok, %{body: overview}} = Fixture.get("guides")
      assert overview =~ "[deploy guide](/manual/guides/deploy)"
      assert overview =~ "[back to setup](/manual/setup#configure)"

      {:ok, %{body: setup}} = Fixture.get("setup")
      assert setup =~ "[the home page](/manual)"
    end

    test "admonitions are blockquotes with a bold title, the body's fence intact" do
      {:ok, %{body: home}} = Fixture.get("")

      assert home =~
               "> **In a hurry?**\n>\n> Skip to [the first run](/manual/guides/deploy#first-run)."

      {:ok, %{body: deploy}} = Fixture.get("guides/deploy")
      assert deploy =~ "> **Note**\n>\n> A note with no custom title"
      assert deploy =~ "> ```json\n> {\"ok\": true}\n> ```"
    end

    test "a snippet include from outside the docs directory is expanded" do
      {:ok, %{body: body}} = Fixture.get("changelog")
      assert body =~ "## Unreleased"
      assert body =~ "- Everything."
      refute body =~ "--8<--"
    end

    test "duplicate headings get comrak's -1 suffix, and the anchor check accepts it" do
      html = Fixture.get("guides/deploy") |> elem(1) |> Map.fetch!(:body)
      rendered = Managoat.Docs.Markdown.to_trusted_html(html)
      assert rendered =~ ~s(id="duplicate-heading")
      assert rendered =~ ~s(id="duplicate-heading-1")
    end
  end

  describe "the search index" do
    test "carries every page's h2-h6 headings with the ids the page renders" do
      entry = Enum.find(Fixture.search_index(), &(&1.slug == "guides/deploy"))
      assert entry.title == "Deploy"

      assert entry.headings == [
               %{id: "first-run", text: "First run"},
               %{id: "duplicate-heading", text: "Duplicate heading"},
               %{id: "duplicate-heading-1", text: "Duplicate heading"}
             ]
    end

    test "skips each page's own h1" do
      entry = Enum.find(Fixture.search_index(), &(&1.slug == "setup"))
      refute Enum.any?(entry.headings, &(&1.text == "Local setup"))
      assert Enum.map(entry.headings, & &1.id) == ["install", "configure"]
    end

    test "search_index_json/0 is the index, encoded once" do
      decoded = Jason.decode!(Fixture.search_index_json())
      assert Enum.find(decoded, &(&1["slug"] == "setup"))["title"] == "Setup"
    end
  end

  describe "the options" do
    test "resolve to absolute paths, the mount and the language list" do
      root = Path.expand("../..", __DIR__)
      assert Fixture.root() == root
      assert Fixture.docs_dir() == Path.join(root, "test/fixtures/manual")
      assert Fixture.mount() == "/manual"
      assert Fixture.languages() == ~w(bash elixir json)
      assert Fixture.path_for_slug("") == "/manual"
      assert Fixture.path_for_slug("setup") == "/manual/setup"
    end

    test "external_resources/0 is the nav, every page and the extra resources, relative to root" do
      assert Enum.sort(Fixture.external_resources()) ==
               Enum.sort([
                 "test/fixtures/manual/nav.yml",
                 "test/fixtures/snippets/CHANGELOG.md",
                 "test/fixtures/manual/index.md",
                 "test/fixtures/manual/setup.md",
                 "test/fixtures/manual/guides/index.md",
                 "test/fixtures/manual/guides/deploy.md",
                 "test/fixtures/manual/changelog.md"
               ])
    end

    test "the same paths are the module's @external_resource attributes" do
      declared =
        :attributes
        |> Fixture.__info__()
        |> Keyword.get_values(:external_resource)
        |> List.flatten()
        |> Enum.map(&Path.relative_to(to_string(&1), Fixture.root()))
        |> Enum.sort()

      assert declared == Enum.sort(Fixture.external_resources())
    end

    test "languages default to the renderer's list when the option is absent" do
      defmodule Defaulted do
        use Managoat.Docs,
          root: Path.expand("../..", __DIR__),
          docs_dir: "test/fixtures/manual",
          nav: "test/fixtures/manual/nav.yml"
      end

      assert Defaulted.languages() == Managoat.Docs.Markdown.languages()
      assert Defaulted.mount() == "/docs"
      assert Defaulted.path_for_slug("setup") == "/docs/setup"
      assert {:ok, %{body: body}} = Defaulted.get("")
      assert body =~ "[setup](/docs/setup)"
    end
  end
end
