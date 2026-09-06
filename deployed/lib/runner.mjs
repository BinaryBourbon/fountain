import { mkdirSync, readFileSync, appendFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { observeDeployment, validateDeployment, verifyStable } from '../adapters/kubernetes.mjs';
import { Contract } from './contract.mjs';
import { Client, Redactor } from './http.mjs';
import { atomicJson, Fixtures } from './fixtures.mjs';
import { probe } from '../profiles/probe.mjs';
import { basic } from '../profiles/basic.mjs';
import { execution } from '../profiles/execution.mjs';

export const VERSION = '0.1.0';
export const profiles = { probe, basic, execution, streaming: execution };
const contractPath = fileURLToPath(new URL('../../sdk/contract/contract.json', import.meta.url));

function requireThat(condition, message) { if (!condition) throw new Error(message); }
function positive(value, fallback, max) {
  const n = value ?? fallback;
  requireThat(Number.isSafeInteger(n) && n > 0 && n <= max, `Expected positive integer limit <= ${max}`);
  return n;
}

export function configFrom(path, env = process.env) {
  const config = JSON.parse(readFileSync(path, 'utf8'));
  const allowed = ['base_url', 'credentials', 'profiles', 'contract', 'required_capabilities', 'optional_capabilities', 'limits', 'execution', 'deployment'];
  requireThat(Object.keys(config).every(key => allowed.includes(key)), 'Unknown configuration field');
  const url = new URL(config.base_url);
  requireThat(['http:', 'https:'].includes(url.protocol) && !url.username && !url.password && !url.search && !url.hash,
    'base_url must be an HTTP(S) URL without credentials, query, or fragment');
  config.base_url = url.href.replace(/\/$/, '');
  requireThat(config.credentials && typeof config.credentials.primary === 'string', 'credentials.primary must name a dedicated test key environment variable');
  requireThat(/^[A-Z][A-Z0-9_]*$/.test(config.credentials.primary), 'Invalid credential environment variable name');
  config.key = env[config.credentials.primary];
  requireThat(typeof config.key === 'string' && config.key.trim().length > 0, `Missing test credential: ${config.credentials.primary}`);
  config.profiles ??= ['probe'];
  requireThat(Array.isArray(config.profiles) && config.profiles.length > 0 && new Set(config.profiles).size === config.profiles.length &&
    config.profiles.every(name => Object.hasOwn(profiles, name)), 'Unknown, empty, or duplicate profile selection');
  requireThat(Object.keys(config.credentials).every(k => ['primary', 'secondary'].includes(k)), 'Unknown credential role');
  requireThat(!(config.profiles.includes('execution') && config.profiles.includes('streaming')), 'Select streaming or execution; streaming already includes execution');
  if (config.profiles.some(name => ['basic', 'execution', 'streaming'].includes(name))) {
    requireThat(typeof config.credentials.secondary === 'string' && /^[A-Z][A-Z0-9_]*$/.test(config.credentials.secondary), 'Selected profile requires credentials.secondary environment variable');
    config.secondaryKey = env[config.credentials.secondary];
    requireThat(typeof config.secondaryKey === 'string' && config.secondaryKey.trim().length > 0, `Missing test credential: ${config.credentials.secondary}`);
  }
  if (config.profiles.some(name => ['execution', 'streaming'].includes(name))) {
    const settings = config.execution;
    requireThat(settings && Object.keys(settings).every(k => ['runtime', 'model', 'sandbox_provider', 'provision_ms', 'turn_ms', 'max_turns'].includes(k)), 'Expected explicit execution configuration');
    requireThat(['claude', 'codex', 'gemini', 'opencode'].includes(settings.runtime) &&
      typeof settings.model === 'string' && /^[a-z0-9_-]+\/[a-z0-9._-]+$/.test(settings.model) &&
      ['sprites', 'e2b', 'daytona', 'runner'].includes(settings.sandbox_provider), 'Pin an execution runtime, model, and sandbox provider');
    settings.provision_ms = positive(settings.provision_ms, 120000, 300000);
    settings.turn_ms = positive(settings.turn_ms, 90000, 300000);
    requireThat(settings.max_turns === 2, 'Execution must explicitly authorize max_turns: 2');
  }
  config.contract = config.contract ? resolve(dirname(path), config.contract) : contractPath;
  const limits = config.limits ?? {};
  requireThat(Object.keys(limits).every(k => ['request_ms', 'run_ms', 'cleanup_ms', 'resources'].includes(k)), 'Unknown limit');
  config.limits = {
    request_ms: positive(limits.request_ms, 10000, 120000), run_ms: positive(limits.run_ms, 120000, 3600000),
    cleanup_ms: positive(limits.cleanup_ms, 30000, 300000), resources: positive(limits.resources, 20, 100),
  };
  for (const field of ['required_capabilities', 'optional_capabilities']) {
    config[field] ??= {};
    requireThat(Object.keys(config[field]).every(k => ['runtimes', 'sandbox_providers'].includes(k)), `Unknown ${field} category`);
    for (const entries of Object.values(config[field])) {
      requireThat(Array.isArray(entries), `Expected ${field} arrays`);
      for (const item of entries) {
        requireThat(field === 'required_capabilities' ? typeof item === 'string' && item.length > 0 :
          typeof item?.name === 'string' && typeof item?.reason === 'string' && item.reason.trim().length > 0,
        `Invalid ${field} entry`);
      }
    }
  }
  if (config.deployment) validateDeployment(config.deployment);
  return config;
}

const xml = value => String(value).replace(/[<>&"']/g, c => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;', "'": '&apos;' })[c]);
export function writeReport(out, report, redactor) {
  const safe = redactor.value(report);
  atomicJson(resolve(out, 'result.json'), safe);
  const cases = safe.checks.map(c => `<testcase name="${xml(c.name)}" time="${(c.duration_ms / 1000).toFixed(3)}">` +
    (c.status === 'failed' ? `<failure message="${xml(c.error)}"/>` : c.status === 'skipped' ? `<skipped message="${xml(c.reason)}"/>` : '') + '</testcase>');
  writeFileSync(resolve(out, 'junit.xml'), `<?xml version="1.0" encoding="UTF-8"?>\n<testsuite name="fountain-deployed" tests="${cases.length}" failures="${safe.checks.filter(c => c.status === 'failed').length}" skipped="${safe.checks.filter(c => c.status === 'skipped').length}">${cases.join('')}</testsuite>\n`, { mode: 0o600 });
  return safe;
}

export async function run({ configPath, out, manifestPath, signal, env = process.env, log = console.log, deploymentObserver = observeDeployment }) {
  mkdirSync(out, { mode: 0o700 }); // Exclusive run directory; never overwrite another run's evidence.
  const redactor = new Redactor();
  const report = { suite_version: VERSION, run_id: randomUUID(), started_at: new Date().toISOString(),
    mode: manifestPath ? 'cleanup' : 'run', status: 'setup_failed', checks: [], revision: { verified: false, reason: 'No deployment revision adapter configured' } };
  let config, fixtures, deploymentBefore;
  try {
    const git = (...args) => execFileSync('git', args, {
      cwd: fileURLToPath(new URL('../..', import.meta.url)), encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
    report.suite_revision = git('rev-parse', 'HEAD');
    report.suite_dirty = Boolean(git('status', '--porcelain', '--untracked-files=normal'));
  } catch { report.suite_revision = null; report.suite_dirty = null; }
  const check = async (name, fn) => {
    const started = performance.now();
    try {
      await fn();
      report.checks.push({ name, status: 'passed', duration_ms: performance.now() - started });
      log(`PASS ${name}`); return true;
    } catch (error) {
      const message = redactor.text(error.message);
      report.checks.push({ name, status: 'failed', duration_ms: performance.now() - started, error: message });
      log(`FAIL ${name}: ${message}`); return false;
    } finally { writeReport(out, report, redactor); }
  };
  try {
    config = configFrom(configPath, env);
    redactor.add(config.key);
    redactor.add(config.secondaryKey);
    report.target = config.base_url;
    report.profiles = config.profiles;
    report.limits = { ...config.limits, concurrency: 1, inference_turns: config.execution?.max_turns ?? 0 };
    const contract = new Contract(config.contract);
    report.contract_sha256 = contract.sha256;
    const timeout = AbortSignal.timeout(config.limits.run_ms);
    const combined = signal ? AbortSignal.any([signal, timeout]) : timeout;
    const client = new Client({ baseUrl: config.base_url, key: config.key, redactor, contract, signal: combined,
      timeoutMs: config.limits.request_ms, trace: entry => appendFileSync(resolve(out, 'http.jsonl'), JSON.stringify(redactor.value(entry)) + '\n', { mode: 0o600 }) });
    if (config.deployment && !manifestPath) {
      const ready = await check('setup/deployment', async () => {
        deploymentBefore = await deploymentObserver(config.deployment, combined);
        report.revision = { verified: false, before: deploymentBefore, reason: 'Awaiting post-run deployment check' };
      });
      if (!ready) throw new Error('Intended deployment is not serving');
    }
    let ownerId;
    const identityOk = await check('setup/identity', async () => {
      const { body } = await client.request('GET', '/api/auth/me', { expected: 200 });
      requireThat(typeof body.id === 'string' && body.email_verified === true, 'Expected a verified dedicated test account');
      ownerId = body.id;
      report.owner_id = ownerId;
    });
    if (!identityOk) throw new Error('Cannot establish fixture owner');
    fixtures = manifestPath ? Fixtures.load(manifestPath, client, ownerId) :
      new Fixtures(resolve(out, 'cleanup.json'), client, { runId: report.run_id, baseUrl: config.base_url, ownerId, maxResources: config.limits.resources });
    if (!manifestPath) {
      const capabilitiesOk = await check('setup/capabilities', async () => {
        const { body } = await client.request('GET', '/api/catalog', { expected: 200 });
        const available = { runtimes: body.data?.runtimes, sandbox_providers: body.data?.sandbox_providers?.enabled };
        requireThat(Object.values(available).every(Array.isArray), 'Catalog capability arrays missing');
        report.capabilities = available;
        if (config.profiles.some(name => ['execution', 'streaming'].includes(name))) {
          requireThat(available.runtimes.includes(config.execution.runtime), 'Execution runtime is unavailable');
          requireThat(available.sandbox_providers.includes(config.execution.sandbox_provider), 'Execution sandbox provider is unavailable');
        }
        for (const [kind, names] of Object.entries(config.required_capabilities)) {
          for (const name of names) requireThat(available[kind].includes(name), `Missing required ${kind}: ${name}`);
        }
        for (const [kind, entries] of Object.entries(config.optional_capabilities)) {
          for (const { name, reason } of entries) if (!available[kind].includes(name)) {
            report.checks.push({ name: `capability/${kind}/${name}`, status: 'skipped', reason, duration_ms: 0 });
          }
        }
      });
      if (!capabilitiesOk) throw new Error('Required capabilities unavailable');
      report.status = 'running';
      const ctx = { client, fixtures, config, report, redactor, check, require: requireThat, signal: combined };
      for (const name of config.profiles) {
        combined.throwIfAborted();
        await profiles[name](ctx);
      }
    } else { report.status = 'running'; report.cleanup_run_id = fixtures.manifest.run_id; }
    report.status = report.checks.some(c => c.status === 'failed') ? 'failed' : 'passed';
  } catch (error) {
    if (report.status === 'running') report.status = 'failed';
    report.checks.push({ name: report.status === 'setup_failed' ? 'setup/configuration' : 'run', status: 'failed', duration_ms: 0, error: redactor.text(error.message) });
  } finally {
    if (fixtures) {
      const failures = await fixtures.cleanup(AbortSignal.timeout(config.limits.cleanup_ms));
      report.cleanup = { failures, remaining: fixtures.manifest.resources.filter(r => r.state !== 'cleaned').length };
      report.inference_attempts = fixtures.manifest.inference_attempts ?? 0;
      if (failures.length) {
        report.status = 'cleanup_failed';
        report.checks.push({ name: 'cleanup', status: 'failed', duration_ms: 0, error: 'Resources remain; see cleanup manifest and result.json' });
      }
    }
    if (deploymentBefore) {
      const stable = await check('deployment/stable', async () => {
        const after = await deploymentObserver(config.deployment, AbortSignal.timeout(20000));
        report.revision = verifyStable(deploymentBefore, after);
      });
      if (!stable && report.status === 'passed') report.status = 'failed';
    }
    if (signal?.aborted) report.status = 'cancelled';
    report.ended_at = new Date().toISOString();
    writeReport(out, report, redactor);
    log(`${report.status.toUpperCase()} — ${resolve(out, 'result.json')}`);
  }
  return { passed: 0, failed: 1, setup_failed: 2, cleanup_failed: 3, cancelled: 130 }[report.status];
}
