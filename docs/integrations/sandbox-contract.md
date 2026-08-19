# The sandbox contract

Every conversation runs in a sandbox, and every sandbox backend plugs into
the same seam: the `Fountain.Sandbox` behaviour. There is one contract a
provider has to meet, and it is executable — the behaviour's moduledoc
specifies the callbacks, capabilities and error taxonomy, and
`Fountain.SandboxConformanceCase` is the conformance suite every adapter
must pass (replay-from-start attach, total `write_stdin`, exactly one
terminal frame per command, `allow: []` means deny-all, and the rest). The
design rationale is
[ADR 0018](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0018-sandbox-provider-abstraction.md).

So far, four providers implement it:

| Provider | What it is | Suspend semantics |
|---|---|---|
| [Sprites](sprites.md) | [sprites.dev](https://sprites.dev) — the original backend and the instance default | Parks implicitly: the sprite scales to zero on its own, disk preserved |
| [E2B](e2b.md) | [e2b.dev](https://e2b.dev) | Explicit `pause`: filesystem **and memory** snapshot, restored on resume |
| [Daytona](daytona.md) | [daytona.io](https://daytona.io) — self-hostable via `DAYTONA_API_URL` | Explicit `stop`: disk preserved; long-parked sandboxes archive to object storage |
| [Self-hosted runner](runners.md) | `fountain runner` on a machine the **user** owns; dials out to Fountain, no vendor account | Stops the sandbox's processes; the directory stays. Trusted mode — no isolation, no egress policy |

The three hosted providers advertise suspend, network policy and attach; a
runner advertises suspend and attach only. TTY support is Sprites-only. Checkpoint-based warm starts exist only in the Sprites
transport and are currently off by default — a checkpoint id is scoped to
the sprite that created it, so cross-sprite warm starts cannot work (#654).

## Picking a provider

- A hosted provider is **enabled** by exactly one thing: its credential is
  present (`SPRITES_TOKEN`, `E2B_API_KEY`, `DAYTONA_API_KEY`). The runner
  provider has no credential — every daemon authenticates with the user's
  own API key — so it is enabled unless `SANDBOX_RUNNERS_ENABLED=false`.
- `SANDBOX_PROVIDER` (default `sprites`) sets the instance default for
  newly-created sandboxes. Boot refuses an explicit default whose credential
  is missing.
- An agent can pin a provider via `sandbox_provider`; the provider select
  appears in the agent form on its own once a second provider is enabled.
- **Existing sandboxes always stay on the provider that created them** — a
  parked disk lives where it was written, so waking never crosses providers.

You need at least one. Without any provider credential the app boots, but
every conversation fails at provision time.

## What the contract guarantees

- **Capabilities are honest.** Adapters advertise what they can actually do
  (`:suspend`, `:network_policy`, `:attach`, `:tty`, `:checkpoint`,
  `:public_url`), and the
  lifecycle degrades accordingly: a provider without `:suspend` destroys on
  idle rather than faking a park — agent memory lives on the sandbox disk,
  and resume-with-a-fresh-disk would be silent data loss.
- **Errors are one taxonomy.** Every adapter normalizes provider errors into
  the shapes in the behaviour moduledoc (`:not_found`, `{:unavailable, _}`,
  `{:denied, _}`, `{:rate_limited, _}`, …), so retry policy is
  provider-independent — and `{:error, :not_found}` is kept distinct from
  transient failure, which is what protects parked disks from being
  destroyed on a flaky network call.
- **Network policy means what it says.** For a `limited` environment,
  `allow: []` is deny-all on every provider, never a no-op.
- **A sandbox URL is real or absent, never a guess.** Providers that give a
  sandbox its own HTTP endpoint advertise `:public_url`; the URL is stored on
  the sandbox row, returned as `sandbox.url` on the conversation API, and set
  inside the sandbox as **`SANDBOX_URL`** so an agent asked "where is it
  running?" can answer. Providers that expose per-port hostnames instead
  report `:unsupported` rather than an address that would not resolve.

  On Sprites the endpoint defaults to requiring a platform credential, so
  Fountain opens it (`url_settings.auth = "public"`) when the sandbox is
  created — an agent serving a page is doing it for a human who has no such
  credential. **Anything an agent serves is therefore reachable by anyone with
  the URL.** Set `config :fountain, :sprites_public_urls, false` to keep the
  default instead; sandboxes then keep their URLs but only a token holder can
  open them.

## Where to go next

- Setting up a specific provider: [Sprites](sprites.md), [E2B](e2b.md),
  [Daytona](daytona.md).
- Implementing the contract for a fourth backend:
  [Adding a provider](adding-a-sandbox-provider.md).
- The original backend's wire protocol, for building a Sprites-compatible
  replacement: [the Sprites transport reference](sprites-contract.md).
