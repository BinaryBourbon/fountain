#!/usr/bin/env node
// Exercise the same tests on runtimes that cannot execute TypeScript directly.
import { cpSync, mkdirSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { execFileSync, spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const sdk = join(dirname(fileURLToPath(import.meta.url)), "..");
const mode = process.argv.slice(2);
if (mode.length > 1 || (mode.length === 1 && mode[0] !== "--conformance")) {
  throw new Error("usage: node scripts/test-compiled.mjs [--conformance]");
}
const temporary = mkdtempSync(join(tmpdir(), "fountain-sdk-tests-"));
const output = join(temporary, "sdk", "typescript");
try {
  mkdirSync(output, { recursive: true });
  execFileSync(process.execPath, [join(sdk, "node_modules/typescript/lib/tsc.js"),
    "-p", join(sdk, "tsconfig.json"), "--outDir", output], { cwd: sdk, stdio: "inherit" });
  // Keep the tests' relative fixture paths and source/package inspections.
  cpSync(join(sdk, "src"), join(output, "src"), { recursive: true });
  cpSync(join(sdk, "package.json"), join(output, "package.json"));
  for (const fixtures of ["conformance", "contract"]) {
    cpSync(join(sdk, "..", fixtures), join(temporary, "sdk", fixtures), { recursive: true });
  }
  const tests = mode.length ? ["conformance.test.js"]
    : readdirSync(join(output, "test")).filter(name => name.endsWith(".test.js")).sort();
  if (!tests.length) throw new Error("No compiled SDK tests found");
  const result = spawnSync(process.execPath, ["--test", ...tests.map(name => join(output, "test", name))],
    { cwd: output, stdio: "inherit" });
  if (result.error) throw result.error;
  process.exitCode = result.status ?? 1;
} finally {
  rmSync(temporary, { recursive: true, force: true });
}
