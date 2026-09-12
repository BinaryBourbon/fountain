import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const cli = fileURLToPath(new URL('../ci.mjs', import.meta.url));
const secret = 'private-configuration-marker';
const base = { SUITE_TARGET: 'staging', SUITE_ENABLED: 'true', SUITE_PROFILE: 'probe',
  SUITE_MODE: 'public', SUITE_TARGET_JSON: '{"base_url":"https://example.test"}',
  FOUNTAIN_SUITE_KEY: secret };

for (const [name, changes, diagnostic] of [
  ['target', { SUITE_TARGET: secret }, 'Target is not approved'],
  ['enablement', { SUITE_ENABLED: '' }, 'Target environment is not enabled'],
  ['profile', { SUITE_PROFILE: secret }, 'Profile is not approved'],
  ['target JSON', { SUITE_TARGET_JSON: '{"password":"' + secret + '"' }, 'SUITE_TARGET_JSON must contain valid JSON'],
  ['target shape', { SUITE_TARGET_JSON: '[]' }, 'SUITE_TARGET_JSON must be a JSON object'],
  ['base URL', { SUITE_TARGET_JSON: JSON.stringify({ base_url: secret }) }, 'SUITE_TARGET_JSON must contain a valid base_url'],
  ['HTTPS', { SUITE_TARGET_JSON: '{"base_url":"http://example.test"}' }, 'CI targets require HTTPS ingress'],
  ['mode', { SUITE_MODE: secret }, 'Unknown verification mode'],
  ['rollout', { SUITE_MODE: 'rollout' }, 'Rollout requires an environment-owned deployment adapter'],
  ['matrix JSON', { SUITE_PROFILE: 'matrix-canary', SUITE_MATRIX_JSON: '{"password":"' + secret + '"' }, 'SUITE_MATRIX_JSON must contain valid JSON'],
  ['matrix shape', { SUITE_PROFILE: 'matrix-canary', SUITE_MATRIX_JSON: 'null' }, 'SUITE_MATRIX_JSON must be a JSON object'],
  ['matrix validation', { SUITE_PROFILE: 'matrix-canary', SUITE_MATRIX_JSON: '{}' }, 'SUITE_MATRIX_JSON must describe a valid bounded matrix'],
]) {
  test('CI reports the failing ' + name + ' setting without exposing configuration', () => {
    const root = mkdtempSync(join(tmpdir(), 'fountain-ci-diagnostics-'));
    try {
      const result = spawnSync(process.execPath, [cli], { env: { ...base, ...changes, RUNNER_TEMP: root }, encoding: 'utf8', timeout: 5000 });
      assert.equal(result.status, 2, result.stderr);
      assert.ok(result.stderr.includes(diagnostic), result.stderr);
      assert.ok(!result.stderr.includes(secret));
      assert.deepEqual(readdirSync(root), [], 'configuration errors must precede file creation and execution');
    } finally { rmSync(root, { recursive: true, force: true }); }
  });
}

test('unexpected setup errors retain the generic message without private paths', () => {
  const root = mkdtempSync(join(tmpdir(), 'fountain-ci-diagnostics-'));
  mkdirSync(join(root, 'deployed-' + secret + '-1'));
  try {
    const result = spawnSync(process.execPath, [cli], { env: { ...base, RUNNER_TEMP: root, GITHUB_RUN_ID: secret }, encoding: 'utf8', timeout: 5000 });
    assert.equal(result.status, 2);
    assert.match(result.stderr, /CI setup failed; check approved target configuration/);
    assert.ok(!result.stderr.includes(secret));
    assert.ok(!result.stderr.includes(root));
  } finally { rmSync(root, { recursive: true, force: true }); }
});
