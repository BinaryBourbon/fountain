defmodule FountainBuzz.ManualTest do
  @moduledoc """
  What the move promised the reader (ADR 0043, #1510): the pages keep their
  URLs, and they keep their place in the sidebar.
  """
  use ExUnit.Case, async: true

  alias Fountain.Manual

  @pages ["integrations/buzz", "catalog/mcp-servers/fountain-buzz"]

  test "the extension is the manual's only other source here" do
    assert FountainBuzz.Extension.docs() == FountainBuzz.Docs
    assert FountainBuzz.Docs in Manual.extension_manuals()
  end

  test "both pages keep the slugs they had as core pages" do
    for slug <- @pages do
      assert {:ok, %{title: title}} = Manual.get(slug)
      assert is_binary(title)
      assert slug in Manual.slugs()
    end
  end

  test "the URLs are unchanged by the move" do
    assert Manual.path_for_slug("integrations/buzz") == "/docs/integrations/buzz"

    assert Manual.path_for_slug("catalog/mcp-servers/fountain-buzz") ==
             "/docs/catalog/mcp-servers/fountain-buzz"
  end

  test "the core manual serves neither, so a core distribution has no dead link to them" do
    for slug <- @pages do
      assert Fountain.Docs.get(slug) == :error
      refute slug in Fountain.Docs.slugs()
    end
  end

  test "the sidebar puts them back in the sections a reader knows" do
    nav = Manual.nav()

    assert {_, catalog} = Enum.find(nav, &match?({"Catalog", _}, &1))
    assert {"fountain-buzz", "catalog/mcp-servers/fountain-buzz"} in catalog

    assert {_, clients} = Enum.find(nav, &match?({"Plug into Fountain", _}, &1))
    assert {"Buzz (Nostr)", "integrations/buzz"} in clients

    # Merged by title rather than appended as a second section with the same
    # name, which is the whole difference between "the page moved" and "the
    # page moved and the sidebar grew a duplicate heading".
    assert Enum.count(nav, &match?({"Catalog", _}, &1)) == 1
    assert Enum.count(nav, &match?({"Plug into Fountain", _}, &1)) == 1
  end

  test "the merged search index carries this app's pages" do
    Manual.reset_search_index()
    index = Jason.decode!(Manual.search_index_json())
    slugs = Enum.map(index, & &1["slug"])

    for slug <- @pages, do: assert(slug in slugs)
    assert "" in slugs, "the core manual's home page should still be indexed"
  after
    Manual.reset_search_index()
  end
end
