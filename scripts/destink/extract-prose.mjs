// Markdown -> prose, preserving byte offsets.
//
// The de-stink linter (vendor/) is a PROSE linter. Its document splitter breaks on
// `. ! ? ; :` and its rules read sentences. Markdown structure is not prose, and feeding
// a page to it raw produces mostly false findings: over docs/ it reported 2,721, of which
// ~1,750 were markdown being mistaken for writing.
//
// The three that mattered, all measured on this repo's docs/:
//
//   1. `--` is a dash to the em-dash rule (vendor/lint/rules/formatting.ts: /—|--/g). Here it
//      is a CLI flag (`--config`) or a table separator (`|---|`). 788 findings, all false.
//   2. Table rows and link lists split into verbless units, so the fragment, anaphora and
//      near-duplicate rules fire on them. ~700 findings.
//   3. URL path segments are words to the lexicon rules, so `guides` and `operate` came back
//      as dead metaphors.
//
// So: blank the non-prose, keep the prose. BLANK, not delete — every character is replaced
// with a space (newlines kept, so paragraph grouping and line classification survive), which
// means every offset in the linter's output still indexes the ORIGINAL file. A finding's
// span slices out of the source page unchanged, and the reported line number is the real one.
// Deleting instead would be shorter and would make every span a lie.
//
// This is deliberately not a markdown parser, for the same reason vendor/lint/markdown.ts
// is not one: the input is this repo's docs/, the shapes are known, and a dependency that
// understands all of CommonMark buys nothing a line scan does not already get right. What
// it does NOT handle is documented per-rule below rather than in a list at the end.

// Replace [a, b) with spaces, keeping newlines so line and paragraph structure survives.
function blank(text, a, b) {
  let out = "";
  for (let i = a; i < b; i++) out += text[i] === "\n" ? "\n" : " ";
  return text.slice(0, a) + out + text.slice(b);
}

// Each entry blanks one kind of non-prose. Order matters where two could overlap: fences go
// first so a table or a backtick INSIDE a code block is already blank by the time the later
// patterns run, and cannot re-match across the hole they left.
const PATTERNS = [
  // Fenced code. Matches the opener's own fence characters so a ``` inside a ~~~ block does
  // not close it. An unterminated fence runs to end of file, matching what the vendored
  // markdown.ts does, and for the same reason: over-suppress rather than lint broken input.
  //
  // The indent is ` *`, not CommonMark's ` {0,3}`. That bound is the rule for a fence at the
  // TOP level; a fence inside a list item is indented to the item's content column, which is
  // 4+ spaces. docs/build/team-chat.md has two of them, and with the tighter bound neither the
  // opener nor the closer was recognised, so ~60 lines of TypeScript leaked into the prose and
  // came back as fragment and near-duplicate findings.
  { name: "code fence", re: /^ *(```+|~~~+)[^\n]*\n[\s\S]*?^ *\1[^\n]*$/gm },
  { name: "unterminated code fence", re: /^ *(```+|~~~+)[^\n]*\n[\s\S]*$/gm },
  // HTML comments, including the `<!-- GENERATED FILE` marker docs-style.py reads.
  { name: "html comment", re: /<!--[\s\S]*?-->/g },
  // A block-level HTML element opened at the start of a line, through its matching close tag.
  // docs/primitives.md inlines a whole SVG diagram this way, and docs/integrations/buzz.md uses
  // <table> and <b>. The text inside an SVG is labels on a picture, not sentences: the arrow in
  // that diagram's "→ GitHub, model APIs, yours" came back as a unicode-decoration finding, and
  // "fixing" it would have broken docs_test.exs, which pins that SVG byte-for-byte against the
  // copy in README.md. Nesting of the SAME tag is not handled (no <div> inside a <div>); nothing
  // under docs/ does that, and the alternative is a real HTML parser.
  { name: "html block", re: /^<(svg|div|table|details|figure|picture|p|blockquote)\b[\s\S]*?<\/\1>/gim },
  // Any line starting with a pipe is a table row. Cell CONTENT is often real prose, but it is
  // prose in fragments with no sentence structure, and the rules that read it produce noise
  // (see (2) above). Tables are checked by docs-style.py's placeholder-cell rule and by vale.
  { name: "table row", re: /^ {0,3}\|.*$/gm },
  // Inline code spans. docs-style.py exempts these too, and for the reason its docstring
  // gives: they quote the world rather than describe it.
  { name: "inline code", re: /(`+)[^\n]*?\1/g },
  // A link's target, not its text: `[Deploy an instance](guides/operate/deploy.md)` keeps
  // "Deploy an instance" and loses the path. This is what stopped `guides` and `operate`
  // being read as prose words.
  { name: "link target", re: /\]\([^)\s]*(?:\s+"[^"]*")?\)/g },
  // Reference-style link definitions and bare URLs.
  { name: "link definition", re: /^ {0,3}\[[^\]]+\]:\s*\S+.*$/gm },
  { name: "bare url", re: /<https?:\/\/[^>\s]+>|https?:\/\/\S+/g },
  // A list item that is nothing but a link is navigation, not a sentence. These are what the
  // anaphora and near-duplicate rules kept finding: a "Related" section of six links reads as
  // six sentences with the same opening.
  { name: "nav list item", re: /^ {0,3}[-*+] +\[[^\]]*\][.,]?\s*$/gm },
  // Image tags carry alt text that is not prose in the flow of the page.
  { name: "image", re: /!\[[^\]]*\]/g },
  // The admonition directive line of the MkDocs dialect the renderer inherited
  // (`!!! tip "In a hurry?"`). The BODY is prose and stays; the marker and its quoted title are a
  // widget label. docs/index.md's `!!! tip "In a hurry?"` came back as a self-posed question,
  // which is exactly what the title on a callout is supposed to be.
  { name: "admonition directive", re: /^ *(?:!!!|\?\?\?\+?) +[a-z-]+(?: +"[^"\n]*")? *$/gim },
];

// Blank every non-prose construct in `text`, returning a string of identical length whose
// prose characters are unchanged and everything else is a space.
export function extractProse(text) {
  let out = text;
  for (const { re } of PATTERNS) {
    re.lastIndex = 0;
    // Collect before blanking: mutating the string under an active regex would move offsets.
    const spans = [];
    for (let m = re.exec(out); m; m = re.exec(out)) {
      spans.push([m.index, m.index + m[0].length]);
      if (m[0].length === 0) re.lastIndex++; // a zero-width match would spin forever
    }
    for (const [a, b] of spans.reverse()) out = blank(out, a, b);
  }
  return out;
}
