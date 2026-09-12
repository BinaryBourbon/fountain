#!/usr/bin/env node
import { lstatSync, readdirSync, mkdirSync } from 'node:fs';
import { resolve, join, relative, sep, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { run } from './lib/runner.mjs';
import { atomicJson } from './lib/fixtures.mjs';

export const REPLAY_START_MS = 120000;

function manifests(root, allowEmpty) {
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
  const stat = lstatSync(root, { throwIfNoEntry: false });
  if (!stat && allowEmpty) return found;
  if (!stat?.isDirectory()) throw new Error('Expected a cleanup evidence directory');
  visit(root, 0);
  // The full matrix has sixteen cells plus its preflight run.
  if ((!found.length && !allowEmpty) || found.length > 17) throw new Error('Expected between one and seventeen cleanup manifests');
  return found;
}

export async function replayCleanup({ configPath, resultsRoot, out, env = process.env,
  signal, allowEmpty = false, execute = run }) {
  const deadline = AbortSignal.timeout(REPLAY_START_MS);
  signal = signal ? AbortSignal.any([signal, deadline]) : deadline;
  resultsRoot = resolve(resultsRoot); out = resolve(out); configPath = resolve(configPath);
  if (out === resultsRoot || out.startsWith(resultsRoot + sep)) throw new Error('Keep replay evidence outside the source results');
  const files = manifests(resultsRoot, allowEmpty); // Validate the entire tree before any API call.
  if (files.length && !lstatSync(configPath).isFile()) throw new Error('Expected a regular target configuration');
  // CI can fail before it creates the run root or target file. An empty report
  // records the absence of journals; it does not assert that cleanup passed.
  if (!files.length) mkdirSync(dirname(out), { recursive: true, mode: 0o700 });
  mkdirSync(out, { mode: 0o700 });
  const report = { version: 1, status: 'running', entries: files.map(path => ({ manifest: relative(resultsRoot, path), status: 'not_run' })) };
  const save = () => atomicJson(join(out, 'replay.json'), report);
  save();
  const interrupted = () => {
    report.status = 'cleanup_failed';
    report.stop_reason = signal.reason?.name === 'TimeoutError' ? 'deadline' : 'interrupted';
    for (const entry of report.entries.filter(entry => entry.status === 'running')) entry.status = 'interrupted';
    save(); // Persist before waiting for cleanup; a subsequent hard kill may win.
  };
  signal.addEventListener('abort', interrupted, { once: true });
  try {
    if (signal.aborted) interrupted();
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
        entry.error = 'execution_threw';
      }
      save(); // One bad manifest must not prevent other run-owned cleanup.
    }
    report.status = signal.aborted ? 'cleanup_failed' : !files.length ? 'no_manifests' :
      report.entries.every(entry => entry.status === 'passed') ? 'passed' : 'cleanup_failed';
    save();
    return ['passed', 'no_manifests'].includes(report.status) ? 0 : 3;
  } finally {
    signal.removeEventListener('abort', interrupted);
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const controller = new AbortController();
  const cancel = () => controller.abort(new Error('Interrupted'));
  process.on('SIGINT', cancel); process.on('SIGTERM', cancel);
  try {
    const { values, positionals } = parseArgs({ allowPositionals: true, options: {
      config: { type: 'string' }, results: { type: 'string' }, out: { type: 'string' },
      'allow-empty': { type: 'boolean', default: false },
    } });
    if (positionals.length || !values.config || !values.results || !values.out) throw new Error('Missing cleanup replay arguments');
    process.exitCode = await replayCleanup({ configPath: values.config, resultsRoot: values.results, out: values.out,
      allowEmpty: values['allow-empty'], signal: controller.signal });
  } catch {
    console.error('Cleanup replay setup failed; retain the original manifests and inspect the target configuration and evidence paths');
    process.exitCode = 2;
  } finally {
    process.off('SIGINT', cancel); process.off('SIGTERM', cancel);
  }
}
