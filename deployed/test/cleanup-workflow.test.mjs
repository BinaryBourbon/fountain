import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { ciConfig } from '../ci.mjs';
import { REPLAY_START_MS } from '../cleanup-replay.mjs';

const root = fileURLToPath(new URL('../..', import.meta.url));
const workflow = readFileSync(join(root, '.github/workflows/deployed.yml'), 'utf8');
const [job, body] = workflow.split('\n  verify:\n')[1].split('\n    steps:\n');
const steps = body.split(/\n(?=      - )/).filter(step => step.trim());
const cleanup = steps.find(step => step.includes('        id: cleanup\n'));
const script = cleanup.split('        run: |\n')[1].replace(/^          /gm, '');
const base = { SUITE_TARGET: 'staging', SUITE_ENABLED: 'true', SUITE_PROFILE: 'probe', SUITE_MODE: 'public',
  SUITE_TARGET_JSON: '{"base_url":"https://example.test"}', FOUNTAIN_SUITE_KEY: 'local-test-key' };

test('workflow budgets include setup, fixture and receiver cleanup, and both artifact uploads', () => {
  const jobMs = Number(job.match(/    timeout-minutes: (\d+)/)[1]) * 60000;
  let stepsMs = 0;
  for (const step of steps) {
    const cap = step.match(/        timeout-minutes: (\d+)/);
    assert.ok(cap, `Unbounded verification step: ${step.split('\n')[0]}`);
    stepsMs += Number(cap[1]) * 60000;
  }
  assert.ok(jobMs >= stepsMs + 2 * 60000, 'Keep job overhead beyond the sum of every step cap');
  const cleanupMs = Number(cleanup.match(/        timeout-minutes: (\d+)/)[1]) * 60000;
  const fixtureMs = ciConfig(base).limits.cleanup_ms;
  assert.ok(cleanupMs >= REPLAY_START_MS + 2 * fixtureMs + 60000,
    'An admitted CI manifest needs fixture cleanup, receiver cleanup and process/evidence overhead');
});

for (const [name, target, hasResults] of [
  ['before the run root exists', '{malformed', false],
  ['after target validation in the runner', '{"base_url":"https://example.test","unknown_field":true}', true],
]) {
  test(`workflow cleanup after setup failure ${name} reports no manifests`, () => {
    const temp = mkdtempSync(join(tmpdir(), 'fountain-cleanup-workflow-'));
    try {
      const env = { ...process.env, ...base, SUITE_TARGET_JSON: target, RUNNER_TEMP: temp, GITHUB_RUN_ID: '123', GITHUB_RUN_ATTEMPT: '2' };
      const runRoot = join(temp, 'deployed-123-2');
      const suite = spawnSync(process.execPath, ['deployed/ci.mjs'], { cwd: root, env, encoding: 'utf8', timeout: 10000 });
      assert.equal(suite.status, 2, suite.stderr);
      const result = join(runRoot, 'results/result.json');
      assert.equal(existsSync(result), hasResults);
      const original = hasResults ? readFileSync(result, 'utf8') : undefined;
      const replay = spawnSync('bash', ['-e', '-o', 'pipefail', '-c', script], { cwd: root, env, encoding: 'utf8', timeout: 10000 });
      assert.equal(replay.status, 0, replay.stderr);
      assert.equal(replay.stderr, '');
      assert.equal(JSON.parse(readFileSync(join(runRoot, 'cleanup-replay/replay.json'))).status, 'no_manifests');
      if (hasResults) assert.equal(readFileSync(result, 'utf8'), original, 'Replay must retain the original failed verdict');
    } finally { rmSync(temp, { recursive: true, force: true }); }
  });
}

test('workflow allow-empty does not suppress a failed manifest', () => {
  const temp = mkdtempSync(join(tmpdir(), 'fountain-cleanup-workflow-'));
  try {
    const env = { ...process.env, ...base, SUITE_TARGET_JSON: '{"base_url":"https://example.test","unknown_field":true}',
      RUNNER_TEMP: temp, GITHUB_RUN_ID: '123', GITHUB_RUN_ATTEMPT: '2' };
    const runRoot = join(temp, 'deployed-123-2');
    const suite = spawnSync(process.execPath, ['deployed/ci.mjs'], { cwd: root, env, encoding: 'utf8', timeout: 10000 });
    assert.equal(suite.status, 2);
    writeFileSync(join(runRoot, 'results/cleanup.json'), '{}');
    const replay = spawnSync('bash', ['-e', '-o', 'pipefail', '-c', script], { cwd: root, env, encoding: 'utf8', timeout: 10000 });
    assert.equal(replay.status, 3, replay.stderr);
    const report = JSON.parse(readFileSync(join(runRoot, 'cleanup-replay/replay.json')));
    assert.equal(report.status, 'cleanup_failed');
    assert.equal(report.entries[0].status, 'failed');
  } finally { rmSync(temp, { recursive: true, force: true }); }
});
