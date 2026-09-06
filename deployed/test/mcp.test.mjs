import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createMcpReceiver, MCP_VERSION, PROTOCOL_VERSION } from '../receivers/mcp.mjs';
import { fingerprint } from '../receivers/secrets.mjs';
import { mcpCoverage, verifyMcpTurn } from '../profiles/mcp.mjs';
import { McpReceiverSession } from '../lib/mcp-receiver.mjs';
import { configFrom } from '../lib/runner.mjs';
import { Redactor } from '../lib/http.mjs';
import { ciConfig } from '../ci.mjs';

function temporary(t) { const dir = mkdtempSync(join(tmpdir(), 'fountain-mcp-test-')); t.after(() => rmSync(dir, { force: true, recursive: true })); return dir; }
async function fixture(t, options = {}) {
  const adminKey = randomUUID(), token = `suite_mcp_${randomUUID()}`, runId = randomUUID(), nonces = [randomUUID(), randomUUID()];
  const server = createMcpReceiver({ adminKey, ...options });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  const url = `http://127.0.0.1:${server.address().port}`;
  const request = async (method, path, body, headers = {}) => {
    const response = await fetch(url + path, { method, headers: { authorization: `Bearer ${adminKey}`, 'content-type': 'application/json', accept: 'application/json, text/event-stream', ...headers },
      body: body === undefined ? undefined : JSON.stringify(body) });
    const text = await response.text(); return { status: response.status, body: text ? JSON.parse(text) : null, session: response.headers.get('mcp-session-id') };
  };
  const runPath = `/_suite/runs/${runId}`, spec = { credential_sha256: fingerprint(token), nonces };
  assert.equal((await request('PUT', runPath, spec)).status, 201);
  let session;
  const rpc = async (method, params, extra = {}) => {
    const response = await request('POST', `/mcp/${runId}`, { jsonrpc: '2.0', id: 1, method, params, ...extra },
      { authorization: `Bearer ${token}`, ...(session ? { 'mcp-session-id': session } : {}) });
    if (response.session) session = response.session;
    return response;
  };
  const initialize = async () => {
    const result = await rpc('initialize', { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'wire-test', version: '1' } });
    assert.equal(result.body.result.protocolVersion, PROTOCOL_VERSION);
    assert.equal((await rpc('notifications/initialized', undefined, { id: undefined })).status, 202);
  };
  return { request, rpc, initialize, runPath, runId, token, adminKey, spec, nonces };
}

test('MCP receiver negotiates lifecycle, discovers tools and records authenticated nonce/denial receipts', async t => {
  const f = await fixture(t);
  assert.equal((await f.request('GET', '/_suite/identity')).body.version, MCP_VERSION);
  await f.initialize();
  assert.deepEqual((await f.rpc('tools/list')).body.result.tools.map(t => t.name), ['suite_nonce', 'suite_denied']);
  for (const name of ['suite_nonce', 'suite_denied']) {
    const response = await f.rpc('tools/call', { name, arguments: { nonce: f.nonces[0] } });
    assert.equal(response.body.result.isError, name === 'suite_denied');
    const receipt = JSON.parse(response.body.result.content[0].text);
    assert.equal(receipt.principal, f.runId);
    assert.equal(receipt.nonce, f.nonces[0]);
    const evidence = (await f.request('GET', f.runPath)).body.observations;
    assert.ok(evidence.some(r => r.receipt_id === receipt.receipt_id && r.outcome === receipt.outcome));
    assert.ok(!JSON.stringify(evidence).includes(f.token));
    assert.ok(!JSON.stringify(evidence).includes(f.spec.credential_sha256));
  }
  await f.initialize();
  await f.rpc('tools/list');
  assert.equal((await f.rpc('tools/call', { name: 'suite_nonce', arguments: { nonce: f.nonces[1] } })).body.result.isError, false);
  assert.equal((await f.request('DELETE', f.runPath)).status, 204);
  assert.equal((await f.request('GET', f.runPath)).status, 404);
  assert.equal((await f.rpc('tools/list')).status, 404);
});

