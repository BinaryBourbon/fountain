---
name: build-fountain-app
description: Build an application on top of the Fountain API — a browser app, a bot, an internal tool, anything that hires agents, sends them prompts and renders what they do. Use whenever the user says "build an app on Fountain", "a client for Fountain", "another fountain-team / workbench / demo app", "Sign in with Fountain", or wants to ship something that talks to /api from its own origin. Covers the shape (static SPA on the SDK, or a small server in front), auth (OAuth code + PKCE, tokens are API keys), streaming, the server-side registration an app needs (API_CORS_ORIGINS, OAUTH_CLIENTS), the home-cloud hosting recipe, and the traps every previous app hit.
---

# Build an app on Fountain

Fountain's own UI is a console. Every product surface that talks to a person
is a separate app on `/api`, on its own origin, with no privileged access.
Three of them are the reference implementations — clone their shape rather
than inventing one:

| Example | Local checkout | Shape | Study it for |
|---|---|---|---|
| [fountain-team](https://github.com/jhgaylor/fountain-team) | `~/dev/jhgaylor/fountain-team` | static SPA, raw `fetch` (predates the SDK) | roster + thread + queue, team stream, PKCE sign-in (`src/lib/oauth.ts`) |
| [fountain-workbench](https://github.com/BinaryBourbon/fountain-workbench) | `~/dev/BinaryBourbon/fountain-workbench` | SPA **plus a Bun server** (`server/`) | when an app needs its own backend: shared projects, a member never holds the owner's key, project-scoped proxy of `/api`, an MCP surface for the agent |
| [fountain-demos](https://github.com/jhgaylor/fountain-demos) + the `*.inevitable.fyi` suite | `~/dev/jhgaylor/fountain-demos` (landing page only), `~/dev/jhgaylor/{briefing-room,table-talk,repo-sage,mission-control,watchtower,arena,mend,rounds}` | one static app per repo, all cloned from `jhgaylor/dns-desk`; Mend and Rounds add a Bun `server/` because a GitHub App private key cannot live in a browser | the hosting recipe (Dockerfile + build.yml + `k8s/`), the `lib/spec.ts` + `lib/protocol.ts` pair (the prompt asks for a fenced answer block, the parser reads it back; change one, change both), lazy hiring on first use |

The public manual already explains the domain; **read it before writing
code, do not re-derive it**:

- `docs/build/index.md` — why the app is static files + a bearer token
- `docs/build/pieces.md` — agent / conversation / sandbox / environment / vault, what happens between Enter and the first word, the two streams, where tenancy lives
- `docs/build/team-chat.md` — the whole app in SDK calls, in order (hire, roster, message, stream, thread, busy/stop/images/search, connectors, routines, ship)
- `docs/sdk.md` — the SDK surface, the error table, the browser section
- `docs/api.md` — every route, incl. *Sign in with Fountain*
- `sdk/typescript/examples/*.ts` — compiled in CI, so they are true

## 1. Decide the shape

Ask one question: **does anyone besides the key's owner need to see the
data?**

- **No** → a static SPA. No backend. Key in `localStorage`, OAuth for
  sign-in, `@agentshit/fountain-sdk` in the browser. This is fountain-team,
  fountain-conversations, dns-desk and all six demo apps. Default here.
- **Yes** (sharing, cross-user rooms, a credential the browser must not
  hold, your own data model) → the workbench shape: a small server that
  holds the owner's key encrypted, authenticates its own users by asking
  Fountain whose key it is (`GET /api/auth/me`), and **proxies a narrowed
  `/api`** so the browser still runs an ordinary SDK client with the proxy as
  `baseUrl` (`server/proxy.ts`). Fountain has no team/org/sharing primitive
  and no per-user prefs store; anything of that kind is the app's own table.

Persist app-only structure (projects, work items, pinned things) in the
app, but make membership **durable on Fountain** via `channel_id`
(`<app>:<scope>/<id>`), so the tree can be rebuilt from
`GET /api/conversations` after a wipe. Pass `fresh: true` on create when a
channel must not *resume* an existing conversation.

## 2. Stack

bun + vite + react + TypeScript, `@agentshit/fountain-sdk` (current
`1.0.0`; the `browser` export condition works under Vite, no runtime deps).
Use the SDK. fountain-team and the demo apps predate it and vendor a
hand-rolled `src/api/client.ts` + `lib/sse.ts` + `lib/acp.ts` from dns-desk;
the SDK is those three files done once, with `blocks` on by default. Copy
`package.json` / `tsconfig.json` / `vite.config.ts` from fountain-workbench.
Scripts: `dev`, `build` (`tsc --noEmit && vite build`), `test` (`bun test`).
A mock/fake Fountain in tests, not the real one (`server/app.test.ts` in the
workbench is the pattern; see the envelope trap in
[references/traps.md](references/traps.md)).

Settings the user must be able to change at runtime: **base URL** (defaults
to `https://fountain.inevitable.fyi`) and the key. The hosted builds work
against any Fountain that admits the origin.

## 3. Auth: Sign in with Fountain, paste-a-key as fallback

OAuth 2.0 authorization code + PKCE (S256), public client, no secret, no
refresh token. The token **is** a 30-day full-scope API key named
`oauth:<client_id>` (ADR 0021). Sign-out is `POST /api/oauth/revoke` with
the token. ~80 lines, copied verbatim in
[references/sign-in.md](references/sign-in.md).

The client id and the **exact** redirect URI must be registered on the
server — a client nobody registered renders an error page and redirects
nowhere. Registration is a Fountain PR, not something the app can do
(§5). Keep the pasted-key path: the CLI, sandboxes (`$FOUNTAIN_TOKEN`) and
a dev instance with no client registered all use it.

## 4. The four things people judge an app on

1. **The 202 is not the answer.** `POST …/messages` and `POST /api/conversations` queue a turn; the words arrive on a stream. Await the SDK `Run`, iterate `run.textStream`, or read the team/events stream.
2. **Render blocks, never a dialect.** `?blocks=true` (the SDK sets it) folds ACP/stdout into `text | thinking | tool_use | tool_result | init | result | error | raw`. fountain-team once shipped a 200-line ACP parser — do not.
3. **Busy is not an error toast.** Catch `ConversationBusyError`, queue locally, flush on the `turn/done` event. Branch on `error.code`, never on status.
4. **Show the real error.** A banner with `status` + `code` (`describeError`) instead of "could not be reached" — the workbench's generic line cost Jake a round trip on a CORS failure. `ConnectionError` in a browser is almost always CORS.

Plus: an `<img src>` at `/api/agents/:id/avatar` is a 401 — fetch with the
bearer and use an object URL. Secrets are write-only (`secrets.list()`
returns keys); say so in the UI when someone pastes a token.

## 5. Register the app on the server (a Fountain PR)

Two env vars on the Fountain deployment, both exact-match lists:

| Var | Where | What |
|---|---|---|
| `API_CORS_ORIGINS` | home-cloud `platform/fountain-site/patches/deployment.yaml` | one exact origin per app (`https://<host>`, no path) |
| `OAUTH_CLIENTS` | same file, JSON | `{"id":"<repo-name>","name":"…","redirect_uris":["https://<host>/"]}` — trailing slash, exact |
| `config/dev.exs` `:oauth_clients` | this repo | add the client with `http://localhost:5173/` and `:5174/` so `bunx vite` can sign in against a local server |

Convention: `client_id` = repo name. If the app *replaces* a first-party
surface (conversations or team), it is also wired through `Fountain.Apps`
(`CONVERSATIONS_APP_URL` / `TEAM_APP_URL`) — that seam is the only place the
server knows where an app lives.

Local dev against a local Fountain:
`API_CORS_ORIGINS=http://localhost:5173 PORT=4000 mix phx.server`. A dev
instance has no `SPRITES_TOKEN`, so a real turn needs prod or a runner.

## 6. Ship it

Static → nginx image → GHCR → Flux on home-cloud, at `<name>.inevitable.fyi`
(wildcard DNS already resolves; GHCR packages under jhgaylor are public).
The full recipe, file by file, is
[references/ship.md](references/ship.md). GitHub Pages is the older path
(`jakegaylor.com/<app>/`) and still works for a pure SPA; the workbench
moved off it because the demo suite shape is what home-cloud already runs.

## 7. Before calling it done

- Sign-in tested in **Firefox**, not only headless Chrome (the User-Agent preflight trap).
- One real turn on prod: hire, message, see blocks render, see `turn/done` on the stream.
- `bun test` + `tsc --noEmit` green; CI = build.yml on push to main.
- The Fountain PR (CORS + OAuth client) merged **and deployed** — check `build.yml` on main, then the pod env, before testing sign-in; a green PR gate proves nothing shipped.
- Read [references/traps.md](references/traps.md) once; every entry cost a previous app real hours.
