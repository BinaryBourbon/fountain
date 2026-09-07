import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { EventEmitter, once } from 'node:events';

const executable = fileURLToPath(new URL('../../apps/fountain/priv/deployed/acp-fixture.mjs', import.meta.url));
const version = 'fountain-acp-fixture/1';
async function processFixture(t, existingRoot) {
  const root = existingRoot ?? mkdtempSync(join(tmpdir(), 'fountain-acp-process-'));
  const child = spawn(process.execPath, [executable], { cwd: root, stdio: ['pipe', 'pipe', 'pipe'] });
  const events = new EventEmitter();
  const frames = [];
  let pending = '', errors = '', nextId = 0;
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', chunk => {
    pending += chunk;
    while (pending.includes('\n')) {
      const at = pending.indexOf('\n');
      frames.push(JSON.parse(pending.slice(0, at)));
      pending = pending.slice(at + 1);
      events.emit('frame');
    }
  });
  child.stderr.on('data', chunk => { errors += chunk; });
  child.on('exit', () => events.emit('frame'));
  async function waitFor(match) {
    const signal = AbortSignal.timeout(3000);
    while (true) {
      const found = frames.find(match);
      if (found) return found;
      if (child.exitCode !== null) throw new Error(`Fixture exited ${child.exitCode}: ${errors}`);
      await once(events, 'frame', { signal });
    }
  }
  function send(value) { child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...value }) + '\n'); }
  function request(method, params = {}) {
    const id = ++nextId;
    send({ id, method, params });
    return { id, response: waitFor(frame => frame.id === id) };
  }
  async function stop() {
    if (child.exitCode === null && child.signalCode === null) { const exited = once(child, 'exit'); child.stdin.end(); await exited; }
  }
  t.after(async () => { await stop(); if (!existingRoot) rmSync(root, { recursive: true, force: true }); });
  const initialized = await request('initialize', { protocolVersion: 1 }).response;
  assert.ok(initialized.result.agentCapabilities.sessionCapabilities.resume);
  const prompt = (sessionId, scenario, nonce = randomUUID(), extra = {}) => ({ nonce,
    ...request('session/prompt', { sessionId, prompt: [{ type: 'text', text: JSON.stringify({ fixture: version, scenario, nonce, ...extra }) }] }) });
  return { root, child, frames, waitFor, send, request, prompt, stop,
    artifact: (sessionId, nonce) => join(root, '.fountain-acp-fixture', `${sessionId}-${nonce}.txt`),
    state: sessionId => JSON.parse(readFileSync(join(root, '.fountain-acp-fixture', `${sessionId}.json`), 'utf8')) };
}
const newSession = async f => (await f.request('session/new', { cwd: f.root }).response).result.sessionId;

test('real ACP process emits incremental output, writes real bytes, follows up and resumes in a new process', async t => {
  const f = await processFixture(t);
  const session = await newSession(f);
  const first = f.prompt(session, 'write', randomUUID(), { delay_ms: 150 });
  await f.waitFor(frame => frame.params?.update?.content?.text?.startsWith('fixture:started:'));
  assert.ok(!f.frames.some(frame => frame.id === first.id));
  assert.equal((await first.response).result.stopReason, 'end_turn');
  assert.equal(readFileSync(f.artifact(session, first.nonce), 'utf8'), `${first.nonce}\n`);
  assert.ok(f.frames.some(frame => frame.params?.update?.sessionUpdate === 'tool_call'));
  assert.ok(f.frames.some(frame => frame.params?.update?.status === 'completed'));
  assert.equal((await f.prompt(session, 'read', first.nonce).response).result.stopReason, 'end_turn');
  await f.stop();
  const resumed = await processFixture(t, f.root);
  assert.equal((await resumed.request('session/resume', { sessionId: session }).response).result.models.currentModelId, 'fixture/deterministic-v1');
  assert.equal((await resumed.prompt(session, 'read', first.nonce).response).result.stopReason, 'end_turn');
  assert.equal(resumed.state(session).turns.length, 3);
  assert.equal(resumed.state(session).artifacts[first.nonce].writes, 1);
  await resumed.stop();
});