test('MCP enforces credential, origin, session and discovery boundaries without echoing rejected input', async t => {
  const f = await fixture(t), path = `/mcp/${f.runId}`;
  for (const authorization of ['', 'Bearer accidental-secret', `Bearer ${f.adminKey}`, `Bearer suite_mcp_${randomUUID()}`]) {
    const response = await f.request('POST', path, { private: 'do-not-echo' }, { authorization });
    assert.equal(response.status, 401);
    assert.ok(!JSON.stringify(response.body).includes('do-not-echo'));
  }
  assert.equal((await f.request('GET', path, undefined, { authorization: `Bearer ${f.token}`, origin: 'https://hostile.example.test' })).status, 403);
  assert.equal((await f.rpc('tools/list')).status, 404);
  await f.rpc('initialize', { protocolVersion: PROTOCOL_VERSION });
  assert.equal((await f.rpc('tools/list')).body.error.code, -32600);
  await f.rpc('notifications/initialized', undefined, { id: undefined });
  assert.equal((await f.rpc('tools/call', { name: 'suite_nonce', arguments: { nonce: f.nonces[0] } })).body.error.code, -32600);
  await f.rpc('tools/list');
  assert.equal((await f.rpc('tools/call', { name: 'unknown-secret-tool', arguments: { nonce: f.nonces[0] } })).body.error.code, -32602);
  assert.equal((await f.rpc('tools/call', { name: 'suite_nonce', arguments: { nonce: randomUUID() } })).body.error.code, -32602);
  assert.equal((await f.request('GET', f.runPath, undefined, { authorization: `Bearer ${f.token}` })).status, 401);
  assert.equal((await f.request('PUT', f.runPath, f.spec)).status, 409);
});

test('MCP receiver bounds runs, tools, bodies and retention', async t => {
  let now = 0;
  const f = await fixture(t, { now: () => now, maxRuns: 1, ttlMs: 100 });
  assert.equal((await f.request('PUT', `/_suite/runs/${randomUUID()}`, f.spec)).status, 503);
  await f.initialize(); await f.rpc('tools/list');
  for (let n = 0; n < 8; n++) assert.equal((await f.rpc('tools/call', { name: 'suite_nonce', arguments: { nonce: f.nonces[0] } })).status, 200);
  assert.equal((await f.rpc('tools/call', { name: 'suite_nonce', arguments: { nonce: f.nonces[0] } })).status, 429);
  assert.equal((await f.rpc('ping', { too_large: 'x'.repeat(17000) })).status, 400);
  now = 101;
  assert.equal((await f.rpc('tools/list')).status, 404);
  assert.equal((await f.request('GET', f.runPath)).status, 404);
});

test('a valid credential and session cannot authenticate another receiver run', async t => {
  const f = await fixture(t), other = randomUUID(), otherToken = `suite_mcp_${randomUUID()}`;
  assert.equal((await f.request('PUT', `/_suite/runs/${other}`, { ...f.spec, credential_sha256: fingerprint(otherToken) })).status, 201);
  const init = await f.rpc('initialize', { protocolVersion: PROTOCOL_VERSION });
  const message = { jsonrpc: '2.0', id: 9, method: 'tools/list' };
  const headers = { authorization: `Bearer ${f.token}`, 'mcp-session-id': init.session };
  assert.equal((await f.request('POST', `/mcp/${other}`, message, headers)).status, 401);
  headers.authorization = `Bearer ${otherToken}`;
  assert.equal((await f.request('POST', `/mcp/${other}`, message, headers)).status, 404);
  const evidence = (await f.request('GET', `/_suite/runs/${other}`)).body.observations;
  assert.equal(evidence.length, 1); assert.equal(evidence[0].outcome, 'unauthorized');
});

