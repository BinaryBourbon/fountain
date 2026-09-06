import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { verifyRecoveryTurns, verifyRecoveryState, recoveredAttachment, verifyRecoveryTranscript } from '../profiles/recovery.mjs';
import { configFrom } from '../lib/runner.mjs';
import { ciConfig } from '../ci.mjs';
import { restoreRecoveryControls } from '../lib/recovery.mjs';
import { Redactor } from '../lib/http.mjs';

const accepted = [{ id: 'turn-1', prompt: 'first', scenario: 'write', nonce: 'nonce-1' },
  { id: 'turn-2', prompt: 'second', scenario: 'permission', nonce: 'nonce-2' }];
const rows = [{ id: 'turn-1', prompt: 'first', turn_number: 1, status: 'completed' },
  { id: 'turn-2', prompt: 'second', turn_number: 2, status: 'running' }];
const state = { version: 'fountain-acp-fixture/1', id: 'session',
  turns: [{ scenario: 'write', nonce: 'nonce-1', status: 'end_turn' }, { scenario: 'permission', nonce: 'nonce-2', status: 'running' }],
  artifacts: { 'nonce-1': { writes: 1 } } };
test('recovery verifier requires the same accepted turns, including the pending turn', () => {
  verifyRecoveryTurns(rows, accepted, 'running');
  for (const mutate of [r => r.pop(), r => r.push({ ...r[1], id: 'duplicate' }), r => r[1].id = 'replacement',
    r => r[1].status = 'failed', r => r[0].prompt = 'rewritten']) {
    const changed = structuredClone(rows); mutate(changed);
    assert.throws(() => verifyRecoveryTurns(changed, accepted, 'running'));
  }
});
test('recovery transcript rejects prior-turn output replayed under the current turn', () => {
  const events = accepted.map(turn => ({ turn_id: turn.id, blocks: [{ kind: 'text', body: `fixture:started:${turn.scenario}:${turn.nonce}\n` }] }));
  verifyRecoveryTranscript(events, accepted);
  assert.throws(() => verifyRecoveryTranscript([...events, { ...events[0], turn_id: accepted[1].id }], accepted), /misattributed/);
  assert.throws(() => verifyRecoveryTranscript([...events, events[0]], accepted), /duplicated/);
});
test('fixture accounting rejects duplicate prompts, premature effects and lost prior files', () => {
  verifyRecoveryState(state, 'session', accepted, 1);
  for (const mutate of [s => s.id = 'new-session', s => s.turns.push({ ...s.turns[1] }),
    s => s.artifacts['nonce-1'].writes = 2, s => delete s.artifacts['nonce-1'],
    s => s.artifacts['nonce-2'] = { writes: 1 }, s => s.turns[1].status = 'end_turn']) {
    const changed = structuredClone(state); mutate(changed);
    assert.throws(() => verifyRecoveryState(changed, 'session', accepted, 1));
  }
  const complete = structuredClone(state); complete.artifacts['nonce-2'] = { writes: 1 }; complete.turns[1].status = 'end_turn';
  verifyRecoveryState(complete, 'session', accepted, 2);
});
test('terminal public evidence fails recovery immediately instead of waiting for an impossible attachment', () => {
  const event = { kind: 'stage', stage: 'turn', state: 'failed', data: JSON.stringify({ turn_id: 'turn-2', reason: 'runner_disconnected' }) };
  assert.throws(() => recoveredAttachment([event], 'turn-2'), /runner_disconnected/);
  assert.equal(recoveredAttachment([event], 'other-turn'), undefined);
  const attached = { kind: 'stage', stage: 'reattach', state: 'done', data: JSON.stringify({ outcome: 'session_attached', turn_id: 'turn-2' }) };
  assert.equal(recoveredAttachment([attached], 'turn-2'), attached);
  assert.throws(() => recoveredAttachment([attached, event], 'turn-2'), /ended before permission/);
});
test('recovery selection pins staging, independent controls, a dedicated runner and four prompts', t => {
  const dir = mkdtempSync(join(tmpdir(), 'fountain-recovery-config-'));
  t.after(() => rmSync(dir, { force: true, recursive: true }));
  const example = JSON.parse(readFileSync(new URL('../recovery.example.json', import.meta.url)));
  const path = join(dir, 'target.json');
  const env = { FOUNTAIN_SUITE_KEY: 'primary', FOUNTAIN_SUITE_OTHER_KEY: 'secondary', FOUNTAIN_RELAY_ADMIN_KEY: 'x'.repeat(40) };
  const parse = value => { writeFileSync(path, JSON.stringify(value)); return configFrom(path, env); };
  assert.equal(parse(example).fixture.max_turns, 4);
  for (const mutate of [c => c.recovery.deployment.environment = 'production', c => c.profiles.push('probe'),
    c => c.fixture = {}, c => c.deployment = c.recovery.deployment, c => c.recovery.max_turns = 5,
    c => c.recovery.runner_id = 'arbitrary', c => c.recovery.relay.receiver_url = 'http://relay.test',
    c => c.recovery.deployment.base_url = 'https://other.test', c => c.recovery.relay.disconnect_ms = 60001,
    c => c.recovery.turn_ms = 240000, c => c.recovery.idle_wait_ms = 100, c => c.limits.run_ms = 3600000,
    c => c.recovery.command = 'kill']) {
    const changed = structuredClone(example); mutate(changed); assert.throws(() => parse(changed));
  }
  assert.throws(() => ciConfig({ SUITE_ENABLED: 'true', SUITE_TARGET: 'production', SUITE_PROFILE: 'recovery',
    SUITE_TARGET_JSON: JSON.stringify(example) }));
});

test('interrupted cleanup checks both control manifests and preserves failure without mutating another run', async t => {
  const dir = mkdtempSync(join(tmpdir(), 'fountain-recovery-cleanup-'));
  t.after(() => rmSync(dir, { force: true, recursive: true }));
  const config = JSON.parse(readFileSync(new URL('../recovery.example.json', import.meta.url)));
  const runId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd', otherId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee';
  writeFileSync(join(dir, 'runner-relay.json'), JSON.stringify({ version: 'fountain-runner-relay/1',
    base_url: 'https://different.example.test', run_id: runId, state: 'created' }));
  writeFileSync(join(dir, 'recovery.json'), JSON.stringify({ version: 1, run_id: otherId, phase: 'roll_requested',
    config: config.recovery.deployment, namespace_uid: 'namespace', service_uid: 'service', annotations_absent: true,
    before: { deployment_uid: config.recovery.deployment.deployment_uid, service_uid: 'service', pods: [] } }));
  const checks = [], report = {};
  const ctx = { config, report, redactor: new Redactor(), env: { FOUNTAIN_RELAY_ADMIN_KEY: 'x'.repeat(40) },
    check: async (name, action) => {
      try { await action(); checks.push({ name, ok: true }); return true; }
      catch (error) { checks.push({ name, error: error.message }); return false; }
    } };
  assert.equal(await restoreRecoveryControls(ctx, dir, runId), false);
  assert.deepEqual(checks.map(c => c.name), ['recovery/relay-cleanup', 'recovery/deployment-cleanup']);
  assert.match(checks[0].error, /manifest does not match/);
  assert.match(checks[1].error, /differs from the selected run/);
  assert.equal(report.recovery.cleanup_failed, true);
  assert.equal(JSON.parse(readFileSync(join(dir, 'recovery.json'))).run_id, otherId);
});
