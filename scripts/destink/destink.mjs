#!/usr/bin/env node
// The de-stink gate for docs/**/*.md. Third prose gate, beside scripts/docs-style.py (the
// style sheet) and `vale lint docs` (ASD-STE100). This one looks for AI-writing tells.
//
//   node scripts/destink/destink.mjs              # every page under docs/
//   node scripts/destink/destink.mjs docs/api.md  # named pages
//   node scripts/destink/destink.mjs --json       # the full report, for tooling
//
// Exits 1 if any enabled rule fires on a page that is not on the allow list.
//
// THE ENGINE IS AN NPM DEPENDENCY, NOT WRITTEN HERE. `sentences` (github.com/lex00/sentences,
// MIT) publishes its lint surface at `./lint/*`, pinned by the version range in
// scripts/destink/package.json. Bump that to pull in an upstream change; run `npm install --prefix
// scripts/destink` after.
//
// WHY ONLY SOME RULES ARE ON. The linter ships 40-odd rules aimed at prose in general. Run whole
// over docs/ it reported 2,721 findings, and most were markdown or ordinary technical writing
// rather than AI tells. ENABLED below is an explicit opt-in list with the measured count beside
// each entry, and DISABLED records what was left off and why, so the next person does not have to
// re-derive it. Opt-IN rather than opt-out is the safety property: a rule added upstream between
// versions arrives off, and turning it on is a deliberate edit with a number attached.

import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { extractProse } from "sentences/lint/markdown-prose";
import { buildDocAnalysis } from "sentences/lint/build-doc";
import { RULES } from "sentences/lint/registry";
import { runRules } from "sentences/lint/engine";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const ROOT = resolve(HERE, "../..");
const DOCS = join(ROOT, "docs");

// Every directory whose markdown is published at /docs: the host's, plus each
// extension's own (ADR 0043, #1510). Discovered rather than listed, so a page
// that moves out of docs/ into an extension does not leave this gate on the
// way out.
function docRoots() {
  const apps = join(ROOT, "apps");
  const extensionDocs = readdirSync(apps, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => join(apps, entry.name, "docs"))
    .filter((dir) => existsSync(dir));

  return [DOCS, ...extensionDocs];
}
const ALLOW = join(HERE, "allow.txt");

// Rules that gate. The count is what the rule found over docs/ when it was turned on, so a
// future reader can tell "this rule is quiet here" from "this rule was cleaned up".
const ENABLED = new Set([
  // --- found real tells, and the pages were fixed ---
  "claude-fiction-gestures", //      27  "at a glance" as a section heading
  "claude-technical-vocabulary", //  13  "Wire up", which is also a phrasal verb STE bans
  "demo/intensifier", //             11  "truly", "really" as filler
  "formatting/unicode-decoration", // 8  a bare arrow standing in for a verb
  "syntactic/self-posed-question", // 7  asking the reader a question, then answering it
  "claude-stock-frames", //           3  "the case for", "baked into"
  "claude-discourse-markers", //      1
  "claude/mirrored-clauses", //       1
  "reframe", //                       1
  "serves-as-dodge", //               1
  // --- quiet on docs/ today, so they cost nothing and cover what gets written next ---
  "claude/ai-leakage", //                    0  assistant boilerplate, leaked artifact strings
  "claude-assistant-voice", //        0
  "claude-fiction-frames", //         0
  "claude/figurative-suffixes", //    0
  "claude/aphoristic-ender", //       0
  "corporate-jargon", //              0
  "discourse/countdown", //           0
  "repetition/dilution", //            0
  "claude/elegant-variation", //   0
  "excess-vocabulary", //             0
  "formatting/listicle-in-trench-coat", // 0
  "lex-delve-family", //              0
  "lex-false-suspense", //            0
  "lex-filler-transitions", //        0
  "lex-invented-concept-labels", //   0
  "lex-magic-adverbs", //             0
  "lex-ornate-nouns", //              0
  "lex-pedagogical-voice", //         0
  "lex-signposts", //                 0
  "lex-stakes-inflation", //          0
  "lex-vague-attribution", //         0
  "claude/sounds-like-claude", //            0
  "ing-tackon", //          0
]);

// Left off, with the count each produced and the reason. A line moves from here to ENABLED by
// cleaning the pages first, the same way scripts/docs-style-allow.txt only ever shrinks.
const DISABLED = new Map([
  ["tricolon/comma-series", "478 — 'a Postgres, an ingress controller, and the Secret' is a list, not a tricolon"],
  ["anaphora/repeated-opening", "128 — parallel openings are deliberate here, and it reads link lists as sentences"],
  ["repetition/near-duplicate", "98 — 'Read the X' repeats on purpose across Related sections"],
  ["dead-metaphor/rare-lemma", "74 — no Technical Names list, so it flags 'agent', 'console', 'token'"],
  ["formatting/em-dash-density", "39 — docs-style.py already bans em dashes; here '--' is a CLI flag"],
  ["discourse/punchy-fragments", "24 — table cells and short procedural steps are not fragments"],
  ["false-range/from-to", "21 — all candidate severity; 'from the key to the string' is ordinary English"],
  ["claude/colon-reveal", "18 — docs-style.py already owns the colon that introduces a list"],
  ["tricolon/density", "6 — same family as tricolon/comma-series"],
  ["claude/contrast-tail", "6 — all candidate; 'X, not Y' is house style, including in CLAUDE.md"],
  [
    "formatting/bold-first-bullet",
    "5 — every hit is a term-definition list (`- **`runtime`**, one of ...`). The bold IS the " +
      "field name, not a run-in label the sentence could carry instead.",
  ],
  [
    "discourse/staccato-register",
    "1 — only reference/glossary.md, whose paragraphs are single definitions by construction. " +
      "The measure (sentences per paragraph) does not mean the same thing on a glossary.",
  ],
  [
    "discourse/setup-turn",
    "1 — concepts/conversation.md, where it pairs the last sentence of one paragraph with the " +
      "first of the next. The vendored splitter has no paragraph concept, so adjacency crosses " +
      "a blank line. Fixing that belongs upstream, not in a rewrite of the page.",
  ],
]);

