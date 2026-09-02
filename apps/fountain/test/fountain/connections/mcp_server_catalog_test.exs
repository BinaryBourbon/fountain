defmodule Fountain.Connections.McpServerCatalogTest do
  use ExUnit.Case, async: true

  alias Fountain.Connections.McpServerCatalog
  alias Managoat.McpAuth.UrlGuard

  test "every entry is well-formed" do
    for entry <- McpServerCatalog.entries() do
      assert is_binary(entry.slug) and entry.slug != ""
      assert entry.slug == String.downcase(entry.slug)
      assert is_binary(entry.name) and entry.name != ""
      assert is_boolean(entry.dcr)
      assert %Date{} = entry.verified_on
      # The same rule discovery applies to a pasted URL: a listed URL that
      # UrlGuard would refuse could never have been verified.
      assert UrlGuard.check(entry.url) == :ok, "#{entry.slug}: #{entry.url}"
    end
  end

  test "slugs and urls are unique" do
    entries = McpServerCatalog.entries()
    assert entries |> Enum.map(& &1.slug) |> Enum.uniq() |> length() == length(entries)
    assert entries |> Enum.map(& &1.url) |> Enum.uniq() |> length() == length(entries)
  end

  test "get/1 finds by slug" do
    assert %{name: "Linear", dcr: true} = McpServerCatalog.get("linear")
    assert McpServerCatalog.get("nope") == nil
  end
end
