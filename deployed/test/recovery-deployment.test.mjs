import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { RecoveryDeployment, validateRecoveryDeployment } from '../adapters/recovery-kubernetes.mjs';

const uid = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const runId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
const beforeDigest = `sha256:${'a'.repeat(64)}`;
const targetDigest = `sha256:${'b'.repeat(64)}`;
const config = { adapter: 'kubernetes', environment: 'staging', base_url: 'https://staging.example.test',
  context: 'staging', namespace: 'fountain', deployment: 'fountain', service: 'fountain', container: 'fountain',
  deployment_uid: uid, before_image: `registry.test/fountain@${beforeDigest}`,
  target_image: `registry.test/fountain@${targetDigest}`, before_digest: beforeDigest, target_digest: targetDigest, timeout_ms: 3000 };
const binding = { 'fountain.dev/deployed-suite-base-url': config.base_url };

async function fixture(t, overrides = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'fountain-recovery-control-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, 'recovery.json');
  const selected = { ...config, ...overrides };
  const state = {
    namespace: { metadata: { uid: 'namespace-1', labels: { 'fountain.dev/environment': 'staging' } } },
    service: { metadata: { uid: 'service-1', annotations: binding } },
    deployment: { metadata: { uid, resourceVersion: '1', generation: 1,
      labels: { 'fountain.dev/recovery-tests': 'enabled' }, annotations: binding },
    spec: { template: { metadata: {}, spec: { containers: [{ name: 'sidecar', image: 'untouched' },
      { name: 'fountain', image: selected.before_image }] } } } },
  };
  let now = 0;
  const patches = [];
  const io = {
    read: async () => structuredClone(state),
    patch: async patch => {
      patches.push(structuredClone(patch));
      const next = structuredClone(state.deployment);
      // Apply the actual JSON Patch atomically, including resourceVersion tests.
      for (const op of patch) {
        const parts = op.path.slice(1).split('/').map(s => s.replaceAll('~1', '/').replaceAll('~0', '~'));
        const key = parts.pop();
        const parent = parts.reduce((value, part) => value[part], next);
        if (op.op === 'test') assert.deepEqual(parent[key], op.value, 'JSON Patch precondition');
        else if (op.op === 'remove') delete parent[key];
        else parent[key] = structuredClone(op.value);
      }
      next.metadata.generation++;
      next.metadata.resourceVersion = String(Number(next.metadata.resourceVersion) + 1);
      state.deployment = next;
    },
    observe: async expected => ({ deployment_uid: uid, service_uid: state.service.metadata.uid,
      generation: state.deployment.metadata.generation, image_digest: expected,
      pods: [{ uid: `pod-${state.deployment.metadata.generation}` }] }),
    now: () => now,
    sleep: async ms => { now += ms; },
  };
  return { control: new RecoveryDeployment(selected, path, io), io, state, path, patches, config: selected };
}

test('rollout and restoration preserve unrelated fields and save private durable evidence', async t => {
  const f = await fixture(t);
  f.state.deployment.spec.template.metadata.annotations = { other: 'keep' };
  await f.control.prepare(runId);
  assert.equal((await stat(f.path)).mode & 0o777, 0o600);
  await f.control.roll();
  assert.equal(JSON.parse(await readFile(f.path)).phase, 'rolled');
  assert.equal(f.state.deployment.spec.template.spec.containers[1].image, config.target_image);
  await f.control.restore();
  assert.deepEqual(f.state.deployment.spec.template.metadata.annotations, { other: 'keep' });
  assert.equal(f.state.deployment.spec.template.spec.containers[0].image, 'untouched');
  const journal = JSON.parse(await readFile(f.path));
  assert.equal(journal.phase, 'restored');
  assert.equal(journal.before.image_digest, beforeDigest);
  assert.equal(journal.after.image_digest, targetDigest);
  assert.equal(journal.restored.image_digest, beforeDigest);
  assert.ok(!JSON.stringify(journal).includes('untouched'));
  await f.control.restore();
  assert.equal(f.patches.length, 2, 'restoration is idempotent');
});

test('lost rollout response can be restored by a fresh process from its journal', async t => {
  const f = await fixture(t);
  await f.control.prepare(runId);
  f.control.io.patch = async patch => { await f.io.patch(patch); throw new Error('reply lost'); };
  await assert.rejects(f.control.roll(), /reply lost/);
  assert.equal(JSON.parse(await readFile(f.path)).phase, 'roll_requested');
  const resumed = await RecoveryDeployment.resume(f.path, f.io);
  await resumed.restore();
  assert.equal(f.state.deployment.spec.template.spec.containers[1].image, config.before_image);
  assert.equal(f.state.deployment.spec.template.metadata.annotations, undefined);
});

test('lost restore response resumes without issuing a second patch', async t => {
  const f = await fixture(t);
  await f.control.prepare(runId); await f.control.roll();
  f.control.io.patch = async patch => { await f.io.patch(patch); throw new Error('reply lost'); };
  await assert.rejects(f.control.restore(), /reply lost/);
  const resumed = await RecoveryDeployment.resume(f.path, f.io);
  await resumed.restore();
  assert.equal(f.patches.length, 2);
});

