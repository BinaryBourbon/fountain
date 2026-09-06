#!/usr/bin/env node
import { createServer as httpServer, request as httpRequest } from 'node:http';
import { createServer as httpsServer, request as httpsRequest } from 'node:https';
import { createHash, randomUUID, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const RELAY_VERSION = 'fountain-runner-relay/1';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const equal = (a, b) => typeof a === 'string' && a.length === b.length &&
  Buffer.byteLength(a) === Buffer.byteLength(b) && timingSafeEqual(Buffer.from(a), Buffer.from(b));
const hash = value => createHash('sha256').update(value).digest('hex');
const reply = (res, status, value) => {
  res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  res.end(value === undefined ? undefined : JSON.stringify(value));
};
const refuse = (socket, status = 503) => socket.end(`HTTP/1.1 ${status} Relay unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);

// A dedicated runner uses this as its base URL. Only its websocket is proxied;
// the daemon and its child sessions keep running during a bounded network cut.
export function createRunnerRelay({ adminKey, runnerKeySha256, runnerName, upstream, tls,
  diagnosticHttpUpstream = false, now = Date.now } = {}) {
  const target = new URL(upstream);
  if (target.origin !== upstream || target.username || target.password ||
      !(target.protocol === 'https:' || diagnosticHttpUpstream && target.protocol === 'http:' &&
      ['127.0.0.1', '[::1]'].includes(target.hostname)) ||
      typeof adminKey !== 'string' || adminKey.length < 32 || !/^[0-9a-f]{64}$/.test(runnerKeySha256) ||
      hash(adminKey) === runnerKeySha256 || typeof runnerName !== 'string' || !/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/.test(runnerName)) {
    throw new Error('Relay requires a fixed HTTPS upstream, dedicated runner identity, and separate strong admin credential');
  }
  const instanceId = randomUUID(), runs = new Map(), peers = new Set();
  let blockedBy, closing = false;
  const identity = { version: RELAY_VERSION, instance_id: instanceId, upstream, runner_name: runnerName };
  const record = (run, outcome, extra = {}) => {
    if (run.observations.length < 64) run.observations.push({ at: now(), outcome, ...extra });
    else run.overflow = true;
  };
  const refresh = () => {
    const owner = runs.get(blockedBy);
    if (owner && owner.blocked_until <= now()) { record(owner, 'automatically_reopened'); blockedBy = undefined; }
    for (const [id, run] of runs) if (run.expires_at <= now()) runs.delete(id);
  };
  const handler = async (req, res) => {
    try {
      refresh();
      if (req.headers.origin !== undefined) return reply(res, 403, { error: 'origin_denied' });
      const url = new URL(req.url, 'http://relay.invalid');
      if (url.search) return reply(res, 400, { error: 'query_denied' });
      if (req.method === 'GET' && url.pathname === '/_suite/identity') return reply(res, 200, identity);
      const id = url.pathname.match(/^\/_suite\/runs\/([^/]+)$/)?.[1];
      if (!id || !uuid.test(id)) return reply(res, 404, { error: 'not_found' });
      if (!equal(req.headers.authorization, `Bearer ${adminKey}`)) return reply(res, 401, { error: 'unauthorized' });
      if (req.method === 'DELETE') {
        if (blockedBy === id) blockedBy = undefined;
        runs.delete(id); return reply(res, 204);
      }
      if (req.method === 'PUT') {
        let bytes = 0; const parts = [];
        for await (const part of req) { bytes += part.length; if (bytes > 1024) return reply(res, 413, { error: 'body_limit' }); parts.push(part); }
        const spec = JSON.parse(Buffer.concat(parts).toString('utf8'));
        if (!spec || Object.keys(spec).length !== 1 || !Number.isInteger(spec.disconnect_ms) ||
          spec.disconnect_ms < 1000 || spec.disconnect_ms > 60000) return reply(res, 422, { error: 'invalid_spec' });
        if (blockedBy || runs.has(id)) return reply(res, 409, { error: 'run_exists_or_active' });
        if (runs.size >= 32) return reply(res, 503, { error: 'capacity' });
        if (peers.size !== 1 || ![...peers][0].connected) return reply(res, 409, { error: 'dedicated_runner_not_connected' });
        const run = { expires_at: now() + 900000, blocked_until: now() + spec.disconnect_ms,
          observations: [], rejected_connections: 0, overflow: false };
        runs.set(id, run); blockedBy = id;
        record(run, 'disconnected', { connections: peers.size });
        for (const peer of [...peers]) peer.close();
        return reply(res, 201, { id, ...identity, expires_at: run.expires_at });
      }
      const run = runs.get(id);
      if (req.method === 'GET') return run ? reply(res, 200, { id, ...identity, ...run,
        blocked: blockedBy === id, active_connections: [...peers].filter(p => p.connected).length }) : reply(res, 404, { error: 'not_found' });
      return reply(res, 405, { error: 'method' });
    } catch { if (!res.headersSent) reply(res, 400, { error: 'invalid_request' }); else res.end(); }
  };
  const server = tls ? httpsServer(tls, handler) : httpServer(handler);
  server.requestTimeout = 5000; server.headersTimeout = 5000; server.keepAliveTimeout = 1000;
  server.on('upgrade', (req, socket, head) => {
    refresh();
    socket.on('error', () => socket.destroy());
    let url;
    try { url = new URL(req.url, 'http://relay.invalid'); } catch { return refuse(socket, 400); }
    const bearer = req.headers.authorization?.match(/^Bearer ([^\s]+)$/)?.[1];
    if (req.method !== 'GET' || url.pathname !== '/api/runners/ws' || url.searchParams.getAll('name').length !== 1 ||
        url.searchParams.get('name') !== runnerName || req.headers.origin !== undefined ||
        !bearer || !equal(hash(bearer), runnerKeySha256) || req.headers.upgrade?.toLowerCase() !== 'websocket') return refuse(socket, 403);
    if (blockedBy) { runs.get(blockedBy).rejected_connections++; return refuse(socket); }
    if (closing || peers.size) return refuse(socket);
    const headers = { authorization: req.headers.authorization, connection: 'Upgrade', upgrade: 'websocket' };
    for (const name of ['sec-websocket-key', 'sec-websocket-version', 'sec-websocket-protocol', 'sec-websocket-extensions']) {
      if (req.headers[name]) headers[name] = req.headers[name];
    }
    let remote, request;
    const peer = { connected: false, close: () => {
      peers.delete(peer); socket.destroy(); remote?.destroy(); request?.destroy();
    } };
    peers.add(peer);
    socket.on('error', peer.close); socket.on('close', peer.close);
    request = (target.protocol === 'https:' ? httpsRequest : httpRequest)(new URL(`${url.pathname}${url.search}`, target), { headers });
    const timer = setTimeout(peer.close, 10000); timer.unref();
    request.on('error', peer.close);
    request.on('response', response => { response.destroy(); peer.close(); });
    request.on('upgrade', (response, upstreamSocket, upstreamHead) => {
      clearTimeout(timer); remote = upstreamSocket;
      remote.on('error', peer.close); remote.on('close', peer.close);
      if (!peers.has(peer) || closing || blockedBy || response.statusCode !== 101) return peer.close();
      const responseHeaders = ['HTTP/1.1 101 Switching Protocols', 'Connection: Upgrade', 'Upgrade: websocket'];
      for (const name of ['sec-websocket-accept', 'sec-websocket-protocol', 'sec-websocket-extensions']) {
        if (response.headers[name]) responseHeaders.push(`${name}: ${response.headers[name]}`);
      }
      socket.write(`${responseHeaders.join('\r\n')}\r\n\r\n`);
      if (upstreamHead.length) socket.write(upstreamHead);
      if (head.length) remote.write(head);
      peer.connected = true;
      for (const run of runs.values()) record(run, 'connected');
      socket.pipe(remote); remote.pipe(socket);
    });
    request.on('close', () => clearTimeout(timer));
    request.end();
  });
  // Date-based admission reopens automatically even without this timer firing.
  const timer = setInterval(refresh, 250); timer.unref();
  const close = server.close.bind(server);
  server.close = callback => { closing = true; clearInterval(timer); for (const peer of [...peers]) peer.close(); return close(callback); };
  return server;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const port = Number(process.env.PORT || '8080');
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid port');
    const tls = process.env.TLS_CERT_FILE && process.env.TLS_KEY_FILE ? {
      cert: readFileSync(process.env.TLS_CERT_FILE), key: readFileSync(process.env.TLS_KEY_FILE) } : undefined;
    if (!tls && process.env.RECEIVER_TLS_AT_INGRESS !== 'true') throw new Error('TLS required');
    const server = createRunnerRelay({ adminKey: process.env.FOUNTAIN_RELAY_ADMIN_KEY,
      runnerKeySha256: process.env.FOUNTAIN_RELAY_RUNNER_KEY_SHA256, runnerName: process.env.FOUNTAIN_RELAY_RUNNER_NAME,
      upstream: process.env.FOUNTAIN_RELAY_UPSTREAM, tls });
    server.listen(port, '0.0.0.0', () => console.log(`${RELAY_VERSION} listening`));
    const stop = () => { server.close(); server.closeAllConnections(); };
    process.on('SIGINT', stop); process.on('SIGTERM', stop);
  } catch { console.error('Runner relay setup failed; configure dedicated identity, upstream, TLS and port'); process.exitCode = 2; }
}
