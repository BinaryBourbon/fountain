import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, symlinkSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { replayCleanup } from '../cleanup-replay.mjs';

function workspace(t) {
  const dir = mkdtempSync(join(tmpdir(), 'fountain-cleanup-replay-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const resultsRoot = join(dir, 'results'); mkdirSync(resultsRoot);
  const configPath = join(dir, 'target.json'); writeFileSync(configPath, '{}');
  return { dir, configPath, resultsRoot, out: join(dir, 'replay') };
}
function journal(root, cell, baseUrl, ownerId) {
  const dir = join(root, cell); mkdirSync(dir, { recursive: true });
  const runId = randomUUID();
  const resource = { kind: 'environment', id: randomUUID(), name: `suite-${runId}-environment-0`, state: 'created' };
  writeFileSync(join(dir, 'cleanup.json'), JSON.stringify({ version: 1, run_id: runId, base_url: baseUrl, owner_id: ownerId, resources: [resource] }));
  return resource;
}

test('real cleanup continues after foreign-owner rejection and replay is idempotent', async t => {
  const w = workspace(t); const ownerId = randomUUID(); const key = randomUUID();
  const resources = new Map(); const requests = []; const deleted = [];
  const server = createServer((req, res) => {
    requests.push([req.method, req.url]);
    assert.equal(req.headers.authorization, `Bearer ${key}`);
    let status = 404; let body = { error: 'not_found' };
    if (req.url === '/api/auth/me') {
      status = 200; body = { id: ownerId, email: 'test@example.test', email_verified: true, role: 'user' };
    } else if (req.url.startsWith('/api/environments/')) {
      const id = req.url.split('/').at(-1);
      if (resources.has(id)) {
        if (req.method === 'DELETE') { deleted.push(id); resources.delete(id); status = 204; body = undefined; }
        else { status = 200; body = { data: resources.get(id) }; }
      }
    }
    res.writeHead(status, { 'content-type': 'application/json' }); res.end(body && JSON.stringify(body));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  writeFileSync(w.configPath, JSON.stringify({ base_url: baseUrl, credentials: { primary: 'SUITE_TEST_KEY' }, profiles: ['probe'] }));
  const foreign = journal(w.resultsRoot, 'a-foreign', baseUrl, randomUUID());
  const valid = [journal(w.resultsRoot, '', baseUrl, ownerId), journal(w.resultsRoot, 'z-cell', baseUrl, ownerId)];
  for (const r of [foreign, ...valid]) resources.set(r.id, r);
  const options = { ...w, env: { SUITE_TEST_KEY: key } };
  assert.equal(await replayCleanup(options), 3);
  assert.deepEqual(deleted, valid.map(r => r.id));
  assert.ok(resources.has(foreign.id));
  assert.ok(!requests.some(([, url]) => url.includes(foreign.id)));
  assert.ok(requests.every(([method, url]) => method === 'GET' || (method === 'DELETE' && url.startsWith('/api/environments/'))));
  const reportText = readFileSync(join(w.out, 'replay.json'), 'utf8');
  assert.deepEqual(JSON.parse(reportText).entries.map(e => e.status), ['failed', 'passed', 'passed']);
  assert.ok(!reportText.includes(key));
  assert.equal(await replayCleanup({ ...options, out: join(w.dir, 'again') }), 3);
  assert.equal(deleted.length, 2);
  // Once the invalid journal is corrected, a complete replay can pass.
  const foreignPath = join(w.resultsRoot, 'a-foreign', 'cleanup.json');
  const corrected = JSON.parse(readFileSync(foreignPath)); corrected.owner_id = ownerId;
  writeFileSync(foreignPath, JSON.stringify(corrected));
  assert.equal(await replayCleanup({ ...options, out: join(w.dir, 'complete') }), 0);
  assert.deepEqual(deleted, [...valid.map(r => r.id), foreign.id]);
});

for (const scenario of ['empty', 'symlink', 'config symlink', 'too many', 'too deep', 'nested output']) {
  test(`rejects ${scenario} before any execution or output creation`, async t => {
    const w = workspace(t);
    if (scenario !== 'empty') journal(w.resultsRoot, '', 'https://example.test', randomUUID());
    if (scenario === 'symlink') symlinkSync(w.configPath, join(w.resultsRoot, 'linked'));
    if (scenario === 'config symlink') { symlinkSync(w.configPath, join(w.dir, 'linked-config')); w.configPath = join(w.dir, 'linked-config'); }
    if (scenario === 'too many') for (let i = 0; i < 17; i++) journal(w.resultsRoot, `cell-${i}`, 'https://example.test', randomUUID());
    if (scenario === 'too deep') journal(w.resultsRoot, 'a/b/c/d/e', 'https://example.test', randomUUID());
    if (scenario === 'nested output') w.out = join(w.resultsRoot, 'replay');
    let calls = 0;
    await assert.rejects(replayCleanup({ ...w, execute: async () => { calls++; } }));
    assert.equal(calls, 0); assert.equal(existsSync(w.out), false);
  });
}

test('aborted replay records untouched manifests and cannot claim success', async t => {
  const w = workspace(t); journal(w.resultsRoot, '', 'https://example.test', randomUUID());
  let calls = 0;
  assert.equal(await replayCleanup({ ...w, signal: AbortSignal.abort(), execute: async () => { calls++; } }), 3);
  assert.equal(calls, 0);
  assert.equal(JSON.parse(readFileSync(join(w.out, 'replay.json'))).entries[0].status, 'not_run');
});

test('thrown errors stay private and do not prevent later cleanup', async t => {
  const w = workspace(t);
  for (const cell of ['a', 'b']) journal(w.resultsRoot, cell, 'https://example.test', randomUUID());
  const secret = randomUUID(); let calls = 0;
  assert.equal(await replayCleanup({ ...w, execute: async ({ signal, manifestPath }) => {
    assert.equal(signal.aborted, false); assert.ok(manifestPath.endsWith('cleanup.json'));
    if (++calls === 1) throw new Error(secret);
    return 0;
  } }), 3);
  const report = readFileSync(join(w.out, 'replay.json'), 'utf8');
  assert.equal(calls, 2); assert.ok(!report.includes(secret));
  assert.deepEqual(JSON.parse(report).entries.map(e => e.status), ['failed', 'passed']);
});
