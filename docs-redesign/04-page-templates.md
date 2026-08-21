# Deliverable 2: a page template per mode

Four skeletons. Each heading carries a one-line note saying what belongs under
it, and a citation for why the slot exists.

Two rules apply to all four.

**Declare the mode in the first two sentences and link the twin.** Modal's
`modal.com/docs/guide/sandbox` opens "This page is a high-level guide to
Sandboxes… For reference documentation on the `modal.Sandbox` interface, see
this page." Two sentences make mode blur structurally impossible, because the
reader who wanted the other mode leaves immediately.

**A page owes exactly one mode.** If a section will not fit under any heading
in its template, that section belongs on a different page. That is the test,
not a guideline.

---

## Tutorial

Fountain should have two of these and no more.
`diataxis.fr/tutorials/` warns that tutorial revisions "cascade through the
entire story", which makes each one a standing maintenance commitment.

```markdown
# <A concrete thing we will build together>

<!-- Title names the artifact, not the skill. "An agent that opens a pull
     request", never "Learning Fountain" or "Getting started with agents". -->

In this tutorial we will <build X>. Along the way we will meet
<primitive>, <primitive> and <primitive>.

<!-- diataxis.fr/tutorials/, "Show the learner where they'll be going".
     Never "you will learn", which the source calls presumptuous and a very
     poor pattern. First person plural throughout; the source calls it the
     affirmation that "we are in this together". -->

## What you need

<!-- Exactly the prerequisites this tutorial uses, with versions. No optional
     items, no "you may also want". Every line here is something the reader
     must have before step 1, and the tutorial fails without it. -->

## 1. <The first concrete result>

<!-- One command or one action. Show it. -->

<!-- Then the expected output, verbatim, in a block. diataxis.fr/tutorials/,
     "Maintain a narrative of the expected". Paste real output including ids
     and timestamps, the way fly.io/docs/machines/overview/ pastes a real
     machine id and a raw IPv6 address. -->

You will see <specific string>. That means <what it means>.

<!-- diataxis.fr/tutorials/, "Point out what the learner should notice".
     One sentence. Not an explanation of the mechanism. -->

If you do not see <specific string>, <the one likely cause>.

<!-- Only for failures you have actually observed. A speculative failure mode
     costs confidence and buys nothing. -->

## 2. <The next concrete result>

<!-- Repeat. Every step produces something the reader can see.
     diataxis.fr/tutorials/, "Deliver visible results early and often". -->

## N. Clean up

<!-- Non-negotiable. The tutorial must be repeatable, and Fountain's steps
     provision billable sandboxes. diataxis.fr/tutorials/, "Encourage and
     permit repetition". -->

## What you just built

<!-- Name the artifact and name the primitives that appeared, linking each to
     its Concepts page. This is the only place a tutorial links outward.
     diataxis.fr/tutorials/, "Describe (and admire, in a mild way) what your
     learner has accomplished". -->

## The whole thing, in one script

<!-- Every command from steps 1 to N, contiguous, copyable. tour.md already
     does this and it is the best single feature of that page. It is also how
     the tutorial gets tested. -->

## Making it yours

<!-- Two or three one-line pointers to how-to guides. Not variations on the
     tutorial. -->
```

**Prohibited in a tutorial.** Alternatives, options, `--flags` the reader is
invited to choose between, "you could also", explanation of why beyond one
clause, and any sentence beginning "Note that". `diataxis.fr/tutorials/`,
"Ignore options and alternatives" and "Ruthlessly minimise explanation".

---

## How-to guide

The most common mode in Fountain and the one with the most pages after the
split. Title always starts with a verb.
`diataxis.fr/how-to-guides/`, "Pay attention to naming", grades
"How to integrate application performance monitoring" as good, "Integrating
application performance monitoring" as bad, and the bare noun phrase as very
bad.