function turnEvidence() {
  const runId = randomUUID(), nonce = randomUUID(), turnId = randomUUID(), sessionId = randomUUID();
  const rows = [{ method: 'tools/list', principal: runId, session_id: sessionId }];
  const blocks = [];
  for (const tool of ['suite_nonce', 'suite_denied']) {
    const row = { method: 'tools/call', principal: runId, session_id: sessionId, tool, nonce, receipt_id: randomUUID(), outcome: tool === 'suite_nonce' ? 'accepted' : 'denied' };
    rows.push(row);
    blocks.push({ kind: 'tool_use', id: tool, name: `mcp__suite__${tool}` },
      { kind: 'tool_result', tool_id: tool, body: JSON.stringify(row), error: tool === 'suite_denied' });
  }
  const event = { turn_id: turnId, blocks };
  return { turn: { turn: { id: turnId }, stored: [structuredClone(event)], events: [{ event: structuredClone(event) }] }, rows, options: { nonce, runId, deny: true } };
}
test('MCP verdict requires independent discovery, exact calls and paired live/durable receipts', () => {
  const f = turnEvidence(); verifyMcpTurn(f.turn, f.rows, f.options);
  for (const mutate of [
    f => f.rows.shift(), f => f.rows.push(structuredClone(f.rows[1])), f => f.rows[1].principal = randomUUID(),
    f => f.turn.stored[0].blocks[1].kind = 'text', f => f.turn.events[0].event.blocks[1].body = 'model says success',
    f => f.turn.stored[0].blocks[1].tool_id = 'unpaired', f => f.turn.stored[0].blocks[3].error = false,
    f => f.turn.stored[0].turn_id = randomUUID(), f => f.rows.reverse(),
  ]) { const bad = turnEvidence(); mutate(bad); assert.throws(() => verifyMcpTurn(bad.turn, bad.rows, bad.options)); }
});

const config = () => ({ base_url: 'https://fountain.example.test', credentials: { primary: 'KEY', secondary: 'OTHER' }, profiles: ['mcp'],
  execution: { runtime: 'claude', model: 'anthropic/claude-haiku-4-5', sandbox_provider: 'e2b', max_turns: 2 },
  mcp: { receiver_url: 'https://mcp.example.test', admin_credential: 'MCP_KEY', auth_mode: 'static_bearer' } });
test('MCP selection requires explicit supported auth, bounded prompts and HTTPS receiver', t => {
  const path = join(temporary(t), 'target.json'), env = { KEY: randomUUID(), OTHER: randomUUID(), MCP_KEY: randomUUID() };
  writeFileSync(path, JSON.stringify(config()));
  assert.equal(configFrom(path, env).execution.max_turns, 2);
  for (const change of [c => c.mcp.auth_mode = 'conversation', c => c.execution.max_turns = 3,
    c => c.mcp.receiver_url = 'http://mcp.example.test', c => c.mcp.receiver_url = 'https://127.0.0.1',
    c => c.execution.sandbox_mode = 'persistent', c => c.profiles.push('basic'), c => c.limits = { run_ms: 600001 }, c => c.limits = { resources: 2 }]) {
    const c = config(); change(c); writeFileSync(path, JSON.stringify(c)); assert.throws(() => configFrom(path, env));
  }
  writeFileSync(path, JSON.stringify(config()));
  assert.throws(() => configFrom(path, { KEY: env.KEY, OTHER: env.OTHER }), /MCP receiver admin/);
  const coverage = mcpCoverage('claude');
  assert.equal(coverage.filter(row => row.static_bearer === 'required_this_run').length, 1);
  assert.ok(coverage.every(row => row.conversation_auth.issue.endsWith('/1405')));
  assert.deepEqual(ciConfig({ SUITE_TARGET: 'staging', SUITE_ENABLED: 'true', SUITE_PROFILE: 'mcp', SUITE_MODE: 'public', SUITE_TARGET_JSON: JSON.stringify(config()) }).profiles, ['mcp']);
});

test('MCP lost create reply retains cleanup intent, and evidence/cleanup cannot be retargeted', async t => {
  const path = join(temporary(t), 'mcp-receiver.json'), runId = randomUUID(), instance = randomUUID();
  const receiver = new McpReceiverSession({ settings: config().mcp, adminKey: randomUUID(), runId, path, redactor: new Redactor() });
  receiver.client.request = async () => ({ body: { version: MCP_VERSION, instance_id: instance } });
  await receiver.verify();
  receiver.client.request = async () => { throw new Error('lost reply'); };
  await assert.rejects(receiver.create({}), /lost reply/);
  assert.equal(JSON.parse(readFileSync(path)).state, 'pending');
  receiver.loadCleanup();
  receiver.client.request = async () => ({ body: { version: MCP_VERSION, id: runId, instance_id: randomUUID(), observations: [] } });
  await assert.rejects(receiver.evidence(), /identity differs/);
  writeFileSync(path, JSON.stringify({ ...receiver.manifest, base_url: 'https://foreign.example.test' }));
  assert.throws(() => receiver.loadCleanup(), /does not match/);
});
