defmodule Managoat.Docs.ChecksTest do
  @moduledoc """
  Each check against a manual built to fail it. The guardrails pass against
  the fixture manual in `docs_test.exs`; this is the other half, that each
  one bites. A broken manual is written to a temporary directory and embedded
  with a throwaway module, exactly as a host would embed a real one.
  """

  use ExUnit.Case, async: true

  alias Managoat.Docs.Checks

  @sound %{
    "nav.yml" => """
    nav:
      - Home: index.md
      - Setup: setup.md
    """,
    "index.md" => "# Home\n\nRead [setup](setup.md#install).\n\n```bash\nls\n```\n",
    "setup.md" => "# Setup\n\n## Install\n\nBack [home](index.md).\n"
  }

  @dockerfile "FROM x\nCOPY mix.exs ./\nCOPY docs ./docs\n"

  # Writes `files` under <tmp>/docs, the Dockerfile at <tmp>/Dockerfile, and
  # defines a docs module over them. Options pass through to the `use` line.
  defp manual(files, opts \\ []) do
    root = Path.join(System.tmp_dir!(), "managoat_docs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "docs"))

    for {name, body} <- files do
      path = Path.join([root, "docs", name])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, body)
    end

    File.write!(Path.join(root, "Dockerfile"), Keyword.get(opts, :dockerfile, @dockerfile))

    name = Module.concat(__MODULE__, "Manual#{System.unique_integer([:positive])}")
    use_opts = Keyword.get(opts, :use, []) ++ [root: root, languages: ~w(bash)]

    {:module, mod, _, _} =
      Module.create(
        name,
        quote(do: use(Managoat.Docs, unquote(use_opts))),
        Macro.Env.location(__ENV__)
      )

    mod
  end

  test "a sound manual passes every check" do
    docs = manual(@sound)
    dockerfile = Path.join(docs.root(), "Dockerfile")

    assert Checks.snippets_copied(docs, dockerfile) == []
    assert Checks.external_resources_copied(docs, dockerfile) == []
    assert Checks.nav_pages_exist(docs) == []
    assert Checks.pages_on_disk_named(docs) == []
    assert Checks.pages_resolve(docs) == []
    assert Checks.no_leftover_syntax(docs) == []
    assert Checks.internal_links_resolve(docs) == []
    assert Checks.anchors_resolve(docs) == []
    assert Checks.search_index_complete(docs) == []
    assert Checks.search_index_headings_resolve(docs) == []
    assert Checks.search_index_json_safe(docs) == []
    assert Checks.languages_known(docs) == []
    assert Checks.fences_baked(docs, ~w(text)) == []
  end

  describe "pages_on_disk_named/1" do
    test "names a page under the docs directory that the nav does not list" do
      docs = manual(Map.put(@sound, "orphans/lost.md", "# Lost\n"))

      assert [failure] = Checks.pages_on_disk_named(docs)
      assert failure =~ "orphans/lost.md"
      assert failure =~ "published nowhere"
    end
  end

  describe "nav_pages_exist/1" do
    test "names a nav entry with no file" do
      # The `use` line cannot embed a missing page; the check reads the nav
      # the module embedded, so delete the file after the compile.
      docs = manual(@sound)
      File.rm!(Path.join(docs.docs_dir(), "setup.md"))

      assert ["the nav lists setup.md, which does not exist"] = Checks.nav_pages_exist(docs)
    end
  end

  describe "anchors_resolve/1" do
    test "names a link to an anchor the target page does not render" do
      docs = manual(Map.put(@sound, "index.md", "# Home\n\n[x](setup.md#no-such-heading)\n"))

      assert [failure] = Checks.anchors_resolve(docs)
      assert failure =~ ~s("" links to /docs/setup#no-such-heading)
      assert failure =~ "no heading with that id"
    end

    test "a mount-only target with an anchor is checked against the linking page" do
      docs =
        manual(
          Map.put(@sound, "index.md", "# Home\n\n## Here\n\n[x](/docs#here) [y](/docs#gone)\n")
        )

      assert [failure] = Checks.anchors_resolve(docs)
      assert failure =~ "/docs#gone"
    end
  end

  describe "internal_links_resolve/1" do
    test "names a link under the mount to a page that is not one" do
      docs = manual(Map.put(@sound, "index.md", "# Home\n\n[x](/docs/nope)\n"))

      assert [failure] = Checks.internal_links_resolve(docs)
      assert failure =~ "/docs/nope, which is not a page"
    end

    test "uses the host's mount" do
      docs =
        manual(Map.put(@sound, "index.md", "# Home\n\n[x](/manual/nope) [y](/docs/x)\n"),
          use: [mount: "/manual"]
        )

      assert [failure] = Checks.internal_links_resolve(docs)
      assert failure =~ "/manual/nope"
    end
  end

  describe "the Dockerfile checks" do
    test "external_resources_copied/2 names a compile-time read outside the COPY set" do
      docs = manual(@sound, dockerfile: "FROM x\nCOPY mix.exs ./\n")

      failures = Checks.external_resources_copied(docs, Path.join(docs.root(), "Dockerfile"))
      assert length(failures) == 3
      assert Enum.any?(failures, &(&1 =~ "reads docs/nav.yml at compile time"))
      assert Enum.all?(failures, &(&1 =~ "breaks `mix release`"))
    end

    test "external_resources_copied/2 names a read that no longer exists" do
      docs = manual(@sound)
      File.rm!(Path.join(docs.docs_dir(), "setup.md"))

      failures = Checks.external_resources_copied(docs, Path.join(docs.root(), "Dockerfile"))
      assert failures == ["#{inspect(docs)} reads docs/setup.md, which does not exist"]
    end

    test "snippets_copied/2 names a snippet include outside the COPY set" do
      docs = manual(@sound)
      File.write!(Path.join(docs.root(), "NOTES.md"), "notes\n")
      File.write!(Path.join(docs.docs_dir(), "setup.md"), "# Setup\n\n--8<-- \"NOTES.md\"\n")

      assert [failure] = Checks.snippets_copied(docs, Path.join(docs.root(), "Dockerfile"))
      assert failure =~ "docs/setup.md includes NOTES.md at compile time"
    end

    test "a COPY with a flag such as --from is not a source" do
      docs = manual(@sound, dockerfile: "COPY --from=deps /deps ./deps\nCOPY docs ./docs\n")
      assert Checks.dockerfile_copies(Path.join(docs.root(), "Dockerfile")) == ["docs"]
    end
  end

  describe "no_leftover_syntax/1" do
    test "names authoring syntax the compiler did not rewrite" do
      # A link with a space is not the dialect's link shape, so it survives;
      # an indented admonition marker is not at line start, so it survives.
      docs = manual(Map.put(@sound, "index.md", "# Home\n\n[x](my page.md)\n"))

      assert [failure] = Checks.no_leftover_syntax(docs)
      assert failure =~ "unrewritten .md link"
    end
  end

  describe "the baked parser list" do
    test "languages_known/1 names a language Lumis has no id for" do
      docs = manual(@sound, use: [languages: ~w(bash klingon)])
      assert [failure] = Checks.languages_known(docs)
      assert failure =~ "klingon is not a Lumis language id"
    end

    test "fences_baked/2 names a fence in a language the list does not bake" do
      docs =
        manual(
          Map.put(
            @sound,
            "setup.md",
            "# Setup\n\n## Install\n\n```elixir\nx\n```\n\n```text\ny\n```\n"
          )
        )

      assert [failure] = Checks.fences_baked(docs, ~w(text))
      assert failure =~ ~s|"setup" fences ```elixir (elixir)|
    end

    test "fences_baked/2 resolves an alias to its language id" do
      docs = manual(Map.put(@sound, "setup.md", "# Setup\n\n## Install\n\n```sh\nx\n```\n"))
      assert Checks.fences_baked(docs, []) == []
    end

    test "unbaked_fences/3 and fenced_languages/1 cover files outside the manual" do
      dir =
        Path.join(System.tmp_dir!(), "managoat_docs_help_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "a.md"), "```python\nx\n```\n\n```text\ny\n```\n")

      fences = Checks.fenced_languages([Path.join(dir, "a.md"), Path.join(dir, "missing.md")])
      assert fences == [{Path.join(dir, "a.md"), "python"}, {Path.join(dir, "a.md"), "text"}]

      assert [failure] = Checks.unbaked_fences(~w(bash), fences, ~w(text))
      assert failure =~ "fences ```python (python)"
    end
  end

  describe "the search index checks" do
    test "search_index_json_safe/1 reports a </ and a decode mismatch" do
      docs = manual(@sound)

      # The generated function is sound by construction; check the checker's
      # arms with a stub that answers the two calls it makes.
      stub = Module.concat(__MODULE__, "Stub#{System.unique_integer([:positive])}")

      Module.create(
        stub,
        quote do
          def search_index, do: [%{slug: "", title: "x", headings: []}]
          def search_index_json, do: ~s([{"slug":"</script>"},{}])
        end,
        Macro.Env.location(__ENV__)
      )

      assert Checks.search_index_json_safe(docs) == []
      assert [closes, count] = Checks.search_index_json_safe(stub)
      assert closes =~ "`</`"
      assert count =~ "decodes to 2 entries"
    end
  end
end
