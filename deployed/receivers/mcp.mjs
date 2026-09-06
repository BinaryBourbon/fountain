#!/usr/bin/env node
// Bounded Streamable HTTP fixture. Synthetic bearer authentication is a suite
// test mode, not an implementation of MCP OAuth or Fountain conversation auth.
import { createServer as httpServer } from 'node:http';
import { createServer as httpsServer } from 'node:https';
import { randomUUID, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { fingerprint } from './secrets.mjs';

export const MCP_VERSION = 'fountain-mcp-receiver/1';
export const PROTOCOL_VERSION = '2025-03-26';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const equal = (a, b) => typeof a === 'string' && Buffer.byteLength(a) === Buffer.byteLength(b) && timingSafeEqual(Buffer.from(a), Buffer.from(b));
function reply(res, status, value, headers = {}) {
  res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', ...headers });
  res.end(value === undefined ? undefined : JSON.stringify(value));
}
async function readBody(req) {
  let bytes = 0; const parts = [];
  for await (const chunk of req) { bytes += chunk.length; if (bytes > 16384) throw new Error('Body limit'); parts.push(chunk); }
  return JSON.parse(Buffer.concat(parts).toString('utf8'));
}
export function mcpHandler({ adminKey, now = Date.now, ttlMs = 900000, maxRuns = 32 } = {}) {
  if (typeof adminKey !== 'string' || adminKey.length < 32 || !Number.isSafeInteger(ttlMs) || ttlMs < 1 || ttlMs > 900000 ||
    !Number.isSafeInteger(maxRuns) || maxRuns < 1 || maxRuns > 32) throw new Error('MCP receiver requires a strong admin key and bounded retention');
  const instanceId = randomUUID(), runs = new Map();
  return async (req, res) => {
    try {
      for (const [id, run] of runs) if (run.expires_at <= now()) runs.delete(id);
      // This machine-only receiver does not accept any browser origin.
      if (req.headers.origin !== undefined) return reply(res, 403, { error: 'origin_denied' });
      const url = new URL(req.url, 'http://receiver.invalid');
      if (url.search) return reply(res, 400, { error: 'query_denied' });
      if (req.method === 'GET' && url.pathname === '/_suite/identity') return reply(res, 200, { version: MCP_VERSION, instance_id: instanceId });
      const admin = url.pathname.match(/^\/_suite\/runs\/([^/]+)$/);
      if (admin) {
        if (!equal(req.headers.authorization, `Bearer ${adminKey}`)) return reply(res, 401, { error: 'unauthorized' });
        const id = admin[1];
        if (!uuid.test(id)) return reply(res, 400, { error: 'invalid_run' });
        if (req.method === 'DELETE') { runs.delete(id); return reply(res, 204); }
        if (req.method === 'PUT') {
          const spec = await readBody(req);
          if (!spec || Object.keys(spec).some(k => !['credential_sha256', 'nonces'].includes(k)) ||
            !/^[0-9a-f]{64}$/.test(spec.credential_sha256) || !Array.isArray(spec.nonces) || spec.nonces.length !== 2 ||
            !spec.nonces.every(n => uuid.test(n)) || spec.nonces[0] === spec.nonces[1]) return reply(res, 422, { error: 'invalid_spec' });
          if (runs.has(id)) return reply(res, 409, { error: 'run_exists' });
          if (runs.size >= maxRuns) return reply(res, 503, { error: 'capacity' });
          const run = { ...spec, expires_at: now() + ttlMs, sessions: new Map(), observations: [], requests: 0, calls: 0 };
          runs.set(id, run);
          return reply(res, 201, { id, version: MCP_VERSION, instance_id: instanceId, expires_at: run.expires_at });
        }
        const run = runs.get(id);
        if (req.method === 'GET') return run ? reply(res, 200, { id, version: MCP_VERSION, instance_id: instanceId,
          expires_at: run.expires_at, observations: run.observations }) : reply(res, 404, { error: 'not_found' });
        return reply(res, 405, { error: 'method' });
      }
      const match = url.pathname.match(/^\/mcp\/([^/]+)$/);
      const runId = match?.[1], run = uuid.test(runId) && runs.get(runId);
      if (!run) return reply(res, 404, { error: 'not_found' });
      if (++run.requests > 96) return reply(res, 429, { error: 'request_budget' });
      const record = (method, outcome, extra = {}) => {
        const row = { receipt_id: randomUUID(), at: now(), method, outcome, ...extra };
        run.observations.push(row); return row;
      };
      const token = req.headers.authorization?.match(/^Bearer (suite_mcp_[0-9a-f-]{36})$/)?.[1];
      if (!token || !equal(fingerprint(token), run.credential_sha256)) {
        record('http', 'unauthorized');
        return reply(res, 401, { error: 'unauthorized' });
      }
      if (req.method === 'GET') return reply(res, 405, { error: 'no_server_stream' }, { allow: 'POST, DELETE' });
      const sessionId = req.headers['mcp-session-id'];
      if (req.method === 'DELETE') {
        if (!run.sessions.delete(sessionId)) return reply(res, 404, { error: 'session_not_found' });
        return reply(res, 204);
      }
      if (req.method !== 'POST') return reply(res, 405, { error: 'method' });
      if (!req.headers.accept?.includes('application/json') || !req.headers.accept.includes('text/event-stream')) return reply(res, 406, { error: 'accept_required' });
      if (!req.headers['content-type']?.startsWith('application/json')) return reply(res, 415, { error: 'json_required' });
      const message = await readBody(req);
      if (!message || Array.isArray(message) || message.jsonrpc !== '2.0' || typeof message.method !== 'string' ||
        (Object.hasOwn(message, 'id') && !(typeof message.id === 'string' && message.id.length <= 128 || Number.isSafeInteger(message.id)))) return reply(res, 400, { error: 'invalid_rpc' });
      const respond = result => reply(res, 200, { jsonrpc: '2.0', id: message.id, result });
      const error = (code, text) => reply(res, 200, { jsonrpc: '2.0', id: message.id, error: { code, message: text } });
      if (message.method === 'initialize' && Object.hasOwn(message, 'id')) {
        if (run.sessions.size >= 8) return reply(res, 429, { error: 'session_budget' });
        if (typeof message.params?.protocolVersion !== 'string') return error(-32602, 'Protocol version required');
        const id = randomUUID(); run.sessions.set(id, { ready: false, discovered: false });
        record('initialize', 'accepted', { session_id: id, principal: runId });
        return reply(res, 200, { jsonrpc: '2.0', id: message.id, result: { protocolVersion: PROTOCOL_VERSION,
          capabilities: { tools: {} }, serverInfo: { name: MCP_VERSION, version: '1.0.0' } } }, { 'mcp-session-id': id });
      }
      const session = run.sessions.get(sessionId);
      if (!session) return reply(res, 404, { error: 'session_not_found' });
      if (!Object.hasOwn(message, 'id')) {
        if (message.method === 'notifications/initialized') {
          session.ready = true; record('notifications/initialized', 'accepted', { session_id: sessionId, principal: runId });
        }
        return reply(res, 202);
      }
      if (message.method === 'ping') return respond({});
      if (!session.ready) return error(-32600, 'Initialize notification required');
      if (message.method === 'tools/list') {
        session.discovered = true;
        record('tools/list', 'accepted', { session_id: sessionId, principal: runId });
        return respond({ tools: ['suite_nonce', 'suite_denied'].map(name => ({ name,
          description: name === 'suite_nonce' ? 'Return a receipt for the exact supplied suite nonce.' : 'Controlled negative test: always deny this tool and return a denial receipt.',
          inputSchema: { type: 'object', properties: { nonce: { type: 'string' } }, required: ['nonce'], additionalProperties: false } })) });
      }
      if (message.method !== 'tools/call') return error(-32601, 'Method not found');
      if (!session.discovered) {
        record('tools/call', 'discovery_required', { session_id: sessionId, principal: runId });
        return error(-32600, 'Discover tools first');
      }
      if (++run.calls > 8) return reply(res, 429, { error: 'tool_budget' });
      const { name, arguments: args } = message.params ?? {};
      if (!['suite_nonce', 'suite_denied'].includes(name)) {
        record('tools/call', 'unknown_tool', { session_id: sessionId, principal: runId });
        return error(-32602, 'Unknown tool');
      }
      if (!args || Object.keys(args).length !== 1 || !run.nonces.includes(args.nonce)) {
        record('tools/call', 'invalid_nonce', { session_id: sessionId, principal: runId, tool: name });
        return error(-32602, 'Invalid suite nonce');
      }
      const row = record('tools/call', name === 'suite_denied' ? 'denied' : 'accepted',
        { session_id: sessionId, principal: runId, tool: name, nonce: args.nonce });
      return respond({ isError: name === 'suite_denied', content: [{ type: 'text', text: JSON.stringify({
        receipt_id: row.receipt_id, nonce: args.nonce, principal: runId, outcome: row.outcome }) }] });
    } catch { if (!res.headersSent) reply(res, 400, { error: 'invalid_request' }); else res.end(); }
  };
}
export function createMcpReceiver(options) {
  const handler = mcpHandler(options), server = options.tls ? httpsServer(options.tls, handler) : httpServer(handler);
  server.requestTimeout = 5000; server.headersTimeout = 5000; server.keepAliveTimeout = 1000;
  return server;
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const port = Number(process.env.PORT || '8080');
    if (!Number.isSafeInteger(port) || port < 1 || port > 65535) throw new Error('Invalid port');
    const tls = process.env.TLS_CERT_FILE && process.env.TLS_KEY_FILE ? { cert: readFileSync(process.env.TLS_CERT_FILE), key: readFileSync(process.env.TLS_KEY_FILE) } : undefined;
    if (!tls && process.env.RECEIVER_TLS_AT_INGRESS !== 'true') throw new Error('TLS required');
    const server = createMcpReceiver({ adminKey: process.env.FOUNTAIN_MCP_ADMIN_KEY, tls });
    server.listen(port, '0.0.0.0', () => console.log(`${MCP_VERSION} listening`));
    const stop = () => { server.close(); server.closeAllConnections(); };
    process.on('SIGINT', stop); process.on('SIGTERM', stop);
  } catch { console.error('MCP receiver setup failed; configure admin credential, TLS and port'); process.exitCode = 2; }
}
