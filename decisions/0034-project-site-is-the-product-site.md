---
type: ADR
title: "The open-source project has no site of its own; managoat.com and /docs carry it"
description: "With the hosted instance branded Managoat, Fountain the AGPL project keeps its name but gets no separate domain or GitHub Pages site. The product site is the project site: one 'Open source' page under /docs states the licence split and links the repo, and the README points back. Built in the PR that adds this file."
tags: [open-source, docs, brand, product]
status: stable
adr: "0034"
adr_status: "Accepted"
date: 2026-08-25
generated: { by: human:jhgaylor, at: 2026-08-25T22:00:00-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-25T22:00:00-04:00 }
---

# 0034 — The open-source project has no site of its own; managoat.com and /docs carry it

**Status:** Accepted, built in the PR that adds this file. Nothing described
here is unbuilt.

## Context

The hosted instance moved from `fountain.inevitable.fyi` to `managoat.com`
(#1177). The console brands itself from the host, so the hosted product now
presents as *Managoat*, while the repo, the CLI (`fountain`), the SDK
(`@agentshit/fountain-sdk`), the Docker image and every ADR still say
*Fountain*. Before the move, the product URL and the project name agreed and
nobody had to decide which was which. After it, an obvious question appears:
where is the open-source project's home? There is no `fountain.dev`, the
GitHub Pages docs site was retired in #1008 (its domain is a redirect
tombstone into `/docs`, #1011), and the only thing on the internet that says
"Fountain is open source" is the README's licence table.

The relicensing to AGPL (0027) made the open-source identity load-bearing:
the copyleft argument only works if people can find the project, read the
licence split, and self-host without the hosted brand in the way.

Three patterns exist among open-core companies:

1. **One domain, one brand** — PostHog, Sentry, Supabase, Cal.com.
   `posthog.com` is marketing, docs, blog and the login for the cloud
   product. "Open source" is a section and a badge, not a site. The repo
   README links back to the product domain.
2. **One domain, two labelled halves** — GitLab, Grafana, Mattermost. The
   project identity is carried by an *edition* (CE/EE) or a path
   (`grafana.com/oss/grafana`), not a second domain.
3. **Separate project and company domains** — Discourse
   (`discourse.org`/`.com`), Elastic once (`elasticsearch.org`, dropped),
   foundation projects (CNCF, OpenTofu). This is the pattern that looks
   like "a project site". Outside a governance split it has mostly been
   collapsed back into pattern 1, because it means two sites to keep
   current, two SEO targets and a permanent "which one do I go to?".

## Decision

Pattern 1, with pattern 2's naming:

- **`managoat.com` is the site.** Marketing, docs, login. It says the server
  is open source and links the repo. There is no second domain and no
  GitHub Pages site for the project, and buying one is out of scope until
  there is a governance reason (a foundation, a second maintainer with
  standing) rather than a branding one.
- **`/docs` is the project manual.** It already is: self-hosting, the CLI,
  the SDK, the API, the sandbox contract. A "project site" would be a copy
  of it, and #1008 retired the last second copy because it went stale.
- **The GitHub repo is the project's home.** The README is the project
  front page. It says what Fountain is, self-host in three lines, the
  licence split, and links the hosted instance for people who do not want
  to run it.
- **The names split by edition, not by domain.** *Fountain* is the AGPL
  server, the CLI and the SDK. *Managoat* is one hosted instance of it.
  `ee/` is the Elastic-2.0 part. The project is not renamed.
- **One page states all of this: `docs/open-source.md`.**
  Published at `/docs/open-source`, in the nav next to Self-host. It is the
  URL to hand to anyone who asks "is this open source?" and the place the
  README's licence section points at for the long form. Grafana's
  `/oss/grafana` is the model.

## Consequences

- No new domain, DNS, cert, workflow or publisher. The docs guardrails
  (nav test, link and anchor test, style script, STE linter) cover the new
  page like any other.
- The README and `/docs` must both keep saying "Managoat is a hosted
  Fountain" or the split stops being legible. The README's licence section
  now links the page; the page links the README's licence table's targets
  (`LICENSE`, `ee/LICENSE`, `NOTICE`, 0027).
- Marketing copy on the hosted homepage is free to lead with Managoat, but
  the "open source" sentence and the repo link stay above the fold. That
  copy lives with the hosted instance's branding and is not versioned here.
- Search: "fountain agent sandbox" resolves to the repo and `/docs`;
  "managoat" resolves to the product. That is the intended split and the
  reason not to rename.

## What would change this

A second organisation running or contributing to Fountain at a scale where
neutral ground matters, or a foundation transfer. Either is the governance
reason that justifies pattern 3, and it would come with the second maintainer
needed to keep a second site alive.

## Related

- 0027 — the AGPL relicensing that makes the open-source identity matter.
- 0032 — the hosted overlay leaving the repo; the same "product and project
  are different things, kept in one place each" line.
- #1008 / #1011 — the GitHub Pages retirement and tombstone; the last time a
  second publisher for the same content was tried.
