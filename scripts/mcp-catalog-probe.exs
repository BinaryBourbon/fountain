# Re-verifies Fountain.Connections.McpServerCatalog (#1322): for every entry,
# the MCP authorization chain (RFC 9728 resource metadata → RFC 8414 AS
# metadata → RFC 7591 registration endpoint where the entry claims DCR) must
# still complete against the listed URL. Read-only — it never registers a
# client, so running it leaves nothing behind on anyone's authorization
# server.
#
#   mix run --no-start scripts/mcp-catalog-probe.exs            # the catalog
#   mix run --no-start scripts/mcp-catalog-probe.exs <url>...   # candidates
#
# The second form probes arbitrary URLs — for rechecking the
# probed-not-qualifying set noted in the catalog module (Stripe, Atlassian,
# Intercom), or vetting a new entry before adding it.
#
# Why this is Elixir driving `Managoat.McpAuth.discover/1` rather than the ~30
# lines of curl+jq the seed data was gathered with: the catalog's claim is
# "discovery completes against this URL", and discovery is
# `Managoat.McpAuth.Discovery` — a parallel curl implementation would
# drift from it (the 401-challenge parse, the four AS metadata candidates,
# the UrlGuard on every hop) and end up verifying a different claim.
#
# Where it runs: on demand, and on a schedule in
# `.github/workflows/mcp-catalog-probe.yml`. Deliberately NOT in PR CI —
# third-party network calls do not belong in the merge gate, and an entry
# going stale is drift to report (re-date it), not a defect in the PR under
# test.

alias Fountain.Connections.McpServerCatalog
alias Managoat.McpAuth

{:ok, _} = Application.ensure_all_started(:req)

defmodule McpCatalogProbe do
  def probe(%{url: url} = entry) do
    case McpAuth.discover(url) do
      {:ok, md} -> check_registration(entry, md)
      {:error, reason} -> {:drift, FountainWeb.ConnectionProviderJSON.describe(reason)}
    end
  end

  # A dcr entry whose AS dropped its registration endpoint still "discovers",
  # but the paste-the-URL-and-nothing-else claim no longer holds.
  defp check_registration(%{dcr: true}, %{"registration_endpoint" => ep}) when is_binary(ep),
    do: {:ok, "dcr"}

  defp check_registration(%{dcr: true}, _md),
    do: {:drift, "chain completes, but the registration endpoint is gone"}

  defp check_registration(%{dcr: false}, %{"registration_endpoint" => ep}) when is_binary(ep),
    do: {:ok, "now offers dcr — consider flipping the entry"}

  defp check_registration(%{dcr: false}, _md), do: {:ok, "no dcr, as listed"}

  def report({entry, {:ok, note}}) do
    IO.puts("ok     #{String.pad_trailing(entry.slug, 12)} #{entry.url} (#{note})")
    false
  end

  def report({entry, {:drift, reason}}) do
    IO.puts("drift  #{String.pad_trailing(entry.slug, 12)} #{entry.url} — #{reason}")
    true
  end
end

entries =
  case System.argv() do
    [] -> McpServerCatalog.entries()
    urls -> Enum.map(urls, &%{slug: URI.parse(&1).host || &1, url: &1, dcr: false})
  end

drifted =
  entries
  |> Task.async_stream(&{&1, McpCatalogProbe.probe(&1)}, timeout: 60_000, ordered: true)
  |> Enum.map(fn {:ok, result} -> McpCatalogProbe.report(result) end)
  |> Enum.count(& &1)

# The trailing marker exists so a caller that swallows exit codes still
# cannot read a partial log as success (same convention as
# scripts/sandbox-image/smoke.sh).
if drifted == 0 do
  IO.puts("MCP_CATALOG_PROBE_RESULT: ok (#{length(entries)} probed)")
else
  IO.puts("MCP_CATALOG_PROBE_RESULT: drift (#{drifted} of #{length(entries)})")
  System.halt(1)
end
