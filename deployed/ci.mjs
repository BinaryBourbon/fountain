#!/usr/bin/env node
import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { run } from './lib/runner.mjs';
import { runMatrix, validateMatrix } from './matrix.mjs';

const matrixSubset = profile => ({ 'matrix-canary': 'canary', 'matrix-scheduled': 'scheduled', 'matrix-full': 'full' })[profile];

export function ciConfig(env) {
  if (!['staging', 'production'].includes(env.SUITE_TARGET)) throw new Error('Target is not approved');
  if (env.SUITE_ENABLED !== 'true') throw new Error('Target environment is not enabled');
  if (!['probe', 'basic', 'execution', 'streaming', 'canary', 'secrets', 'mcp', 'webhooks', 'schedules'].includes(env.SUITE_PROFILE) && !matrixSubset(env.SUITE_PROFILE)) throw new Error('Profile is not approved');
  const config = JSON.parse(env.SUITE_TARGET_JSON || '{}');
  const url = new URL(config.base_url);
  if (url.protocol !== 'https:') throw new Error('CI targets require HTTPS ingress');
  config.credentials = { primary: 'FOUNTAIN_SUITE_KEY', secondary: 'FOUNTAIN_SUITE_OTHER_KEY' };
  config.profiles = matrixSubset(env.SUITE_PROFILE) ? ['probe'] : env.SUITE_PROFILE === 'canary' ? ['basic', 'execution'] : [env.SUITE_PROFILE];
  // Bound exposure even if an environment variable accidentally requests a longer run.
  config.limits = { request_ms: 30000, run_ms: env.SUITE_PROFILE === 'schedules' ? 900000 : 420000, cleanup_ms: 90000, resources: 12 };
  if (config.execution) config.execution = { ...config.execution, provision_ms: 120000, turn_ms: 90000, max_turns: env.SUITE_PROFILE === 'webhooks' ? 0 : ['secrets', 'schedules'].includes(env.SUITE_PROFILE) ? 1 : 2 };
  if (env.SUITE_MODE === 'rollout') {
    if (!config.deployment) throw new Error('Rollout requires an environment-owned deployment adapter');
    config.deployment.expected_digest = env.SUITE_EXPECTED_DIGEST;
  } else if (env.SUITE_MODE === 'public') {
    if (env.SUITE_EXPECTED_DIGEST) throw new Error('Expected digest requires rollout mode');
    delete config.deployment;
  } else throw new Error('Unknown verification mode');
  return config;
}

export async function ciMain(env = process.env) {
  const controller = new AbortController();
  const cancel = () => controller.abort(new Error('Interrupted'));
  process.on('SIGINT', cancel);
  process.on('SIGTERM', cancel);
  try {
    const config = ciConfig(env);
    const subset = matrixSubset(env.SUITE_PROFILE);
    const matrix = subset ? JSON.parse(env.SUITE_MATRIX_JSON || '{}') : undefined;
    if (matrix) validateMatrix(matrix, subset);
    const root = resolve(env.RUNNER_TEMP || '.', `deployed-${env.GITHUB_RUN_ID || 'local'}-${env.GITHUB_RUN_ATTEMPT || '1'}`);
    mkdirSync(root, { mode: 0o700 });
    const configPath = resolve(root, 'target.json');
    writeFileSync(configPath, JSON.stringify(config), { mode: 0o600 });
    if (matrix) {
      const matrixPath = resolve(root, 'matrix.json');
      writeFileSync(matrixPath, JSON.stringify(matrix), { mode: 0o600 });
      return await runMatrix({ configPath, matrixPath, subset, out: resolve(root, 'results'), signal: controller.signal, env });
    }
    return await run({ configPath, out: resolve(root, 'results'), signal: controller.signal, env });
  } finally {
    process.off('SIGINT', cancel);
    process.off('SIGTERM', cancel);
  }
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { process.exitCode = await ciMain(); }
  catch { console.error('CI setup failed; check approved target configuration and required environment settings'); process.exitCode = 2; }
}
