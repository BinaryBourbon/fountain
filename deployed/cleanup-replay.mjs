#!/usr/bin/env node
import { lstatSync, readdirSync, mkdirSync } from 'node:fs';
import { resolve, join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { run } from './lib/runner.mjs';
import { atomicJson } from './lib/fixtures.mjs';

function manifests(root) {
  const found = [];
  let visited = 0;
  function visit(path, depth) {
    if (++visited > 512 || depth > 4) throw new Error('Cleanup evidence exceeds traversal bounds');
    const stat = lstatSync(path);
    if (stat.isSymbolicLink()) throw new Error('Cleanup evidence must not contain symbolic links');
    if (stat.isDirectory()) {
      for (const name of readdirSync(path).sort()) visit(join(path, name), depth + 1);
    } else if (stat.isFile() && path.endsWith(sep + 'cleanup.json')) found.push(path);
  }
  if (!lstatSync(root).isDirectory()) throw new Error('Expected a cleanup evidence directory');
  visit(root, 0);
  // The full matrix has sixteen cells plus its preflight run.
  if (!found.length || found.length > 17) throw new Error('Expected between one and seventeen cleanup manifests');
  return found;
}

export async function replayCleanup({ configPath, resultsRoot, out, env = process.env,
  signal = AbortSignal.timeout(180000), execute = run }) {
  resultsRoot = resolve(resultsRoot); out = resolve(out); configPath = resolve(configPath);
  if (out === resultsRoot || out.startsWith(resultsRoot + sep)) throw new Error('Keep replay evidence outside the source results');
  if (!lstatSync(configPath).isFile() || lstatSync(configPath).isSymbolicLink()) throw new Error('Expected a regular target configuration');
  const files = manifests(resultsRoot); // Validate the entire tree before any API call.
  mkdirSync(out, { mode: 0o700 });
  const report = { version: 1, status: 'running', entries: files.map(path => ({ manifest: relative(resultsRoot, path), status: 'not_run' })) };
  const save = () => atomicJson(join(out, 'replay.json'), report);
  save();
  for (const [index, manifestPath] of files.entries()) {
    if (signal.aborted) break;
    const entry = report.entries[index];
    entry.status = 'running'; save();
    try {
      // Supplying manifestPath always selects cleanup mode. The runner retains
      // its owner/target/resource checks and fresh bounded cleanup signal.
      entry.code = await execute({ configPath, manifestPath, out: join(out, `manifest-${index}`), env, signal, log() {} });
      entry.status = entry.code === 0 ? 'passed' : 'failed';
    } catch {
      entry.status = 'failed'; // Never copy raw configuration or response errors.
    }
    save(); // One bad manifest must not prevent other run-owned cleanup.
  }
  report.status = report.entries.every(entry => entry.status === 'passed') ? 'passed' : 'cleanup_failed';
  save();
  return report.status === 'passed' ? 0 : 3;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const { values, positionals } = parseArgs({ allowPositionals: true, options: {
      config: { type: 'string' }, results: { type: 'string' }, out: { type: 'string' },
    } });
    if (positionals.length || !values.config || !values.results || !values.out) throw new Error('Missing cleanup replay arguments');
    process.exitCode = await replayCleanup({ configPath: values.config, resultsRoot: values.results, out: values.out });
  } catch {
    console.error('Cleanup replay setup failed; retain the original manifests and inspect the target configuration and evidence paths');
    process.exitCode = 2;
  }
}