test('permission blocks the actual write until approved, and denial leaves no artifact', async t => {
  const f = await processFixture(t);
  const session = await newSession(f);
  for (const optionId of ['allow-once', 'reject-once']) {
    const turn = f.prompt(session, 'permission');
    const request = await f.waitFor(frame => frame.method === 'session/request_permission' && frame.params.toolCall.toolCallId === turn.nonce);
    assert.equal(existsSync(f.artifact(session, turn.nonce)), false);
    assert.ok(!f.frames.some(frame => frame.id === turn.id));
    f.send({ id: request.id, result: { outcome: { outcome: 'selected', optionId } } });
    assert.equal((await turn.response).result.stopReason, 'end_turn');
    assert.equal(existsSync(f.artifact(session, turn.nonce)), optionId === 'allow-once');
  }
});

test('cancellation answers exactly once and a late permission answer cannot produce a side effect', async t => {
  const f = await processFixture(t);
  const session = await newSession(f);
  const turn = f.prompt(session, 'permission');
  const permission = await f.waitFor(frame => frame.method === 'session/request_permission');
  f.send({ method: 'session/cancel', params: { sessionId: session } });
  assert.equal((await turn.response).result.stopReason, 'cancelled');
  f.send({ id: permission.id, result: { outcome: { outcome: 'selected', optionId: 'allow-once' } } });
  const next = f.prompt(session, 'write');
  assert.equal((await next.response).result.stopReason, 'end_turn');
  assert.equal(f.frames.filter(frame => frame.id === turn.id).length, 1);
  assert.equal(existsSync(f.artifact(session, turn.nonce)), false);
  assert.deepEqual(f.state(session).turns.map(t => t.status), ['cancelled', 'end_turn']);
});

test('delayed work and long-running work cancel promptly, then explicit failure remains distinguishable', async t => {
  const f = await processFixture(t);
  const session = await newSession(f);
  for (const scenario of ['write', 'wait']) {
    const turn = f.prompt(session, scenario, randomUUID(), { delay_ms: 30000 });
    await f.waitFor(frame => frame.params?.update?.content?.text?.includes(turn.nonce));
    f.send({ method: 'session/cancel', params: { sessionId: session } });
    assert.equal((await turn.response).result.stopReason, 'cancelled');
    assert.equal(existsSync(f.artifact(session, turn.nonce)), false);
  }
  const failed = f.prompt(session, 'fail');
  assert.equal((await failed.response).error.code, -32000);
  assert.equal(f.state(session).turns.at(-1).status, 'failed');
  assert.equal((await f.prompt(session, 'write').response).result.stopReason, 'end_turn');
});

test('fixture rejects arbitrary paths, excessive delay, duplicate writes, and concurrent prompts', async t => {
  const f = await processFixture(t);
  const session = await newSession(f);
  assert.equal((await f.prompt(session, 'write', '../../secret').response).error.code, -32602);
  assert.equal((await f.prompt(session, 'write', randomUUID(), { delay_ms: 30001 }).response).error.code, -32602);
  assert.equal((await f.prompt(session, 'write', randomUUID(), { command: 'anything' }).response).error.code, -32602);
  const first = f.prompt(session, 'write');
  await first.response;
  assert.equal((await f.prompt(session, 'write', first.nonce).response).error.code, -32000);
  assert.equal(f.state(session).artifacts[first.nonce].writes, 1);
  const waiting = f.prompt(session, 'wait');
  await f.waitFor(frame => frame.params?.update?.content?.text?.includes(waiting.nonce));
  assert.equal((await f.prompt(session, 'write').response).error.code, -32602);
  f.send({ method: 'session/cancel', params: { sessionId: session } });
  await waiting.response;
});

test('oversized unterminated input exits instead of retaining an active turn', async t => {
  const f = await processFixture(t);
  const session = await newSession(f);
  const turn = f.prompt(session, 'wait');
  await f.waitFor(frame => frame.params?.update?.content?.text?.includes(turn.nonce));
  const exited = once(f.child, 'exit', { signal: AbortSignal.timeout(3000) });
  f.child.stdin.write('x'.repeat(65537));
  assert.equal((await turn.response).result.stopReason, 'cancelled');
  assert.equal((await exited)[0], 2);
});
