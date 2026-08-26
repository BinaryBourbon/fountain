---
type: ADR
title: "Sandboxes on the tenant's tailnet: inbound by default, ephemeral nodes, outbound refused"
description: "Proposed; nothing is built. A tenant connects a Tailscale OAuth client once and flips a switch on an environment; each sandbox joins their tailnet as an ephemeral, tagged, userspace-mode node whose MagicDNS name is surfaced beside the public URL. Inbound (reach the sandbox) is the shipped direction; outbound (the agent reaches the tailnet) is refused by name because it collides with the egress broker's HTTPS_PROXY."
tags: [sandbox, networking, egress, architecture]
status: draft
adr: "0036"
adr_status: "Proposed"
date: 2026-08-26
generated: { by: human:jhgaylor, at: 2026-08-26T12:00:00-04:00 }
stale_after: 2026-11-26
---

# 0036 — Sandboxes on the tenant's tailnet: inbound by default, ephemeral nodes, outbound refused

**Status:** Proposed. **Nothing described here is built.** There is no
Tailscale code in the repo today; `grep -ri tailscale` finds only two
references in `standards/` to Tailscale's writing. What exists is the manual
path of [Context](#context), which any tenant can already assemble out of a
vault secret and a `setup_script`. Gate 0 has not been run, so the central
factual premise — that a userspace-mode node comes up at all inside a Sprites
or E2B sandbox — is an expectation, not a measurement.

Extends [0018](0018-sandbox-provider-abstraction.md) with a per-provider
capability, constrains [0019](0019-egress-credential-brokerage.md) at the
point where the two mechanisms want the same environment variable, and
inherits [0017](0017-suspend-idle-sandboxes.md)'s park/wake cycle as the
hardest part of the lifecycle.

## Context

Fountain's sandboxes reach the public internet and nothing else. The thing
people ask for next is the opposite direction: *my* Postgres, *my* Gitea,
*my* staging box, *my* Mac — hosts that exist only on a network Fountain has
no route to. Today there are two answers and both are bad. Publish the
service to the internet and defend it, or run a self-hosted runner
([0022](0022-self-hosted-runner-provider.md)) on that network and give up
isolation and per-minute economics for everything else the agent does.

A tailnet is the answer the audience already has. Most of the people who want
this are running Tailscale, and the shape they expect is the one every other
container platform offers: a checkbox, and the machine shows up in their
admin console.

**The manual path already works, roughly.** A tenant can put a `TS_AUTHKEY`
in a vault and write eight lines of `setup_script` — the image gives `sprite`
passwordless sudo (`images/e2b/e2b.Dockerfile:31`) and `setup_script` runs
last in the pipeline with the environment sourced from `/home/sprite/.env`
(`Fountain.Conversations.Provisioning`, step 5). What that path does not give
anyone is a lifecycle: the auth key is long-lived and reusable and sits in a
vault the agent can read; the tailnet fills with dead machines as sandboxes
churn, because nothing removes a node when its sandbox is destroyed; the
MagicDNS name is nowhere in the product, so there is no way to find the box
you just made; and the whole thing breaks silently the moment the environment
is `limited` or the tenant is on the broker. Every tenant who wants this
writes the same eight lines and hits the same four walls.

**The constraint that shapes everything below** is that userspace Tailscale is
asymmetric. `tailscaled --tun=userspace-networking` needs no privileges and no
`/dev/net/tun`, and it *accepts* connections on the node's tailnet address and
forwards them to localhost with no per-tool configuration. But it intercepts
nothing outbound: reaching a tailnet host from inside the sandbox means
pointing each tool at tailscaled's SOCKS5 or HTTP proxy. Those are
`ALL_PROXY` / `HTTP_PROXY` / `HTTPS_PROXY`, and
[0019](0019-egress-credential-brokerage.md) already owns all four
(`Fountain.Broker.sandbox_env/1`), for a mechanism whose entire security
argument is that the broker is the only reachable host. Two proxies cannot
own one variable, and the resolution is not a naming trick.

## Decision

### One tenant-level Tailscale connection; keys are minted, never pasted

A tenant registers a Tailscale **OAuth client** (id + secret, scoped to
`auth_keys`, owning at least one tag) once, on a connections page. Fountain
stores the secret encrypted with the tenant DEK, the way
`Fountain.Connections` stores a refresh token, and never puts it in a sandbox.

At each join, Fountain mints a **fresh auth key** through the Tailscale API
with four properties, all of them load-bearing:

* **ephemeral** — the node deletes itself when it disconnects. This is what
  keeps a tenant's admin console from filling with a thousand dead sandboxes,
  and it is why nothing here needs a reaper of its own.
* **preauthorized** — the node is usable without a human clicking approve.
* **tagged** (`tag:fountain-sandbox` by default, tenant-overridable) — the ACL
  surface. A tagged node is not owned by a user, so the tenant writes one ACL
  rule for the tag rather than one per sandbox.
* **single-use, minutes-long expiry** — the key authenticates one join. A key
  that leaks after the join is worthless.

`Fountain.Connections` is the right *shape* and the wrong *flow*: this is a
stored client credential used for machine-to-machine minting, not a user
signing in to an account, and it has no `account_email`. It is a sibling
context (`Fountain.Tailnet`) that borrows the encryption pattern.

### Inbound is what ships; outbound is refused by name

The switch on an environment means: **this sandbox appears on your tailnet and
you can reach it.** `ssh`, `curl`, a browser against whatever the agent is
serving, the workbench app talking to a dev server. Userspace mode gives that
with no privileges and no collision.

The switch does **not** mean the agent can reach tailnet hosts. Making it mean
that requires either `/dev/net/tun` (a privilege no hosted provider is known
to grant) or handing tailscaled the proxy variables the broker holds. A
brokered tenant asking for outbound is refused at preflight, before a sandbox
exists, with a named stage event — exactly the shape
`Provisioning.check_network_policy_support/3` uses for a `limited` environment
on a backend with no `:network_policy` (#935), and for the same reason: the
alternative is a failure several steps in, wearing the shape of a transport
error.

Naming the two directions separately in the schema (`tailnet_inbound` /
`tailnet_outbound`) rather than one boolean is deliberate. Outbound is a
different decision with a different blocker, and a product that promises "your
tailnet" and delivers half of it silently is worse than one that says which
half.

### The join runs on both provisioning arms, and again on every wake

Joining a tailnet is **configuration and a live daemon**, not a disk artifact.
That puts it in the same class as the network policy, and the network policy
already taught this lesson the expensive way: `run_provisioning_pipeline/6`
skips packages, clone and `setup_script` on a warm start, and skipping the
policy with them turned a `limited` environment into an unrestricted one
silently while reporting `provision/done` (#989). The join runs on the warm
arm and the cold arm both.

It also runs on **reattach**. [0017](0017-suspend-idle-sandboxes.md) parks
idle sandboxes; a parked machine's daemon stops, the node disconnects, and
because the node is ephemeral it is *gone*. Waking it means minting a new key
and joining again under the same `--hostname`, next to the broker session
re-mint and the CA re-install that `do_reattach/6` already does best-effort on
every wake. A tailnet join that only ran at provision time would work
perfectly until the first idle timeout and then quietly stop, which is the
failure mode this repo has shipped twice.

### The node key never enters a checkpoint

`tailscaled.state` holds the node's private key. A warm-start checkpoint that
captured it would make every sandbox restored from that checkpoint *the same
node*, and they would flap each other offline in the tenant's tailnet with no
error anywhere in Fountain. The state directory lives outside the checkpointed
path, and authentication happens after restore, never before snapshot. The
environment's tailnet fields join `@warm_start_fields` so that turning the
switch on invalidates the checkpoint rather than warm-starting into a
half-configured machine.

### The minted key reaches the daemon and nothing else

The key is written to a mode-600 file and passed as `--auth-key=file:<path>`,
then unlinked. Not on argv, where `ps` shows it to the agent; not in
`/home/sprite/.env`, which is shared by every conversation on the machine and
is explicitly meant to be `source`d by user scripts. If any variable ends up
carrying it, that variable goes in `Fountain.Conversations.Identity`'s
`@process_only` list, which is where the broker's session-bearing
`HTTPS_PROXY` already lives for the same reason.

### The name is surfaced, or the feature does not exist

The node's MagicDNS name (`<hostname>.<tailnet>.ts.net`) goes in the sandbox
row's `provider_meta` beside `public_url`, is published as a `tailnet` stage
event, and is rendered wherever the public URL is rendered. "Did it work" must
have an answer that is not the tenant's Tailscale admin console.

The hostname is derived from the sandbox name, not the agent name: two
concurrent conversations of one agent ([0023](0023-persistent-agent-sandbox.md)
notwithstanding) would otherwise collide and Tailscale would silently suffix
one of them.

### Egress policy, per `networking_type`

* **`unrestricted`** — works. This is the only combination gate 1 supports.
* **`limited`** — the allowlist must gain `controlplane.tailscale.com` and
  the DERP hosts, and even then a domain allowlist cannot express direct
  WireGuard, which is UDP to arbitrary peer addresses. A `limited` tailnet
  sandbox is therefore relay-only and slower. Gate 3; refused by name until
  then.
* **brokered** — the floor is `allow: [broker]`
  (`Provisioning.apply_broker_floor/2`). A tailnet join needs a second
  permitted destination, which is a change to 0019's central claim and is
  0019's decision to make, not this ADR's. Refused by name until someone makes
  it.

### Providers answer for themselves

`:tailnet` becomes a `Fountain.Sandbox` capability, advertised per adapter and
pinned by the conformance suite, because whether outbound UDP 41641 leaves the
sandbox at all is a per-provider fact nobody here knows yet.
`Fountain.Sandbox.Runner` **refuses it**: the machine is the user's and so is
its network (`Runner` already refuses `:network_policy` on that reasoning), and
a user who wants their own Mac mini on their own tailnet does not need
Fountain to arrange it.

### Off means off

With no Tailscale connection on the tenant and no switch on the environment,
no code here makes an HTTP call and provisioning is byte-for-byte what it was.
The same rule 0019 holds itself to.

## Gates

* **Gate 0 — the spike, before any code.** A throwaway environment, a vault
  key, eight lines of `setup_script`, run once on Sprites and once on E2B.
  Answers: does a userspace node come up; is it reachable inbound from another
  tailnet host; does a direct connection ever establish or is everything DERP;
  what does it cost at startup. **If gate 0 fails on the hosted providers,
  this ADR is withdrawn** and the outcome is a docs page and a shareable
  environment, not a feature.
* **Gate 1 — inbound, one provider, unrestricted only.** The connection, key
  minting, the environment switch, the provisioning stage on both arms, the
  name surfaced. Refusals by name for `limited`, brokered, and providers
  without the capability.
* **Gate 2 — the lifecycle.** Re-join on wake, `tailscale logout` on destroy
  (best-effort; ephemeral expiry is the real backstop), and a check that a
  destroyed sandbox's node is actually gone from the tenant's tailnet.
* **Gate 3 — `limited`.** Translate `allowed_hosts` to keep control plane and
  DERP reachable, and say plainly in the docs that this configuration is
  relay-only.
* **Gate 4 — outbound.** Unscheduled, and blocked on a decision that belongs
  to 0019. Do not build it as a variant of gate 1.

## Consequences

**The isolation story gets a caveat, and it should be stated where the claim
is made.** A sandbox on a tenant's tailnet can reach that tenant's private
network. That is the entire point, and it also means 0019's "the only host it
may reach is the broker" stops describing the whole picture for these
sandboxes. An agent that goes wrong now goes wrong on a network with real
things on it. The docs page says this in the same breath as the feature, and
the brokered refusal above is not a scheduling accident — it is the seam where
the two guarantees actually conflict.

**The tenant owns their ACLs and we cannot fix them from here.** The OAuth
client must own the tag, and the tag must be granted access to whatever the
tenant wants reachable. The mitigation is a copyable ACL snippet and a
connect-time preflight that mints a throwaway key and reports Tailscale's own
error verbatim, rather than a Fountain-shaped guess at what went wrong.

**Provisioning gets slower.** A join is a binary in the image (bake it; do not
apt-fetch per boot), a daemon start and a control-plane round trip. It is on
the critical path to the first turn for every conversation in an enabled
environment.

**A new external dependency on the provisioning path.** Tailscale's API being
down becomes a provisioning failure for enabled environments. It fails by
name, like the broker's `/health` preflight, and does not fail conversations
in environments that never asked for it.

**Nothing bills.** No credit, no quota, no rent. The tenant's Tailscale plan
is between them and Tailscale, and an ephemeral node costs them nothing on any
plan that counts machines.

**What we give up by shipping inbound only:** the most compelling demo — an
agent running `psql` against a database that has never been on the internet —
is exactly the half that is refused. The honest framing is that this feature
makes the sandbox reachable, and reaching *out* is still an open problem.

## Alternatives considered

- **Document the manual recipe and ship nothing** — a docs page plus a
  shareable environment gets most of the inbound value for zero server
  changes, which is precisely why it is gate 0's fallback rather than a
  competing option. It does not fix key lifetime, dead nodes, discovery, or
  the silent breakage under `limited` and the broker, and every tenant pays
  the same eight lines.
- **A pasted reusable auth key on the environment** — half the code, and it
  keeps the two failures that actually hurt: a long-lived credential the agent
  can read, and nodes that outlive their sandboxes.
- **Fountain runs a subnet router into the tenant's network** — inverts the
  trust: we would hold a route into their LAN instead of them holding a node
  in our sandbox. Also puts Fountain in the business of operating their
  network.
- **Fountain runs a Headscale control plane** — a coordination server is a
  product, not a feature, and tenants who want this already have a tailnet.
- **`tailscale funnel`, or lean harder on `public_url`** — solves reaching the
  sandbox from the internet, which the `:public_url` capability already does.
  It does not put the sandbox on a private network, which is the entire ask.
- **A reverse SSH tunnel to a bastion the tenant runs** — DIY-able today with
  no Fountain change, and it delivers a port, not a network: no discovery, no
  names, no ACLs, and a bastion to operate.
- **A per-provider Tailscale sidecar** — the clean answer, and not on offer:
  none of Sprites, E2B or Daytona expose a sidecar or a shared network
  namespace for one.
