import { randomUUID, createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import { setTimeout as sleep } from 'node:timers/promises';
import { RecoveryDeployment } from '../adapters/recovery-kubernetes.mjs';
import { recoveryRelay, restoreRecoveryControls } from '../lib/recovery.mjs';
import { ensure, phaseSignal, history, watchUntil, waitFor, turnMetadata } from '../lib/execution.mjs';
import { compareEvents } from '../lib/replay.mjs';
import { streamEvents } from '../lib/sse.mjs';

const version = 'fountain-acp-fixture/1';
const source = new URL('../../apps/fountain/priv/deployed/acp-fixture.mjs', import.meta.url);
export function verifyRecoveryTurns(rows, accepted, status) {
  ensure(rows.length === accepted.length, 'Recovery created or lost an accepted turn');
  for (const [i, expected] of accepted.entries()) {
    const row = rows.find(t => t.turn_number === i + 1);
    ensure(row?.id === expected.id && row.prompt === expected.prompt &&
      row.status === (i === accepted.length - 1 ? status : 'completed'), 'Recovery changed turn identity, prompt or outcome');
  }
}
export function verifyRecoveryState(state, sessionId, accepted, completed) {
  ensure(state.version === version && state.id === sessionId && state.turns.length === accepted.length,
    'Fixture session or accepted prompt count changed');
  const written = accepted.filter((a, i) => a.scenario !== 'read' && i < completed).map(a => a.nonce).sort();
  ensure(isDeepStrictEqual(Object.keys(state.artifacts).sort(), written), 'Fixture artifact accounting changed');
  for (const nonce of written) ensure(state.artifacts[nonce].writes === 1, 'Fixture repeated a side effect');
  for (const [i, expected] of accepted.entries()) ensure(state.turns[i].nonce === expected.nonce &&
    state.turns[i].scenario === expected.scenario && state.turns[i].status === (i < completed ? 'end_turn' : 'running'),
  'Fixture lost or duplicated a prompt across recovery');
}
export function recoveredAttachment(events, turnId) {
  for (const event of events) {
    if (event.stage === 'turn' && ['failed', 'interrupted', 'done'].includes(event.state) && turnMetadata(event)?.turn_id === turnId) {
      throw new Error(`Recovery turn ended before permission was answered: ${event.state} (${JSON.parse(event.data).reason ?? 'no reason'})`);
    }
  }
  return events.find(e => e.stage === 'reattach' && e.state === 'done' && JSON.parse(e.data).outcome === 'session_attached');
}
export function verifyRecoveryTranscript(events, accepted) {
  const starts = events.flatMap(event => (event.blocks ?? []).filter(b => b.kind === 'text' && b.body?.includes('fixture:started:'))
    .map(block => ({ turn_id: event.turn_id, body: block.body })));
  for (const turn of accepted) {
    const own = starts.filter(item => item.turn_id === turn.id);
    ensure(own.length === 1 && own[0].body === `fixture:started:${turn.scenario}:${turn.nonce}\n`,
      'Recovery duplicated or misattributed a fixture turn in the transcript');
  }
}

export async function recovery(ctx, dependencies = {}) {
  const { config, client, fixtures, check } = ctx, settings = config.recovery;
  const report = ctx.report.recovery = { runtime: 'fountain-fixture', model: 'fixture/deterministic-v1',
    provider: 'runner', backend: { configured: 'process', public_api_exposes_backend: false }, mode: 'persistent', inference: false, turns: [], boundaries: [],
    source_sha256: createHash('sha256').update(readFileSync(source)).digest('hex'),
    unsupported: [
      { scenario: 'runner daemon termination', reason: 'Process sessions belong to the daemon and terminate with it', issue: 1617 },
      { scenario: 'hosted providers and Firecracker recovery', reason: 'This profile requires a dedicated process runner; provider-specific recovery remains unverified', issue: 1617 },
    ] };
  const control = dependencies.control ?? new RecoveryDeployment(settings.deployment, resolve(ctx.out, 'recovery.json'));
  const relay = dependencies.relay ?? recoveryRelay(ctx, ctx.out, ctx.report.run_id);
  ctx.beforeCleanup.push(() => (dependencies.restore ?? restoreRecoveryControls)(ctx, ctx.out, ctx.report.run_id));
  let conversation, sessionId, cursor = 0;
  const accepted = [];
  const detail = async signal => (await client.request('GET', `/api/conversations/${conversation.id}`, { expected: 200, signal })).body.data;
  const turns = async signal => (await client.request('GET', `/api/conversations/${conversation.id}/turns`, { expected: 200, signal })).body.data;
  const file = async (path, signal) => {
    const { body } = await client.request('GET', `/api/sandboxes/${conversation.sandbox_id}/file?path=${encodeURIComponent(path)}&max_bytes=65536`, { expected: 200, signal });
    ensure(!body.data.truncated, 'Recovery artifact was truncated');
    return body.data.encoding === 'base64' ? Buffer.from(body.data.content, 'base64') : Buffer.from(body.data.content);
  };
  const runner = async (online, signal) => {
    const rows = await waitFor(client, '/api/runners', signal, rows => rows.some(r => r.id === settings.runner_id && r.online === online));
    const row = rows.find(r => r.id === settings.runner_id);
    ensure(row.name === settings.relay.runner_name && rows.filter(r => r.online).every(r => r.id === row.id),
      'Runner identity changed or another runner could receive the fixture');
    return { id: row.id, name: row.name, online: row.online, connected_at: row.connected_at, version: row.version };
  };
  const identity = async signal => {
    const current = await detail(signal);
    ensure(current.sandbox_id === conversation.sandbox_id && current.sandbox?.mode === 'persistent' &&
      current.sandbox.provider === 'runner' && current.sandbox.runner?.id === settings.runner_id &&
      current.agent_id === conversation.agent_id && current.environment_id === conversation.environment_id &&
      current.channel_id === conversation.channel_id, 'Recovery changed public conversation or home ownership');
    if (sessionId) ensure(current.runtime_session_id === sessionId, 'Recovery changed the persisted runtime session');
    else { sessionId = current.runtime_session_id; ensure(typeof sessionId === 'string', 'Runtime session is missing'); }
    return current;
  };
  const accounting = async (completed, signal) => {
    await identity(signal);
    const state = JSON.parse((await file(`.fountain-acp-fixture/${sessionId}.json`, signal)).toString());
    verifyRecoveryState(state, sessionId, accepted, completed);
    verifyRecoveryTranscript((await history(client, conversation.id, signal)).events, accepted);
    for (const item of accepted.slice(0, completed).filter(a => a.scenario !== 'read')) {
      ensure((await file(`.fountain-acp-fixture/${sessionId}-${item.nonce}.txt`, signal)).toString() === `${item.nonce}\n`, 'Recovery lost or changed artifact bytes');
    }
    return { session_id: sessionId, accepted_prompts: state.turns.length, artifacts: state.artifacts };
  };
  async function submit(scenario, nonce, signal) {
    const prompt = JSON.stringify({ fixture: version, scenario, nonce });
    fixtures.reserveTurn(conversation.id, 4);
    const queued = await client.request('POST', `/api/conversations/${conversation.id}/prompts`, { body: { prompt }, expected: 200, signal });
    ensure(queued.body.status === 'queued', 'Recovery prompt was not acknowledged');
    const rows = await waitFor(client, `/api/conversations/${conversation.id}/turns`, signal,
      rows => rows.some(t => t.turn_number === accepted.length + 1));
    const row = rows.find(t => t.turn_number === accepted.length + 1);
    accepted.push({ id: row.id, prompt, scenario, nonce });
    ensure(row.prompt === prompt && rows.length === accepted.length, 'Recovery prompt created unexpected work');
    return accepted.at(-1);
  }
  async function completed(signal) {
    const done = await watchUntil(client, conversation.id, signal, e => e.state === 'done' &&
      turnMetadata(e)?.turn_id === accepted.at(-1).id, { after: cursor });
    cursor = done.cursor;
    const rows = await waitFor(client, `/api/conversations/${conversation.id}/turns`, signal,
      rows => rows.find(t => t.id === accepted.at(-1).id)?.status === 'completed');
    verifyRecoveryTurns(rows, accepted, 'completed');
    report.turns.push({ ...accepted.at(-1), number: accepted.length, status: 'completed',
      accounting: await accounting(accepted.length, signal) });
  }
  async function replay(before, afterCursor, signal) {
    const stored = (await history(client, conversation.id, signal)).events;
    ensure(isDeepStrictEqual(stored.filter(e => e.id <= before.at(-1).id), before), 'Recovery rewrote or lost the durable history prefix');
    const full = [], resumed = [];
    for await (const { event } of streamEvents(client, `/api/conversations/${conversation.id}/stream?blocks=true&wait=false`, { signal })) full.push(event);
    for await (const { event } of streamEvents(client, `/api/conversations/${conversation.id}/stream?blocks=true&wait=false`, { signal, after: afterCursor })) resumed.push(event);
    return { before_cursor: afterCursor, through: cursor,
      full_events: compareEvents(full, stored, { through: cursor }),
      resumed_events: compareEvents(resumed, stored, { after: afterCursor, through: cursor }) };
  }
  async function barrier(name, disrupt) {
    const signal = phaseSignal(ctx.signal, settings.turn_ms), nonce = randomUUID();
    await submit('permission', nonce, signal);
    let permission;
    const held = await watchUntil(client, conversation.id, signal, event => {
      permission = event.blocks?.find(b => b.kind === 'permission_request'); return Boolean(permission);
    }, { after: cursor });
    cursor = held.cursor;
    ensure(permission.options.some(o => o.optionId === 'allow-once'), 'Recovery permission does not offer allow-once');
    verifyRecoveryTurns(await turns(signal), accepted, 'running');
    await accounting(accepted.length - 1, signal);
    const requests = await waitFor(client, `/api/conversations/${conversation.id}/events?after=${cursor}&blocks=true&limit=100`, signal,
      rows => rows.some(e => e.stage === 'request' && e.state === 'started' && JSON.parse(e.data).request_id === permission.request_id));
    const request = requests.find(e => e.stage === 'request' && e.state === 'started' && JSON.parse(e.data).request_id === permission.request_id);
    const permissionTimeout = JSON.parse(request.data).timeout_ms;
    const requiredHold = name === 'deployment' ? settings.deployment.timeout_ms + 30000 : settings.relay.disconnect_ms + 60000;
    ensure(Number.isInteger(permissionTimeout) && permissionTimeout >= requiredHold, 'Permission timeout cannot cover the configured recovery window');
    const before = (await history(client, conversation.id, signal)).events, afterCursor = cursor;
    const boundary = { name, turn_id: accepted.at(-1).id, nonce, session_id: sessionId, cursor, permission_id: permission.request_id,
      permission_timeout_ms: permissionTimeout };
    report.boundaries.push(boundary);
    ctx.persist?.();
    await disrupt(boundary, signal);
    verifyRecoveryTurns(await turns(signal), accepted, 'running');
    await accounting(accepted.length - 1, signal);
    const path = `/api/conversations/${conversation.id}/requests/${encodeURIComponent(permission.request_id)}`;
    await client.request('POST', path, { key: config.secondaryKey, expected: 404, body: { option_id: 'allow-once' }, signal });
    await client.request('POST', path, { expected: 200, body: { option_id: 'allow-once' }, signal });
    await completed(signal);
    boundary.replay = await replay(before, afterCursor, signal);
  }
  if (!await check('recovery/setup', async () => {
    const other = (await client.request('GET', '/api/auth/me', { expected: 200, key: config.secondaryKey })).body;
    ensure(other.email_verified && other.id !== ctx.report.owner_id, 'Recovery requires a distinct verified second tenant');
    report.runner_before = await runner(true, phaseSignal(ctx.signal, 10000));
    const identity = await relay.verify();
    ensure(identity.upstream === config.base_url && identity.runner_name === settings.relay.runner_name, 'Relay is bound to a different target or runner');
    report.before = await control.prepare(ctx.report.run_id, ctx.signal);
    const environment = await fixtures.create('environment');
    const agent = await fixtures.create('agent', { runtime: report.runtime, model: report.model, environment_id: environment.id,
      sandbox_provider: 'runner', sandbox_mode: 'persistent', permission_policy: { default: 'ask' } });
    conversation = await fixtures.create('conversation', { agent_id: agent.id, environment_id: environment.id, sandbox_mode: 'persistent' });
    const signal = phaseSignal(ctx.signal, settings.provision_ms);
    cursor = (await watchUntil(client, conversation.id, signal, e => e.stage === 'provision' && e.state === 'done')).cursor;
    conversation = await detail(signal);
    ensure(conversation.sandbox?.status === 'ready' && conversation.sandbox.runner?.id === settings.runner_id, 'Fixture provisioned on a different runner');
    ensure(createHash('sha256').update(await file('.fountain-acp-fixture.mjs', signal)).digest('hex') === report.source_sha256, 'Installed fixture differs from suite source');
    report.conversation_id = conversation.id; report.sandbox_id = conversation.sandbox_id;
  })) return;
  const baseline = randomUUID();
  if (!await check('recovery/baseline', async () => {
    const signal = phaseSignal(ctx.signal, settings.turn_ms);
    await submit('write', baseline, signal); await completed(signal);
  })) return;
  if (!await check('recovery/deployment-turn', () => barrier('deployment', async (boundary, signal) => {
    report.after = await control.roll(signal);
    report.runner_after_roll = await runner(true, signal);
    const events = await waitFor(client, `/api/conversations/${conversation.id}/events?after=${boundary.cursor}&blocks=true&limit=100`, signal,
      rows => Boolean(recoveredAttachment(rows, boundary.turn_id)));
    const attached = recoveredAttachment(events, boundary.turn_id);
    const meta = JSON.parse(attached.data);
    ensure(meta.turn_id === boundary.turn_id && typeof meta.session_id === 'string', 'Deployment attached a different active turn');
    boundary.reattach = { event_id: attached.id, ...meta };
  }))) return;
  if (!await check('recovery/runner-turn', () => barrier('runner_connection', async (boundary, signal) => {
    await relay.create({ disconnect_ms: settings.relay.disconnect_ms });
    boundary.offline = await runner(false, signal);
    boundary.online = await runner(true, signal);
    const result = await relay.client.request('GET', `/_suite/runs/${ctx.report.run_id}`, { expected: 200, signal });
    relay.assertIdentity(result.body);
    ensure(!result.body.blocked && !result.body.overflow && result.body.active_connections === 1 &&
      result.body.observations.some(o => o.outcome === 'disconnected' && o.connections === 1) &&
      result.body.observations.some(o => o.outcome === 'connected'), 'Relay did not prove the bounded disconnection and reconnect');
    boundary.relay = result.body;
    await relay.cleanup(signal);
  }))) return;
  await check('recovery/persistent-home-wake', async () => {
    const before = (await history(client, conversation.id, ctx.signal)).events, afterCursor = cursor;
    const signal = phaseSignal(ctx.signal, settings.idle_wait_ms);
    let parked;
    while (true) {
      parked = await identity(signal);
      if (parked.sandbox.status === 'suspended') break;
      ensure(parked.sandbox.status === 'ready', 'Persistent home ended instead of parking');
      await sleep(1000, undefined, { signal });
    }
    report.parked = { sandbox_id: parked.sandbox_id, status: parked.sandbox.status, at: new Date().toISOString() };
    const wakeSignal = phaseSignal(ctx.signal, settings.turn_ms);
    await submit('read', baseline, wakeSignal); await completed(wakeSignal);
    const awake = await identity(wakeSignal);
    ensure(awake.sandbox.status === 'ready', 'Persistent home did not wake');
    report.wake = { sandbox_id: awake.sandbox_id, session_id: sessionId, replay: await replay(before, afterCursor, wakeSignal) };
    const sandboxes = (await client.request('GET', '/api/sandboxes', { expected: 200, signal: wakeSignal })).body.data;
    ensure(sandboxes.filter(s => s.agent_id === conversation.agent_id && !['terminated', 'failed'].includes(s.status)).length === 1,
      'Recovery left additional live homes for the fixture agent');
  });
}
