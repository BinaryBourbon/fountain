import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { open, rename, readFile, link, unlink } from 'node:fs/promises';
import { dirname } from 'node:path';
import { randomUUID } from 'node:crypto';
import { setTimeout as sleep } from 'node:timers/promises';
import { observeDeployment, validateDeployment } from './kubernetes.mjs';

const exec = promisify(execFile);
const check = (ok, message) => { if (!ok) throw new Error(message); };
const marker = 'fountain.dev/recovery-run';
const annotations = '/spec/template/metadata/annotations';
const markerPath = `${annotations}/fountain.dev~1recovery-run`;
const uuid = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/;
const digest = /^sha256:[a-f0-9]{64}$/;
const image = /^[a-z0-9][a-z0-9.:/_-]*@sha256:[a-f0-9]{64}$/;

function observerConfig(config, expected_digest) {
  const { context, namespace, deployment, service, container } = config;
  return { adapter: 'kubernetes', context, namespace, deployment, service, container, expected_digest };
}

export function validateRecoveryDeployment(config) {
  check(config?.adapter === 'kubernetes' && ['staging', 'production'].includes(config.environment), 'Recovery requires an explicit staging or production target');
  const keys = ['adapter', 'environment', 'base_url', 'context', 'namespace', 'deployment', 'service', 'container',
    'deployment_uid', 'before_image', 'target_image', 'before_digest', 'target_digest', 'timeout_ms', 'allow_production_restart'];
  check(Object.keys(config).every(key => keys.includes(key)), 'Unknown recovery deployment setting');
  const url = new URL(config.base_url);
  check(url.protocol === 'https:' && url.origin === config.base_url && !url.username && !url.password,
    'Recovery base_url must be an HTTPS origin');
  validateDeployment(observerConfig(config, config.before_digest));
  check(digest.test(config.target_digest), 'Recovery requires a target runtime digest');
  check(image.test(config.before_image) && image.test(config.target_image), 'Recovery requires immutable image references');
  check(uuid.test(config.deployment_uid), 'Recovery requires a pinned deployment UID');
  check(Number.isInteger(config.timeout_ms) && config.timeout_ms >= 1000 && config.timeout_ms <= 300000,
    'Recovery rollout timeout must be 1–300 seconds');
  if (config.environment === 'production') {
    check(config.allow_production_restart === true, 'Production recovery requires allow_production_restart:true');
    check(config.before_image === config.target_image && config.before_digest === config.target_digest,
      'Production recovery restarts the pinned serving image; release upgrades and downgrades require a separate deployment');
  } else check(config.allow_production_restart === undefined, 'Production restart acknowledgement belongs only to a production target');
  return config;
}

// Persist before each mutation. Never put raw Kubernetes objects in this journal.
export async function saveRecoveryJournal(path, record) {
  const temporary = `${path}.${randomUUID()}.tmp`;
  const file = await open(temporary, 'wx', 0o600);
  try { await file.writeFile(`${JSON.stringify(record, null, 2)}\n`); await file.sync(); }
  finally { await file.close(); }
  try {
    if (record.phase === 'prepared') { await link(temporary, path); await unlink(temporary); }
    else await rename(temporary, path);
  } catch (error) { await unlink(temporary).catch(() => {}); throw error; }
  const directory = await open(dirname(path), 'r');
  try { await directory.sync(); } finally { await directory.close(); }
}

function kubernetesIO(config) {
  const command = async (args, signal) => {
    try {
      const { stdout } = await exec('kubectl', ['--context', config.context, '--namespace', config.namespace,
        '--request-timeout=10s', ...args], { signal, timeout: 15000, maxBuffer: 4 * 1024 * 1024 });
      return stdout;
    } catch { throw new Error('Recovery Kubernetes command failed; inspect cluster access and the saved recovery journal'); }
  };
  return {
    read: async signal => {
      const [namespace, deployment, service] = await Promise.all([
        ['namespace', config.namespace], ['deployment', config.deployment], ['service', config.service],
      ].map(async args => JSON.parse(await command(['get', ...args, '-o', 'json'], signal))));
      return { namespace, deployment, service };
    },
    patch: (patch, signal) => command(['patch', 'deployment', config.deployment, '--type=json',
      '--patch', JSON.stringify(patch), '-o', 'name'], signal),
    observe: (expected, signal) => observeDeployment(observerConfig(config, expected), signal),
    sleep: (ms, signal) => sleep(ms, undefined, { signal }),
    now: Date.now,
  };
}

