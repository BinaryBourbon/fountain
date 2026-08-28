// Module customization hook for scripts/destink-score.mjs. Node's own TypeScript type-stripping
// (--experimental-strip-types on Node >=22.6, on by default on Node >=23) runs .ts files fine, but
// its module resolver is strict ESM: it does not remap a ".js" specifier to a sibling ".ts" file.
// This project's TS source imports its own modules with ".js" specifiers (NodeNext-style — the
// specifier names the file the compiler WOULD emit, not the file on disk), which vite and tsc
// resolve but plain Node does not.
//
// So: try the default resolution first: if a specifier ending in ".js" fails with
// ERR_MODULE_NOT_FOUND, retry it as ".ts", and only use that result if the file actually exists.
// Anything that isn't a relative/absolute ".js" specifier (bare imports like "compromise",
// "node:fs", or a real ".js" file that does exist) is untouched.
//
// This is Node's stable module.register() customization-hooks API (node:module) — no bundler, no
// transpiler, no new dependency.

import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

export async function resolve(specifier, context, nextResolve) {
  if (!specifier.endsWith(".js") || !context.parentURL) return nextResolve(specifier, context);

  try {
    return await nextResolve(specifier, context);
  } catch (err) {
    if (!(err && typeof err === "object" && "code" in err && err.code === "ERR_MODULE_NOT_FOUND")) throw err;
    const asTs = `${specifier.slice(0, -".js".length)}.ts`;
    const candidateUrl = new URL(asTs, context.parentURL);
    if (!existsSync(fileURLToPath(candidateUrl))) throw err;
    return nextResolve(asTs, context);
  }
}
