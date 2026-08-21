# Working note: the mode test I will apply to Fountain pages

Read in full at diataxis.fr. Pages used here are `/start-here/`, `/tutorials/`,
`/how-to-guides/`, `/reference/`, `/explanation/`, `/tutorials-how-to/`,
`/reference-explanation/`, `/compass/`, `/map/`, `/how-to-use-diataxis/`,
`/quality/`, `/application/`, `/foundations/`.

## What the framework actually claims

Diátaxis is not a list of four content types. It is a two-axis map of a craft,
and the four modes fall out of the axes rather than being chosen
(`/foundations/`). The axes are action versus cognition, and acquisition versus
application. Two binary axes give four quadrants, which is why the framework
insists there are four and not three or five.

The tool for deciding is the compass, not the map (`/compass/`). The map is
reference, so it cannot tell you what to do. The compass is a two-question
decision table.

| If the content | and serves the user's | then it must belong to |
|---|---|---|
| informs action | acquisition of skill | a tutorial |
| informs action | application of skill | a how-to guide |
| informs cognition | application of skill | reference |
| informs cognition | acquisition of skill | explanation |

## The test I will use on a Fountain page

The compass asks two questions. Both are hard to answer honestly on a page you
wrote yourself, because a writer always believes the page informs action and
always believes the reader is working. So I am going to answer them through
four proxy questions that have observable answers.

**1. Who chose the goal.** Read the page's first paragraph. If the page told
the reader what they are about to accomplish, the page chose the goal, and the
reader is at study. If the reader arrived already knowing what they wanted and
the page's job is to hand it to them, the reader is at work. This is the
acquisition/application axis, and for Fountain it is the load-bearing one,
because tutorial/how-to conflation is the single most common failure in
software docs (`/tutorials-how-to/`).

**2. What the reader's hands are doing.** If the page only makes sense with the
reader's hands on a keyboard mid-task, it informs action. If the reader could
usefully read it on a train with no terminal open, it informs cognition. The
source's own version of this is that explanation is the only mode it might make
sense to read in the bath (`/explanation/`).

**3. Whether the page is allowed to fork.** A tutorial follows a single line
and offers no alternatives, because choices are cognitive load that break the
learning experience (`/tutorials/`, "Ignore options and alternatives"). A
how-to forks constantly, because the real world forks (`/tutorials-how-to/`).
Reference is a flat description of the machinery and does not sequence at all.
Explanation must consider alternatives, because weighing them is its job
(`/explanation/`, "Admit opinion and perspective"). So counting the branches in
a page is a fast way to catch a mislabelled one.

**4. What breaks if the page is wrong.** If a wrong page makes a competent
reader ship something broken, it was serving work, so it is reference or
how-to, and it owes accuracy. If a wrong page makes a newcomer conclude they
cannot use the product, it was serving study, so it is a tutorial or
explanation, and it owes confidence. Diátaxis's clothing analogy in `/quality/`
separates these as functional quality against deep quality.

Applied in order, questions 1 and 2 give the quadrant. Questions 3 and 4 are
the audit, used to catch a page whose declared mode and actual behaviour
disagree.

### The Fountain-specific tie-breaker

Fountain has four pages that all look like ordered steps with shell commands.
`setup.md`, `tour.md`, `self-hosting.md`'s quick start and
`build/team-chat.md`. Question 1 separates them cleanly.

- `tour.md` and `build/team-chat.md` announce the destination in their own
  first paragraph. The reader did not arrive wanting to open a pull request
  from an agent, the page proposed it. Tutorials.
- `setup.md` is read by someone who already decided to contribute to Fountain
  and needs a working checkout. How-to.
- `self-hosting.md`'s quick start is read by someone who already decided to
  self-host. How-to.

## The specific failure when two modes share a page

The general answer is blur (`/map/`, "Blur"), and the general consequence is
that writing style and content migrate into inappropriate places. That is true
but not actionable. Three specific failures matter for Fountain, in order of
how much damage they are doing today.

**The page loses its stopping condition, and then nobody can tell whether it is
finished.** Each mode is bounded by something different. A tutorial is bounded
by what the learner must encounter. A how-to is bounded by the user's goal. A
reference page is bounded by the machinery itself, which is the only bound that
is externally checkable. Explanation is the one mode with no natural bound, and
`/explanation/` says so directly, recommending you invent a why-question to
serve as a prompt. Put two of these on one page and the page inherits the
weakest bound. `docs/primitives.md` is the live example. Its Conversation
section describes a status enum, which is bounded by the code, and also
discusses suspension policy, which is bounded by nothing, and the section has
grown to whatever the last writer felt like adding. A contributor adding a
fifth status cannot tell whether they owe one edit or three.

**Reference stops being consultable and explanation never gets to develop.**
`/reference-explanation/` states the damage as symmetric. Interleaving hurts
the reference, which is "interrupted and obscured by digressions", and hurts
the explanation, which "is not allowed to develop appropriately and do its own
work". On `docs/primitives.md` the `model` field's reference entry carries nine
lines of prose arguing why a provider outside the allowed set is rejected at
write time. That argument is good, and it is longer than the entire
Substitution section, and it is unfindable by anyone who wants it, because it
is filed under a field name.

**Edits stop being local, so maintenance cost rises superlinearly.**
`/tutorials/` observes that tutorial revisions cascade through the whole story
because the end-to-end journey must keep making sense, where changes elsewhere
in documentation can be made discretely. A page that is part tutorial inherits
the cascade for its whole length. Fountain feels this already. Every change to
the conversation lifecycle currently touches `primitives.md`, `architecture.md`
and `build/pieces.md`, because all three narrate the same sequence at different
altitudes.

## One caution about acting on this

`/how-to-use-diataxis/` is explicit that Diátaxis is a guide rather than a
plan, that you should not create empty four-way structures, and that structure
should emerge from repeated small improvements rather than be imposed. The nav
tree in deliverable 1 is therefore not proposed as a build order. It is the
shape 34 existing pages settle into once each one is made to do a single job,
and it is accompanied by an ordered list of individually mergeable moves. No
step in that list creates an empty section.