function guardedState(config, state, identities) {
  const { namespace, deployment, service } = state;
  check(namespace.metadata?.labels?.['fountain.dev/environment'] === config.environment, `Namespace is not labelled ${config.environment}`);
  check(deployment.metadata?.labels?.['fountain.dev/recovery-tests'] === 'enabled', 'Deployment has not enabled recovery tests');
  check(deployment.metadata?.uid === config.deployment_uid, 'Deployment UID changed');
  for (const resource of [namespace, deployment, service]) {
    check(!resource.metadata?.deletionTimestamp && resource.metadata?.uid, 'Recovery resource is missing or terminating');
  }
  for (const resource of [deployment, service]) {
    check(resource.metadata?.annotations?.['fountain.dev/deployed-suite-base-url'] === config.base_url,
      'Recovery URL binding differs from the approved target');
  }
  if (identities) check(namespace.metadata.uid === identities.namespace_uid && service.metadata.uid === identities.service_uid,
    'Recovery namespace or service was replaced');
  check(!deployment.spec?.paused, 'Recovery deployment is paused');
  const containers = deployment.spec?.template?.spec?.containers ?? [];
  const index = containers.findIndex(c => c.name === config.container);
  check(index >= 0 && containers.filter(c => c.name === config.container).length === 1, 'Recovery container is missing or ambiguous');
  check(typeof deployment.metadata.resourceVersion === 'string', 'Deployment resourceVersion is missing');
  return { deployment, index, image: containers[index].image,
    marker: deployment.spec.template.metadata?.annotations?.[marker] };
}

function tests(state) {
  return [{ op: 'test', path: '/metadata/uid', value: state.deployment.metadata.uid },
    { op: 'test', path: '/metadata/resourceVersion', value: state.deployment.metadata.resourceVersion },
    { op: 'test', path: `/spec/template/spec/containers/${state.index}/image`, value: state.image }];
}

function rolloutCount(value, replicas, round) {
  if (Number.isInteger(value) && value >= 0) return value;
  if (typeof value === 'string' && /^(?:100|[0-9]{1,2})%$/.test(value)) return round(replicas * Number(value.slice(0, -1)) / 100);
  throw new Error('Invalid production rolling-update quantity');
}

// Admission checks run before either preparation or the fault mutation. They
// deliberately do not gate restoration: an unhealthy rollout still needs to
// remove its own marker and restore its recorded template using the CAS guards.
function productionAdmission(config, state) {
  if (config.environment !== 'production') return;
  const { spec, status, metadata } = state.deployment;
  const replicas = spec.replicas;
  check(Number.isInteger(replicas) && replicas >= 2, 'Production recovery requires at least two replicas');
  check((spec.strategy?.type ?? 'RollingUpdate') === 'RollingUpdate', 'Production recovery requires RollingUpdate');
  const rolling = spec.strategy?.rollingUpdate ?? {};
  check(rolloutCount(rolling.maxUnavailable ?? '25%', replicas, Math.floor) === 0 &&
    rolloutCount(rolling.maxSurge ?? '25%', replicas, Math.ceil) === 1,
  'Production recovery requires zero unavailable replicas and exactly one surge replica');
  check(status?.observedGeneration === metadata.generation &&
    ['replicas', 'updatedReplicas', 'readyReplicas', 'availableReplicas'].every(key => status[key] === replicas) && !status.unavailableReplicas,
  'Production recovery requires a fully available, converged deployment');
}

// Control-plane evidence is separate from the recovery profile's public API assertions.
export class RecoveryDeployment {
  constructor(config, journalPath, overrides = {}) {
    this.config = structuredClone(validateRecoveryDeployment(config));
    check(typeof journalPath === 'string' && journalPath.length > 0, 'Recovery journal path is required');
    this.path = journalPath;
    this.io = { ...kubernetesIO(this.config), save: record => saveRecoveryJournal(this.path, record), ...overrides };
  }

  async save(phase) {
    this.record.phase = phase;
    await this.io.save(structuredClone(this.record));
  }

