import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer, request } from 'node:http';
import { createHash, randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { createRunnerRelay, RELAY_VERSION } from '../receivers/runner-relay.mjs';

const adminKey = 'a'.repeat(40), runnerKey = 'b'.repeat(40);
const hash = value => createHash('sha256').update(value).digest('hex');
async function listen(server) { server.listen(0, '127.0.0.1'); await once(server, 'listening'); return `http://127.0.0.1:${server.address().port}`; }
async function fixture(t) {
  let now = 0;
  const received = [], sockets = new Set();
  const upstream = createServer();
  upstream.on('upgrade', (req, socket) => {
    received.push({ url: req.url, authorization: req.headers.authorization });
    sockets.add(socket); socket.on('close', () => sockets.delete(socket)); socket.on('error', () => {});
    socket.write('HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: fixture\r\n\r\n');
    socket.pipe(socket);
  });
  const origin = await listen(upstream);
  const relay = createRunnerRelay({ adminKey, runnerKeySha256: hash(runnerKey), runnerName: 'dedicated', upstream: origin,
    diagnosticHttpUpstream: true, now: () => now });
  const url = await listen(relay);
  t.after(async () => {
    relay.closeAllConnections(); await new Promise(done => relay.close(done));
    for (const socket of sockets) socket.destroy();
    await new Promise(done => upstream.close(done));
  });
  const api = async (method, id, body, key = adminKey) => {
    const response = await fetch(`${url}/_suite/runs/${id}`, { method, headers: { authorization: `Bearer ${key}` },
      body: body === undefined ? undefined : JSON.stringify(body) });
    return { status: response.status, body: response.status === 204 ? undefined : await response.json() };
  };
  const connect = ({ key = runnerKey, name = 'dedicated', path = `/api/runners/ws?name=${name}`, origin: browserOrigin } = {}) => new Promise((done, reject) => {
    const req = request(url, { path, headers: { authorization: `Bearer ${key}`, connection: 'Upgrade', upgrade: 'websocket',
      'sec-websocket-version': '13', 'sec-websocket-key': 'fixture', ...(browserOrigin ? { origin: browserOrigin } : {}) } });
    req.on('upgrade', (res, socket, head) => { socket.on('error', () => {}); done({ status: res.statusCode, socket, head }); });
    req.on('response', res => { res.resume(); done({ status: res.statusCode }); });
    req.on('error', reject); req.end();
  });
  return { url, api, connect, received, relay, advance: ms => { now += ms; } };
}

test('relay cuts the dedicated connection, denies reconnect, then automatically forwards again', async t => {
  const f = await fixture(t), id = randomUUID();
  const first = await f.connect();
  assert.equal(first.status, 101);
  const bytes = once(first.socket, 'data'); first.socket.write('opaque runner bytes');
  assert.equal((await bytes)[0].toString(), 'opaque runner bytes');
  const closed = once(first.socket, 'close');
  assert.equal((await f.api('PUT', id, { disconnect_ms: 1000 })).status, 201);
  await closed;
  assert.equal((await f.connect()).status, 503);
  f.advance(1001);
  const second = await f.connect(); assert.equal(second.status, 101);
  const evidence = (await f.api('GET', id)).body;
  assert.equal(evidence.version, RELAY_VERSION);
  assert.equal(evidence.blocked, false);
  assert.equal(evidence.active_connections, 1);
  assert.equal(evidence.rejected_connections, 1);
  assert.deepEqual(evidence.observations.map(r => r.outcome), ['disconnected', 'automatically_reopened', 'connected']);
  assert.equal(evidence.observations[0].connections, 1);
  assert.ok(!JSON.stringify(evidence).includes(runnerKey));
  assert.ok(!JSON.stringify(evidence).includes(adminKey));
  assert.equal(f.received.length, 2);
  assert.ok(f.received.every(row => row.authorization === `Bearer ${runnerKey}`));
  assert.equal((await f.api('DELETE', id)).status, 204);
  assert.equal((await f.api('GET', id)).status, 404);
  second.socket.destroy();
});

test('early cleanup reopens only its own disruption and repeated PUT never extends the cut', async t => {
  const f = await fixture(t), id = randomUUID();
  const peer = await f.connect();
  await f.api('PUT', id, { disconnect_ms: 60000 });
  assert.equal((await f.api('PUT', id, { disconnect_ms: 60000 })).status, 409);
  await f.api('DELETE', randomUUID());
  assert.equal((await f.connect()).status, 503);
  await f.api('DELETE', id);
  const restored = await f.connect(); assert.equal(restored.status, 101);
  peer.socket.destroy(); restored.socket.destroy();
});

test('unconnected runner, wrong credentials, identity, and browser origin cannot trigger or use the relay', async t => {
  const f = await fixture(t), id = randomUUID();
  assert.equal((await f.api('PUT', id, { disconnect_ms: 1000 })).status, 409);
  assert.equal((await f.api('PUT', id, { disconnect_ms: 1000 }, runnerKey)).status, 401);
  for (const options of [{ key: adminKey }, { key: 'wrong' }, { name: 'other' }, { origin: 'https://browser.test' },
    { path: '/api/runners/ws?name=dedicated&name=other' }, { path: '/api/auth/me' }]) {
    assert.equal((await f.connect(options)).status, 403);
  }
  assert.equal(f.received.length, 0);
});

test('upstream is fixed even for absolute request targets, and a second peer is refused', async t => {
  const f = await fixture(t);
  const peer = await f.connect({ path: 'https://attacker.invalid/api/runners/ws?name=dedicated' });
  assert.equal(peer.status, 101);
  assert.equal(f.received[0].url, '/api/runners/ws?name=dedicated');
  assert.equal((await f.connect()).status, 503);
  peer.socket.destroy();
});

test('outage settings reject unbounded durations and unrelated fields', async t => {
  const f = await fixture(t);
  for (const spec of [{ disconnect_ms: 0 }, { disconnect_ms: 60001 }, { disconnect_ms: 1000, command: 'kill' }, {}]) {
    assert.equal((await f.api('PUT', randomUUID(), spec)).status, 422);
  }
});

test('production relay entry rejects HTTP upstreams and shared admin/runner credentials', () => {
  const valid = { adminKey, runnerKeySha256: hash(runnerKey), runnerName: 'dedicated', upstream: 'https://staging.example.test' };
  for (const change of [{ upstream: 'http://127.0.0.1' }, { upstream: 'https://other.test/path' },
    { runnerKeySha256: hash(adminKey) }, { upstream: 'http://public.test', diagnosticHttpUpstream: true }]) {
    assert.throws(() => createRunnerRelay({ ...valid, ...change }));
  }
});