```markdown
# <Verb> <object>

<!-- "Rotate the master secrets key", not "Key rotation", not "Rotating keys". -->

This guide shows you how to <goal>, when <the situation the reader is in>.

<!-- diataxis.fr/how-to-guides/, "This guide shows you how to…". The second
     clause is the entry condition. A reader in a different situation should
     be able to leave on this sentence. -->

<!-- If a sibling guide covers the adjacent situation, route here, before the
     first step. This is Sentry's wrong-page interceptor, at
     docs.sentry.io/platforms/javascript/guides/react/, which routes Next.js,
     Remix and Gatsby readers away before Install. -->

## Before you start

<!-- Preconditions as a checkable list. State access level, which surface
     (console, CLI, API), and anything irreversible ahead. -->

## <Verb the first sub-goal>

<!-- Headings are sub-goals, not tool names. Not "Use the vault API", but
     "Attach the vault to one run". diataxis.fr/how-to-guides/ is emphatic
     that guides are "about goals, projects and problems, not about tools",
     and that tools appear as "incidental bit-players". -->

<!-- Conditional imperatives where the path forks. "If you want x, do y. To
     achieve w, do z." A how-to may fork; a tutorial may not. -->

<!-- Judgment goes here, in prose, not as a step. Stripe's
     docs.stripe.com/payments/payment-intents keeps its recommendations in a
     Best practices block and its warnings in Caution admonitions, both
     outside the numbered flow. -->

## Verify it worked

<!-- One observable check with its expected output. Every Fountain services
     page already ends with a "Verify" section; promote it into the template.
     Without this the guide cannot tell the reader they are done. -->

## If it did not work

<!-- Observed failures only, as symptom then cause then fix. Link to the
     Troubleshooting page rather than growing a runbook here. -->

## Related

<!-- Links to the reference this guide skipped, and to adjacent guides.
     diataxis.fr/how-to-guides/, "Refer to the x reference guide for a full
     list of options". A how-to must not become complete. -->
```

**Prohibited in a how-to.** Complete option lists, teaching, background,
history, and any sentence explaining why the system is designed this way.
`diataxis.fr/how-to-guides/`, "no digression, explanation, teaching".

---

## Reference

Austere. `diataxis.fr/reference/` calls neutral description "the key
imperative" and says reference should be "austere and uncompromising". This is
the one mode that gets no voice at all. Fly.io demonstrates the split on its
own site, where `fly.io/docs/machines/overview/` contains a GOTO joke and
`fly.io/docs/flyctl/machine-run/` contains sixty flags and no adjectives.

```markdown
# <The thing, named exactly as the machinery names it>

<!-- The page title is the identifier. "Conversation states", "fountain acp",
     "Configuration". Not "Understanding conversation states". -->

<one sentence stating what this describes, and one linking the explanation>

<!-- Modal's two-sentence mode declaration, inverted. Reference points at its
     explanation twin; explanation points at its reference twin. -->

## <Structural division that matches the code>

<!-- diataxis.fr/reference/, "Respect the structure of the machinery". The
     page's sections mirror the module, the command tree, the router, or the
     state enum. Not a division the writer invented. For Fountain this means
     configuration groups match config file sections, API groups match router
     scopes, and CLI groups match the Cobra tree. -->

| Field | Type | Default | Description |
|---|---|---|---|

<!-- Tables over prose wherever the data is tabular. Same column order on
     every reference page in the site. diataxis.fr/reference/, "Adopt standard
     patterns", which says reference is useful when it is consistent and that
     it is "definitely not" the place for varied style. -->

<!-- Where a default exists, state value, unit, ceiling and the exact override
     in one place. Modal does this in two sentences: "Sandboxes have a default
     maximum lifetime of 5 minutes. You can change this by passing a timeout of
     up to 24 hours to the Sandbox.create(...) function." -->

### Example

<!-- One minimal example per non-obvious entry. diataxis.fr/reference/,
     "Provide examples", explicitly licenses illustration in reference.
     Follow Stripe's rule from docs.stripe.com/payments/payment-intents: every
     example is the same base call with exactly one thing changed, never a
     cumulative sequence. Independent and substitutable, so no example depends
     on a previous one. -->

## Warnings

<!-- diataxis.fr/reference/, "Provide warnings where appropriate": "You must
     use a. You must not apply b unless c. Never d." Constraints, not advice.
     "Never call an _unsafe_ function as the first fetch in a user-facing
     request" belongs here. "We recommend" does not. -->
```

