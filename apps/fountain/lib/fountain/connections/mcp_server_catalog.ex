defmodule Fountain.Connections.McpServerCatalog do
  @moduledoc """
  Remote MCP servers verified to work with connection discovery (#1322).

  An entry is a checkable claim, not an endorsement: *the MCP authorization
  chain (RFC 9728 resource metadata → RFC 8414 authorization-server
  metadata → RFC 7591 registration where `dcr: true`) completed against
  `url` on `verified_on`*. No human judgement is in the claim —
  `scripts/mcp-catalog-probe.exs` re-runs the chain through
  `Managoat.McpAuth.discover/1` itself and reports drift.
  That definition is what unblocked #932: "supported" as an opinion is an
  assertion nobody can verify, which CLAUDE.md forbids in docs.

  Suggestions, not an allowlist — the `Managoat.Runtimes.Model` philosophy.
  Nothing gates on membership: any URL a tenant pastes into the console or
  `POST /api/connection-providers` is discovered the same way. The list
  feeds the preset chips on the console's *Connect a remote MCP server*
  box, the `mcp_servers` key of `GET /api/catalog`, and the entries under
  `docs/catalog/mcp-servers/`.
  """

  # Every entry below was probed on 2026-09-01 with read-only metadata
  # fetches (no client was registered, except where noted). `dcr: true`
  # means the authorization-server metadata carried a
  # `registration_endpoint`, so connecting is paste-the-URL with zero
  # credentials typed; `dcr: false` means discovery fills the endpoints and
  # the tenant pastes a client id from their own app registration — the
  # console's existing fallback.
  #
  # A probe failure on a listed entry is drift, not deletion: the entry
  # keeps its last good `verified_on`, and the stale date is the honest
  # statement (#932's "known to work, dated"). Update the date only from a
  # probe run, never by hand.
  #
  # Probed on 2026-09-01 and NOT qualifying — recheck with
  # `mix run --no-start scripts/mcp-catalog-probe.exs <url>` before adding:
  #   * Atlassian (https://mcp.atlassian.com/v1/sse) — no resource metadata
  #     (404 at the well-known path).
  #   * Intercom (https://mcp.intercom.com/mcp) — same.
  # Stripe sat on this list in #1322's seed data ("AS metadata has no
  # authorize endpoint") and turned out to qualify: the seed was a curl
  # probe of one metadata path, while `Managoat.McpAuth` tries the four RFC
  # 8414/OIDC candidates and finds Stripe's at the issuer-path form. Which
  # is why the probe drives the production discovery code and not curl.
  @entries [
    # Linear is the one entry verified past metadata: a provider was
    # created end-to-end in prod via `POST /api/connection-providers`
    # and came back `client_source: "dcr"`.
    %{
      slug: "linear",
      name: "Linear",
      url: "https://mcp.linear.app/mcp",
      dcr: true,
      verified_on: ~D[2026-09-01]
    },
    %{
      slug: "sentry",
      name: "Sentry",
      url: "https://mcp.sentry.dev/mcp",
      dcr: true,
      verified_on: ~D[2026-09-01]
    },
    %{
      slug: "notion",
      name: "Notion",
      url: "https://mcp.notion.com/mcp",
      dcr: true,
      verified_on: ~D[2026-09-01]
    },
    %{
      slug: "asana",
      name: "Asana",
      url: "https://mcp.asana.com/sse",
      dcr: true,
      verified_on: ~D[2026-09-01]
    },
    %{
      slug: "cloudflare",
      name: "Cloudflare",
      url: "https://mcp.cloudflare.com/mcp",
      dcr: true,
      verified_on: ~D[2026-09-01]
    },
    %{
      slug: "paypal",
      name: "PayPal",
      url: "https://mcp.paypal.com/mcp",
      dcr: true,
      verified_on: ~D[2026-09-01]
    },
    %{
      slug: "square",
      name: "Square",
      url: "https://mcp.squareup.com/sse",
      dcr: true,
      verified_on: ~D[2026-09-01]
    },
    %{
      slug: "webflow",
      name: "Webflow",
      url: "https://mcp.webflow.com/sse",
      dcr: true,
      verified_on: ~D[2026-09-01]
    },
    # Issuer https://access.stripe.com/mcp; its RFC 8414 document lives at
    # the issuer-path candidate, which is the one a naive probe misses.
    %{
      slug: "stripe",
      name: "Stripe",
      url: "https://mcp.stripe.com/mcp",
      dcr: true,
      verified_on: ~D[2026-09-01]
    },
    # GitHub's AS (github.com/login/oauth) publishes its metadata but
    # offers no registration endpoint.
    %{
      slug: "github",
      name: "GitHub",
      url: "https://api.githubcopilot.com/mcp",
      dcr: false,
      verified_on: ~D[2026-09-01]
    }
  ]

  @type entry :: %{
          slug: String.t(),
          name: String.t(),
          url: String.t(),
          dcr: boolean(),
          verified_on: Date.t()
        }

  @doc "Every verified entry, in display order."
  @spec entries() :: [entry()]
  def entries, do: @entries

  @doc "The entry for a slug, or nil."
  @spec get(String.t()) :: entry() | nil
  def get(slug), do: Enum.find(@entries, &(&1.slug == slug))
end
