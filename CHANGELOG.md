# Changelog

All notable changes to Fountain are documented here. Format:
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/).

Pre-1.0, a minor bump (`0.x` → `0.y`) may include breaking changes; when one
does, the release carries an **Upgrade notes** section. Patch releases are
always safe to take. Every release publishes the server image to
`ghcr.io/binarybourbon/fountain` as `vX.Y.Z` (immutable) and `vX.Y` (moving,
newest patch in the line). The full policy, including how migrations run on
upgrade, is in
[Versioning and upgrades](https://binarybourbon.github.io/fountain/self-hosting/#versioning-and-upgrades).

---

## [Unreleased]

### Added

- **`!rotate` from a Buzz channel opens a new conversation.** The channel-bound
  resume (#774) meant a rotated harness's next `session/new` landed straight
  back on the same conversation, so rotation did nothing on a hosted agent.
  The harness now sends `_meta.freshSession: true` on that one `session/new`
  (block/buzz#6103); `fountain acp` forwards it as `fresh: true` on
  `POST /api/conversations`, which unbinds the current conversation from the
  channel (it keeps running and is retired like any other idle one) and opens
  a new one as the binding. `fresh` is documented in the OpenAPI schema and
  ignored without `channel_id`.

### Fixed

- **`!shutdown` no longer restart-loops a hosted harness.** The supervisor
  restarts `buzz-acp` on any exit and the fresh process replayed the same
  `!shutdown` from its subscription backlog — five exits per command before
  the message aged out, ending *online*. The harness now ignores owner
  control commands created before it started (block/buzz#6104). The pin moves
  to `buzz-acp-v0.5.14-fountain.3` for both changes.

- **A hosted Buzz agent now honors the desktop's "respond to" policy — anyone
  (or an allowlist) can `@`-mention it, not just its owner.** `buzz-acp` takes
  its inbound author gate from `BUZZ_ACP_RESPOND_TO` and defaults to
  `owner-only`; the desktop sets that when it spawns the harness itself, but the
  Fountain-hosted harness never got it, so every hosted agent silently dropped
  mentions from anyone but the owner whatever the record said. The
  `buzz-backend-fountain` provider now forwards the desktop's `respond_to` /
  `respond_to_allowlist`, `POST /api/buzz/agents` accepts and stores them on the
  identity, and the launch sets `BUZZ_ACP_RESPOND_TO` (and the allowlist var in
  `allowlist` mode). A converging deploy that changes a launch-relevant field
  (the gate, the environment override, relay, display name or agent) now
  restarts the running harness so it takes effect — previously a re-deploy onto
  a running harness was a no-op. Rebuild the provider binary to pick this up.
  (#790)

- **Owner control commands (`!rotate`, `!cancel`, `!shutdown`) now work from
  the Buzz Desktop composer.** The hosted `buzz-acp` required the message body
  to be *exactly* the command, but Desktop renders the `@Name` mention into the
  body, so `@Fountain Maintainer !rotate` reached the agent as an ordinary
  prompt and a bare `!rotate` was dropped for lacking the `p` tag. The fork pin
  moves to a build carrying block/buzz#6101 (`buzz-acp-v0.5.14-fountain.2`),
  which matches the command with mention text around it. #776 still tracks
  the repin to upstream — it now waits on #6101 as well as #6088.

## [0.12.0] — 2026-08-17

One agent config, many baselines: a conversation can now be provisioned from
an environment other than its agent's, from the API, the CLI, and a hosted
Buzz identity. Also the channel-bound conversations that keep a restarted
`buzz-acp` on the same sandbox, and three fixes for hosted harnesses and ACP
turns across deploys.

### Upgrade notes

- **A migration adds `conversations.environment_id`,
  `buzz_identities.environment_id` and `agents.allowed_environment_ids`.**
  Additive and nullable; runs on boot as usual. Existing conversations and
  identities keep behaving exactly as before (nil = the agent's environment).
- **One-time step for hosted Buzz harnesses started before this release**:
  a harness that predates the launch-in-child fix below keeps its old Horde
  spec (stale launcher path + revoked key) until it is stopped and started
  once. Disable and re-enable each Buzz agent after the upgrade.
- **`buzz-backend-fountain` provider settings gain an optional
  `environment` selector.** Rebuild/reinstall the provider binary to see it in
  the Buzz desktop; existing deploys need nothing.

### Added

- **Per-launch environment override (#783).** A conversation may be provisioned
  from an environment other than its agent's: `environment_id` on
  `POST /api/conversations`, `--environment` on `fountain acp` and
  `fountain run`, `environment_id` on the hosted-Buzz provision request
  (the identity's harness passes it through), and an optional `environment`
  selector in the `buzz-backend-fountain` provider's settings. One agent config can now run
  under N environments — a "fountain engineer" and a "buzz engineer" no longer
  need to be two agents. The override is pinned to the conversation across
  wakes and is part of the `channel_id` resume key. Agents get
  `allowed_environment_ids`, the same shape as `allowed_vault_ids`, to scope
  which environments may stand in for a reviewed one; the agent's own always
  passes.

- **Channel-bound conversations (#774).** `POST /api/conversations` accepts
  an opaque `channel_id`; when set, the latest live conversation for the same
  agent, vault and channel is resumed (200, `meta.resumed: true`) instead of
  a new one being opened (201). `fountain acp` forwards `_meta.channelId`
  from `session/new`, so a chat harness that forgets its sessions on restart
  — `buzz-acp`, on every hosted deploy — lands back on the same conversation
  and sandbox. The hosted `buzz-acp` is built from a fork carrying the
  upstream change that sends the channel id (block/buzz#6088;
  `buzz-acp.source`) until it merges — #776 tracks the repin.

### Fixed

- **Two hosted harnesses for one Buzz identity no longer both run.** When two
  nodes ran the boot sweep before the cluster formed, both registered a
  harness and Horde told the loser to exit — but the harness traps exits and
  swallowed the `:name_conflict` message, so two `buzz-acp` processes
  answered the same channel and raced one conversation (`conversation_busy`
  on every second prompt). The loser now stops: port closed, buzz-acp
  reaped, its launch key revoked.
- **A hosted Buzz harness survives deploys and version bumps.** Horde replays
  a harness's child spec on every deploy, and the spec carried the launch:
  the launcher path (`/app/lib/fountain-<version>/priv/buzz-acp-launch.sh`,
  stale after the next version bump — the harness crash-looped on `No such
  file`) and the minted `FOUNTAIN_API_KEY` (revoked by the old node's
  `terminate/2`, then replayed by the new one). The spec now carries only the
  identity id; the launch — key, env, launcher — is resolved by the child's
  start on whichever node runs it. **One-time step after upgrading:** a
  harness started before this fix keeps its old spec until it is stopped and
  started once (disable and re-enable the Buzz agent).
- **An ACP turn in flight across a deploy no longer hangs.** Every deploy
  restarts every `ConversationServer`; the agent in the sandbox keeps running
  and the server reattached to its session — but on the ACP path it reattached
  with no peer, so nobody answered the agent's `session/request_permission`
  and nobody saw the `session/prompt` response. The turn sat `running` until
  the user prompted again (which interrupts it) or the sandbox hit its
  lifetime ceiling. The peer now records the prompt's JSON-RPC id on the turn
  and a reattach starts a peer in attach mode that resumes exactly that
  request; a turn whose prompt was never sent is orphaned cleanly instead of
  left to hang. Replayed output is de-duplicated by content: sprites replays
  the last 16 KiB of the session, not the whole buffer, so the byte-count
  skip could not apply.

## [0.11.0] — 2026-08-16

Fountain can now **host a Buzz agent** — a Nostr identity whose coding-agent
body runs in a Fountain sandbox, with its signing key held server-side in a
vault and no desktop required (ADR 0020, gates 1–4). Minor, not patch, because
the release image changes underneath: new base image, three baked binaries, and
a background supervisor that starts on boot.

### Upgrade notes

- **Runtime base image is now `debian:trixie-slim`** (was bookworm). The
  shipped `buzz-acp` needs glibc ≥ 2.38, which bookworm does not have. If you
  run the published image, nothing to do; if you build your own runtime stage
  on bookworm, `buzz-acp` will not start there.
- **The image now bakes three extra binaries**: `buzz-acp` and `buzz` (built
  by us for amd64 **and** arm64 from the pinned block/buzz source, checksum
  verified at build time) and the `fountain` Go CLI. `runtime.exs` finds them
  at their baked paths; `BUZZ_ACP_BASE_URL` / `FOUNTAIN_CLI_PATH` exist only
  for a non-standard layout (see the configuration reference).
- **A boot sweep starts a `buzz-acp` harness for every enabled Buzz identity**
  (Horde-supervised, one per identity, cluster-wide). With no identities
  provisioned it is inert — no new process, no new egress.
- **New migration** for `buzz_identities`. Runs with `mix ecto.migrate` /
  the release migrator as usual.
- **Markdown rendering moved to a Rust NIF** (MDEx / comrak, precompiled).
  The published image is a supported target; a from-source build on an
  unsupported platform needs a Rust toolchain.

### Added

- **Hosted Buzz agents.** A `BuzzIdentity` binds a Nostr keypair (kept in a
  vault, never in the row) to a Fountain agent; a supervised `buzz-acp`
  harness per identity keeps the agent online on its relay and drives
  `fountain acp` for each mention, off the user's desktop (#739, #740, #742,
  #745). Provision one with `POST /api/buzz/agents` (idempotent on the
  pubkey; the nsec is stored server-side and never returned), list with
  `GET`, tear down with `DELETE /:id` (#753, #754) — or from the Buzz
  desktop via the new **`buzz-backend-fountain`** remote-agents provider
  binary in `cli/` (#755).
- **The reply path — the sandbox never sees the key.** A Buzz-driven
  conversation gets a Fountain-hosted MCP server injected at `session/new`
  (`POST /api/mcp/buzz/:conversation_id`, authenticated with the sprite
  token) exposing `buzz_send_message` and `buzz_react`; Fountain resolves the
  agent's key server-side and publishes through the baked `buzz` CLI, with
  credentials in the environment, never in argv (#750, #751, #752). A
  successful publish audits `buzz.published` without the message content.
- **`buzz-acp` diagnostics reach the pod log**, tagged per identity, so
  `kubectl logs` shows relay connection and presence (#747); and the desktop's
  ACP activity panel populates (`BUZZ_ACP_RELAY_OBSERVER`, #756).
- **OpenClaw is a documented ACP client** of `fountain acp` — config-only via
  its `acpx` plugin, verified against the real acpx 0.11.2 and a live gateway
  (#757, #758, #759, #760). New page at `/docs/integrations/openclaw`.
- **Buzz integration page** in the in-app docs, with inline SVG diagrams —
  the docs renderer gained a trusted path that keeps a scrubbed
  `<figure>`/`<svg>` block as real markup for the in-repo corpus only; agent
  output is still fully escaped (#761).
- **`decisions/` is an OKF bundle**, validated in CI, with a generated index
  (#741); ADR 0020 records the Buzz-at-the-gateway design (#734).

### Changed

- **Markdown rendering moved from Earmark to MDEx.** Earmark is retired
  upstream (`mix hex.audit` flags it as unmaintained), and it sat under
  the XSS-hardened renderer for agent output and the in-app docs. The
  same guarantees hold on MDEx (comrak): raw HTML is neutralized to text
  on the untrusted path, `javascript:`/`data:` URLs are dropped, and the
  docs corpus keeps its scrubbed SVG diagrams. Two visible differences:
  a link or image with a dropped URL is now unwrapped to its text/alt
  instead of rendered as an element with no `href`/`src`, and an
  HTML-comment block is dropped rather than shown as escaped text (#762).

- **`fountain acp` implements `session/set_config_option`** as
  accept-but-do-not-apply — a Fountain agent's model is set on the agent, so
  a client's push is acknowledged and ignored rather than rejected as
  method-not-found, which OpenClaw's acpx treated as fatal (#759).

### Fixed

- **A hosted `buzz-acp` is reaped on stop, not orphaned.** buzz-acp closes
  the BEAM's pipe while it keeps running, which both faked an exit (a
  restart → duplicate harness) and survived `Port.close` (an agent that stays
  online after stop, across deploys). A launcher middleman now delivers one
  true exit status and TERM→KILLs the child on close (#746).
- **`fountain acp` no longer trips OpenClaw's session-control sync.** The
  `session/set_config_option` reply advertised a config-option list, and
  acpx narrows the controls it will push to whatever that list says — so the
  next control (`thinking`) failed with "does not advertise config option"
  and the gateway turn died. The reply now carries no list (Fountain has no
  per-session options; the agent's model is authoritative) and says
  `_meta.fountain.applied: false`. The full OpenClaw gateway round trip —
  brain → `sessions_spawn` → acpx → `fountain acp` → sandbox → reply — is
  green against the real acpx 0.11.2 (#760).

- **In-app docs anchor links land on their section.** `/docs` and `/help`
  headings now carry GFM-style ids, so the docs' `#anchor` cross-links
  (e.g. `/docs/architecture#the-secrets-model`) scroll to the heading
  instead of the top of the page, matching the public MkDocs site (#765).

## [0.10.2] — 2026-08-15

### Fixed

- **The CLI shows agent output again.** Since ACP became the only path
  for claude, codex and opencode, `fountain run` printed a turn starting
  and finishing with nothing in between: the renderer only understood
  claude's own stream-json, so every protocol line rendered as empty.
  Agent text, tool calls and thinking now appear, matching how the
  legacy path always looked (#723).

- **A lost wake race no longer strands a conversation on a dead
  sandbox.** Waking a dormant conversation repointed it at its new
  sandbox *before* the server started; when the start lost the race, the
  loser terminated its own row without undoing that, leaving the
  conversation naming a sandbox it had just retired while the winner
  served turns on another. Visible as a conversation that reads
  `terminated` through the API while it answers normally, an orphan
  sandbox nothing references, and a quota slot spent twice. The row is
  now repointed only after the server starts — which also means a loser
  can no longer retire the sandbox a winner is reusing (#717).

- **A model the runtime refuses is no longer invisible.** The turn still
  continues on the runtime's default, but the notice went only to
  `stderr` — the one stream `?streams=acp,stage` drops and `fountain
  acp` treats as noise, so an editor never heard. It is now a
  `model`/`failed` stage event carrying the requested model and the
  runtime's own explanation, which the conversation view, the API, the
  CLI and an editor's log all receive (#724).

## [0.10.1] — 2026-08-15

### Added

- **`fountain acp --vault <name-or-id>`** attaches a vault to every
  conversation an editor entry opens. Vault values override the agent's
  environment, so this is where a secret belonging to *that entry* goes —
  an identity the agent posts under, a token scoped to one workspace. Two
  entries pointing at the same agent stay separate; the same secret in a
  shared environment would be used by every agent attached to it, which
  is a good way to have one agent publish under another's name.

## [0.10.0] — 2026-08-15

### Upgrade notes

- **Sprites sandboxes now expose their HTTP endpoint publicly.** Every
  sprite already had a URL; it required a platform credential to open,
  which meant a web service an agent started could not be reached by the
  person who asked for it. Fountain now sets `url_settings.auth =
  "public"` when it creates a sandbox, so **anything an agent serves is
  reachable by anyone who has the URL** (a name plus a random suffix,
  not guessable, but not secret either). Set
  `config :fountain, :sprites_public_urls, false` to keep the previous
  behaviour: sandboxes keep their URLs, and only a token holder can open
  them. E2B and Daytona are unaffected — they expose per-port hostnames
  rather than one sandbox URL, and report no URL at all.

### Added

- **A sandbox can tell you where it is running.** Agents asked "what's
  the URL?" had no way to answer: the platform assigns the endpoint
  outside the sandbox, and inside it the hostname is just `sprite`. The
  URL is now stored on the sandbox, returned as `sandbox.url` on the
  conversation API, and set inside the sandbox as **`SANDBOX_URL`**.
  Providers that have no such endpoint report `:unsupported` rather than
  a guess — a URL that does not resolve is worse than none, because the
  agent hands it to a human who then blames the service.

## [0.9.1] — 2026-08-15

### Fixed

- **ACP clients could not add a Fountain agent.** Buzz refused one with
  "unknown reported no models. Check that the CLI is installed and signed
  in" — a message about a different problem. Two fields the protocol
  expects were missing: `initialize` sent no `agentInfo`, so a client had
  no name for us but "unknown", and `session/new` reported no model
  state, which reads as an agent that cannot run anything. Both are now
  sent; the model list is the agent's own model, since that is what every
  conversation on it runs (#721).

### Added

- **`fountain --version`.** The binary had no version at all, which is
  why the ACP handshake had none to report. Release builds stamp the tag
  in; a build from source says `dev`.

## [0.9.0] — 2026-08-15

### Upgrade notes

- **ACP is now the only way Fountain talks to claude, codex and opencode.**
  The legacy spawn path is deleted and the per-agent `metadata["acp"]`
  opt-out is retired — see *Changed* below. Nothing is required of an
  operator, but the change is worth knowing before you upgrade: those
  runtimes now carry their MCP servers, session ids and tool spans over
  the protocol rather than through argv and config files. Gemini agents
  are untouched and stay on their legacy path (#658, #659).
- **Sandbox backends are pluggable, and Sprites remains the default.** An
  instance that sets nothing keeps behaving exactly as before.
  `SANDBOX_PROVIDER` picks a different default (`sprites`, `e2b`,
  `daytona`), each provider needs its own API key, and E2B and Daytona
  need a prepared template/snapshot before they will run anything.
- **Two additive migrations** (`sandboxes.provider`,
  `agents.sandbox_provider`); both run automatically on boot per the
  standard upgrade flow.

### Added

- **Drive a Fountain conversation from your editor.** `fountain acp` is a
  new CLI subcommand that speaks the
  [Agent Client Protocol](https://agentclientprotocol.com) on stdio, so an
  ACP-capable editor — Zed and friends — can open a conversation on one of
  your agents, prompt it, watch messages, thoughts and tool calls stream in,
  cancel a running turn, and reopen the transcript later. The turn runs in
  Fountain, not in the editor: close the laptop mid-turn and it keeps going.
  It is a control surface, not a workspace — the agent works on its sandbox's
  files, declares no access to the ones open in your editor, and deliberately
  does not send sandbox paths as clickable locations. Agents on a runtime
  that does not speak ACP are refused by name. Setup and editor config are on
  the new [Editors (ACP)](https://binarybourbon.github.io/fountain/integrations/editors/)
  page (ADR 0015; #709, #698–#707).

- **The conversation event stream is documented as the interface it now is.**
  Both `GET /api/agents/:id` and `GET /api/conversations/:id` gained a derived
  read-only `acp` boolean, and the SSE endpoint's `?streams=` parameter now
  documents every stream it carries — including `acp`, one ACP
  `session/update` notification per line — plus the event envelope's fields.
  Two clients render from this stream now, so its shape carries compatibility
  obligations (#702, #707).


- **The documentation site is served in-app at `/docs`.** The same markdown
  GitHub Pages publishes is embedded at compile time and rendered through
  the app's sanitizing markdown pipeline, with the sidebar mirroring the
  `mkdocs.yml` nav (a test fails on drift). Public, like the Pages site;
  the curated `/help` topics are unchanged and now link to it.

- **Pluggable sandbox backends: E2B and Daytona join Sprites.** The
  sandbox layer is a provider-agnostic behaviour (`Fountain.Sandbox`) with
  an executable conformance suite; `SANDBOX_PROVIDER` picks the instance
  default, an agent can pin `sandbox_provider`, and every sandbox row
  records the provider that owns it — parked sandboxes always wake where
  their disk lives. E2B (`E2B_API_KEY`) pauses idle sandboxes with a
  filesystem+memory snapshot; Daytona (`DAYTONA_API_KEY`) stops them with
  the disk preserved. A provider that cannot park degrades to
  destroy-on-idle, and the reaper reconciles each provider independently.
  Reference sandbox images live in `images/e2b/` and `images/daytona/`;
  decisions/0018 has the full design (#676–#686).

- **Tool-level OTel spans for every ACP runtime.** Tool-call tracing was
  claude-only (a parser over its proprietary stream-json); ACP's
  `tool_call`/`tool_call_update` carry the id and status for all runtimes,
  so every ACP turn now emits `fountain.tool_use` child spans plus
  `fountain.text_bytes`/`thinking_bytes`/`tool_calls` turn totals. Cost
  and token-usage attributes do not exist on the ACP path — the protocol's
  stop reason carries no usage block (#637).

### Changed

- **The sandbox docs now tell the provider story straight.** The docs site
  gets a "Sandbox providers" section — one contract
  (`Fountain.Sandbox` + its conformance suite), three implementations
  (Sprites, E2B, Daytona) — with a new contract overview page, and the
  Sprites page no longer claims to be the only backend.

- **The four dialect parsers are out of the conversation LiveView.** The
  24 `event_blocks/2` clauses move to a dedicated, tested
  `LegacyBlocks` module: gemini's dialect stays live (#659), and the
  claude/codex/opencode parsers are frozen — they render pre-ACP
  history only and are deleted when that history ages out. The rule
  this closes: a dialect parser is never written again; a runtime that
  doesn't speak ACP gets an adapter at the sandbox boundary (#642).
- **The legacy spawn path for claude, codex and opencode is deleted; ACP
  is the only way Fountain talks to them.** The three `build_command/5`
  argv builders go — and with them `--dangerously-skip-permissions`,
  `--dangerously-bypass-approvals-and-sandbox`, codex's
  resume-by-guessing `--last`, and the claude-only stream-json OTel
  tracer (superseded by the protocol-wide ACP tracer). The per-agent
  `metadata["acp"]` flag is retired: with no legacy path left there is
  nothing to opt out into, and stale metadata is ignored. The ACP
  decision now keys on the conversation's runtime rather than the agent,
  so conversations whose agent was deleted keep working. Gemini keeps
  its full legacy stack until its `session/load` is fixed upstream
  (#658, #659).
- **MCP servers now reach claude, codex and opencode agents through the
  protocol, not the sandbox.** The three out-of-band mechanisms — claude's
  `mcp add-json` provisioning loop, codex's `config.toml` writer,
  opencode's `opencode.json` writer — are deleted; `session/new`'s
  `mcpServers` param is the single path (#636). Consequence for the
  `"acp": false` escape hatch: an opted-out agent runs its legacy turns
  without MCP servers. Gemini's argv mechanism stays with its legacy
  path.
- **ACP is now the default protocol for claude, codex and opencode
  agents.** The per-agent `metadata["acp"]` flag flips polarity: instead
  of opting in with `true`, agents on those runtimes speak the Agent
  Client Protocol unless the agent carries `"acp": false` (an operational
  escape hatch, set over the API). Gemini agents stay on the legacy path
  until gemini's `session/load` is fixed upstream (#658, #659). ADR 0014
  gate 4 begins here.

### Fixed

- **A filtered replay dropped ACP events entirely.** `?streams=` has two
  implementations — one for history, one for live events — and the history
  one carried a list of stream names written before ACP existed, so
  `?streams=acp` returned a conversation's future and none of its past. The
  editor integration's `session/load` replayed an empty transcript and every
  mid-turn reconnect silently lost the updates it missed. The filter no
  longer keeps a list, and one test now runs the same cases through both
  halves (#716). This is the API-side sibling of the rendering bug fixed in
  0.8.1 (#669): both were a stale allow-list meeting a new stream name.


## [0.8.1] — 2026-08-13

### Fixed

- **ACP agents' replies now render in the conversation view.** Since the
  ACP conversion, an ACP-flagged agent's output — stored under its own
  event stream — was filtered out by all three view modes, which still
  keyed on `stdout`: the transcript showed the agent never answering while
  the API and CLI streamed the reply fine. ACP output now follows the
  stdout pill, including for accounts with stream preferences saved before
  the flag existed (#669).

## [0.8.0] — 2026-08-13

### Upgrade notes

- **Sandboxes now rest in a new `suspended` status instead of being
  destroyed when idle.** Suspended sandboxes keep their sprite alive at
  sprites.dev indefinitely (scaled to zero; treated as free) and do not
  count toward the concurrent-sandbox quota. Anything consuming the API's
  sandbox `status` field needs to accept the new value, and operators
  who relied on idle reclaim to clean up sprites should know it no longer
  does — only the max-lifetime ceiling, explicit termination, tenant
  suspension and account deletion destroy sprites now.
- **One additive migration** (`sandboxes.last_resumed_at`); it runs
  automatically on boot per the standard upgrade flow. No new required
  configuration.

### Added

- **Agents can opt into speaking the Agent Client Protocol to their
  runtime.** Setting `metadata.acp: true` on an agent whose runtime is
  `claude`, `codex` or `opencode` replaces the per-turn CLI invocation with
  an ACP connection scoped to the turn: prompts, images and MCP servers are
  carried over the protocol, `agent.model` is honored on every turn, and
  follow-up turns resume the runtime's own session (`session/resume` or
  `session/load`, whichever the adapter advertises). The legacy path remains
  the default and is unchanged (#647, #648, #656). `gemini` is deliberately
  held back from the flag until its upstream `session/load` can find the
  session it just wrote — a flag set on a gemini agent is a no-op, not an
  error (#659, #660, #661). The design record is decisions/0014 through
  0016.

### Changed

- **An idle sandbox is suspended rather than destroyed, and the next prompt
  reattaches to the same sprite — the agent keeps its memory of the
  conversation.** Idle reclaim was built on the premise that an idle sprite
  bills until destroyed; it doesn't (sprites scale themselves to zero), and
  the destroy was silently costing every idle conversation its runtime
  session (#649). The max-lifetime ceiling still destroys — it exists to
  bound runaway busy compute — and its message still says honestly that the
  agent will not remember. The ceiling now measures a continuous run
  (restarting on each wake) rather than calendar age, so a conversation
  parked for a week is not destroyed the moment it is woken. See
  decisions/0017.
- **Environment warm-start checkpoints are no longer created.** A
  checkpoint id is scoped to the sprite that made it, and an environment's
  checkpoint was only ever restored into a *different* sprite — so every
  restore failed and the checkpoint only spent time and storage. Creation
  is now off by default behind a flag, ready to re-enable if the platform
  grows a create-from-checkpoint call (#654).

### Fixed

- **ACP authentication only ever uses an API-key method, never whatever the
  adapter listed first.** The fallback could pick an interactive login flow —
  which a headless sandbox can never complete, leaving a turn in flight
  forever, disarming idle reclaim and billing the sprite to its ceiling.
- **Checkpoint creation never actually captured an id** — the extractor
  matched a shape the library doesn't emit, so `checkpoint_id` was never
  written and every restore was skipped; the id is now read from the
  checkpoint listing (#653). Moot for warm starts since checkpoints stopped
  being created (#654, above), but the restore path is correct if
  re-enabled.

## [0.7.0] — 2026-08-07

### Upgrade notes

- **No migrations, and no new required configuration.** An instance on
  v0.6.x upgrades by taking the new image.
- **`agent.model` now takes effect on the `claude`, `codex` and `gemini`
  runtimes, where it was previously ignored.** Those three built
  model-agnostic argv, so an agent configured for
  `anthropic/claude-haiku-4-5` ran whatever the CLI defaulted to. After this
  release it runs the model it says it runs — which is the point of the
  field, but it means an existing agent can start using a different model,
  with different cost and latency, without its config having changed. Check
  the model on agents you did not deliberately set (#553)
- **An agent whose provider cannot be reached by its runtime is now rejected
  on write.** `anthropic` for `claude`, `openai` for `codex`, `google` for
  `gemini`; `opencode` is unconstrained as the only multi-provider
  front-end. Previously such a pairing saved cleanly and did nothing; now it
  would ship a model flag the CLI cannot serve, so the changeset refuses it.
  **Existing rows are not migrated or validated** — the check runs on write,
  so a stored mismatch surfaces the next time that agent is edited, not at
  upgrade. Across production, all 45 agents were already `claude`/`anthropic`
  with model ids the CLI accepts (#553, #554)
- **Audit rows written from here on use a converged actor vocabulary.** Email
  verification records `ui` or `api` rather than the bare `system` it derived
  before a session exists, and operator-driven billing transitions record
  `admin` rather than `system:admin`. Rows already written keep their old
  spelling, so anything you query or alert on by actor needs to accept both
  (#604)

### Added

- **The agent form suggests models, and a misspelled provider is caught at
  save time.** `agent.model` was format-checked and nothing more, so
  `anthopic/claude-sonnet-4-6` saved cleanly and then failed inside the
  sandbox: `opencode` reads the prefix to decide which API key to export and
  falls through to none for an unrecognised one, so the run started with no
  inference credentials at all and died as an auth error in the conversation
  log. The provider is now validated on write against the three Fountain
  actually holds credentials for — `anthropic`, `openai`, `google` — and the
  model field offers a `<datalist>` of current models, scoped to the selected
  runtime so it can't lead you into the runtime/provider mismatch #553 added.
  The **model id is deliberately still unchecked**: type anything and it is
  passed to the CLI as-is (the form says so), so a model released after your
  Fountain version works without waiting for a release (#554)

- **`MIGRATE_ON_BOOT=false` — run migrations somewhere other than at boot.**
  The release migrates before it serves, on every replica, which is right for
  the single-replica shape it ships as and rules out the standard Kubernetes
  shape: migrations once in a Job, app pods that only serve. The switch turns
  the boot-time migration off — both the paths that did it, the image's `CMD`
  and the `Ecto.Migrator` child in the supervision tree — and leaves
  `bin/migrate` untouched, since that is what the Job runs. Default unchanged:
  an instance that sets nothing migrates exactly as before. Nothing checks
  that the Job ran, so ordering it before the rollout is the operator's job;
  [the guide](https://binarybourbon.github.io/fountain/self-hosting/#running-migrations-in-a-job)
  and `deploy/k8s/README.md` say so and carry the manifest (#610)

### Changed

- **The audit trail's actor vocabulary is closed, and the rules behind it are
  now a decision rather than a habit.** `decisions/0013-audit-trail.md`
  records what the #540 campaign settled — mutations audit inside the context,
  never inside a transaction, never recording values — and fixes the call
  sites that had drifted from it. The members are `self`, `ui`, `api`,
  `sprite`, `admin`, `admin:<operator_id>` and `system:<worker>`; a bare
  `system` is now a defect signal rather than a value, since the only routes
  that produced it — email verification, which runs before a session exists —
  are always a person whose surface the call site knows. Operator-driven
  billing transitions record `admin` instead of claiming to be unattended as
  `system:admin`. A guard test fails the build on an actor outside the set,
  or on an ADR that has stopped naming one (#604)

### Fixed

- **`agent.model` is honored on the `claude`, `codex` and `gemini` runtimes.**
  The field is required, format-validated and front-and-centre in the agent
  form, but only `opencode` ever read it — the other three built
  model-agnostic argv, so an agent set to a cheaper or larger model silently
  ran the CLI's default with no error and no signal the setting did nothing.
  All three CLIs do take a model flag, each wanting the bare id rather than
  the canonical `provider/model_id`; that translation now lives in one place,
  and `opencode` keeps receiving the prefixed string it uses to pick an API
  key. See the upgrade notes — an agent that was quietly running a default
  will change model on upgrade (#553)

- **Two replicas booting together against an empty database no longer race
  each other into a restart.** Ecto's default migration lock is a row lock on
  `schema_migrations` — which cannot serialize the creation of
  `schema_migrations` itself, the one moment on a virgin database when both
  replicas are inside `Ecto.Migrator` at once. The loser died on the type's
  unique index (`pg_type_typname_nsp_index`), Kubernetes restarted it, and the
  retry succeeded: a benign `RESTARTS 1` that reads exactly like a crash loop
  on a first deploy. The lock is now a Postgres advisory lock, taken before
  anything touches the table. Only ever observed at two or more replicas on a
  brand-new database (#610)

## [0.6.1] — 2026-08-07

### Fixed

- **A turn that fails before it starts now says why.** When a runtime exits
  before it reads the prompt, it has already sent its exit code and whatever
  it printed on the way out — but those arrived just after the turn was
  marked failed, on the one path that never registers the command they
  belong to, so they were dropped without a trace. `turns.exit_code` stayed
  `NULL` and every such failure reported the same `:command_exited`: an
  expired key, a renamed binary and an OOM kill were indistinguishable. The
  turn now records the exit code, keeps the runtime's last lines of
  stdout/stderr as ordinary turn output, and reports
  `:command_exited (runtime exited 1)`. The outcome is unchanged — this is
  the diagnosis #603 left missing (#608)

- **`Fountain.Release.verify_email/1` no longer reports failure for work it
  completed.** The account was verified, the first-admin bootstrap ran, and
  then the task crashed on a PubSub broadcast and exited non-zero having
  printed nothing but a stack trace — so any caller checking the exit code
  concluded it had failed and an operator re-running it saw the same crash on
  an already-verified account. The broadcast exists so a waiting page in one
  tab advances when the link is clicked in another, and the release VM starts
  the Repo and nothing else on purpose; it is now skipped when there is
  nobody to hear it. The web paths are unchanged, and `promote_admin/1` was
  never affected. Regression in v0.6.0; v0.4.1 and earlier are unaffected
  (#609, #614)

## [0.6.0] — 2026-08-06

### Upgrade notes

- **No migrations, and no new required configuration.** An instance on
  v0.5.x upgrades by taking the new image.
- **A bearer token belonging to an account that never verified its email now
  gets `403 email_unverified`.** Verification is enforced where the identity
  is established rather than at each door, so `authenticate_api_key/1`
  refuses for such accounts and unverified browser sessions land on
  `/auth/verify-pending` instead of reaching controller routes (theme,
  avatars, export downloads, turn images, the credential POSTs). Nothing is
  affected in practice — across 163 unverified accounts, zero API keys had
  ever been issued — but a key minted before `POST /api/auth/token` was
  closed would have kept working forever, and no longer does (#533).
- **Expect `audit_events` to grow faster.** Mutations now record in the
  context rather than at whichever surface happened to remember, so the UI
  leaves the same trail `/api` always did, and background workers attribute
  their own writes. The retention pruner already covers the table and now
  records its own run; no action needed unless you have tightened retention
  on the assumption of the old volume.
- `POSTGRES_HOST_PORT` is a new optional compose variable, defaulting to
  `5432` — set it if the evaluating machine already runs Postgres there
  (#549). Existing compose files are unaffected.

### Added

- **How long a turn takes, and how long before it says anything, are now
  metrics rather than one-off traces.** Turn duration existed only in the
  `fountain.turn` OTel span and in `turns.started_at/ended_at` — a trace you
  open one at a time and a column you query by hand, neither of which backs a
  dashboard or an alert. There is now a `fountain.turn.duration` histogram
  tagged by runtime and terminal status, and a `fountain.turn.first_output`
  histogram for the gap between hitting enter and the agent visibly doing
  something, which nothing captured at all. First output is measured in bytes
  on stdout rather than parsed tokens, so claude, codex, gemini and opencode
  stay directly comparable; a turn resumed after a restart deliberately emits
  neither, since monotonic time does not survive the restart and a missing
  sample beats a wrong one (#536, #535)

- **Provisioning sub-steps have their own histograms.** `fresh_provision` and
  `reattach` have been measured since #405, so a provision getting slower was
  visible — but which step got slower was not, and attributing it meant
  grepping log lines or opening individual traces. The setup script, package
  installs, network policy, repository clones and checkpoint create/restore
  each export a histogram now, sharing `fresh_provision`'s buckets so the
  parts stay comparable with the whole. The emitters were already firing these
  spans; nothing outside the log and OTel had subscribed. No tags on any of
  them — the span metadata carries conversation and environment ids, and
  promoting one to a label mints a time series per conversation (#537)

- **The `/audit` page has the filters the API got in #526.** `GET /api/audit`
  could narrow the trail by action prefix, resource type and time window; the
  page could not, so the API was strictly better than the UI at the one thing
  the UI is for — "show me every `vault.` event since Tuesday" was a curl away
  and impossible in a browser, where you scrolled 200 rows and hoped. The
  page now takes the same four filters through the same query, with the
  resource-type list built from what is actually in your trail. Filter state
  lives in the URL, so a filtered view is a link you can send someone and it
  survives the 5s refresh. Admins get the filters over the cross-tenant view
  too — previously the person seeing the most events could filter the least
  (#572)

- **`/api/admin/*` makes operator tasks scriptable** — list and inspect
  accounts with the filters the admin UI has, set the sandbox cap, extend a
  trial, comp, suspend, resync from Stripe, delete an account, list and reap
  sandboxes, and read both the cross-tenant audit trail and the privilege
  trail. Every one of these was AdminLive-only, so a bulk trial extension or
  a suspension from an incident runbook meant a human clicking. The surface
  needs three things at once: an authenticated key, `full` scope (a
  sandbox's per-conversation token is not an operator credential even when
  the account is an admin) and the admin role. Refusals mirror the UI — no
  self-suspend, no self-delete, billing actions refused when billing is
  disabled — plus one the UI has no need for: you cannot revoke your own
  admin role, which over an API is a lockout one scripted typo away. Actions
  record the same `admin.*` privilege-trail events, so a curl'd suspension
  is as visible as a clicked one (#527)

- **Billing is self-serve over the API**: `GET /api/account/billing` for
  status, trial and period dates and the current month's usage, plus
  `POST /api/account/billing/portal` and `.../checkout` to mint Stripe URLs.
  All user-facing billing lived in `BillingLive`, so a CLI user who hit the
  subscription gate got a 402 with no programmatic way out, and an expiring
  trial was invisible — `/api/auth/me` carried `subscription_status` and
  nothing else. Checkout refuses with 409 when Stripe already holds a live
  subscription instead of quietly minting a duplicate, and refuses outright
  when Stripe cannot be asked. With billing disabled the endpoints are 404
  with `billing: "disabled"`, matching the UI's redirect. The URL-minting
  rules moved into the billing context so the LiveView and the API cannot
  drift; everything stays in `ee/` (#524)

- **Account data export and account deletion are driveable over the API** —
  `POST/GET /api/account/exports`, `GET /api/account/exports/:id/download`
  and `DELETE /api/account`. These are the closest things Fountain has to
  GDPR flows and both were browser-only. Export keeps its one-per-hour limit
  (429 with `Retry-After`) and, since the API has no PubSub, reports progress
  by polling instead of pushing; the download is the same owner-scoped,
  expiring, audited artifact the session route serves. Deletion is
  irreversible and takes the tenant encryption key with it, so it requires
  both a typed `{"confirm": "<account email>"}` body — the API equivalent of
  the UI's typed-email gate — and a `full`-scoped key, which keeps a
  sandbox's per-conversation token from destroying the account it is running
  inside (#523)

- **Agent avatars have an API**: `GET/PUT/DELETE /api/agents/:id/avatar`, and
  `avatar_media_type` is serialized on the agent so a client can tell one
  exists. Upload and delete lived only in the agents LiveView, and even
  *reading* the bytes required a session — while turn images next door
  already had both a session route and a bearer route, so `fountain apply`
  shipping an avatar file had nowhere to send it. Uploads take raw bytes with
  an image content-type or the same base64 JSON shape prompt images use, cap
  at 5 MB, and are refused with 415 for anything that is not one of the four
  accepted image types — the ingest half of the rule that keeps
  client-declared `text/html` from ever being servable from the app's own
  origin (#528)

- **Onboarding can be completed over the API** —
  `POST /api/account/onboarding/complete`, with `GET /api/account/onboarding`
  and new `onboarding_state` / `onboarding_completed` / `email_verified`
  fields on `GET /api/auth/me`. `complete_onboarding/1` had exactly one
  caller, the wizard LiveView, so an account configured entirely through the
  API stayed permanently un-onboarded and a later browser visit dropped the
  user into a wizard they had no reason to see (#525)

- **`GET /api/audit`** serves the account's own audit trail — tenant-scoped,
  newest first, cursor-paginated, with filters the `/audit` LiveView does not
  have yet (`action_prefix`, `resource_type`, `since`, `until`). Programmatic
  access previously meant scraping a LiveView or requesting a whole account
  export, which is a poor fit for shipping events to a SIEM or an archive.
  `action_prefix` is matched as a literal, so a `%` filters to nothing rather
  than returning the entire trail, and a malformed `since`/`until` is a 400
  rather than a silently unfiltered response (#526)

- **Password and email changes work over a bearer token**:
  `POST /api/auth/password` and `POST /api/auth/email`. Both existed only as
  browser POSTs with session auth and CSRF, so an API-driven account could
  never rotate its own credentials. Both still require the current password —
  a stolen bearer token must not be enough — and sit behind the `full`-scope
  gate so a sandbox's per-conversation token cannot rotate the account
  password. A password change signs out browser sessions but does not revoke
  API keys, which is what it has always done; the response now says so
  (`sessions_invalidated`, `api_keys_revoked`) instead of leaving a caller
  rotating a leaked password to find out later (#521)

- **The auth email flows can be finished over the API.** An API consumer
  could start every one of them — register, resend-verification, forgot —
  and finish none: confirmation and reset were browser routes, so account
  activation required a browser round-trip. `POST /api/auth/verify`,
  `POST /api/auth/reset` and `POST /api/auth/email/confirm` accept the same
  tokens the emailed links carry, so a CLI can prompt "paste the code from
  your email". The links themselves still point at the browser pages.
  `verify` is idempotent and issues no session — an API client mints a key
  at `POST /api/auth/token` once the account is live — and every flow keeps
  the browser path's rate limits, single-use token semantics and audit
  events (#522)

- **Usage counts are in the resource read-model**: agents carry
  `conversation_count`, environments `secret_count` and `agent_count`, vaults
  `secret_count` — on the list *and* single-resource reads, so "is this
  environment in use / safe to delete" is one request instead of an N+1 the
  client assembles. The counting queries already existed for the UI and had
  no controller caller (#529)

- **The conversation read-model the UI has is now the one the API serves.**
  Conversation JSON gained `title`, `turn_count`, `last_active_at`,
  `last_read_at` and a computed `unread`; `GET /api/conversations` takes
  `?roots_only=true` (the context supported it, no caller passed it);
  `POST /api/conversations/:id/read` marks one read; and
  `GET /api/conversations/:id/tree` returns the whole spawn tree —
  ancestors and descendants — so an agent that fanned out can enumerate its
  own sub-conversations instead of keeping client-side bookkeeping.
  `GET /api/conversations/:id` now reports real counts rather than the
  struct defaults. The unread rule had three copies in the web layer and now
  has one, in the context (#520)

- **A conversation's log events are readable as JSON**, not only as an SSE
  stream: `GET /api/conversations/:id/events`, cursor-paginated
  (`?after=`, `?limit=`) with the same `?streams=` filter the stream takes.
  Draining history with `?wait=false` still returned `text/event-stream`, so
  anything fetching, archiving or analysing a conversation's output had to
  implement an event-stream parser for what is a paginated list read. Rows
  carry the same fields the stream sends plus each event's `id` — the same
  value the stream uses as `Last-Event-ID`, so a client can page through
  history and then attach the tail exactly where it stopped (#519)

- **Inference credentials can be set over the API**, so an account can be
  bootstrapped without ever opening a browser: `GET/PUT/DELETE
  /api/account/inference-credentials[/:provider]`. A conversation cannot run
  without one of these, and until now `put_credential` had exactly two
  callers — the settings LiveView and the onboarding wizard — which made a
  headless `register → configure → run` flow impossible. `PUT` runs the same
  provider ping the settings page does and reports the outcomes distinctly
  (422 rejected, 504 timed out, 502 unreachable) so a client knows whether to
  re-type or retry; `validate: false` stores without the ping. Values stay
  write-only, and the endpoints need a `full`-scoped key — a leaked
  per-conversation sprite token must not be able to swap the keys the account
  runs on. Both surfaces now emit `inference_credential.write` / `.delete`
  audit events (#518)

### Fixed

- **A runtime that dies at startup now fails its turn instead of orphaning
  it.** Writing the prompt to a command whose process had already stopped —
  what happens when the runtime exits before reading stdin, from a bad flag, a
  missing binary or an OOM kill — exited the conversation's own server rather
  than returning an error. The supervisor restarted it, the restart found the
  sandbox already `ready` and so reattached, and the turn was left hanging
  behind a `list_sessions` error that named nothing real. The turn now ends
  `failed` and the conversation returns to idle, ready for another prompt.
  Healthy runtimes never took this path — the claude runtime blocks on stdin —
  but fast-exiting ones did, and against a one-shot exec it was close to a
  coin flip (#603)

- **Deleting your account no longer leaves a hole in the record of it.** The
  request that deleted the account was itself audited on the way out — after
  the account row was gone — so the write referenced a user that no longer
  existed, was refused by the database, and was dropped. The account-deletion
  event itself was never affected, but the request beside it vanished. That
  row is now kept, attributed to nobody, which is where it was headed anyway:
  a deleted account's audit rows are anonymised rather than removed, so an
  insert landing a moment earlier would have ended up in exactly the same
  state. Nothing about what a deletion erases has changed (#590)

- **Secret and credential events are recorded in one place instead of five.**
  Writing an environment or vault secret was audited identically by both
  LiveView forms, both API endpoints and `fountain apply` — five copies of the
  same event that had to agree, on the most sensitive data in the system, with
  a sixth surface one forgotten call from silence. Password resets, password
  changes and email verification had the same shape across two controllers
  each. All of them now record inside the context, so every surface present
  and future leaves the same trail, and the guardrail test covers them (#593)

- **Suspending an account, changing its role or cap, and revoking a key are in
  the affected account's own audit trail.** These recorded only into the
  admin privilege trail, which the page a user actually reads never shows — so
  from their side the account changed state with no explanation. They record
  in the context now, like every other mutation, and the admin surfaces still
  write their own privilege row on top. A test enumerates every context
  mutation that must audit, so the next one to be added fails loudly instead
  of silently joining the gap list (#552)

- **Your subscription changing state is in your own audit trail now.** The
  billing context recorded nothing, so an account could move from active to
  cancelled, or from trialing to gated, and the person it happened to saw only
  the result. Admin-initiated changes did land in the privilege trail, but the
  page users actually read never showed that table. Every transition —
  Stripe-driven, operator-driven, or decided by the trial sweeper — now
  records both ends of the change plus which of those three moved it, because
  "cancelled" means something different depending on who did it. A sync that
  reasserts the status an account already had records nothing, so the real
  transitions stay findable (#550)

- **Starting, prompting, interrupting, stopping and deleting a conversation
  are audited from the browser too.** Like resource CRUD, these were recorded
  through `/api` and silent through the UI — where conversations are actually
  driven. They are also the spend-relevant actions in the product, since every
  conversation runs a sandbox, so the trail matters for a billing question as
  much as a security one. Prompt events record the byte size and image count
  and never the text: the trail says a prompt happened, not what it said. A
  conversation ended by sandbox reclamation is attributed to the reaper, so
  "why did my agent stop" has an answer that is not "no idea" (#545)

- **The audit trail can now account for its own shrinkage, and background
  workers no longer change your data anonymously.** The retention pruner
  deletes `audit_events` among other tables, so the trail could get shorter
  with nothing to say when or by how much; it now records one summary per run
  with per-table counts, written after the pruning so a shortened window
  cannot delete the record of the deletion. The sandbox reaper's expiries and
  stuck-sandbox releases, an export completing, failing or aging out, and the
  bulk trial backfill in the release task all record too, each attributed to
  the worker that did it. Previously "my sandbox vanished" and "I asked for my
  data and never heard back" had answers only in the server log (#551)

- **Saving an inference credential during onboarding is audited like saving
  one anywhere else.** BYO provider keys are secret material on par with
  environment and vault secrets, and the settings page and API already
  recorded every write — but the onboarding wizard, saving the same
  credential through the same code, recorded nothing. The recording moved
  into the context, so all three surfaces share it and a fourth cannot
  quietly miss it. The provider name is still the whole payload; the
  credential never reaches the trail (#546)

- **Signing up and signing out are in your audit trail.** Registration was
  recorded only for OAuth signups; the browser form and
  `POST /api/auth/register` both created accounts silently, the latter because
  it runs on a public pipeline with no audit plug. Logins were recorded and
  logouts were not, so the trail showed sessions opening and never closing. An
  account's trail now opens with its own creation, which also means a brand
  new account no longer shows an empty audit page (#544)

- **Creating, changing or deleting an agent, environment or vault is audited
  from the browser too.** These mutations were recorded when driven through
  `/api`, because a blanket plug on that pipeline caught every write, and
  recorded nothing at all when driven through the UI — the inverse of the
  secrets gap fixed earlier, and backwards for the surface where most of this
  work actually happens. Someone reviewing their own trail saw an account
  where resources appeared and vanished with no explanation. The audit moves
  into the context functions, so the UI, the API, the onboarding wizard and
  `fountain apply` all leave the same record, and update events name the
  fields that moved — never their values (#543)

- **Minting an API key always leaves an audit trail now, whichever door you
  came through.** There are four ways to get a key, and `POST /api/auth/token`
  — the one that exchanges a password for a full-scope key, and the most
  attack-relevant of them — was the only one that minted silently, because it
  runs on a public pipeline that carries no audit plug. Anyone auditing "who
  issued a key and when" saw the UI and `POST /api/auth/api-keys` but not the
  CLI login door. The audit moves into `Accounts.create_api_key/3`, which
  every mint already goes through, so UI, API, CLI and the per-conversation
  callback rotation are covered by construction and a future surface gets it
  for free. Events carry the key's name, scopes and public prefix — enough to
  match a trail row to a listed key — and never the key (#542)

- **Email verification is now enforced where identity is established, not at
  each door.** #533 moved unverified logins onto a waiting page but left the
  check inside the LiveView hook, so it held only because every entry point
  remembered it — four of them on the API side alone. Two consequences were
  real: every controller route in the session pipeline (theme, avatars, export
  downloads, turn images, the credential POSTs) was reachable by an unverified
  session, and the bearer-token plug never checked verification at all, so a
  key minted before #314 closed `POST /api/auth/token` would still work
  forever. `TenantSessionAuth` now redirects such sessions to
  `/auth/verify-pending`, and `authenticate_api_key/1` refuses with 403
  `email_unverified` — the same status and reason the token endpoint gives
  when refusing to mint for that account. No key is affected in practice:
  across 163 unverified accounts, zero API keys have ever been issued (#533)

- **An unverified login no longer looks like a failed one.** Signing in with
  the right password but an unverified address issued a perfectly good session
  and then bounced it to `/auth/login` with "Please verify your email address"
  — so the user landed back on the form they had just used successfully, with
  nothing to say their session was fine and the resend path nowhere in sight.
  Worse, re-entering the password never helped: the verification link logs you
  in by itself. Those sessions now land on `/auth/verify-pending`, a page that
  names the address the link went to, offers a resend (same five-an-hour
  budget, keyed by account rather than IP) and a sign-out for anyone who typed
  the wrong address, and advances on its own the moment verification lands —
  in another tab or on a phone — with no second login. It cannot be camped on:
  a verified user hitting it is sent where they were going (#533)

- **Fetching a turn image over the API no longer fails when you ask for an
  image.** `GET /api/conversations/:id/turns/:turn_id/images/:position`
  returns PNG or JPEG bytes, but sat behind a JSON-only content-negotiation
  pipeline, so a client sending `Accept: image/png` — the natural header for
  the request — got `406 Not Acceptable` before the endpoint ran. It worked
  only if you asked for `*/*`, which is why browsers never hit it. The
  endpoint was also in no spec at all, while the `Turn` schema advertised
  `image_count`: the API told you two images existed and documented no way to
  reach them. Both fixed, and the endpoint is now in `/api/openapi.json` and
  `docs/api.md` (#578)

- **The `/api/auth/*` endpoints are now in the OpenAPI spec.** They never
  were: the spec is generated from the router, and a controller that does
  not declare operations is skipped in silence — so the published spec
  described every resource endpoint but not the one thing a client needs
  first, which is how to get a bearer token. `/api/docs` opened on a surface
  whose front door was invisible, and generated clients had to hand-roll
  authentication. All thirteen auth routes are documented now, with the seven
  public ones (`token`, `register`, `resend-verification`, `verify`, `forgot`,
  `reset`, `email/confirm`) declaring `security: []` so a generated client
  will actually call them without a credential it cannot yet have. A test
  walks the router and fails on any `/api/` route without an operation, so
  the gap cannot silently re-open (#571)

- **Secrets written through the API now leave the same audit trail as
  secrets written through the UI.** `POST/DELETE /api/environments/:id/secrets`,
  the vault equivalents, and the secret half of `POST /api/apply` recorded
  only the generic request row — so the trail could answer "who wrote a
  secret" only for people who used a browser, and the account export's
  `audit_trail` under-reported API-driven secret activity. All three paths
  now emit the same `environment.secret.write` / `vault.secret.write` (and
  `.delete`) events the LiveView forms do, carrying the key, never the
  value, and attributed to `api` or `sprite` as appropriate (#530)

- **The compose quick start no longer collides with a Postgres you already
  run.** The file published `5432:5432` unconditionally, which describes most
  machines evaluating Fountain — so the documented quick start failed on a
  developer workstation for a reason that had nothing to do with Fountain.
  The publish is host-side convenience only (the app reaches Postgres over the
  compose network), so it is now `${POSTGRES_HOST_PORT:-5432}:5432`: unchanged
  by default, and settable when 5432 is taken. CI also boots the pinned image
  against main's compose file on every run — the pairing a fresh `git clone &&
  docker compose up` actually gets, which nothing had been exercising, and
  which is how both #513 boot failures shipped (#549, #548)

## [0.5.2] — 2026-08-05

### Fixed

- The account-deletion warning on `/account` opened with "Cancels your
  subscription" on instances where billing is disabled and no subscription
  exists — the last billing reference the #513 fresh-machine sweep found on
  any surface. The clause now renders only when `BILLING_ENABLED=true`
  (#513, #569)

## [0.5.1] — 2026-08-05

### Fixed

- **The compose quick start still crash-looped on v0.5.0 — actually fixed
  now, verified by booting the built image through compose.** The #497/#541
  blank guards protect the config value, but the Sentry SDK also reads the
  `SENTRY_DSN` env var itself: `Sentry.Config.put_config/2` re-validates a
  partial keyword with no `:dsn` entry and `fill_in_from_env` injects the
  raw env value into it — and `Sentry.Application.start` calls `put_config`
  at boot, so the compose-supplied `SENTRY_DSN=""` crashed the `:sentry`
  application regardless of the config. A blank `SENTRY_DSN` is now deleted
  from the environment during config, before any application starts, so the
  SDK never sees it. Instances with a real DSN are unaffected (#513, #561)

## [0.5.0] — 2026-08-05

### Upgrade notes

- **Set `PUBLIC_URL` before upgrading.** Production now refuses to boot
  without it (or the deprecated `FOUNTAIN_DOMAIN`) — see below. The compose
  file and the `deploy/k8s` baseline already set it; anything hand-rolled
  from older docs may not.
- **With a real mail provider (Resend/SMTP), set `EMAIL_FROM`.** Also a boot
  requirement now. Instances on `EMAIL_DELIVERY=none` are unaffected.
- On billing-disabled instances, account export and deletion moved from
  `/account/billing` to `/account`, and accounts no longer carry
  trial/subscription state. If you later enable billing, the documented
  `expire_legacy_trials` release task is still the way to start trial clocks
  for pre-existing accounts.

### Added

- **`/terms` and `/privacy` render your legal identity, not the project's.**
  Set `LEGAL_ENTITY`, `LEGAL_CONTACT_EMAIL`, `LEGAL_JURISDICTION` and
  `LEGAL_EFFECTIVE_DATE` — all four or none; partially set refuses to boot.
  Unset, the pages are hidden and their links removed from signup and the
  footer, instead of rendering placeholder terms nobody agreed to
  (#506, #517, #534)

- Admin billing operations for the hosted service: Stripe webhook failures
  are persisted and surfaced on `/admin` instead of vanishing into logs
  (#501, #516); a user's subscription state can be force-resynced from
  Stripe (#502, #515); `/admin/users/:id` shows a read-only view of the
  user's Stripe invoices (#502, #539); dropped usage events emit telemetry
  (#503, #514); and a daily sweeper backstops stale `trialing` rows whose
  webhooks never arrived (#504, #512)

- The marketing homepage renders its price from `STRIPE_PRICE_MONTHLY_CENTS`
  instead of hardcoding the hosted instance's number (#500, #508)

### Changed

- **A billing-disabled instance no longer shows billing anywhere.** The
  Billing nav item, the admin dashboard's trial tiles, `trialing`
  filters/sorts and per-user trial controls all render only when
  `BILLING_ENABLED=true`; the core `/account` page owns export and account
  deletion (#479, #481, #491, #494). Accounts on billing-disabled instances
  are no longer stamped `trialing` at registration, and `/api/auth/me`
  reports `subscription_status: null` (#480, #496)

- Subscribers whose state is `past_due` or `canceled` keep read-only access
  to their conversations instead of a hard gate — they can read what they
  already ran, not start new work (#505, #538)

- **Two silent misconfigurations now refuse to boot in prod with actionable
  errors.** `PUBLIC_URL` is required (or the deprecated `FOUNTAIN_DOMAIN`) —
  the old `http://localhost:4000` fallback meant a prod instance ran fine
  while every verification/reset link and every sprite's `FOUNTAIN_BASE_URL`
  silently pointed at localhost. And `EMAIL_FROM` is required whenever a
  real delivery provider (Resend/SMTP) is configured — the old default was
  the hosted instance's sending domain, so an instance that didn't set it
  sent mail as someone else's domain, which providers checking SPF/DKIM
  reject anyway. With `EMAIL_DELIVERY=none`, `EMAIL_FROM` stays optional
  (nothing is sent) and falls back to a neutral `noreply@localhost`. The
  compose quick start and `deploy/k8s` baseline already set `PUBLIC_URL`,
  and instances that took the mail integration guide's advice to change
  `EMAIL_FROM` are unaffected (#495)

- The README no longer contradicts the licence story: it said nothing lived
  in `ee/` and that ee code would not be MIT — both false since #472. It now
  states what `ee/` holds (billing + growth mail) and that it is MIT today,
  a future-licence option only (decisions/0010). API examples run against
  `$FOUNTAIN_URL` instead of the hosted instance's domain, and the
  orchestrator "bus repo" framing moved out of the front door. Removed
  `PREREQUISITES.md` (stale instructions for the predecessor AoD stack) and
  `fly.toml` (an undocumented third deploy path with the hosted domains
  baked in) (#490)

### Fixed

- The self-host quick start pinned `v0.3.0` — an image from before the
  in-app first-login flow (#478), so following the docs verbatim dead-ended
  signup under `EMAIL_DELIVERY=none`. The compose and `deploy/k8s` pins now
  sit at `v0.4.1`, the release workflow bumps them inside every release
  commit, and a test fails any PR where a pin drifts from the released
  version. (#489)

- **The compose quick start no longer crash-loops on a fresh machine.**
  Compose interpolates unset `${VAR:-}` passthroughs to present-but-empty
  strings, and three reads in `runtime.exs` didn't survive that: the sandbox
  lifetime bounds hit the refusal written for typos (`Integer.parse("")`),
  `SENTRY_DSN=""` was handed to the Sentry SDK, which refuses to start, and
  `SPRITES_BASE_URL=""` displaced the default API endpoint so every
  conversation would fail at provision. Blank now means "not configured" and
  gets the default; a non-blank typo still refuses to boot. Found by running
  the fresh-machine walkthrough (#513) exactly as the docs write it
  (#497, #509, #541)

- Three documented variables were silently ignored under compose — set in
  `.env`, never passed to the app: `TRUSTED_PROXIES` (per-IP rate limits
  collapsed into one bucket behind a proxy), `SENTRY_DSN`, and
  `DATABASE_SSL_VERIFY`/`DATABASE_SSL_CA_FILE`. All pass through now
  (#397, #509)

- The CLI's built-in default `base_url` is the hosted instance, so on a
  self-hosted deployment the first unconfigured command sent the freshly
  minted API key to the hosted domain. The docs now call this out and lead
  with `FOUNTAIN_BASE_URL=... fountain auth login`, which records the URL in
  the saved profile (#510)

## [0.4.1] — 2026-08-05

### Upgrade notes

- Nothing breaking, and both new switches default off in the application. One
  default changed in the bundled compose file only: `docker-compose.yml` now
  sets `FIRST_USER_ADMIN=true` (see Added). If your compose instance
  deliberately has no admin, set `FIRST_USER_ADMIN=false` in `.env` before
  upgrading — otherwise the next account to become verified while no admin
  exists is promoted

### Added

- Self-host first login happens in-app (ADR 0011, #478). Under
  `EMAIL_DELIVERY=none`, accounts now self-verify at registration — a
  verification link that can never be delivered gates nothing — and the
  registration responses say "you can sign in now" instead of pointing at an
  inbox that will stay empty. With the new `FIRST_USER_ADMIN=true` (default
  off; the compose quickstart sets it), the first account to become verified
  on an instance with no admin is promoted, audit-recorded as
  `admin.role.granted` with a nil actor and `via: "first_user_admin"`. The
  grant fires on verification, not registration, so it always lands on a
  login-capable account, and concurrent first verifications are serialized so
  exactly one can win. `Fountain.Release.verify_email/1` and
  `promote_admin/1` remain as escape hatches for broken mail providers and
  lock-out recovery

### Changed

- Billing and all transactional email moved under a top-level `ee/` directory
  (#472), still compiled into the same application and still MIT — a
  future-license boundary, not a license change (decisions/0010). Module
  names are unchanged; a fork that deletes `ee/` loses billing and email, not
  auth or conversations

### Security

- The sobelow scan now covers web modules under `ee/lib` via a merged-tree
  script (#473), so the `ee/` move could not silently drop controllers out of
  the security scan's reach

## [0.4.0] — 2026-08-04

### Upgrade notes

- **`BILLING_ENABLED` now defaults to `false`** — the subscription gate is
  opt-in. An instance that relies on the gate must set `BILLING_ENABLED=true`
  explicitly before upgrading, or every account gets ungated access (the
  repo's hosted manifest under `k8s/` already sets it). See the #336 entry
  under Changed

- **A billing-enabled production instance now refuses to boot without
  `STRIPE_WEBHOOK_SECRET`** (#390). The webhook endpoint previously fell back
  to an empty signing secret, which is a signature anyone can forge, so the
  fallback is gone: set the secret, or leave `BILLING_ENABLED=false`. An
  instance with billing off is unaffected

- One migration adds a **unique** index on `users.stripe_customer_id`
  (#411), replacing the plain index. If a pre-upgrade instance has two
  accounts pointing at the same Stripe customer, the migration fails — resolve
  the duplicate before upgrading. Duplicates were themselves the bug: the
  webhook lookup raised and 500ed every delivery for that customer

- The compose quick start now pins an explicit image tag rather than tracking
  `latest` (#410). `.env.compose.example` ships the pin uncommented; an
  existing `.env` keeps whatever it already had, so set `FOUNTAIN_IMAGE_TAG`
  deliberately when you upgrade

### Added

- Point-in-time recovery for the hosted database (#209): continuous WAL
  archiving plus nightly base backups via the CNPG barman-cloud plugin into
  the existing Garage bucket, retention 14 days, RPO ~5 minutes with the
  nightly `pg_dump` kept as the operator-independent fallback. The dump job
  now sends a Sentry Crons check-in, so a backup that quietly stops running
  pages instead of rotting

- Accounts that register and never verify their email are deleted after 30
  days (#258) — they cannot log in, and 158 of them were briefly mistaken for
  a legacy trial cohort. Same teardown as self-serve deletion, Stripe
  cancellation included; `UNVERIFIED_PRUNE_AFTER_DAYS=0` disables,
  `UNVERIFIED_PRUNE_EXEMPT` protects deliberate unverified accounts

- Optional error tracking via Sentry (or any Sentry-API-compatible endpoint):
  crashes from every process — not just web requests — are reported with
  release correlation, rate-limited, with PII off. Fully inert unless
  `SENTRY_DSN` is set (#211)
- A portable Kubernetes baseline under `deploy/k8s/` — plain manifests,
  `kubectl apply -k`, no operators assumed; bring a Postgres and an ingress
  (#191)
- Dialyzer now gates CI and `mix precommit` (#236). Triage of its 77 findings
  fixed real bugs: OTel spans were ended by passing the span where a
  timestamp belongs (silently corrupting recorded spans), Stripe API params
  used strings where the client's specs say atoms, six schema modules never
  defined the `t()` their specs referenced, and `upsert_oauth_user`'s spec
  omitted the registration-refusal atoms — making dialyzer condemn the live
  controller branch handling them. Three understood warnings are pinned in
  `.dialyzer_ignore.exs` with reasons
- Transient Sprites API failures no longer fail provisioning outright:
  idempotent steps retry with bounded exponential backoff, sprite creation
  adopts an already-created sprite after a lost response, and the Sprites
  HTTP timeout is explicit and tunable (`SPRITES_TIMEOUT_MS`) (#168)
- Admin support tooling: subscription status, trial end and a Stripe dashboard
  link per user, trial extension (Stripe-aware), a `comped` status for
  operator-granted free access, per-user 30-day usage, and a sandbox reap
  action (#169). Admin account deletions are now actually audit-recorded —
  the event type was missing from the audit allowlist and failed validation
  silently

- An account security page at `/account/security` (#448): a logged-in user can
  finally change their password (previously only the logged-out
  forgot-password flow existed) and change their email address at all. Both
  are current-password gated; a password change ends every other session and
  keeps the current one, and an email change is confirmed by clicking a link
  sent to the new address — which also marks it verified — while the **old**
  address gets a notice, the tripwire for a takeover in progress. OAuth-only
  accounts see an explanation and a pointer at the reset flow instead of forms
- A working resend-verification path (#445): `GET`/`POST
  /auth/resend-verification` and `POST /api/auth/resend-verification`, rate
  limited and with the same fixed-response anti-enumeration contract as the
  password-reset request. The check-your-email page had linked to this route
  for some time and the link was dead. The verification email itself moved to
  a durable background job — it used to be an in-request task the finishing
  response could kill, and a dropped email was unrecoverable with no resend
  path
- A welcome email on the transition to a verified account (#449), sent once
  per user forever, so pre-existing verified accounts are never welcomed late
- Notification emails for the two account-state transitions that used to
  happen silently (#450): suspension and unsuspension (re-checked at send
  time, so a suspension lifted before the queue drained is not announced) and
  deletion, whose copy is honest about what survives — Stripe keeps invoices,
  backups age out on their own schedule. The billing page's danger zone now
  points at the export section before the destructive click, and the optional
  `SUPPORT_EMAIL` puts a real reply-to address in the copy when set
- Account suspension — an abuse lever between comping and deleting (#287):
  sessions are invalidated, active sandboxes are best-effort reaped,
  provisioning is refused at the door, and billing is deliberately untouched
  so webhooks keep syncing. Refusals are neutral and password-checked first,
  so login, OAuth and API keys never become an account-state oracle
- Self-serve data export (#288): a tenant-scoped export built by a background
  job, downloadable from the account page through an owner-scoped expiring
  link. Secret values are deliberately excluded — names only
- An admin per-user detail view at `/admin/users/:id` (#446) — billing state,
  resource counts, conversations, API key metadata (never key material), the
  user's own audit trail and every admin action taken against them — plus a
  metadata-only admin conversation view at `/admin/conversations/:id`, where
  prompts, outputs and log content deliberately never render. Both
  cross-tenant reads are themselves audited. Before this, an admin could
  suspend or delete a user but not look at one, and conversation links 404ed
  for every conversation the admin did not personally own
- Admin user table search, filtering, sorting and pagination, with the state
  in URL params so a refresh or an admin action preserves position (#285)
- An admin billing overview (#286): status counts, trials ending in the next
  seven days, conversions this month, MRR from active subscriptions ×
  `STRIPE_PRICE_MONTHLY_CENTS` (nil when unconfigured — no fabricated
  numbers), and the recent webhook events
- An admin lifecycle funnel (#282): registered → verified → onboarded →
  activated → subscribed with per-stage conversion and median timing, a
  stalled-user breakdown answering how far the verified-but-never-ran accounts
  actually got, and the same stages exported as Prometheus gauges
- Post-trial and payment-failure lifecycle emails (#283): `trial_expired`,
  `payment_failed` and `subscription_canceled`, enqueued from webhook status
  transitions, where an enqueue or delivery failure can never error the
  webhook
- First-class dunning: `invoice.payment_failed`,
  `invoice.payment_action_required` and `invoice.paid` are handled instead of
  everything being inferred from subscription updates (#447). The SCA email is
  new and leads with the fix; a new payment-recovered email fires on the
  `past_due` → `active` transition; and `invoice.paid` writes status in
  exactly one case — dunning recovery — so the $0 invoice Stripe pays at trial
  creation and at every renewal can never touch the account
- Self-serve subscription management (#284): `cancel_at_period_end` and
  `current_period_end` sync from webhooks and are cleared on resubscription,
  an "access until <date>" notice while a cancellation is pending, a direct
  billing-history portal link, and a guard that routes an existing customer
  with any live subscription to the Billing Portal rather than handing them a
  second, duplicate subscription
- `mix fountain.verify_lifecycle` (#289): a repeatable end-to-end billing
  check driven by Stripe Test Clocks — trial → T-3d email → expiry → paid
  subscribe → cancel-at-period-end → period end → re-subscribe → dunning →
  recovery — asserting Fountain-side state at every step. Test-mode keys only,
  with cleanup that runs even on failure. Documented as the release check for
  any billing-touching change
- `Fountain.Release.promote_admin/1` (#275): first-admin bootstrap without raw
  SQL, symmetrical with `verify_email/1`, audit-recorded and idempotent. Both
  deploy guides drop their SQL step
- A per-conversation durable log budget (#331): output stops being persisted
  at `LOG_OUTPUT_BUDGET_MB` (default 50 MB, `0` disables), with one truncation
  marker written at the crossing. Retention bounds age, not rate, and
  `log_events` shares the volume the database depends on, so a sandbox
  printing garbage was an availability risk. The counter is cumulative across
  wakes
- An absolute provision deadline (#329): a server stuck inside provisioning
  was invisible to every reclamation mechanism — the reaper skips rows whose
  server is alive, and the server's own timers queue behind the stuck
  callback — so the sandbox billed until the next deploy. An external watchdog
  now kills it at 30 minutes and applies the normal provision-failure
  transitions
- Substantially more operational visibility: conversation and sandbox gauges
  by status plus Oban queue depth and job outcome metrics with alerts (#321),
  provisioning and turn metrics rewired onto events that actually fire (#310),
  alerts on the cost signals that previously fired into nothing — leaked
  untracked sprites, platform-wide sandbox and conversation ceilings,
  provision deadlines (#405) — CNPG PITR backup alerting (#338), and
  rehydrator sweep telemetry (#408)
- A self-host observability pack (#277): a generic `PrometheusRule` with every
  alert commented with its meaning and action, and a 12-panel starter Grafana
  dashboard built only from metrics the app actually exports
- A backup and restore story for both deploy paths (#276): a profile-gated
  nightly `pg_dump` service for compose, a generic backup CronJob for
  `deploy/k8s` targeting any S3-compatible store, and the restore drill in
  `docs/operations.md` with the `MASTER_SECRETS_KEY` pairing rule stated
  loudly — a database restored without its matching master key cannot decrypt
  any secret
- Public documentation for the parts that had none: a system architecture page
  with failure domains and the life of a conversation (#273), an operations
  and troubleshooting guide (#278), one guide per third-party integration —
  Sprites, GitHub OAuth, Stripe, Sentry, mail — with the required/optional
  matrix up front (#274), the Sprites dependency contract as consumed (#279),
  and a complete runtime configuration reference where every variable
  `config/runtime.exs` reads is documented, enforced by a test in both
  directions (#292)
- `fountain keys list --json`, matching every other list command, and
  first-time documentation of the `op://`, `bws://` and `infisical://` secret
  resolvers (#410)

### Changed

- Self-host first-run papercuts (#336): the GitHub sign-in button only renders
  when `GITHUB_OAUTH_CLIENT_ID` is configured (clicking it unconfigured
  dead-ended on a GitHub error page); the compose `app` service now has a
  healthcheck against `/health`; `TRUSTED_PROXIES` is documented in the
  `deploy/k8s` baseline; and **`BILLING_ENABLED` now defaults to `false`** —
  the subscription gate is opt-in (breaking; see Upgrade notes above)

- With billing disabled, an instance stops performing billing (#335): signups
  no longer enqueue a Stripe customer sync that 401s through all five attempts
  — dead jobs and error noise a self-hoster has no way to know are benign —
  and the billing page says plainly that billing is disabled instead of
  showing a trial countdown and an Upgrade button whose only possible outcome
  was "Unable to reach Stripe"
- Trace export is off unless an export target is configured (#317). It
  defaulted to OTLP aimed at Honeycomb whenever the app ran in production, so
  the portable baseline — which sets no OTEL variables — shipped continuous
  rejected span batches to a third-party vendor. Setting
  `OTEL_EXPORTER_OTLP_ENDPOINT`, `HONEYCOMB_ENDPOINT` or `HONEYCOMB_API_KEY`
  switches it back on
- Every route to a sprite is now gated on billing and suspension, not just
  fresh provisioning (#313). Reattaching to a live sandbox provisioned
  nothing, so it never met a gate; and a running conversation outlived the
  subscription state it started under, where every turn reset the idle clock —
  a trial that expired at minute one could buy up to 24 hours of continued
  service. The gate now also runs per turn, whichever door the prompt came in
  by
- The published OpenAPI spec describes this product (#423): it still called
  itself "Agent on Demand", pointed at the `aod` CLI and told integrators to
  authenticate with the `ADMIN_TOKEN` mechanism deleted two phases ago. It now
  names Fountain, the `fountain` CLI and per-user API keys, and the error
  table documents the `402` and `410` responses the API has been returning all
  along. The Conversation schema also drops an unreachable `completed` status
  and gains the `source` and `parent_conversation_id` fields it has been
  emitting, both now pinned by a drift test (#415)
- The production image is built on the same Elixir and OTP the test suite runs
  against (#425). The Dockerfile had drifted to a higher Elixir and a *lower*
  OTP than `.tool-versions` and CI; a test now fails if the three pins ever
  disagree again
- `k8s/` became a kustomize overlay of the portable `deploy/k8s` baseline
  (#264), so probes, security context, resources and rollout strategy exist
  once; the hosted overlay keeps only what is genuinely personal
- Deploys became less able to surprise: image builds trigger on a *successful*
  CI run rather than independently on push (#333), the manifest publish is
  gated by a `kustomize build` + `kubeconform -strict` + `promtool` validation
  job over both manifest trees (#414), the image-pin substitution is verified
  rather than assumed, and CI cancel-in-progress is now PR-only so a rapid
  merge cannot cancel another commit's build out from under it
- Rollouts drain properly (#408): a 120-second termination grace period and a
  preStop delay in the shared deployment base, plus a PodDisruptionBudget
  wired into the hosted manifests (shipped commented out in the portable base,
  where the 1-replica default would block drains)
- Container images are built natively per architecture instead of emulating
  arm64 under QEMU, with a registry layer cache (#361) — the same images,
  roughly 20 minutes sooner
- Manifests are published as an OCI artifact, and the `deploy` git branch that
  previously carried them is retired (#301, #303); rollback is now
  `flux tag artifact ... --tag latest` against an older `sha-` tag, documented
  in the workflow header
- `mix precommit` matches CI more closely: Credo no longer runs with
  `--mute-exit-status` (#333), sobelow was moved to where it actually scans a
  Phoenix app — at the umbrella root it detected nothing and exited 0, so the
  gate had scanned nothing since it was added — and now runs locally too
  (#311), and its threshold was lowered to the confidence level this codebase's
  entire XSS surface is reported at, with each of the 11 findings individually
  reviewed and justified in place (#414)

### Fixed

- A conversation's very first prompt could vanish (#367). It was cast through
  the distributed registry immediately after the server started, and a
  registration that has not yet propagated makes the cast a silent no-op: the
  API returned 201, provisioning succeeded, and zero turns ever ran. The cast
  now targets the pid directly
- Prompt, interrupt and terminate no longer 500 against a conversation that is
  still provisioning (#412). A blocked server means the call *exits* rather
  than returning an error tuple, and none of the seven call sites caught it;
  worst case was `DELETE`, where the 500 masked a delete that silently never
  ran. Callers now get a `503` with `Retry-After`, and the delete goes through
- A sprite WebSocket that dropped mid-turn left the turn "running" forever
  (#413): every further prompt answered "busy", idle reclaim was suppressed,
  the reaper skipped the sandbox, and the sprite billed until its 24-hour
  maximum lifetime. A dropped socket now fails the turn and returns the
  conversation to idle, the same shape as a non-zero exit
- The SSE stream now tells a client when the server behind it dies (#415)
  instead of sending heartbeats forever on a topic nothing will publish to
  again; a client disconnecting mid-replay no longer produces a crash report
  and a Sentry event per interrupted `curl`; and a spawn that never starts
  resets the conversation from `running` back to `idle`
- The provision watchdog now fails the database rows *before* killing the
  stuck server (#394). Killing first let the supervisor restart it into
  provisioning while the row still said pending — usually winning that race,
  provisioning a second billable sprite, and leaving a live server streaming
  into a sandbox whose row said terminal
- Concurrent requests can no longer exceed the per-tenant sandbox cap (#330):
  the quota check and the row insert now happen in one transaction under a
  per-user advisory lock. Separately, when two wakes of the same conversation
  raced, the loser stranded a pending row holding a quota slot until the
  reaper's next pass an hour later — a user at their cap could lock themselves
  out by double-clicking. The loser now cleans up and forwards its prompt to
  the winner
- Stripe webhooks whose apply failed are no longer lost (#312). The claim was
  written before the apply and outside any transaction, so the 500 that asks
  Stripe to redeliver was answered by a redelivery that deduped against the
  claim and did nothing. Claim and apply now share a transaction
- Webhook sync is keyed by the subscription of record, not the customer
  (#309). Upgrading mid-trial creates a second Stripe subscription, and events
  from either one wrote the same account — so Stripe cancelling the abandoned
  trial subscription locked out a customer who was paying on the other one.
  Checkout completion now cancels the other live subscriptions, and events for
  anything but the subscription of record never touch the account
- Webhook sync guards are evaluated under a row lock (#393), closing a window
  where a `customer.subscription.deleted` could read a user mid-upgrade,
  before the checkout transaction committed, and land its update afterwards —
  marking a just-paid customer canceled. The Stripe cancellation calls also
  moved out of that transaction, so no database lock is ever held across
  third-party HTTP
- An operator's trial extension outranks in-flight webhooks (#334): the
  extension now advances the sync watermark, so a straggler event from an old
  subscription can no longer silently revert the decision and re-gate the user
- Trial subscriptions are actually created at signup (#351). Two halves of the
  design cancelled each other — registration stamps a local trial end on every
  account, and the worker only opened a Stripe subscription when that field
  was nil — so no signup ever got one: no trial-ending warning, no cancellation
  at trial end, and nothing for the trial-expired email to hang off. The
  subscription now anchors to the locally-stamped date rather than restarting
  the clock
- Trial creation is idempotent (#400). Stripe statuses the changeset rejects
  made the write fail, the retry guard checked a field the failed write never
  set, and each of up to five retries created another subscription — all of
  which converted when the user later added a card. Statuses now go through
  the same coercion the webhook uses, and creation carries a stable
  per-user idempotency key
- A comped account is never offered Checkout (#399). Comping cancels every
  live subscription, so the billing page read a comped account as a fresh
  customer, showed Upgrade, opened Checkout and took the money — after which
  webhook adoption dropped the subscription id on the floor, making a paying
  customer invisible and locking them out when the comp was revoked
- The two usage numbers on the billing page no longer diverge for exactly the
  accounts whose provisioning is failing (#411): a sandbox that dies before
  reaching ready now emits its own usage event, counted by both summaries
- `docker compose up -d postgres` works on a fresh clone (#392). Compose
  interpolates the whole file regardless of which service you target, so the
  required-variable syntax on the app service aborted the documented
  database-only path — the very first command in `SETUP.md` — with an error
  about a service the contributor never asked to start
- Compose-style empty strings are treated as unset (#426). Passing optional
  variables as `${VAR:-}` makes them present-but-empty, and an empty string is
  truthy in Elixir, so every unset-guard written for these variables failed to
  fire: `RESEND_API_KEY=""` selected the Resend adapter and POSTed every
  verification and reset email — recipient address and live signed URL — to
  Resend to be 401'd, making the stock compose configuration's mail path
  unreachable; `SMTP_USERNAME=""` forced authentication with an empty
  username; and `SPRITES_TOKEN=""` defeated its own missing-token guard and
  turned a helpful message into an opaque 401
- `.env.compose.example` no longer advertises variables compose silently
  ignores (#410) — a new drift test immediately caught five, including
  `SPRITES_BASE_URL` and `REGISTRATION_ALLOWED_EMAIL_DOMAINS`
- LiveView pages reconcile state they used to load once at mount (#401): the
  conversation log viewer subscribed to a topic nothing publishes on, so live
  log events never arrived; the conversation header froze at its mount-time
  status instead of tracking the run; six delete handlers crashed on a row
  deleted in another tab instead of flashing; mid-session refusals show real
  messages instead of a raw atom; and `idle` — the resting state of every
  healthy conversation — gets the healthy badge colour instead of the
  unknown-value grey
- The API prompts endpoint maps every refusal to a 4xx (#332). Three known
  error shapes 500ed — the fourth time an unhandled shape hit this
  hand-maintained clause — and unmapped future ones now become a logged 422
  rather than a blank 500
- CLI: `keys create` decoded an envelope the server does not send, losing the
  plaintext key it had just minted; `conv prompt`/`stream` replayed full
  history and exited on the first *prior* turn's completion; and a failed turn
  exited 0 (#398). Provisioning and setup output is no longer silently
  dropped, so a failing `apt install` or `git clone` is visible, and server
  errors render as messages rather than raw Go map dumps (#410)
- Telemetry no longer dies for the lifetime of the pod after a single blip
  (#365, #395). The poller permanently drops a measurement whose tick fails,
  and the first collection fires while the database pool is still starting —
  verified on both production pods, where the funnel gauges were never
  recorded at all. The guards now cover raises, exits and throws, and the next
  tick retries
- The leaked-sprite metric was a level reported as a counter (#405), so a
  steady 102 untracked sprites read as 2,448 after a day and climbed forever
- Rate-limit buckets are swept every 10 minutes (#326). The table grew one row
  per distinct bucket and IP since boot — unbounded, and invisible until an
  instance stayed up long enough or someone walked an IPv6 range
- Unbounded growth elsewhere (#408): `log_events` gets the `inserted_at` index
  its nightly prune needs, expired export payloads are purged every run rather
  than only when someone requests another export, and expired API keys are
  pruned even when nothing revoked them
- Conversation server lifecycle races (#408): callback-key revocation now acts
  only on the key that server itself minted, so a rotation cannot revoke a
  live duplicate's credential under registry lag, and the supervisor has its
  own restart budget instead of sharing the default 3-in-5-seconds across
  every conversation on the node
- An admin event type missing from the audit allowlist no longer disappears
  silently (#451). It has happened twice; rejections now log at error level
  and emit a telemetry counter, and a static test scans for admin event
  literals that are missing from the list, so the mistake surfaces during
  development instead of as a hole in the privilege trail
- Client IP resolution behind the tunnel (#300): the endpoint listens on
  `[::]`, so IPv4 peers arrive as IPv4-mapped IPv6 addresses that never match
  a v4 CIDR — the trusted-proxy gate failed on every request and every
  rate-limit bucket and audit row keyed on the node gateway
- Release tasks run in production (#256): they used to boot the whole
  application, which beside a running server dies on `eaddrinuse` and would
  otherwise start Oban and the distributed registry on a throwaway node
  competing with the real cluster. The OpenAPI export job now migrates before
  booting (#255), and the release job downloads only the artifacts it ships
  (#257)

### Security

- The Stripe webhook endpoint fails closed when no signing secret is
  configured (#390). It resolved the secret from a key nothing sets and fell
  back to an empty string, so on every instance that never configured billing
  the signature check was an HMAC keyed on `""` — which anyone can compute,
  giving unauthenticated write access to subscription state through forged
  events. Requests are now rejected outright when the secret is missing (see
  Upgrade notes)
- The tenant data-encryption key is no longer held in LiveView assigns
  (#391). The environment and vault secret forms unwrapped the key at mount
  and kept it in process state with the in-flight plaintext secret beside it,
  reassigned on every keystroke — and LiveView crash reports dump channel
  state to the logger and to Sentry, so any unhandled exception leaked the key
  that decrypts the tenant's entire secret set. The key is now loaded inside
  the handler and the form is uncontrolled, so neither ever enters assigns
- Conversation server state is redacted from crash reports (#315). It holds
  plaintext sprite environment values, the raw tenant key, decrypted
  bring-your-own inference credentials, the sprite callback key and the
  platform Sprites token; a probe crash was verified to print every one of
  them before the fix
- Request bodies are scrubbed by shape, not by name, before reaching Sentry
  (#402). The SDK default is an exact-name denylist, so the secret-write
  endpoints' `value` field and a manifest apply's whole `spec.secrets` map
  arrived as plaintext whenever an exception fired mid-request. Every string
  value now becomes a length tag, which covers the next secret-bearing
  endpoint by default
- Password-reset tokens are single-use (#325). A used token stayed live for
  the rest of its hour and could re-reset the password from a shared inbox,
  forwarded mail or a proxy log. Legacy tokens issued before the upgrade fail
  closed and die out within one hour of deploy
- Agent output is no longer an XSS vector, and browser routes carry a Content
  Security Policy (#323). Worse than filed: the markdown renderer escapes
  *inline* raw HTML but passed *block-level* raw HTML through verbatim, so
  agent output containing an `<img onerror=...>` as its own paragraph was live
  XSS rather than a `javascript:` link behind a click. Rendering now goes
  through the AST with verbatim nodes escaped and link schemes filtered after
  entity and whitespace normalization
- An agent can only attach an environment owned by the same tenant (#308).
  The error deliberately mirrors a nonexistent id, so a foreign environment
  cannot be confirmed by probing, and the conversation server loads the
  environment scoped by owner as a second layer — a legacy cross-tenant row
  provisions without it rather than materialising another tenant's secrets and
  checkpoint into the attacker's sprite
- Password login against an OAuth-only account returns `401` instead of `500`
  (#324). Verifying against a nil password hash raised, which was a
  Sentry-flooding crash and an account-existence oracle in one, defeating the
  anti-enumeration work everywhere else. The nil case now burns the same
  constant-time comparison as the no-user branch
- `/api` is rate limited before authentication (#316), so failed authentication
  is metered. The auth plug halted with a 401 before the limiter ever ran, so
  anonymous callers had unlimited attempts, each costing a hash and an indexed
  lookup
- Minting an API key requires a verified email (#314). Verification was
  enforced in the browser hooks only, so register → token → create agent →
  provision worked without ever touching an inbox. Separately, an account
  whose trial end is missing now fails closed unless it predates the legacy
  backfill
- Avatar uploads are validated against the same media-type allowlist as turn
  images and re-checked at serve time behind `nosniff` and a sandboxing CSP
  (#407) — the upload widget's `accept` list does not constrain what gets
  stored, so a crafted client could store `text/html` and have it served from
  the application's own origin. The conversation LiveView also stopped
  decoding raw client base64 with a raising call that crashed the process, and
  the LiveView socket has an explicit maximum frame size instead of Phoenix's
  unlimited default
- Audit rows recorded from LiveView resolve the client IP the same way the API
  does (#407), instead of trusting the leftmost, client-supplied entry in
  `X-Forwarded-For`
- The sprite callback token is revoked on supervisor shutdown (#322). The
  server never trapped exits, so its teardown skipped the most common
  teardown there is — application shutdown and rebalances, i.e. every deploy —
  leaving a live sprite-scoped tenant credential outstanding until its 30-day
  expiry
- Every unscoped context function now carries the `_unsafe_` prefix (#328,
  #407), so a reader of a call site never has to go and find out whether
  tenant scoping applied; the dead unscoped surface was deleted outright. A
  custom Credo check enforces that each `_unsafe_` call site names what
  established ownership on that path

### Removed

- SSH repository clones (#228). Implemented and hardened but unreachable —
  validation has required `https://` since the schema existed, and production
  confirmed zero use. Private repos are covered by https + token secrets; the
  implementation stays in git history if demand appears
- The legacy single-tenant admin login (#327): `POST /login` read a token set
  only in test config, so in production the public route's failure mode was a
  500, and the login form it belonged to could never succeed. Real admin
  authentication is the `require_admin` hook. The four legacy routes, two
  unused auth plugs and their test scaffolding are gone
- The `deploy` git branch (#303) — the OCI manifest artifact is now the only
  deploy target
- `render.yaml` and the home-cloud cutover runbook (#409): production has been
  Kubernetes since the cutover, and both documents still asserted a deployment
  that no longer exists. `STRIPE_PUBLISHABLE_KEY`, read by nothing, is gone
  from `.env.example` (#292)

## [0.3.0] — 2026-08-02

### Upgrade notes

- Set `PUBLIC_URL` to your external URL, scheme included. It is now separate
  from `PHX_HOST` and is what generated links, OAuth callbacks, and sandbox
  callbacks are built from (#204). An `https://` `PUBLIC_URL` also switches on
  the HTTPS redirect, HSTS, and secure session cookies (#241) — if you
  terminate TLS in front of Fountain, your proxy must set `X-Forwarded-Proto`.
- Production now refuses to boot without a mail setting. Configure
  `RESEND_API_KEY`, `SMTP_HOST`, or explicitly opt out with
  `EMAIL_DELIVERY=none` (#223).
- Migrations continue to run automatically at boot; no manual steps.

### Added

- Bulk manifest apply — a whole manifest in one request, and the CLI's
  `fountain apply` uses it (#151)
- Agent-scoped vault allowlists: an agent can be restricted to a named set of
  vaults (#144)
- `networking_config` on Environment, typed and documented (#146)
- `metadata` field on Environment and Vault for external tooling (#145)
- `GET /api/auth/api-keys` — list active keys, metadata only (#143)
- GitHub-sourced agent skills require a ref/SHA pin (#149)
- Account deletion, self-serve and admin (#234)
- Billing that holds: real Stripe trial subscriptions with end dates (#244), a
  warning email three days before a trial ends (#251), usage events (#213),
  idempotent order-aware webhooks (#214), and billing gates on every
  provisioning path (#212)
- Sandbox lifecycle bounds: per-tenant concurrent-sandbox cap (#205), idle
  timeout and maximum age (#233), and a reaper for leaked sprites and rows
  stuck mid-provision (#232)
- Durable job queue (#217)
- Self-hosting support: compose file and guide (#225), configurable
  `SPRITES_BASE_URL` (#189), database TLS / billing / registration switches
  (#224), SMTP delivery (#223), split liveness and readiness probes (#230),
  and an explicit MIT licence (#226)
- LLM-generated conversation titles, agent avatars, unread indicators, and a
  live-updating sidebar
- Public documentation site (MkDocs); OTel instrumentation for the
  conversation lifecycle (#125); Prometheus/Loki/Alertmanager wiring for the
  hosted instance (#210)
- Context-level and property-based test suites, with coverage held above a CI
  floor

### Changed

- Agent, environment, and vault editors use structured form UI instead of raw
  JSON textareas (#122–#124)
- Sandboxes are named `fountain-<tenant>-<id>` (#70)
- The hosted instance runs two clustered replicas (#132), with a single
  elected leader for conversation rehydration (#133)
- CI actually gates: strict Credo, coverage floor, sobelow, secret scanning,
  CLI tests on release (#237), and a smoke test that boots the built image
  against its own health probes (#249)
- Deploys pin the exact built image on a dedicated `deploy` branch so manifest
  and image can never diverge (#250)

### Fixed

- Conversations no longer replay their last prompt on every deploy (#248)
- The SSE stream endpoint no longer 406s real clients (#229), and the CLI
  resumes a dropped stream instead of reporting success (#219)
- `force_ssl` is applied as a runtime plug (#243), with health probes exempt
  from the HTTPS redirect (#245)
- Paid checkouts are never orphaned (#212)
- Turn images are validated at ingest, not only on serve (#235)
- `agents.skills` migrated from `text[]` to `jsonb[]` (#65)
- `PasswordResetController` returns `422 Unprocessable Entity` (was `200 OK`)
  on validation failure

### Security

- HSTS, secure cookies, and a scoped `check_origin`, all derived from
  `PUBLIC_URL` (#241)
- OAuth identities require a provider-verified email before linking (#240)
- Tenant secrets are redacted from sprite output before it is persisted (#222)
- Real client IP resolution behind proxies, and rate-limited login forms
  (#216)
- Tenant scoping tightened across the conversation spawn graph (#215), turn
  images (#202), sprite callback tokens — now with key expiry (#206), audit
  events (#68), and per-conversation `FOUNTAIN_TOKEN`s scoped to their owner
  (#75)
- Provisioning hardening: `.env` values quoted inertly (#227)
- Audit coverage extended to the browser surface, auth events, and admin
  actions (#221); external audit findings addressed (#129, #130)

## [0.2.1] — 2026-05-10

### Fixed

- CLI defaults its base URL to `fountain.inevitable.fyi` (#62)
- Dashboard "Recent conversations" card links to `/conversations`

## [0.2.0] — 2026-05-10

### Added

- Public marketing landing page at `/`
- Cross-tenant security regression suite (#55)

### Changed

- CLI ported from Elixir/Burrito to Go; the Elixir CLI and its release
  pipeline are removed (#60, #47, #50)
- Unscoped context functions renamed `_unsafe_*` as an enforcement convention
  (#54)

### Fixed

- Postgres `$N` placeholders in recursive CTE queries (#58)
- `fountain apply` strips ownership fields before POST/PUT (#59)

### Security

- Agent, Environment, Secret, and Vault controllers scoped to the
  authenticated user (#49, #51, #52); `user_id` propagated through
  `start_conversation` and orphaned rows backfilled (#48)

## [0.1.0] — 2026-04-01

### Added

- Multi-tenant API and UI for managing Agents, Environments, Vaults, and Conversations
- GitHub OAuth login via Ueberauth
- Stripe billing integration with subscription enforcement
- Per-tenant envelope encryption for secrets (AES-256-GCM, per-tenant DEK)
- Sprites sandbox platform integration (spawn / poll / stream log events)
- LiveView UI: dashboard, agent editor, environment/vault editors, conversation viewer, admin panel
- REST API with API-key authentication and per-tenant rate limiting
- `fountain` CLI (`cli/`) with `auth`, `apply`, `get`, `describe`, `delete` commands
- `llms.txt` / `llms-full.txt` / `/skill` endpoints for LLM-native API discovery
- Audit log for state-changing actions (append-only, best-effort)
- Substitution engine for `${VAR}` / `$$` interpolation in agent configs

[0.7.0]: https://github.com/BinaryBourbon/fountain/compare/v0.6.1...v0.7.0
[0.6.1]: https://github.com/BinaryBourbon/fountain/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/BinaryBourbon/fountain/compare/v0.5.2...v0.6.0
[0.5.2]: https://github.com/BinaryBourbon/fountain/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/BinaryBourbon/fountain/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/BinaryBourbon/fountain/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/BinaryBourbon/fountain/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/BinaryBourbon/fountain/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/BinaryBourbon/fountain/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/BinaryBourbon/fountain/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/BinaryBourbon/fountain/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/BinaryBourbon/fountain/releases/tag/v0.1.0
