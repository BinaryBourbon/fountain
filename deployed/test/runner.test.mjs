import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtempSync, readFileSync, writeFileSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { run } from '../lib/runner.mjs';
import { Client, Redactor } from '../lib/http.mjs';
import { Fixtures } from '../lib/fixtures.mjs';
import { Contract } from '../lib/contract.mjs';

const ownerId = 'aaaaaaaa-1111-4111-8111-111111111111';
const catalog = { data: {
  runtimes: ['claude'], models: { claude: ['anthropic/claude-sonnet-4-6'] },
  sandbox_providers: { enabled: [], default: 'sprites' }, package_managers: [],
  avatar: { bases: [], moods: [] }, apps: { conversations: null, team: null },
  first_request: { curl: '', typescript: '', prompt: '', placeholders: [] },
} };
function send(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json', 'x-request-id': 'test-request' });
  res.end(body === undefined ? undefined : JSON.stringify(body));
}
async function fixture(t, handler) {
  const dir = mkdtempSync(join(tmpdir(), 'fountain-runner-test-'));
  const requests = [];
  const fixtureKey = randomUUID();
  const server = createServer(async (req, res) => {
    requests.push([req.method, req.url, req.headers.authorization]);
    if (handler && await handler(req, res)) return;
    if (req.url === '/api/auth/me') return send(res, 200, { id: ownerId, email: 'test@example.test', email_verified: true, role: 'user' });
    if (req.url === '/api/catalog') return send(res, 200, catalog);
    if (req.url === '/health') return send(res, 200, { status: 'ok' });
    if (req.url === '/health/ready') return send(res, 200, { status: 'ok', checks: { database: 'ok' } });
    send(res, 404, { error: 'not_found' });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    rmSync(dir, { recursive: true, force: true });
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  const configPath = join(dir, 'target.json');
  const config = { base_url: baseUrl, credentials: { primary: 'SUITE_TEST_KEY' }, profiles: ['probe'] };
  const execute = async (changes = {}, options = {}) => {
    writeFileSync(configPath, JSON.stringify({ ...config, ...changes }));
    const out = join(dir, randomUUID());
    const code = await run({ configPath, out, env: { SUITE_TEST_KEY: fixtureKey }, log() {}, ...options });
    return { code, out, report: JSON.parse(readFileSync(join(out, 'result.json'))) };
  };
  const trace = [];
  const client = new Client({ baseUrl, key: fixtureKey, redactor: new Redactor(), timeoutMs: 300, trace: item => trace.push(item) });
  return { dir, baseUrl, configPath, execute, requests, client, trace, fixtureKey };
}

test('probe runs over real HTTP, records evidence, and never sends auth to health', async t => {
  const f = await fixture(t);
  const { code, out, report } = await f.execute();
  assert.equal(code, 0);
  assert.equal(report.checks.length, 4);
  assert.match(report.contract_sha256, /^[a-f0-9]{64}$/);
  assert.equal(report.revision.verified, false);
  assert.equal(report.cleanup.remaining, 0);
  assert.equal(f.requests.find(([, path]) => path === '/health')[2], undefined);
  const artifacts = readdirSync(out).map(p => readFileSync(join(out, p), 'utf8')).join('\n');
  assert.ok(!artifacts.includes(f.fixtureKey));
  assert.ok(!artifacts.includes('test@example.test'));
  assert.match(artifacts, /test-request/);
});

test('missing credential and unknown profile are setup failures before network traffic', async t => {
  const f = await fixture(t);
  const missing = await f.execute({}, { env: {} });
  assert.equal(missing.code, 2);
  assert.equal(f.requests.length, 0);
  assert.equal((await f.execute({ profiles: ['execution'] })).code, 2);
  assert.equal(f.requests.length, 0);
});

test('required capability disappearance fails; optional omissions carry a reason', async t => {
  const f = await fixture(t);
  const missing = await f.execute({ required_capabilities: { sandbox_providers: ['sprites'] } });
  assert.equal(missing.code, 2);
  assert.ok(!f.requests.some(([, path]) => path === '/health'));
  const optional = await f.execute({ optional_capabilities: { sandbox_providers: [{ name: 'sprites', reason: 'This fixture has no paid provider' }] } });
  assert.equal(optional.code, 0);
  assert.equal(optional.report.checks.filter(c => c.status === 'skipped').length, 1);
  assert.match(readFileSync(join(optional.out, 'junit.xml'), 'utf8'), /<skipped message=/);
});

test('deployed response regressions fail independently of its advertised schema', async t => {
  const f = await fixture(t, (req, res) => {
    if (req.url !== '/health') return false;
    send(res, 200, { status: 42 }); return true;
  });
  const { code, report } = await f.execute();
  assert.equal(code, 1);
  assert.match(report.checks.find(c => c.name === 'probe/liveness').error, /expected string/);
});

test('redirects are not followed with test credentials', async t => {
  const f = await fixture(t, (req, res) => {
    if (req.url !== '/api/auth/me') return false;
    res.writeHead(302, { location: '/stolen' }); res.end(); return true;
  });
  assert.equal((await f.execute()).code, 2);
  assert.equal(f.requests.length, 1);
});

test('request deadline covers a body that never finishes', async t => {
  const f = await fixture(t, (req, res) => {
    if (req.url !== '/health') return false;
    res.writeHead(200, { 'content-type': 'application/json' }); res.write('{'); return true;
  });
  const started = performance.now();
  const result = await f.execute({ limits: { request_ms: 70, run_ms: 1000 } });
  assert.equal(result.code, 1);
  assert.ok(performance.now() - started < 2000);
  assert.match(result.report.checks.find(c => c.name === 'probe/liveness').error, /deadline/);
});

test('cancellation writes a terminal report', async t => {
  const controller = new AbortController();
  const f = await fixture(t, (req, res) => {
    if (req.url !== '/health') return false;
    controller.abort(); res.end(); return true;
  });
  const result = await f.execute({}, { signal: controller.signal });
  assert.equal(result.code, 130);
  assert.equal(result.report.status, 'cancelled');
});

test('new secrets in responses are redacted before sibling fields reach trace', async t => {
  const f = await fixture(t, (req, res) => {
    if (req.url !== '/issued-key') return false;
    send(res, 201, { message: 'issued brand-new-key-123', key: 'brand-new-key-123' }); return true;
  });
  await f.client.request('GET', '/issued-key');
  assert.ok(!JSON.stringify(f.trace).includes('brand-new-key-123'));
});

test('fixture cleanup preserves reverse order and checks recorded owner names', async t => {
  const values = new Map();
  const deleted = [];
  const f = await fixture(t, async (req, res) => {
    if (!req.url.startsWith('/api/environments')) return false;
    if (req.method === 'POST') {
      let raw = ''; for await (const chunk of req) raw += chunk;
      const data = { ...JSON.parse(raw), id: randomUUID() }; values.set(data.id, data);
      send(res, 201, { data });
    } else {
      const id = req.url.split('/').at(-1);
      if (req.method === 'DELETE') { deleted.push(id); values.delete(id); send(res, 204); }
      else send(res, values.has(id) ? 200 : 404, values.has(id) ? { data: values.get(id) } : { error: 'not_found' });
    }
    return true;
  });
  const fixtures = new Fixtures(join(f.dir, 'cleanup.json'), f.client, { runId: randomUUID(), baseUrl: f.baseUrl, ownerId });
  const a = await fixtures.create('environment'); const b = await fixtures.create('environment');
  assert.deepEqual(await fixtures.cleanup(AbortSignal.timeout(1000)), []);
  assert.deepEqual(deleted, [b.id, a.id]);
  assert.deepEqual(await fixtures.cleanup(AbortSignal.timeout(1000)), []);
  assert.equal(deleted.length, 2);
});

test('schema failure after create retains the resource ID for cleanup', async t => {
  let value;
  const f = await fixture(t, async (req, res) => {
    if (req.url !== '/api/environments') return false;
    let raw = ''; for await (const chunk of req) raw += chunk;
    value = { ...JSON.parse(raw), id: randomUUID() };
    send(res, 201, { data: value }); return true;
  });
  f.client.contract = { check() { throw new Error('schema regression'); } };
  const path = join(f.dir, 'cleanup.json');
  const fixtures = new Fixtures(path, f.client, { runId: randomUUID(), baseUrl: f.baseUrl, ownerId });
  await assert.rejects(fixtures.create('environment'), /schema regression/);
  assert.equal(JSON.parse(readFileSync(path)).resources[0].id, value.id);
  assert.equal(fixtures.manifest.resources[0].state, 'created');
});

test('a create committed before connection death is reconciled by exact name', async t => {
  let stored;
  const f = await fixture(t, async (req, res) => {
    if (!req.url.startsWith('/api/environments')) return false;
    if (req.method === 'POST') {
      let raw = ''; for await (const chunk of req) raw += chunk;
      stored = { ...JSON.parse(raw), id: randomUUID() };
      res.destroy();
    } else if (req.method === 'GET') send(res, 200, { data: [stored] });
    else { assert.equal(req.url, `/api/environments/${stored.id}`); send(res, 204); }
    return true;
  });
  const path = join(f.dir, 'cleanup.json');
  const fixtures = new Fixtures(path, f.client, { runId: randomUUID(), baseUrl: f.baseUrl, ownerId });
  await assert.rejects(fixtures.create('environment'));
  assert.equal(fixtures.manifest.resources[0].state, 'pending');
  const recovered = Fixtures.load(path, f.client, ownerId);
  assert.deepEqual(await recovered.cleanup(AbortSignal.timeout(1000)), []);
  assert.equal(recovered.manifest.resources[0].state, 'cleaned');
});

test('cleanup failures survive in JSON, JUnit and the nonzero exit code', async t => {
  const id = randomUUID(); const runId = randomUUID();
  const name = `suite-${runId}-environment-0`;
  const f = await fixture(t, (req, res) => {
    if (req.url !== `/api/environments/${id}`) return false;
    send(res, req.method === 'DELETE' ? 500 : 200, req.method === 'DELETE' ? { error: 'failed' } : { data: { id, name } });
    return true;
  });
  const path = join(f.dir, 'cleanup.json');
  const fixtures = new Fixtures(path, f.client, { runId, baseUrl: f.baseUrl, ownerId });
  fixtures.manifest.resources.push({ kind: 'environment', id, name, state: 'created' }); fixtures.save();
  const result = await f.execute({}, { manifestPath: path });
  assert.equal(result.code, 3);
  assert.equal(result.report.cleanup.remaining, 1);
  assert.match(readFileSync(join(result.out, 'junit.xml'), 'utf8'), /name="cleanup".*<failure/);
  assert.equal(JSON.parse(readFileSync(path)).resources[0].state, 'created');
});

test('cleanup refuses another target, owner, or unowned resource name', async t => {
  const id = randomUUID();
  const f = await fixture(t, (req, res) => {
    if (req.method === 'GET' && req.url === `/api/environments/${id}`) {
      send(res, 200, { data: { id, name: 'a-real-user-environment' } }); return true;
    }
    return false;
  });
  const path = join(f.dir, 'cleanup.json');
  const runId = randomUUID();
  const fixtures = new Fixtures(path, f.client, { runId, baseUrl: f.baseUrl, ownerId });
  fixtures.manifest.resources.push({ kind: 'environment', name: `suite-${runId}-environment-0`, id, state: 'created' }); fixtures.save();
  assert.throws(() => Fixtures.load(path, f.client, randomUUID()), /does not match/);
  assert.throws(() => Fixtures.load(path, { baseUrl: 'https://different.test' }, ownerId), /does not match/);
  const failures = await Fixtures.load(path, f.client, ownerId).cleanup(AbortSignal.timeout(1000));
  assert.equal(failures.length, 1);
  assert.match(failures[0].error, /ownership evidence/);
  assert.ok(!f.requests.some(([method]) => method === 'DELETE'));
});

test('unresolved pending intent is visible instead of being silently discarded', async t => {
  const f = await fixture(t, (req, res) => {
    if (req.url !== '/api/environments') return false;
    send(res, 200, { data: [] }); return true;
  });
  const runId = randomUUID();
  const fixtures = new Fixtures(join(f.dir, 'cleanup.json'), f.client, { runId, baseUrl: f.baseUrl, ownerId });
  fixtures.manifest.resources.push({ kind: 'environment', name: `suite-${runId}-environment-0`, state: 'pending' }); fixtures.save();
  assert.equal((await fixtures.cleanup(AbortSignal.timeout(1000))).length, 1);
  assert.equal(fixtures.manifest.resources[0].state, 'pending');
});

test('contract checks requiredness, nullability, enums and unions while allowing compatible additions', () => {
  const c = new Contract(new URL('../../sdk/contract/contract.json', import.meta.url));
  const schema = { type: 'object', properties: { state: { type: 'string', enum: ['done'], required: true }, reason: { type: 'string', nullable: true } } };
  assert.doesNotThrow(() => c.validate({ state: 'done', reason: null, added: 3 }, schema));
  assert.throws(() => c.validate({ state: 'running' }, schema), /enum/);
  assert.throws(() => c.validate({}, schema), /missing/);
  assert.throws(() => c.validate('x', { oneOf: [{ type: 'string' }, { type: 'string' }] }), /oneOf/);
  assert.doesNotThrow(() => c.validate(3, { anyOf: [{ type: 'string' }, { type: 'integer' }] }));
});