**Prohibited in reference.** Recommendations, rationale, numbered procedures,
second person exhortation, and any sentence that would change if the product's
strategy changed rather than its code.

**Generate what can be generated.** `docs/api.md` is 629 hand-written lines
alongside an OpenAPI spec that CI already validates, and `docs/cli.md` is 279
hand-written lines alongside a Cobra tree that a Go test already walks.
`diataxis.fr/reference/` notes that generated reference is "a powerful way of
ensuring that it remains faithfully accurate to the code". Fly generates its
command pages and hand-writes only the task-grouped index at
`fly.io/docs/flyctl/`. Fountain should do the same.

---

## Explanation

The mode Fountain is missing entirely. Its distinguishing property is that it
has no natural boundary, so `diataxis.fr/explanation/` recommends inventing a
why-question as a prompt and drawing a line.

```markdown
# About <topic>

<!-- The source says you should be able to place an implicit "about" in front
     of every explanation title. Use it explicitly where it reads well.
     "Where a secret comes from", "Why you bring your own inference
     credentials", "The console, the apps, and the API". Never a verb, never
     a bare primitive name without framing. -->

<one sentence stating this page explains rather than instructs, and linking
the how-to and the reference for the same subject>

## <The reader's current situation>

<!-- Start where the reader already is, and let it fail. Tailscale's
     tailscale.com/blog/how-tailscale-works builds hub-and-spoke, steelmans it
     ("But we can do it, right? It's only about 5 times as much work as one
     hub, which is not that much work"), then enumerates the four specific
     things that break. The product is not named until the reader has watched
     the problem accumulate. -->

## What it is

<!-- One sentence in terms the reader already has, then a contrast with the
     sibling they already know. Modal introduces Sandboxes as "In addition to
     the Function interface…" and Temporal introduces Activities as "a normal
     function or method". -->

## Why it exists

<!-- Name the failure the thing prevents, not the features it has. Temporal's
     docs.temporal.io/activities.md states what happens when an Activity fails
     without checkpointing. Stripe's Payment Intents advantages list is three
     avoided failures out of four bullets. -->

## What it is not

<!-- Mandatory on every Fountain explanation page. Three of the current client
     pages independently grew a "What this is, and is not" heading, and four
     grew "Limits, stated rather than discovered". Those writers were right and
     the template should stop making them reinvent it.

     Where a term collides with a well-known product, this section names the
     collision. Fountain's Vault against HashiCorp Vault is the worst case and
     is worked in deliverable 5. -->

## When to use something else

<!-- The negative boundary, present on Temporal, Modal and Fly independently.
     Temporal: "If you only want to execute one Activity Function, then you
     don't need to use a Workflow." Fly: "For most applications, most of the
     time, you don't need to be picky!" -->

## How it works

<!-- The mechanism, at explanation altitude. Prose and a diagram, not a field
     table. Where the mechanism has two surfaces, name both in the same
     sentence, which is Fly's join-table move: "You create a Fly Machine with a
     Create Machine request, or with fly machine run." Doing this here is what
     lets the CLI reference and the API reference stay separate and neutral. -->

## What we chose not to do

<!-- diataxis.fr/explanation/ is the one mode that admits opinion and
     perspective, and says explanation "must consider alternatives,
     counter-examples or multiple different approaches". Fountain has ADRs
     already; this section is where an ADR's reasoning becomes readable, with a
     link to the decision record. -->

## Where to go next

<!-- Mode-labelled links, following docs.temporal.io/temporal.md's Next steps,
     which routes to a tutorial, a how-to and two explanations and says which
     is which. -->
```

**Prohibited in explanation.** Numbered procedures, complete field lists, and
copy-pasteable setup. `diataxis.fr/explanation/`, "Keep explanation closely
bounded", warns that explanation "tends to absorb other things" and that
letting instruction creep in both interferes with the explanation and removes
the instruction from view in the correct place.

**Sign and date explanation pages.** Tailscale's post carries a byline and 20
March 2020. Explanation is the only mode allowed opinion, and a byline is what
makes an opinion attributable rather than institutional. It also lets a reader
discount a stale claim, which matters on a page like `concepts/surfaces.md`
whose subject changed twice this year.
