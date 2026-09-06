#!/usr/bin/env node
// Controlled receiver for #1614. Terminate HTTPS at an explicitly configured
// ingress, or supply TLS_CERT_FILE/TLS_KEY_FILE. No request logging or disk state.
import { createServer as httpServer } from 'node:http';
import { createServer as httpsServer } from 'node:https';
import { createHash, randomUUID, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const RECEIVER_VERSION = 'fountain-secret-receiver/1';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const digest = /^[0-9a-f]{64}$/;
const synthetic = /^suite_secret_[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
export const fingerprint = value => createHash('sha256').update(value).digest('hex');
const equal = (left, right) => typeof left === 'string' && Buffer.byteLength(left) === Buffer.byteLength(right) && timingSafeEqual(Buffer.from(left), Buffer.from(right));
function reply(res, status, value) {
  res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
  res.end(value === undefined ? undefined : JSON.stringify(value));
}
async function body(req) {
  let bytes = 0; const parts = [];
  for await (const chunk of req) { bytes += chunk.length; if (bytes > 16384) throw new Error('Request exceeds bound'); parts.push(chunk); }
  return JSON.parse(Buffer.concat(parts).toString('utf8'));
}

export function receiverHandler({ adminKey, now = Date.now, maxRuns = 32, ttlMs = 900000 } = {}) {
  if (typeof adminKey !== 'string' || adminKey.length < 32 || !Number.isSafeInteger(maxRuns) || maxRuns < 1 || maxRuns > 100 ||
    !Number.isSafeInteger(ttlMs) || ttlMs < 1 || ttlMs > 900000) throw new Error('Receiver requires a strong admin credential and bounded retention');
  const instanceId = randomUUID(), runs = new Map();
  return async (req, res) => {
    try {
      for (const [id, run] of runs) if (run.expires_at <= now()) runs.delete(id);
      const url = new URL(req.url, 'http://receiver.invalid');
      if (url.search) return reply(res, 400, { error: 'query_not_supported' });
      if (req.method === 'GET' && url.pathname === '/_suite/identity') return reply(res, 200, { version: RECEIVER_VERSION, instance_id: instanceId });
      const admin = url.pathname.match(/^\/_suite\/runs\/([^/]+)$/);
      if (admin) {
        if (!equal(req.headers.authorization, `Bearer ${adminKey}`)) return reply(res, 401, { error: 'unauthorized' });
        const id = admin[1];
        if (!uuid.test(id)) return reply(res, 400, { error: 'invalid_run' });
        if (req.method === 'DELETE') { runs.delete(id); return reply(res, 204); }
        if (req.method === 'PUT') {
          const spec = await body(req);
          if (!spec || Object.keys(spec).some(k => !['nonce', 'bound_sha256', 'plain_sha256', 'placeholder'].includes(k)) ||
            !uuid.test(spec.nonce) || !digest.test(spec.bound_sha256) || !digest.test(spec.plain_sha256) ||
            typeof spec.placeholder !== 'string' || !/^__suite_[a-z0-9_]+__$/.test(spec.placeholder) || spec.placeholder.length > 210) return reply(res, 422, { error: 'invalid_spec' });
          if (runs.has(id)) return reply(res, 409, { error: 'run_exists' });
          if (runs.size >= maxRuns) return reply(res, 503, { error: 'capacity' });
          const run = { ...spec, expires_at: now() + ttlMs, observations: [] };
          runs.set(id, run);
          return reply(res, 201, { id, expires_at: run.expires_at, version: RECEIVER_VERSION, instance_id: instanceId });
        }
        const run = runs.get(id);
        if (req.method === 'GET') return run ? reply(res, 200, { id, version: RECEIVER_VERSION, instance_id: instanceId,
          expires_at: run.expires_at, observations: run.observations }) : reply(res, 404, { error: 'not_found' });
        return reply(res, 405, { error: 'method' });
      }
      const capture = url.pathname.match(/^\/capture\/([^/]+)\/(allowed|blocked)\/([^/]+)$/);
      if (!capture || !uuid.test(capture[1]) || !uuid.test(capture[3])) return reply(res, 404, { error: 'not_found' });
      const run = runs.get(capture[1]);
      if (!run || run.nonce !== capture[3]) return reply(res, 404, { error: 'not_found' });
      if (run.observations.length >= 8) return reply(res, 429, { error: 'request_budget' });
      if (req.method !== 'POST') return reply(res, 405, { error: 'method' });
      const data = await body(req);
      const bound = req.headers['x-fountain-fixture'];
      const received = { id: randomUUID(), at: now(), phase: capture[2], method: req.method,
        nonce_matches: data?.nonce === run.nonce,
        bound_matches: typeof bound === 'string' && synthetic.test(bound) && fingerprint(bound) === run.bound_sha256,
        plain_matches: typeof data?.plain === 'string' && synthetic.test(data.plain) && fingerprint(data.plain) === run.plain_sha256,
        placeholder_matches: data?.placeholder === run.placeholder };
      run.observations.push(received);
      const valid = received.nonce_matches && received.bound_matches && received.plain_matches && received.placeholder_matches;
      if (!valid || capture[2] === 'blocked') return reply(res, 403, { error: 'fixture_rejected', receipt_id: received.id });
      // Echo only matching synthetic values, to test Fountain's promised output
      // redaction. Store booleans and receipt IDs, never headers or raw bodies.
      reply(res, 200, { receipt_id: received.id, nonce: run.nonce, bound_echo: bound, plain_echo: data.plain });
    } catch { if (!res.headersSent) reply(res, 400, { error: 'invalid_request' }); else res.end(); }
  };
}

export function createReceiver(options) {
  const handler = receiverHandler(options);
  const server = options.tls ? httpsServer(options.tls, handler) : httpServer(handler);
  server.requestTimeout = 5000; server.headersTimeout = 5000; server.keepAliveTimeout = 1000;
  return server;
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const port = Number(process.env.PORT || '8080');
    if (!Number.isSafeInteger(port) || port < 1 || port > 65535) throw new Error('Invalid port');
    const tls = process.env.TLS_CERT_FILE && process.env.TLS_KEY_FILE ? { cert: readFileSync(process.env.TLS_CERT_FILE), key: readFileSync(process.env.TLS_KEY_FILE) } : undefined;
    if (!tls && process.env.RECEIVER_TLS_AT_INGRESS !== 'true') throw new Error('Configure TLS or explicitly declare HTTPS ingress termination');
    const server = createReceiver({ adminKey: process.env.FOUNTAIN_RECEIVER_ADMIN_KEY, tls });
    server.listen(port, '0.0.0.0', () => console.log(`${RECEIVER_VERSION} listening`));
    const stop = () => { server.close(); server.closeAllConnections(); };
    process.on('SIGINT', stop); process.on('SIGTERM', stop);
  } catch { console.error('Receiver setup failed; configure admin credential, TLS and port'); process.exitCode = 2; }
}
