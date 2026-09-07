#!/usr/bin/env node
// Pinned, dependency-free ACP process for an explicitly enabled test deployment.
import { randomUUID } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync, renameSync, existsSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';

const VERSION = 'fountain-acp-fixture/1';
const MODEL = 'fixture/deterministic-v1';
const models = { currentModelId: MODEL, availableModels: [{ modelId: MODEL, name: 'Deterministic fixture v1' }] };
if (process.argv.includes('--version')) { console.log(VERSION); process.exit(0); }
const root = resolve(process.cwd(), '.fountain-acp-fixture');
mkdirSync(root, { recursive: true, mode: 0o700 });
const uuid = value => typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(value);
const requireThat = condition => { if (!condition) throw new Error('Invalid fixture request'); };
const send = message => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n');
const respond = (id, result) => send({ id, result });
const failure = (id, code, message) => send({ id, error: { code, message } });
let session, active, initialized = false, permissionCounter = 0;
const sessionPath = id => join(root, `${id}.json`);
const artifactPath = nonce => join(root, `${session.id}-${nonce}.txt`);
function persist() {
  const path = sessionPath(session.id);
  writeFileSync(`${path}.tmp`, JSON.stringify(session), { mode: 0o600 });
  renameSync(`${path}.tmp`, path);
}
const update = value => send({ method: 'session/update', params: { sessionId: session.id, update: value } });
const text = value => update({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: value } });
function tool(nonce, status, content) {
  update({ sessionUpdate: status === 'pending' ? 'tool_call' : 'tool_call_update', toolCallId: nonce,
    title: 'fixture-artifact', kind: 'edit', status,
    ...(content ? { content: [{ type: 'content', content: { type: 'text', text: content } }] } : {}) });
}
function finish(turn, result, error) {
  if (active !== turn) return;
  session.turns.at(-1).status = error ? 'failed' : result.stopReason;
  persist();
  active = null;
  turn.permission?.resolve(false);
  if (error) failure(turn.id, -32000, 'Scripted fixture failure');
  else respond(turn.id, result);
}
async function askPermission(turn, nonce) {
  const id = `fixture-permission-${++permissionCounter}`;
  const answer = new Promise(resolveAnswer => { turn.permission = { id, resolve: resolveAnswer }; });
  send({ id, method: 'session/request_permission', params: { sessionId: session.id,
    toolCall: { toolCallId: nonce, title: 'fixture-artifact', kind: 'edit', status: 'pending' },
    options: [{ optionId: 'allow-once', name: 'Allow once', kind: 'allow_once' },
      { optionId: 'reject-once', name: 'Reject once', kind: 'reject_once' }] } });
  return answer;
}
async function execute(turn, spec) {
  try {
    text(`fixture:started:${spec.scenario}:${spec.nonce}\n`);
    if (spec.delay_ms) await sleep(spec.delay_ms, undefined, { signal: turn.controller.signal });
    if (spec.scenario === 'fail') return finish(turn, null, true);
    if (spec.scenario === 'wait') {
      // The runner must cancel this turn; a bounded fallback makes a lost client visible.
      await sleep(120000, undefined, { signal: turn.controller.signal });
      return finish(turn, null, true);
    }
    const path = artifactPath(spec.nonce);
    if (spec.scenario === 'write' || spec.scenario === 'permission') {
      tool(spec.nonce, 'pending');
      if (spec.scenario === 'permission' && !await askPermission(turn, spec.nonce)) {
        if (active !== turn) return;
        text(`fixture:permission:denied:${spec.nonce}\n`);
        tool(spec.nonce, 'failed', 'Permission denied; no file written');
        return finish(turn, { stopReason: 'end_turn' });
      }
      turn.controller.signal.throwIfAborted();
      requireThat(!existsSync(path));
      writeFileSync(path, `${spec.nonce}\n`, { flag: 'wx', mode: 0o600 });
      session.artifacts[spec.nonce] = { writes: 1 };
      persist();
      tool(spec.nonce, 'completed', `Wrote ${path}`);
    } else {
      requireThat(session.artifacts[spec.nonce]?.writes === 1);
      tool(spec.nonce, 'pending');
      requireThat(readFileSync(path, 'utf8') === `${spec.nonce}\n`);
      tool(spec.nonce, 'completed', `Read ${path}`);
    }
    text(`fixture:artifact:${spec.nonce}:writes=1:turns=${session.turns.length}:path=${path}\n`);
    finish(turn, { stopReason: 'end_turn', usage: { inputTokens: 0, outputTokens: 0 } });
  } catch {
    if (active === turn) finish(turn, null, true);
  }
}
function dispatch(message) {
  const { id, method, params = {} } = message;
  if (method === undefined && id === active?.permission?.id) {
    const permission = active.permission;
    active.permission = null;
    const outcome = message.result?.outcome;
    permission.resolve(outcome?.outcome === 'selected' && outcome.optionId === 'allow-once');
    return;
  }
  if (method === 'initialize') {
    requireThat(!initialized && params.protocolVersion === 1 && id !== undefined);
    initialized = true;
    return respond(id, { protocolVersion: 1,
    agentInfo: { name: VERSION, version: '1' }, authMethods: [],
    agentCapabilities: { sessionCapabilities: { resume: {} } } });
  }
  requireThat(initialized);
  if (method === 'session/new') {
    requireThat(!active && !session);
    session = { version: VERSION, id: randomUUID(), turns: [], artifacts: {} };
    persist();
    return respond(id, { sessionId: session.id, models });
  }
  if (method === 'session/resume') {
    requireThat(!active && !session && uuid(params.sessionId));
    const stored = JSON.parse(readFileSync(sessionPath(params.sessionId), 'utf8'));
    requireThat(stored.version === VERSION && stored.id === params.sessionId);
    session = stored;
    return respond(id, { models });
  }
  if (method === 'session/set_model') {
    requireThat(session && params.sessionId === session.id && params.modelId === MODEL);
    return respond(id, {});
  }
  if (method === 'session/cancel') {
    if (active && params.sessionId === session.id) {
      const turn = active;
      turn.controller.abort();
      finish(turn, { stopReason: 'cancelled' });
    }
    return;
  }
  if (method === 'session/prompt') {
    requireThat(session && params.sessionId === session.id && !active && id !== undefined);
    requireThat(Array.isArray(params.prompt) && params.prompt.length === 1 && params.prompt[0].type === 'text');
    const spec = JSON.parse(params.prompt[0].text);
    requireThat(spec.fixture === VERSION && ['write', 'read', 'permission', 'wait', 'fail'].includes(spec.scenario) && uuid(spec.nonce));
    requireThat(Object.keys(spec).every(k => ['fixture', 'scenario', 'nonce', 'delay_ms'].includes(k)));
    requireThat(spec.delay_ms === undefined || (Number.isSafeInteger(spec.delay_ms) && spec.delay_ms >= 0 && spec.delay_ms <= 30000));
    requireThat(session.turns.length < 16);
    const turn = { id, controller: new AbortController(), permission: null };
    session.turns.push({ scenario: spec.scenario, nonce: spec.nonce, status: 'running' });
    persist();
    active = turn;
    void execute(turn, spec);
    return;
  }
  if (id !== undefined) failure(id, -32601, 'Unsupported fixture method');
}
let pending = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => {
  pending += chunk;
  while (pending.includes('\n')) {
    const newline = pending.indexOf('\n');
    const line = pending.slice(0, newline);
    pending = pending.slice(newline + 1);
    if (Buffer.byteLength(line) > 65536) { process.exitCode = 2; stop(); break; }
    let message;
    try { message = JSON.parse(line); requireThat(message?.jsonrpc === '2.0'); dispatch(message); }
    catch { failure(message?.id ?? null, -32602, 'Invalid fixture request'); }
  }
  if (Buffer.byteLength(pending) > 65536) { process.exitCode = 2; stop(); }
});
function stop() {
  if (active) { const turn = active; turn.controller.abort(); finish(turn, { stopReason: 'cancelled' }); }
  process.stdin.destroy();
}
process.stdin.on('end', stop);
process.on('SIGTERM', stop);
process.on('SIGINT', stop);