test('an unsuccessful patch still leaves a restorable baseline record', async t => {
  const f = await fixture(t);
  await f.control.prepare(runId);
  f.control.io.patch = async () => { throw new Error('request never reached server'); };
  await assert.rejects(f.control.roll(), /never reached/);
  const resumed = await RecoveryDeployment.resume(f.path, f.io);
  await resumed.restore();
  assert.equal(f.patches.length, 0);
});

for (const [name, mutate] of Object.entries({
  'production namespace': s => s.namespace.metadata.labels['fountain.dev/environment'] = 'production',
  'disabled recovery': s => delete s.deployment.metadata.labels['fountain.dev/recovery-tests'],
  'different deployment': s => s.deployment.metadata.uid = runId,
  'wrong URL binding': s => s.service.metadata.annotations = {},
  'existing run': s => s.deployment.spec.template.metadata.annotations = { 'fountain.dev/recovery-run': runId },
  'different image': s => s.deployment.spec.template.spec.containers[1].image = 'latest',
  'paused deployment': s => s.deployment.spec.paused = true,
  'terminating namespace': s => s.namespace.metadata.deletionTimestamp = 'now',
})) test(`preparation rejects ${name} without mutations`, async t => {
  const f = await fixture(t); mutate(f.state);
  await assert.rejects(f.control.prepare(runId));
  assert.equal(f.patches.length, 0);
  await assert.rejects(readFile(f.path), { code: 'ENOENT' });
});

for (const [name, mutate] of Object.entries({
  'image': s => s.deployment.spec.template.spec.containers[1].image = 'foreign',
  'marker': s => s.deployment.spec.template.metadata.annotations['fountain.dev/recovery-run'] = uid,
  'service identity': s => s.service.metadata.uid = 'new-service',
  'namespace identity': s => s.namespace.metadata.uid = 'new-namespace',
})) test(`restoration refuses changed ${name}`, async t => {
  const f = await fixture(t);
  await f.control.prepare(runId); await f.control.roll(); mutate(f.state);
  await assert.rejects(f.control.restore());
  assert.equal(f.patches.length, 1);
});

test('same-image rollout requires a new generation and replacement serving pods', async t => {
  const f = await fixture(t, { target_image: config.before_image, target_digest: beforeDigest });
  await f.control.prepare(runId);
  const observe = f.control.io.observe;
  f.control.io.observe = async expected => ({ ...await observe(expected), pods: [{ uid: 'pod-1' }] });
  await assert.rejects(f.control.roll(), /deadline/);
  assert.equal(f.patches.length, 1, 'no retry of the rollout mutation');
  await f.control.restore();
});

test('failed target readiness does not prevent rollback', async t => {
  const f = await fixture(t);
  await f.control.prepare(runId);
  const observe = f.control.io.observe;
  f.control.io.observe = expected => expected === targetDigest ? Promise.reject(new Error('unhealthy')) : observe(expected);
  await assert.rejects(f.control.roll(), /deadline/);
  await f.control.restore();
  assert.equal(f.control.record.phase, 'restored');
});

test('a concurrent edit between read and patch fails the atomic precondition', async t => {
  const f = await fixture(t);
  await f.control.prepare(runId);
  f.control.io.patch = async patch => {
    f.state.deployment.metadata.resourceVersion = '2';
    await f.io.patch(patch);
  };
  await assert.rejects(f.control.roll(), /JSON Patch precondition/);
  assert.equal(f.state.deployment.spec.template.spec.containers[1].image, config.before_image);
});

test('journal persistence failure prevents mutation, and an existing journal is never overwritten', async t => {
  const f = await fixture(t);
  await f.control.prepare(runId);
  await assert.rejects(new RecoveryDeployment(config, f.path, f.io).prepare(uid), /already exists/);
  f.control.io.save = async () => { throw new Error('disk full'); };
  await assert.rejects(f.control.roll(), /disk full/);
  assert.equal(f.patches.length, 0);
});

test('concurrent journal preparation cannot overwrite or restore the winning run', async t => {
  const f = await fixture(t);
  const other = new RecoveryDeployment(config, f.path, f.io);
  const results = await Promise.allSettled([f.control.prepare(runId), other.prepare(uid)]);
  assert.equal(results.filter(r => r.status === 'fulfilled').length, 1);
  const winner = results[0].status === 'fulfilled' ? f.control : other;
  const loser = winner === f.control ? other : f.control;
  assert.equal(loser.record, undefined);
  await assert.rejects(loser.restore(), /record is missing/);
  assert.equal(JSON.parse(await readFile(f.path)).run_id, winner.record.run_id);
});

test('restoration preserves annotations added while the recovery rollout is active', async t => {
  const f = await fixture(t);
  await f.control.prepare(runId); await f.control.roll();
  f.state.deployment.spec.template.metadata.annotations.added = 'keep';
  await f.control.restore();
  assert.deepEqual(f.state.deployment.spec.template.metadata.annotations, { added: 'keep' });
});

test('strict configuration rejects production, mutable images, shell arguments, and unbounded waits', () => {
  for (const change of [{ environment: 'production' }, { before_image: 'repo:latest' }, { base_url: 'http://localhost' },
    { context: '--server=evil' }, { timeout_ms: 300001 }, { deployment_uid: 'name' }, { command: 'sh' }]) {
    assert.throws(() => validateRecoveryDeployment({ ...config, ...change }));
  }
});
