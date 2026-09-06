import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const exec = promisify(execFile);
const requireThat = (condition, message) => { if (!condition) throw new Error(message); };

export function validateDeployment(config) {
  requireThat(config?.adapter === 'kubernetes', 'Unsupported deployment adapter');
  requireThat(Object.keys(config).every(k => ['adapter', 'context', 'namespace', 'deployment', 'service', 'container', 'expected_digest'].includes(k)), 'Unknown deployment setting');
  for (const key of ['context', 'namespace', 'deployment', 'service', 'container']) {
    requireThat(typeof config[key] === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9_.:/-]*$/.test(config[key]), `Invalid deployment ${key}`);
  }
  requireThat(/^sha256:[a-f0-9]{64}$/.test(config.expected_digest), 'Expected a runtime image digest');
  return config;
}

// Only selected metadata leaves this adapter. Raw Kubernetes objects can contain secrets.
export function verifySnapshot(config, { deployment, service, pods, slices, replicaSets }) {
  validateDeployment(config);
  const desired = deployment.spec?.replicas ?? 1;
  const status = deployment.status ?? {};
  requireThat(desired > 0 && status.observedGeneration === deployment.metadata.generation &&
    ['replicas', 'updatedReplicas', 'readyReplicas', 'availableReplicas'].every(k => status[k] === desired) &&
    !status.unavailableReplicas, 'Deployment rollout is incomplete');
  requireThat(!deployment.metadata.deletionTimestamp, 'Deployment is terminating');
  requireThat(!service.spec?.publishNotReadyAddresses && service.spec?.selector &&
    Object.keys(service.spec.selector).length > 0, 'Service must select ready pods');
  const selected = pods.items.filter(p => Object.entries(service.spec.selector).every(([k, v]) => p.metadata.labels?.[k] === v));
  requireThat(selected.length === desired, 'Service selector includes missing, extra, or terminating pods');
  const rsIds = new Set(replicaSets.items.filter(rs => rs.metadata.ownerReferences?.some(o =>
    o.controller && o.kind === 'Deployment' && o.uid === deployment.metadata.uid)).map(rs => rs.metadata.uid));
  const members = selected.map(p => {
    requireThat(!p.metadata.deletionTimestamp && p.status?.conditions?.some(c => c.type === 'Ready' && c.status === 'True'), 'Serving pod is not ready');
    requireThat(p.metadata.ownerReferences?.some(o => o.controller && o.kind === 'ReplicaSet' && rsIds.has(o.uid)), 'Service routes outside the approved deployment');
    const container = p.status.containerStatuses?.find(c => c.name === config.container);
    requireThat(container?.ready && container.state?.running && container.imageID?.endsWith(`@${config.expected_digest}`), 'Serving container has the wrong image digest or is not running');
    return { uid: p.metadata.uid, name: p.metadata.name, image_digest: config.expected_digest, restarts: container.restartCount };
  }).sort((a, b) => a.uid.localeCompare(b.uid));
  const endpoints = slices.items.flatMap(s => s.endpoints ?? []);
  requireThat(endpoints.length > 0 && endpoints.every(e => e.conditions?.ready === true &&
    e.conditions?.terminating !== true && e.conditions?.serving !== false && e.targetRef?.kind === 'Pod' &&
    e.targetRef.namespace === config.namespace && members.some(p => p.uid === e.targetRef.uid)),
  'EndpointSlices contain unready, unknown, or terminating backends');
  requireThat(members.every(p => endpoints.some(e => e.targetRef.uid === p.uid)), 'EndpointSlices omit a deployment pod');
  return { adapter: 'kubernetes', observed_at: new Date().toISOString(), context: config.context,
    namespace: config.namespace, deployment: config.deployment, service: config.service,
    deployment_uid: deployment.metadata.uid, generation: deployment.metadata.generation,
    service_uid: service.metadata.uid, image_digest: config.expected_digest, pods: members };
}

export async function observeDeployment(config, signal) {
  validateDeployment(config);
  const get = async (...args) => {
    try {
      const { stdout } = await exec('kubectl', ['--context', config.context, '--namespace', config.namespace,
        '--request-timeout=10s', 'get', ...args, '-o', 'json'], { timeout: 15000, maxBuffer: 4 * 1024 * 1024, signal });
      return JSON.parse(stdout);
    } catch { throw new Error('Deployment adapter could not read Kubernetes state; check connectivity and read-only RBAC'); }
  };
  const [deployment, service, pods, slices, replicaSets] = await Promise.all([
    get('deployment', config.deployment), get('service', config.service), get('pods'),
    get('endpointslices', '-l', `kubernetes.io/service-name=${config.service}`), get('replicasets'),
  ]);
  return verifySnapshot(config, { deployment, service, pods, slices, replicaSets });
}

export function verifyStable(before, after) {
  const identity = ({ observed_at, ...value }) => JSON.stringify(value);
  requireThat(identity(before) === identity(after), 'Serving deployment changed during verification');
  return { verified: true, adapter: 'kubernetes', image_digest: after.image_digest, before, after,
    scope: 'Approved URL-to-Service binding; every serving pod checked before and after the public suite' };
}
