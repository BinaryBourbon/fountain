import test from 'node:test';
import assert from 'node:assert/strict';
import { validateDeployment, verifySnapshot, verifyStable } from '../adapters/kubernetes.mjs';
import { ciConfig } from '../ci.mjs';

const digest = `sha256:${'a'.repeat(64)}`;
const config = { adapter: 'kubernetes', context: 'test', namespace: 'fountain', deployment: 'fountain', service: 'fountain', container: 'fountain', expected_digest: digest };
function fixture() {
  return {
    deployment: { metadata: { uid: 'deployment-1', generation: 2 }, spec: { replicas: 2 },
      status: { observedGeneration: 2, replicas: 2, updatedReplicas: 2, readyReplicas: 2, availableReplicas: 2 } },
    replicaSets: { items: [{ metadata: { uid: 'rs-1', ownerReferences: [{ controller: true, kind: 'Deployment', uid: 'deployment-1' }] } }] },
    service: { metadata: { uid: 'service-1' }, spec: { selector: { app: 'fountain' } } },
    pods: { items: [1, 2].map(n => ({ metadata: { uid: `pod-${n}`, name: `fountain-${n}`, labels: { app: 'fountain' },
      ownerReferences: [{ controller: true, kind: 'ReplicaSet', uid: 'rs-1' }] },
    status: { conditions: [{ type: 'Ready', status: 'True' }], containerStatuses: [{ name: 'fountain', ready: true,
      imageID: `ghcr.io/example/fountain@${digest}`, restartCount: 0, state: { running: {} } }] } })) },
    slices: { items: [1, 2].map(n => ({ endpoints: [{ targetRef: { kind: 'Pod', namespace: 'fountain', uid: `pod-${n}` },
      conditions: { ready: true, serving: true, terminating: false } }] })) },
  };
}
test('deployment evidence covers every endpoint slice, digest, and deployment owner', () => {
  const evidence = verifySnapshot(config, fixture());
  assert.equal(evidence.pods.length, 2);
  assert.equal(evidence.image_digest, digest);
  assert.equal(verifyStable(evidence, { ...evidence, observed_at: 'later' }).verified, true);
});
for (const [name, change] of Object.entries({
  'old observed generation': f => f.deployment.status.observedGeneration--,
  'partial rollout': f => f.deployment.status.updatedReplicas--,
  'zero replicas': f => f.deployment.spec.replicas = 0,
  'old image on one backend': f => f.pods.items[1].status.containerStatuses[0].imageID = `example@sha256:${'b'.repeat(64)}`,
  'unready pod': f => f.pods.items[0].status.conditions = [],
  'terminating pod': f => f.pods.items[0].metadata.deletionTimestamp = 'now',
  'unrelated deployment': f => f.replicaSets.items[0].metadata.ownerReferences[0].uid = 'other',
  'extra selected pod': f => f.pods.items.push(structuredClone(f.pods.items[0])),
  'missing slice': f => f.slices.items.pop(),
  'unknown backend': f => f.slices.items[0].endpoints[0].targetRef.uid = 'external',
  'unknown readiness': f => delete f.slices.items[0].endpoints[0].conditions.ready,
  'draining endpoint': f => f.slices.items[0].endpoints[0].conditions.terminating = true,
  'publish unready addresses': f => f.service.spec.publishNotReadyAddresses = true,
  'selectorless service': f => f.service.spec.selector = {},
})) test(`rejects ${name}`, () => {
  const f = fixture(); change(f);
  assert.throws(() => verifySnapshot(config, f));
});
test('a restart or replacement during a successful public run invalidates attribution', () => {
  const before = verifySnapshot(config, fixture());
  const after = structuredClone(before);
  after.pods[0].restarts++;
  assert.throws(() => verifyStable(before, after), /changed/);
});
test('adapter configuration rejects malformed identity and unsupported fields', () => {
  assert.throws(() => validateDeployment({ ...config, expected_digest: 'latest' }));
  assert.throws(() => validateDeployment({ ...config, context: '--server=evil' }));
  assert.throws(() => validateDeployment({ ...config, command: 'arbitrary' }));
});
const env = { SUITE_TARGET: 'staging', SUITE_ENABLED: 'true', SUITE_PROFILE: 'canary', SUITE_MODE: 'public',
  SUITE_TARGET_JSON: JSON.stringify({ base_url: 'https://example.test', deployment: config,
    execution: { runtime: 'claude', model: 'anthropic/claude-haiku-4-5', sandbox_provider: 'sprites', max_turns: 100 } }) };
test('public canary uses environment-owned target and fixed budgets without cluster credentials', () => {
  const result = ciConfig(env);
  assert.deepEqual(result.profiles, ['basic', 'execution']);
  assert.equal(result.deployment, undefined);
  assert.equal(result.execution.max_turns, 2);
  assert.equal(result.limits.run_ms, 420000);
  assert.equal(result.credentials.primary, 'FOUNTAIN_SUITE_KEY');
});
test('dispatch rejects missing activation, unknown targets/profiles, and unverified revision requests', () => {
  for (const changes of [{ SUITE_ENABLED: '' }, { SUITE_TARGET: 'attacker' }, { SUITE_PROFILE: 'custom' },
    { SUITE_EXPECTED_DIGEST: digest }, { SUITE_MODE: 'unknown' },
    { SUITE_TARGET_JSON: '{' }, { SUITE_TARGET_JSON: '{"base_url":"http://example.test"}' }]) {
    assert.throws(() => ciConfig({ ...env, ...changes }));
  }
  const result = ciConfig({ ...env, SUITE_MODE: 'rollout', SUITE_EXPECTED_DIGEST: digest });
  assert.equal(result.deployment.expected_digest, digest);
  assert.throws(() => ciConfig({ ...env, SUITE_MODE: 'rollout', SUITE_TARGET_JSON: '{"base_url":"https://example.test"}' }));
});
