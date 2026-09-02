defmodule Managoat.Docs.GuardrailCase do
  @moduledoc """
  The structural gate on an embedded manual, as a case template. A host
  `use`s it once, in a test file of its own, and gets every check in
  `Managoat.Docs.Checks` as an ExUnit test against its real manual. The
  test module's body starts with the `use` and goes on to tests about the
  manual's content:

      use Managoat.Docs.GuardrailCase,
        docs: MyApp.Docs,
        dockerfile: "Dockerfile",
        unhighlightable: ~w(text txt plain plaintext promql)

  Options:

  - `docs:` (required) the module that `use`s `Managoat.Docs`;
  - `dockerfile:` the image's Dockerfile, relative to the docs module's
    `root/0`. Without it the two Dockerfile checks are not generated, for a
    host that ships no image;
  - `unhighlightable:` fence languages exempt from the baked-parser check.
    Defaults to the names that ask for no highlighting.

  Why a case template and not a shared test file: the checks only mean
  something against the host's own manual, Dockerfile and language list,
  and a host wants them in the same file as the tests about its content,
  under the same `mix test path` a CI docs job names. The library runs the
  same template against a fixture manual, so the checks are exercised
  before any host `use`s them.

  Every test asserts that a check returned no failures and prints the
  failures as the assertion message. The messages are the documentation of
  the incident behind each check; read `Managoat.Docs.Checks`.
  """

  @doc false
  defmacro __using__(opts) do
    docs = Keyword.fetch!(opts, :docs)
    dockerfile = Keyword.get(opts, :dockerfile)
    unhighlightable = Keyword.get(opts, :unhighlightable, ~w(text txt plain plaintext))

    quote do
      use ExUnit.Case, async: true

      alias Managoat.Docs.Checks

      @managoat_docs unquote(docs)
      @managoat_docs_unhighlightable unquote(unhighlightable)

      defp assert_sound([]), do: :ok
      defp assert_sound(failures), do: flunk(Enum.join(failures, "\n\n"))

      unquote(dockerfile_tests(dockerfile))

      describe "nav" do
        test "every page the nav names exists on disk" do
          @managoat_docs |> Checks.nav_pages_exist() |> assert_sound()
        end

        test "every page on disk is named in the nav" do
          @managoat_docs |> Checks.pages_on_disk_named() |> assert_sound()
        end
      end

      describe "pages" do
        test "every nav entry resolves and the home slug is empty" do
          @managoat_docs |> Checks.pages_resolve() |> assert_sound()
        end

        test "unknown slugs miss" do
          assert :error = @managoat_docs.get("nope")
          assert :error = @managoat_docs.get("index")
          assert :error = @managoat_docs.get("../../etc/passwd")
        end

        test "no unsupported syntax survives preprocessing" do
          @managoat_docs |> Checks.no_leftover_syntax() |> assert_sound()
        end

        test "every internal link targets a page that exists" do
          @managoat_docs |> Checks.internal_links_resolve() |> assert_sound()
        end

        test "every internal anchor link targets a heading on that page" do
          @managoat_docs |> Checks.anchors_resolve() |> assert_sound()
        end
      end

      describe "search index" do
        test "has one entry per page, matching slugs/0" do
          @managoat_docs |> Checks.search_index_complete() |> assert_sound()
        end

        test "every heading id resolves on its own page" do
          @managoat_docs |> Checks.search_index_headings_resolve() |> assert_sound()
        end

        test "search_index_json/0 round-trips and has no </ that could close a <script> tag early" do
          @managoat_docs |> Checks.search_index_json_safe() |> assert_sound()
        end
      end

      describe "the baked parser list" do
        test "every language name is one Lumis knows, by id" do
          @managoat_docs |> Checks.languages_known() |> assert_sound()
        end

        test "covers every language the manual fences" do
          @managoat_docs
          |> Checks.fences_baked(@managoat_docs_unhighlightable)
          |> assert_sound()
        end
      end
    end
  end

  defp dockerfile_tests(nil), do: nil

  defp dockerfile_tests(dockerfile) do
    quote do
      @managoat_docs_dockerfile Path.join(@managoat_docs.root(), unquote(dockerfile))

      describe "compile-time reads ↔ Dockerfile" do
        test "every snippet path is copied into the image" do
          @managoat_docs
          |> Checks.snippets_copied(@managoat_docs_dockerfile)
          |> assert_sound()
        end

        test "every file the docs module reads at compile time is copied into the image" do
          @managoat_docs
          |> Checks.external_resources_copied(@managoat_docs_dockerfile)
          |> assert_sound()
        end
      end
    end
  end
end