const isMd = (p) => p.endsWith(".md");

function walk(dir) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    const p = join(dir, entry);
    if (statSync(p).isDirectory()) out.push(...walk(p));
    else if (isMd(p)) out.push(p);
  }
  return out.sort();
}

// The ratchet, same shape and same rule as scripts/docs-style-allow.txt: a page listed here is
// skipped, a page not listed is checked, and a line naming a page that no longer exists is an
// error so a rename cannot quietly re-exempt one.
function loadAllow() {
  let raw;
  try {
    raw = readFileSync(ALLOW, "utf8");
  } catch {
    return new Set();
  }
  const out = new Set();
  for (const line of raw.split("\n")) {
    const trimmed = line.split("#", 1)[0].trim();
    if (trimmed) out.add(trimmed);
  }
  return out;
}

// Line and column for an offset, 1-based, so output is clickable in an editor and in CI logs.
function locate(text, offset) {
  const before = text.slice(0, offset);
  const line = before.split("\n").length;
  const col = offset - (before.lastIndexOf("\n") + 1) + 1;
  return { line, col };
}

async function main() {
  const args = process.argv.slice(2);
  const json = args.includes("--json");
  const paths = args.filter((a) => !a.startsWith("--"));

  // An id in ENABLED or DISABLED that the registry no longer has means upstream renamed or
  // deleted a rule. Fail loudly: the alternative is a gate that silently stops checking
  // something, which is the failure this whole file is arranged to avoid. `demo/intensifier` in
  // particular is one upstream calls a placeholder and plans to delete.
  const known = new Set(RULES.map((r) => r.id));
  const stale = [...ENABLED, ...DISABLED.keys()].filter((id) => !known.has(id));
  if (stale.length) {
    console.error(
      `destink: these rule ids are named here but are not in the sentences package's registry:\n` +
        stale.map((id) => `  ${id}`).join("\n") +
        `\nUpstream renamed or removed them. Reconcile ENABLED/DISABLED in scripts/destink/destink.mjs\n` +
        `against the sentences package's lint/registry, then re-run.`,
    );
    process.exit(2);
  }
  // The other direction: a rule the registry has that this file does not mention at all. It
  // arrived in a version bump and nobody decided about it. Off is the safe default, but say so.
  const undecided = RULES.filter((r) => !ENABLED.has(r.id) && !DISABLED.has(r.id)).map((r) => r.id);
  if (undecided.length && !json) {
    console.error(`destink: note — ${undecided.length} rule(s) not yet triaged, left off:`);
    for (const id of undecided) console.error(`  ${id}`);
    console.error("");
  }

  const rules = RULES.filter((r) => ENABLED.has(r.id));
  const allow = loadAllow();
  const files = paths.length
    ? paths.map((p) => resolve(p))
    : docRoots().flatMap((dir) => walk(dir));

  const skipped = [];
  const reports = [];
  let findingCount = 0;

  for (const file of files) {
    const rel = relative(ROOT, file);
    if (allow.has(rel)) {
      skipped.push(rel);
      continue;
    }
    const source = readFileSync(file, "utf8");
    // Generated pages quote the world rather than describing it, and an edit here is undone by
    // the next regeneration. docs-style.py and .vale-ste.yml make the same exemption.
    if (source.slice(0, 2048).includes("<!-- GENERATED FILE")) {
      skipped.push(rel);
      continue;
    }
    const prose = extractProse(source);
    const { findings, errors } = runRules(rules, buildDocAnalysis(prose));
    for (const e of errors) console.error(`destink: rule ${e.ruleId} failed on ${rel}: ${e.message}`);
    findingCount += findings.length;
    reports.push({ file: rel, source, findings });
  }

  if (json) {
    console.log(
      JSON.stringify(
        reports.map((r) => ({
          file: r.file,
          findings: r.findings.map((f) => ({ ...f, ...locate(r.source, f.span.start) })),
        })),
        null,
        2,
      ),
    );
    process.exit(findingCount ? 1 : 0);
  }

  for (const { file, source, findings } of reports) {
    for (const f of findings) {
      const { line, col } = locate(source, f.span.start);
      const quoted = source.slice(f.span.start, f.span.end).replace(/\s+/g, " ").trim();
      console.log(`${file}:${line}:${col}: ${f.ruleId} [${f.severity}] ${f.message}`);
      console.log(`    ${quoted.length > 100 ? quoted.slice(0, 100) + "…" : quoted}`);
      console.log(`    ${f.explanation}`);
    }
  }

  const checked = files.length - skipped.length;
  if (findingCount === 0) {
    console.log(`destink: ${checked} page(s) clean, ${rules.length} rules.`);
    return;
  }
  console.log(`\ndestink: ${findingCount} finding(s) across ${checked} page(s), ${rules.length} rules.`);
  console.log("Fix the pages. To park one, add it to scripts/destink/allow.txt with a reason.");
  process.exit(1);
}

main();
