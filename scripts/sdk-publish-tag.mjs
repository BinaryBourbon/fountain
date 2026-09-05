#!/usr/bin/env node
/** Choose the dist-tag inside the publish workflow's serialized concurrency group. */
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

// Only stable releases may move latest. Compare numeric components, not strings;
// build metadata has no precedence and prereleases remain on next.
function stable(version) {
  const match = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:\+[\da-zA-Z.-]+)?$/.exec(version);
  return match ? match.slice(1, 4).map(BigInt) : null;
}

function greater(left, right) {
  for (let i = 0; i < 3; i++) {
    if (left[i] !== right[i]) return left[i] > right[i];
  }
  return false;
}

export function publishTag(version, registry) {
  if (!registry || typeof registry.versions !== "object" || registry.versions === null || Array.isArray(registry.versions)) {
    throw new Error("Registry response has no versions map; refusing to choose a publish tag");
  }
  const candidate = stable(version);
  if (!candidate) return "next";
  const published = [...Object.keys(registry.versions), registry["dist-tags"]?.latest].filter(Boolean);
  return published.some((version) => {
    const tuple = stable(version);
    return tuple && !greater(candidate, tuple);
  }) ? "backport" : "latest";
}

export async function registryState(name, fetchRegistry = fetch) {
  const response = await fetchRegistry(`https://registry.npmjs.org/${encodeURIComponent(name)}`, {
    headers: { accept: "application/json", "cache-control": "no-cache" },
    signal: AbortSignal.timeout(30_000),
  });
  if (response.status === 404) return { versions: {} };
  if (!response.ok) throw new Error(`Registry answered ${response.status}; refusing to publish`);
  return response.json();
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const pkg = JSON.parse(readFileSync(new URL("../sdk/typescript/package.json", import.meta.url), "utf8"));
  console.log(publishTag(pkg.version, await registryState(pkg.name)));
}
