# Phase 2: what the reference sites actually do

Every pattern below is given a short name in **bold**, so the later
deliverables can cite it. Every claim is from a page I fetched and read.
Anything I could not verify is marked "unverified".

---

## Temporal

Question. How do they teach four primitives to readers with no prior model,
how is the concepts tree separated from the how-to tree, and how does each
concept page justify the primitive's existence.

Pages read: `docs.temporal.io/llms.txt`, `/temporal.md`, `/workflows.md`,
`/activities.md`, `/evaluate/understanding-temporal`,
`/develop/typescript/llms.txt`.

### The two trees are the same topic list, twice

`docs.temporal.io/llms.txt` is the whole information architecture in one file.
The top section is **Core Primitives**, whose children are Activities, Child
Workflows, Data conversion, Event History, Namespace, Nexus, Temporal Service,
Visibility, Workers, Workflow, Workflow message passing. A later section is
**SDK Development Guides**, one per language, each at
`/develop/<language>/llms.txt`.

Fetch `/develop/typescript/llms.txt` and the child list is Activities, Best
Practices, Client, Nexus, Platform, Workers, Workflows. The same nouns. So a
reader who learned "Activity" from `/activities.md` finds the how-to at
`/develop/typescript/activities/basics.md`, by substitution rather than by
search.

**Pattern: mirrored topic trees.** One topic vocabulary, instantiated once as
explanation and once per language as how-to. Reference lives in a third tree
(`/references/`, `/cli/`) and troubleshooting in a fourth
(`/troubleshooting/`). Note that the top-level sections are named for what they
contain in reader language, not "Explanation" and "How-to guides".

### How a concept page justifies the primitive

`/activities.md` does four things in its first screen, in this order.

1. Defines the thing in one sentence in terms the reader already has. An
   Activity is "a normal function or method that executes a single,
   well-defined action".
2. Gives four recognizable jobs it is for, phrased as work the reader has
   already done. Single write operations, batches of similar writes, read then
   write, a read that should be memoized.
3. States the failure that the primitive exists to survive. If an Activity
   Execution fails, a future attempt starts from the initial state unless the
   code checkpoints with heartbeat details.
4. Says when you do not need it. "If you only want to execute one Activity
   Function, then you don't need to use a Workflow."

**Pattern: justify-by-failure.** The primitive is motivated by naming what
breaks without it, not by listing its features. **Pattern: the negative
boundary.** Every concept page states a case where the reader should use
something else.

### Disambiguating an overloaded noun

`/workflows.md` opens by conceding the word is overloaded. "In day-to-day
conversations, the term Workflow might refer to Workflow Type, a Workflow
Definition, or a Workflow Execution." It then numbers the three senses and
defines each. There is also a standalone `/glossary.md` in the Concepts
section.

**Pattern: noun disambiguation up front.** Directly relevant to Fountain, which
overloads "environment", "agent" and "fountain" worse than Temporal overloads
"workflow".

### The entry page routes into all four modes

`/temporal.md` ends with a **Next steps** list whose five items are a tutorial
(Quickstarts), how-to (Developer guides), reference-adjacent (Temporal Cloud),
and two explanations (architecture, Understanding Temporal). The reader is
handed the mode, not just the link.

**Pattern: mode-labelled next steps.**

---

## Stripe

Question. How does a conceptual page end in runnable code without becoming a
tutorial.

