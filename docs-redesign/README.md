# Fountain docs: IA redesign and writing standards

## Status

**Mostly executed.** These were planning documents; `docs/` has since been
rebuilt from them. Tracker: #903.

| Shipped | Where |
|---|---|
| Concepts tree, tutorial promoted, `primitives.md` split | #901 |
| `self-hosting.md` and `operations.md` split, Troubleshooting section | #913 |
| The three missing explanation pages | #914 |
| Catalog: runtimes and skills | #915 |
| Catalog: the three MCP servers Fountain hosts | #920 |
| Style checker, ratchet, and the whole backlog cleared | #917, #923 to #927 |
| Generated flag-complete CLI reference | #928 |

Still open: #906 (refile the 19 `integrations/` pages onto the entry
template), #908 (a third-party MCP catalog, which needs a product decision),
and the API half of #912.

**Read these as the reasoning, not as the current state of `docs/`.** Where a
plan below differs from what shipped, what shipped is right and the difference
is noted inline. Two known divergences:

- `03-nav-tree.md` groups Guides into sub-sections. The `mkdocs.yml` nav parser
  takes **one level of sections** and raises on anything deeper, so those
  flattened into sibling sections (`Run an instance`, `Troubleshooting`).
- `05-catalog-template.md` treats YAML front matter as load-bearing, on the
  assumption that index pages render from it. Nothing in this MkDocs stack
  does that without a macros plugin, which is not installed. The catalog index
  tables that shipped are hand-written. The front-matter design stands if a
  generator ever arrives; until then it would be unused metadata.

---

The original note follows.

Working documents, not yet a docs PR. Nothing under `docs/` has been changed.

| File | What it is |
|---|---|
| [00-diataxis-working-note.md](00-diataxis-working-note.md) | Phase 1. The mode test I apply to a Fountain page, and the specific failure when two modes share one |
| [01-reference-site-study.md](01-reference-site-study.md) | Phase 2. Nine sites, named patterns with URLs, and the four places they disagree |
| [02-audit.md](02-audit.md) | Phase 3. All 34 live pages classified, the four known gaps confirmed or refuted, six more found |
| [03-nav-tree.md](03-nav-tree.md) | Deliverable 1. Proposed tree, every page labelled and traced, plus a nine-step merge order |
| [04-page-templates.md](04-page-templates.md) | Deliverable 2. One markdown skeleton per mode |
| [05-catalog-template.md](05-catalog-template.md) | Deliverable 3. Catalog entry template, index design, and the search and filtering thresholds |
| [06-voice-and-style.md](06-voice-and-style.md) | Deliverable 4. One page, with the CI checks |
| [07-primitives-rewrite.md](07-primitives-rewrite.md) | Deliverable 5. `primitives.md` before and after, with sixteen traced decisions |

## Sources read in full

Diátaxis. `/start-here/`, `/tutorials/`, `/how-to-guides/`, `/reference/`,
`/explanation/`, `/tutorials-how-to/`, `/reference-explanation/`, `/compass/`,
`/map/`, `/how-to-use-diataxis/`, `/quality/`, `/application/`,
`/foundations/`.

Reference sites. `docs.temporal.io` (llms.txt, temporal, workflows, activities,
develop/typescript), `docs.stripe.com/payments/payment-intents`, `fly.io/docs`
(nav, flyctl, machines, machines/overview, flyctl/machine-run),
`tailscale.com/blog/how-tailscale-works`, `workos.com/docs/integrations`
(okta-saml, azure-ad-saml), `docs.sentry.io/platforms` (javascript/react,
python/django), `supabase.com/docs/guides/auth` (server-side/nextjs,
quickstarts/react-native), `segment.com/docs/connections/destinations`
(catalog, actions-slack), `modal.com/docs/guide` (guide, sandbox),
`developer.hashicorp.com/vault/docs` (what-is-vault, concepts/seal).

Fountain. All 34 pages under `docs/`, `mkdocs.yml`,
`cli/internal/cmd/docs_test.go`, `fountain.inevitable.fyi/docs`, and
`fountain.inevitable.fyi`.

## Flagged as unverified

Nothing in these documents is asserted from memory. Two things are worth
knowing about the evidence.

`diataxis.fr/complex-hierarchies/` and `diataxis.fr/needs/` both return 404.
The content those URLs used to hold is covered by `/map/` and `/foundations/`,
which I read instead.

Segment's counts (1021 listings, 495 distinct names, roughly 45 categories) are
mine, computed from the rendered catalog index text. They are the right order
of magnitude rather than Segment's official figure, which is not published on
that page.
