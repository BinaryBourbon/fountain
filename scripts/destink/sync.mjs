#!/usr/bin/env node
// Re-copy the vendored lint engine from a checkout of lex00/sentences.
//
//   node scripts/destink/sync.mjs ../sentences
//
// Recomputes the import closure rather than copying a hardcoded file list, so a module the
// upstream rules start importing comes along on its own. The alternative — a list in this file —
// goes stale silently, and the failure is a missing module at gate time on someone else's PR.
//
// After a sync, run the gate. It refuses to start if an id named in destink.mjs is not in the
// vendored registry, which is what an upstream rename looks like from here, and it prints any
// rule the registry has that destink.mjs does not mention (arrived in this sync, nobody has
// decided about it, currently off).

import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync, readFileSync, rmSync, existsSync, writeFileSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const VENDOR = join(HERE, "vendor");

// The four modules destink.mjs imports. Everything else is reached from them.
const ENTRY = ["src/lint/build-doc.ts", "src/lint/registry.ts", "src/lint/engine.ts", "src/lint/report.ts"];

// Follow relative imports only. A ".js" specifier means the ".ts" file beside it (this project
// writes the name the compiler WOULD emit), which is the same remap ts-loader.mjs does at run
// time. Bare specifiers are real npm packages and belong in package.json, not here.
// Comments out, so a sentence in a doc comment cannot look like an import. `//` is only treated
// as a comment when it does not follow a colon, which keeps the "https://" inside a string intact.
const strip = (src) => src.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:])\/\/[^\n]*/g, "$1");

function closure(root) {
  const seen = new Set();
  const bare = new Set();
  const visit = (file) => {
    if (seen.has(file)) return;
    seen.add(file);
    const src = strip(readFileSync(file, "utf8"));
    // Import and export forms that name a module. Deliberately not a parser: this runs against
    // one known repo, and a missed edge shows up as a missing file on the next gate run. It DOES
    // have to see past comments, though: upstream's doc comments are long and prose-heavy, and
    // scanning them raw reported "The building is not" as an npm dependency, because a sentence
    // in a comment happened to put the word `from` before a quoted phrase.
    for (const m of src.matchAll(/(?:^|\n)\s*(?:import|export)[\s\S]*?from\s+["']([^"']+)["']/g)) {
      const spec = m[1];
      if (!spec.startsWith(".")) {
        bare.add(spec);
        continue;
      }
      const p = spec.endsWith(".js") ? resolve(dirname(file), spec).slice(0, -3) + ".ts" : resolve(dirname(file), spec);
      if (existsSync(p)) visit(p);
      else throw new Error(`${relative(root, file)} imports ${spec}, which does not resolve`);
    }
  };
  for (const e of ENTRY) visit(join(root, e));
  return { files: [...seen].sort(), bare: [...bare].sort() };
}

const src = resolve(process.argv[2] ?? "");
if (!process.argv[2] || !existsSync(join(src, "src/lint/registry.ts"))) {
  console.error("usage: node scripts/destink/sync.mjs <path-to-a-lex00/sentences-checkout>");
  process.exit(1);
}

const sha = execFileSync("git", ["-C", src, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
const dirty = execFileSync("git", ["-C", src, "status", "--porcelain"], { encoding: "utf8" }).trim();
if (dirty) {
  console.error(`refusing to sync: ${src} has uncommitted changes, so the pin below would name a\ncommit that is not what was copied.`);
  process.exit(1);
}

const { files, bare } = closure(src);
const kept = files.filter((f) => !f.endsWith(".test.ts"));

rmSync(VENDOR, { recursive: true, force: true });
for (const file of kept) {
  const rel = relative(join(src, "src"), file);
  const dest = join(VENDOR, rel);
  mkdirSync(dirname(dest), { recursive: true });
  copyFileSync(file, dest);
}
copyFileSync(join(src, "LICENSE"), join(VENDOR, "LICENSE"));
copyFileSync(join(src, "scripts/ts-loader.mjs"), join(HERE, "ts-loader.mjs"));

const upstream = readFileSync(join(VENDOR, "..", "vendor.UPSTREAM.tmpl"), "utf8").replace("__COMMIT__", sha);
writeFileSync(join(VENDOR, "UPSTREAM"), upstream);

console.log(`synced ${kept.length} file(s) from ${src} @ ${sha.slice(0, 12)}`);
console.log(`npm dependencies upstream needs: ${bare.filter((b) => !b.startsWith("node:")).join(", ") || "none"}`);
console.log(`\nCheck those against scripts/destink/package.json, then run:\n  node scripts/destink/destink.mjs`);