Page read: `docs.stripe.com/payments/payment-intents` ("The Payment Intents
API"), in full.

The page contains four `curl` blocks and is not a tutorial. The mechanism is
mechanical and copyable.

### Every snippet is the same stem with one parameter changed

Block 1 is the base object.

```
curl https://api.stripe.com/v1/payment_intents -u "sk_test_..." \
  -d amount=1099 -d currency=usd
```

Blocks 2, 3 and 4 are that exact request with exactly one line added.
`-d setup_future_usage=off_session`, then
`-d "statement_descriptor_suffix=Custom descriptor"`, then
`-d "metadata[order_id]=6735"`.

**Pattern: one-parameter variations on a fixed stem.** This is what prevents
the page becoming a tutorial. A tutorial's steps are ordered and cumulative, so
step 4 fails if you skipped step 2. These four blocks are independent and
substitutable. Any one of them runs on its own, and none of them advances a
state machine. Diátaxis licenses exactly this in `/reference/`, "Provide
examples", as illustration that avoids becoming instruction.

### The page explicitly refuses the tutorial and names its address

The Creating a PaymentIntent section's first sentence is "To get started, see
the accept a payment guide." The page then shows the object rather than the
build sequence. It closes with a **See also** list of four how-to guides
(Accept a payment online, in an iOS app, in an Android app, Set up future
payments).

**Pattern: hand off the sequence by name.** The conceptual page does not
compress the tutorial into a smaller tutorial. It says where the tutorial is,
in its first paragraph, and again at the end.

### Judgment goes in prose blocks, never in a numbered step

Between the code blocks the page carries **Best practices** (create the object
as soon as you know the amount, reuse it if checkout resumes, supply an
idempotency key) and repeated **Caution** admonitions (do not log the client
secret, do not store PII in metadata). These are the sentences that would be
steps in a tutorial. Here they are standing advice with no position in a
sequence.

### The advantage list is the justification

The page's second paragraph is four bullets. Automatic authentication handling,
no double charges, no idempotency key issues, support for SCA. Three of the
four are named failures avoided, which is Temporal's justify-by-failure
arriving independently at a second site.

---

## Fly.io

Question. How is reference organized for a CLI-first user with the API as the
escape hatch, and what exactly is the voice.

Pages read: `fly.io/docs/` (nav), `/docs/flyctl/`, `/docs/machines/`,
`/docs/machines/overview/`, `/docs/flyctl/machine-run/`.

### Resource-first, with the same four-shape inside each resource

The nav is organized by resource, not by mode. `/docs/machines/`,
`/docs/volumes/`, `/docs/networking/`, `/docs/monitoring/`, `/docs/mpg/`,
`/docs/security/`. Inside a resource the same sub-shape repeats.

| Slot | Machines | Volumes |
|---|---|---|
| explanation | `/docs/machines/overview/` | `/docs/volumes/overview/` |
| state reference | `/docs/machines/machine-states/` | `/docs/volumes/volume-states/` |
| how-to | `/docs/machines/guides-examples/...` | `/docs/volumes/volume-manage/` |
| CLI reference | `/docs/machines/flyctl/fly-machine-run/` | |
| API reference | `/docs/machines/api/` | |

**Pattern: the state machine is its own reference page.** Fly gives Machine
states and Volume states dedicated URLs rather than a section inside the
overview. Fountain's Conversation status lifecycle is currently four lines
inside an explanation page.

`/docs/reference/` exists as a separate top-level bucket, and it holds only the
platform-wide reference that no single resource owns. Configuration, regions,
health checks, fly-proxy, architecture, autoscaling.

### The CLI is indexed twice, by task and by command

`/docs/flyctl/` groups commands under task headings, not alphabetically. "Using
your Fly.io Account", "Working with Apps", "Viewing and monitoring an App",
"Configuring networking and certificates". Each entry is a human goal followed
by the exact command, in the form "Deploy An App: `fly deploy`". The same
command pages are also reachable inside the resource section.

Each command page itself (`/docs/flyctl/machine-run/`) is austere and
generated. Title, one-line summary, Usage, Options, Global options. No prose,
no voice, no examples. All ~60 flags in one block.

**Pattern: task-grouped command index over a generated command reference.** The
human organization is in the index. The command pages are machine output.

### The API is the escape hatch, and the concept page is the join

`/docs/machines/` is a three-item hub that names both surfaces and their
relationship in the deck. Machines are controlled "with a simple REST API or
flyctl commands". Its three children are the concept intro, the Machines API,
and the flyctl commands.

Then `/docs/machines/overview/` does the actual joining. Every lifecycle
transition names both surfaces in the same sentence. "You create a Fly Machine
with a Create Machine request, or with `fly machine run`." "you stop it with a
Stop Machine request, or `fly machine stop`." "Send a Delete Machine request,
or use `fly machine destroy`."

**Pattern: the concept page is the CLI/API join table.** The two reference
trees stay separate and neutral. The mapping between them lives in the
explanation, once, in prose, where it does not have to be maintained in two
generated files.

The same page also routes readers away twice. "For most applications, most of
the time, you don't need to be picky! ... Fly Launch does all that for you."
And `/docs/machines/` closes with "On the other hand, try Fly Launch if you
prefer easy app-wide configuration". That is Temporal's negative boundary
again, from a third site.

### The voice, concretely

Verbatim markers from `/docs/machines/overview/`, so this can be imitated or
rejected on evidence rather than vibes.

- Second person and contractions throughout. "If you've launched an app on
  Fly.io, you're already using Fly Machines."
- Editorializing exclamation inside technical prose. "you don't need to be
  picky!"
- Self-deprecation about their own product's ergonomics. "Here, we're going to
  scale Machines directly, in a fiddly way."
- Slang intensifier as a definition. "The big Fly Machine trick is: starting up
  super fast; like, 'in response to an HTTP request from a user' fast."
- A programming in-joke inside a lifecycle list. Step 3 ends "if you want to do
  that, GOTO 2."
- Anthropomorphized objects. "You're tired of the Fly Machine, and want it to
  go away permanently."
- Hedged numbers instead of precise ones. "this can take some time, maybe low
  double digit seconds."
- Real terminal output pasted verbatim, including the machine-generated app
  name `flyctl-interactive-shells-g1b7jg6wpdbq0i8b8yrl4q9rlqu5pm-502673` and a
  raw IPv6 address.
- Direct encouragement. "Go ahead and try it!"

**The voice is confined to explanation.** `/docs/flyctl/machine-run/` has none
of it. That split is the part worth copying regardless of what you think of the
jokes.

---

## Tailscale

Question. How does the "how it works" explainer do marketing work while staying
honest technical writing.

Page read: `tailscale.com/blog/how-tailscale-works` (Avery Pennarun, 20 March
2020), in full.

### The marketing is structural, not adjectival

The page never claims Tailscale is good. It builds the reader's existing
solution, lets it fail, rebuilds it better, lets that fail, and repeats. The
sequence is hub-and-spoke, then multi-hub, then mesh, then Tailscale.

Each stage is steelmanned before it is knocked down. On multi-hub: "But we can
do it, right? It's only about 5 times as much work as one hub, which is not
that much work." Only then does it enumerate what actually breaks. Nodes cannot
find each other, user devices rarely have static IPs, you cannot open a
firewall port in a cafe, and compliance auditing has nowhere to sit.

**Pattern: build the reader's status quo, then break it.** The product arrives
as the answer to a problem the reader has just watched accumulate, so no
adjective is needed.

### The honesty is specific and costly

- It gives away the implementation. "you should be able to build your own
  Tailscale replacement… except you don't have to, since our node software is
  open source and we have a flexible free plan." The commercial reason not to
  reimplement is stated plainly rather than hidden behind vagueness.
- It credits the component it did not build, by exact variant. "the userspace
  Go variant, wireguard-go".
- It admits its own complexity instead of smoothing it. "This is where things
  get a bit hairy."
- It names the case where the good path does not work. "Some especially cruel
  networks block UDP entirely, or are otherwise so strict that they simply
  cannot be traversed using STUN and ICE." The DERP relay fallback is then
  introduced as a concession, not a feature.
- It corrects an inaccuracy in its own diagram, in a parenthetical, quoting
  their designer on why London is missing from a map.
- It defers rather than pads. NAT traversal gets a one-paragraph summary and a
  link to a teammate's dedicated post.
- It is dated and bylined, so a 2020 claim reads as a 2020 claim.

**Pattern: concede the failure case in the same breath as the feature.**
**Pattern: date and sign explanation.** Explanation is the one mode allowed
opinion (`diataxis.fr/explanation/`), and a byline is what makes an opinion
attributable rather than corporate.

---

## WorkOS

Question. Reverse-engineer the template behind the per-provider setup guides.

Pages read: `workos.com/docs/integrations/okta-saml` and
`workos.com/docs/integrations/azure-ad-saml`, in full, diffed against each
other.

### The template, field by field, in order

1. **Breadcrumb** `Integrations`.
2. **H1** `<Provider> <Protocol>`, with the vendor's rename in parentheses when
   there is one. "Entra ID SAML (formerly Azure AD)".
3. **Deck**, one sentence, same skeleton both times. "Learn how to configure a
   connection to `<Provider>` via `<Protocol>`."
4. **On this page** auto-generated TOC.
5. **Introduction.** Opens with boilerplate that is near-identical across
   guides. "Each SSO Identity Provider requires specific information to create
   and configure a new Connection. And often, the information required to
   create a Connection will differ by Identity Provider." Then exactly one
   variable sentence naming what this provider needs. Okta needs three items,
   Entra needs one.
6. **What WorkOS provides.** The constant half of the exchange. Each field gets
   a definition sentence that is identical across guides ("The ACS URL is the
   location an Identity Provider redirects its authentication response to"),
   followed by a per-provider translation sentence ("the ACS URL will need to
   be set as the 'Single Sign-On URL'" for Okta, "as the 'Reply URL (Assertion
   Consumer Service URL)'" for Entra).
7. **What you'll need.** The variable half, coming from the customer's IdP,
   with a note that it normally arrives from the customer's IT team.
8. **Numbered steps.** Titles are reused across guides wherever the work is the
   same. Both guides have `1 Log in`, `2 Select or create your application`,
   `3 Initial SAML Application Setup`, `4 Configure SAML Application`. They
   diverge only at step 5.
9. **Optional steps marked in the heading.** "Role Assignment (optional)",
   present in both.
10. **Forward skips.** "move to Step 4" (Okta), "move to Step 7" (Entra), so
    the guide serves both the create-new and already-exists reader.
11. **Screenshot per UI step.**

### Why the fortieth guide is cheap

The genuinely new content per provider is three things. The provider's own UI
label for each of about three WorkOS-side fields, the click path through their
admin console, and the screenshots. Everything conceptual is boilerplate that
is written once and pasted.

**Pattern: constant-half / variable-half.** The guide is explicitly a
translation table between a fixed set of your-side terms and one vendor's
labels for them. This is the single most transferable idea in Phase 2.

**Pattern: shared step titles.** Reusing `1 Log in` verbatim across forty
guides is not laziness. It means a reader who has done one guide can skim the
next, and it means the writer knows which steps they are allowed to invent.

**Pattern: the vendor rename goes in the title.** Catalogs outlive vendor
branding, and a reader searching "Azure AD" must land on the Entra page.

---

## Sentry and Supabase

Question. How do they handle the same task documented once per platform without
it reading as copy-paste.

Pages read: `docs.sentry.io/platforms/javascript/guides/react/`,
`docs.sentry.io/platforms/python/guides/django/`,
`supabase.com/docs/guides/auth/server-side/nextjs`,
`supabase.com/docs/guides/auth/quickstarts/react-native`.

### Sentry: one URL per platform, one templated body underneath

The React and Django pages have a byte-identical skeleton. Deck ("Learn how to
set up Sentry in your `<X>`, capture your first errors and traces, and view
them in Sentry"), Prerequisites, Install, Configure, Initialize the Sentry SDK,
Verify.

The "Want to learn more about these features?" block is word-for-word the same
on both pages for the features they share.

What varies is small and mechanical. The package manager tabs (npm/yarn/pnpm
against pip/uv/poetry), the install command, the file the SDK is initialized in
(`instrument.js` against `settings.py`), and the version rows in Prerequisites.

The mechanism is visible in the fetched source. The code blocks contain
`___PUBLIC_DSN___` and paired `___PRODUCT_OPTION_START___ performance` /
`___PRODUCT_OPTION_END___ performance` markers. So the snippet is a single
templated artifact, filled at render time with the signed-in reader's real DSN
and toggled by the on-page feature picker.

**Pattern: token-substituted snippets.** The code is not written per platform,
it is generated from one source with slots.

**Pattern: capability-driven feature picker.** React offers Error Monitoring,
Tracing, Session Replay, Logs, User Feedback. Django offers Error Monitoring,
Tracing, Profiling, Logs, Metrics. The picker enumerates what this platform
actually supports, which turns "unsupported here" from missing prose into a
visibly absent option.

**Pattern: the wrong-page interceptor.** Near the top of the React page, before
Install, sits a block headed "Using React Server Components or a React
framework?" that routes to Next.js, Remix and Gatsby, and then states what the
current page is for. "This guide is for client-side React applications (SPAs)
built with tools like Vite or custom bundler configurations."

### Supabase: two different answers depending on the mode

Supabase does both things, and the split is not arbitrary.

`/guides/auth/quickstarts/react-native` is a **tutorial**, and it gets a
dedicated URL per framework. Numbered steps 1 to N, one concrete path, a "View
source" link to a real repo.

`/guides/auth/server-side/nextjs` is a **how-to plus explanation**, and it is
one page with an in-page framework switcher listing Next.js, SvelteKit, Astro,
Remix, Nuxt, React Router, Express, Hono and TanStack Start. The
framework-invariant prose is written once. The three-way comparison of
`getClaims` against `getUser` against `getSession`, and the reason a Next.js
Server Component needs a proxy to write cookies, appear once and are shared by
all nine frameworks.

**This is the correct rule, and it falls straight out of Diátaxis.** A tutorial
must be concrete, single-line, and must not offer alternatives
(`diataxis.fr/tutorials/`), so it duplicates per framework. Explanation is
about a topic rather than a tool and must weigh alternatives, so it is shared.
A how-to may fork, so a switcher is fine.

Both sites also inject the reader's live project values into the snippets.
Sentry's `___PUBLIC_DSN___`, Supabase's "Project URL" and "Publishable key"
fields, which render as "No project found" when signed out.

### Where they disagree, and which side to take

Sentry gives every platform its own URL. Supabase gives its how-tos one URL and
a switcher. The tradeoff is real. Per-URL wins on deep linking, on search
landing, on per-platform ownership, and on being able to say "read
`/platforms/python/guides/django/`" in a support reply. Switcher wins on
never letting the shared prose drift.

**Take Supabase's split, not either extreme.** Duplicate the URL when the page
is a tutorial or when the content is genuinely mostly different. Share the URL
with a switcher when the only difference is the code block. For Fountain the
practical consequence is that the four runtimes (`claude`, `codex`, `gemini`,
`opencode`) should be a switcher on shared pages, not four page trees, because
almost everything about them is identical and the divergences are small enough
to name inline.

---

## Segment

Question. What does catalog UX need once there are hundreds of entries.

Pages read: `segment.com/docs/connections/destinations/catalog/`,
`segment.com/docs/connections/destinations/catalog/actions-slack/`.

### Measured shape

I extracted the catalog index and counted. 1021 entry lines resolving to 495
distinct strings, across roughly 45 function categories ("A/B Testing",
"Advertising", "Analytics", and so on). So each destination is listed under
about two categories on average.

**Pattern: cross-listing is mandatory at scale.** Segment does not file each
entry once. AB Smartly appears under both A/B Testing and Analytics. AdQuick
appears under both Advertising and Analytics. A single home starts mis-filing
entries long before 495, because vendors do not respect your taxonomy.

**Pattern: one vendor is not one entry.** The unit is one integration. Slack
has two entries, Optimizely five, TikTok five, LinkedIn three, Facebook three.

**Pattern: status and variant live in the entry title.** Names carry inline
suffixes so a scanner can disambiguate without clicking. `Beta`, `(Actions)`,
`Cloud Mode`, `Web Mode`, `(Classic)`. "Optimizely Web" and "Optimizely Full
Stack" and "Optimizely Data Platform (Beta)" are visibly three things in the
list itself.

**Pattern: two views over one dataset.** At the very top of the categorized
catalog sits "Want a simpler list? Check out the list of all destinations." The
categorized view answers "what should I use for analytics". The flat view
answers "do you support X". Neither view can answer both, and at this scale
both questions are common.

### The entry page template

From the Slack (Actions) page, in order.

1. H1 `<Vendor> (<Variant>) Destination`.
2. **Destination Info** box, hoisted above all prose. What call types it
   accepts, and the exact identifier string to use in the API. Machine facts
   first.
3. **Version disambiguation callout.** "Additional versions of this destination
   are available… See below for information about other versions of the Slack
   destination", linking to Slack (Classic).
4. One-sentence vendor description, clearly vendor-supplied.
5. **Benefits of X vs Y**, present only when variants exist.
6. **Getting started**, numbered click path.
7. **Important differences from the classic destination**, the gotcha section.
   Here it is a single line about handlebars against Slack's formatting syntax.
8. **Available Actions**, with a generated
   `Property name | Type | Required | Description` table per action.
9. **Migration from**.

The generated property tables are why the entry is cheap. They come from the
destination's own schema, not from prose.

---

## Modal

Question. How do they build the mental model for remote sandboxed execution.

Pages read: `modal.com/docs/guide`, `modal.com/docs/guide/sandbox`.

This is the closest analogue to Fountain in the whole set, and the Sandboxes
page is worth treating as the target for Fountain's Conversation page.

### The page declares its own mode in its first sentence

"This page is a high-level guide to Sandboxes, secure containers for executing
untrusted user or agent code on Modal. For reference documentation on the
`modal.Sandbox` interface, see this page."

**Pattern: state the mode and link the twin.** Two sentences that make
reference/explanation blur structurally impossible. The reader who wanted the
other mode leaves in three seconds instead of scrolling.

### The primitive is introduced as a contrast with the known one

"In addition to the Function interface, Modal has a direct interface for
defining containers at runtime and securely running arbitrary code inside
them."

The reader already knows Functions. Sandboxes are defined by what they add.

### The H2 is literally the reader's two questions

"What are Sandboxes and why should I use them?" is answered with a list of
recognizable jobs rather than a definition. Execute code generated by a
language model. Create isolated environments for running untrusted code. Check
out a git repository and run a command against it, like a test suite, or
`npm lint`. Run containers with arbitrary dependencies and setup scripts.

Three of those four are literally what a Fountain Conversation does.

### The lifecycle is events, each with a paragraph saying what exists yet

Created, Scheduled, Started, Ready, Finished. Each gets a paragraph that
answers three things. What exists now, what does not exist yet, and what you
are allowed to do at this state.

- Created. "the Sandbox object exists and has an ID, but no compute resources
  have been allocated yet."
- Started. "At this point you can begin executing commands inside the Sandbox
  with `sandbox.exec(...)`. Network tunnels and volume mounts are active."
- Ready. Conditional, and says so. "If readiness probes are enabled… If
  readiness probes are not configured, this event is skipped."
- Finished. Enumerates all five ways it can happen. The entrypoint exited, it
  was terminated from the dashboard, `sandbox.terminate()`, the timeout or idle
  timeout was reached, or out of memory.

**Pattern: per-state paragraph, not a diagram.** A state diagram tells you the
edges. It does not tell you what you may call, which is the question a reader
actually has.

**Pattern: enumerate every exit.** The Finished paragraph does not say "for
various reasons".

### Defaults are stated with their override in the same sentence

"Sandboxes have a default maximum lifetime of 5 minutes. You can change this by
passing a timeout of up to 24 hours to the `Sandbox.create(...)` function."

Value, unit, ceiling, and the exact parameter, in two sentences.

### The intro page's voice, for contrast with Fly

`modal.com/docs/guide` is terse and mostly claim-then-stop, with one flourish.
"Take a breath of fresh air and feel how good it tastes with no YAML in it." It
then shows a complete 25-line runnable example, followed by "That's it!" and
the exact command to run it. Multi-language tabs (Python, async Python,
JavaScript, Go) rather than four page trees, which is Supabase's switcher
arriving independently.

---

## HashiCorp Vault

Question. What does "vault" already mean to a developer who has used their
product, and where does that prior collide with Fountain's Vault.

Pages read: `developer.hashicorp.com/vault/docs/what-is-vault`,
`developer.hashicorp.com/vault/docs/concepts/seal`.

### What the word already means

1. **A deployed server or cluster, not a data object.** It has storage backends
   with an HA support column (Integrated, File system, External, In-memory).
   You install it, run it, and operate it.
2. **Singular and central.** The opening sentence is "centralized, well-audited
   privileged access and secret management". There is one Vault per
   environment. You do not make many small ones.
3. **Sealed by default.** "When you start a Vault server, it starts in a sealed
   state. In this state, Vault can access the physical storage, but it cannot
   decrypt any of the data on it." Unsealing is an operational ritual, with
   Shamir shares and a quorum threshold.
4. **Dynamic, leased, revocable credentials.** The headline capability is
   database secret plugins that "manage dynamic credentials".
5. **Path-mounted, policy-governed.** "Clients interact with secrets and
   encryption operations based on resource paths mounted in Vault", authorized
   against policies set on that path.
6. **Audited unconditionally.** "Vault audits all activity, regardless of
   whether authentication or authorization succeeds".
7. **The system of record.** If it is in Vault, it is authoritative.

### Where the prior collides with Fountain's Vault

| Reader's prior from HashiCorp | Fountain's actual Vault |
|---|---|
| One central server you deploy and operate | Many small rows in Postgres, created freely per customer or per environment |
| The authoritative store | A patch layer. The Environment is the baseline; the Vault is the exception |
| Dynamic, leased, short-lived credentials | Static key/value written once, never rotated, never revoked, never returned |
| Sealed/unsealed operational state | No state. There is nothing to unseal |
| Path mounts and per-path policy | A flat key/value bag, scoped only by tenant and by `allowed_vault_ids` |
| Precedence is not a concept | Precedence is the whole point. Vault values win on key collision |

**The prior actively inverts the most important fact.** A HashiCorp user reads
"Vault" and assumes it is the base of truth. In Fountain the Environment is the
base and the Vault overrides it. Getting that backwards produces exactly the
wrong mental model of the merge, which is the one thing a reader must get right
to use vaults at all.

**Two dangerous silent assumptions.** That putting a credential in a Fountain
Vault gets it rotation and revocation, and that a Fountain Vault is audited at
read time the way HashiCorp's is. Neither is true, and neither is currently
denied anywhere in Fountain's docs.

**One thing that does transfer, and should be leaned on.** The envelope
encryption chain is the same shape. HashiCorp goes unseal key to root key to
keyring to data. Fountain goes `MASTER_SECRETS_KEY` to per-tenant DEK to secret
value. A reader with the HashiCorp prior will understand Fountain's crypto
immediately, so that is the place to say "yes, like Vault", right after saying
"no, not like Vault" about everything else.

---

## Where the sites disagree, and the side I take

**1. Top-level nav: four Diátaxis buckets, or reader-language sections.**

Nobody in this set uses the four Diátaxis words at top level. Temporal uses
Core Primitives / SDK Development Guides / References / Guides / Best Practices
/ Troubleshooting. Fly uses resources. Modal uses Guide / Reference / Examples.

Take reader-language sections, with one mode per section. Diátaxis licenses
this itself. `diataxis.fr/explanation/` says explanation "doesn't need to be
called Explanation" and offers Discussion, Background, Conceptual guides,
Topics as alternatives. The discipline is that a section contains exactly one
mode, not that it is named after it.

**2. Resource-first (Fly) or mode-first (Temporal).**

Fly repeats the whole four-mode shape inside every resource, which is right
when you have twelve resources of comparable weight. Temporal keeps one
concepts tree and mirrors its topic names into the how-to trees, which is right
when a small number of primitives are referenced everywhere.

Take Temporal. Fountain has four primitives and a growing catalog. Replicating
overview / states / guides / CLI / API under each of Environment, Vault, Agent
and Conversation would produce twenty near-empty pages, which is the empty
structure `diataxis.fr/how-to-use-diataxis/` explicitly warns against. Borrow
exactly one thing from Fly, the state machine as its own reference page.

**3. Per-platform URLs (Sentry) or one page with a switcher (Supabase).**

Take Supabase's split, as argued above. Tutorial duplicates, how-to and
explanation share with a switcher.

**4. How much voice belongs in docs.**

Fly is chatty everywhere in explanation. Modal is terse with one joke per page.
Stripe and Temporal are neutral throughout. Tailscale is chatty but signed and
dated.

Take Modal's calibration with Tailscale's honesty, and take Fly's *split*
rather than Fly's register. Voice lives in explanation only. Reference pages
get none. The deciding argument is Fly's own site. `/docs/machines/overview/`
contains "GOTO 2" and `/docs/flyctl/machine-run/` contains sixty flags and no
adjectives, and both are correct.