  async prepare(runId, signal) {
    check(uuid.test(runId), 'Recovery run ID must be a UUID');
    check(!this.record, 'Recovery deployment is already prepared');
    // Refuse to overwrite an interrupted run's durable recovery record.
    try { await readFile(this.path); throw new Error('Recovery journal already exists; restore it before starting another run'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    const raw = await this.io.read(signal);
    const state = guardedState(this.config, raw);
    productionAdmission(this.config, state);
    check(state.image === this.config.before_image && state.marker === undefined, 'Deployment does not match the unclaimed baseline');
    const before = await this.io.observe(this.config.before_digest, signal);
    check(before.deployment_uid === this.config.deployment_uid && before.service_uid === raw.service.metadata.uid &&
      before.generation === state.deployment.metadata.generation, 'Deployment changed during recovery preparation');
    this.record = { version: 1, run_id: runId, config: this.config,
      namespace_uid: raw.namespace.metadata.uid, service_uid: raw.service.metadata.uid,
      before, annotations_absent: !state.deployment.spec.template.metadata?.annotations };
    try { await this.save('prepared'); }
    catch (error) { this.record = undefined; throw error; }
    return before;
  }

  async roll(signal) {
    check(this.record?.phase === 'prepared', 'Recovery rollout has already been attempted or was not prepared');
    const state = guardedState(this.config, await this.io.read(signal), this.record);
    productionAdmission(this.config, state);
    check(state.image === this.config.before_image && state.marker === undefined &&
      state.deployment.metadata.generation === this.record.before.generation, 'Deployment changed before recovery rollout');
    const patch = tests(state);
    if (!state.deployment.spec.template.metadata?.annotations) patch.push({ op: 'add', path: annotations, value: {} });
    patch.push({ op: 'add', path: markerPath, value: this.record.run_id },
      { op: 'replace', path: `/spec/template/spec/containers/${state.index}/image`, value: this.config.target_image });
    await this.save('roll_requested');
    await this.io.patch(patch, signal);
    this.record.after = await this.waitHealthy(this.config.target_digest, true, signal);
    await this.save('rolled');
    return this.record.after;
  }

  async waitHealthy(expected, replacing, signal) {
    const timeout = AbortSignal.timeout(this.config.timeout_ms);
    signal = signal ? AbortSignal.any([signal, timeout]) : timeout;
    const deadline = this.io.now() + this.config.timeout_ms;
    while (this.io.now() < deadline) {
      signal?.throwIfAborted();
      // Ownership failures must not be hidden by rollout polling.
      const state = guardedState(this.config, await this.io.read(signal), this.record);
      check(state.image === (replacing ? this.config.target_image : this.config.before_image) &&
        state.marker === (replacing ? this.record.run_id : undefined), 'Recovery image or ownership changed');
      let observed;
      try { observed = await this.io.observe(expected, signal); } catch { signal?.throwIfAborted(); }
      if (observed?.deployment_uid === this.config.deployment_uid && observed.service_uid === this.record.service_uid &&
          observed.generation === state.deployment.metadata.generation && (!replacing ||
          (observed.generation > this.record.before.generation && observed.pods.length > 0 &&
          observed.pods.every(p => !this.record.before.pods.some(old => old.uid === p.uid))))) return observed;
      await this.io.sleep(Math.min(1000, Math.max(1, deadline - this.io.now())), signal);
    }
    throw new Error('Recovery rollout did not become healthy before its deadline');
  }

  async restore(signal) {
    check(this.record, 'Recovery record is missing');
    const state = guardedState(this.config, await this.io.read(signal), this.record);
    if (state.marker === undefined) {
      check(state.image === this.config.before_image, 'Unclaimed deployment differs from the baseline; refusing restoration');
    } else {
      check(state.marker === this.record.run_id && state.image === this.config.target_image,
        'Another actor changed recovery ownership or image; refusing restoration');
      const patch = tests(state);
      patch.push({ op: 'test', path: markerPath, value: this.record.run_id },
        { op: 'replace', path: `/spec/template/spec/containers/${state.index}/image`, value: this.config.before_image });
      patch.push({ op: 'remove', path: this.record.annotations_absent &&
        Object.keys(state.deployment.spec.template.metadata.annotations).length === 1 ? annotations : markerPath });
      await this.save('restore_requested');
      await this.io.patch(patch, signal);
    }
    this.record.restored = await this.waitHealthy(this.config.before_digest, false, signal);
    await this.save('restored');
    return this.record.restored;
  }

  static async resume(journalPath, overrides = {}) {
    const record = JSON.parse(await readFile(journalPath, 'utf8'));
    check(record.version === 1 && uuid.test(record.run_id) && record.before?.deployment_uid === record.config?.deployment_uid &&
      record.before?.service_uid === record.service_uid && typeof record.namespace_uid === 'string' &&
      typeof record.annotations_absent === 'boolean' && Array.isArray(record.before?.pods) &&
      ['prepared', 'roll_requested', 'rolled', 'restore_requested', 'restored'].includes(record.phase), 'Invalid recovery journal');
    const control = new RecoveryDeployment(record.config, journalPath, overrides);
    control.record = record;
    return control;
  }
}
