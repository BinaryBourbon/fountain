import { randomUUID, createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { ensure, phaseSignal, history, turnMetadata, waitFor, watchUntil } from '../lib/execution.mjs';
import { streamEvents } from '../lib/sse.mjs';
import { verifyReplay } from '../lib/replay.mjs';

const version = 'fountain-acp-fixture/1';
const source = new URL('../../apps/fountain/priv/deployed/acp-fixture.mjs', import.meta.url);
export async function deterministic(ctx) {
  const { client, fixtures, config, check } = ctx;
  const settings = config.fixture;
  const report = ctx.report.fixture = { version, runtime: 'fountain-fixture', model: 'fixture/deterministic-v1',
    sandbox_provider: settings.sandbox_provider, source_sha256: createHash('sha256').update(readFileSync(source)).digest('hex'),
    inference: false, turns: [] };
  let conversation, provision, sessionId, cursor, number = 0, first, second;
  const nonce = randomUUID();
  const artifact = n => `.fountain-acp-fixture/${sessionId}-${n}.txt`;
  const readFile = async (path, expected = 200) => {
    const { body } = await client.request('GET', `/api/sandboxes/${conversation.sandbox_id}/file?path=${encodeURIComponent(path)}&max_bytes=65536`, { expected });
    if (expected !== 200) return;
    ensure(!body.data.truncated, 'Fixture file was truncated');
    return body.data.encoding === 'base64' ? Buffer.from(body.data.content, 'base64') : Buffer.from(body.data.content);
  };
  if (!await check('fixture/setup', async () => {
    const { body } = await client.request('GET', '/api/auth/me', { key: config.secondaryKey, expected: 200 });
    ensure(body.email_verified && body.id !== ctx.report.owner_id, 'Fixture requires a distinct verified second tenant');
    const environment = await fixtures.create('environment');
    const agent = await fixtures.create('agent', { runtime: report.runtime, model: report.model,
      environment_id: environment.id, sandbox_provider: settings.sandbox_provider, sandbox_mode: 'ephemeral',
      permission_policy: { default: 'ask' } });
    conversation = await fixtures.create('conversation', { agent_id: agent.id, environment_id: environment.id });
    const signal = phaseSignal(ctx.signal, settings.provision_ms);
    provision = await watchUntil(client, conversation.id, signal, event => event.kind === 'stage' && event.stage === 'provision' && event.state === 'done');
    cursor = provision.cursor;
    const detail = await client.request('GET', `/api/conversations/${conversation.id}`, { expected: 200 });
    conversation = detail.body.data;
    ensure(conversation.sandbox?.status === 'ready' && conversation.sandbox.mode === 'ephemeral' &&
      conversation.sandbox.provider === settings.sandbox_provider, 'Fixture sandbox does not match requested provider/mode');
    ensure(createHash('sha256').update(await readFile('.fountain-acp-fixture.mjs')).digest('hex') === report.source_sha256,
      'Installed ACP fixture bytes differ from the pinned suite source');
    report.conversation_id = conversation.id;
    report.sandbox_id = conversation.sandbox_id;
  })) return;

  async function scenario(name, n, { answer, interrupt = false, expected = 'completed', delay = 0 } = {}) {
    const signal = phaseSignal(ctx.signal, settings.turn_ms);
    const prompt = JSON.stringify({ fixture: version, scenario: name, nonce: n, delay_ms: delay });
    fixtures.reserveTurn(conversation.id, settings.max_turns);
    number++;
    const response = await client.request('POST', `/api/conversations/${conversation.id}/prompts`, { body: { prompt }, expected: 200, signal });
    ensure(response.body.status === 'queued', 'Fixture prompt was not acknowledged');
    const events = [];
    let terminal, permissionAnswered = false, interrupted = false, observedRunning = false;
    for await (const frame of streamEvents(client, `/api/conversations/${conversation.id}/stream?blocks=true`, { signal, after: cursor })) {
      const event = frame.event;
      ensure(event.id > cursor, 'Fixture stream duplicated or reordered an event');
      cursor = event.id;
      events.push(frame);
      const blocks = event.blocks ?? [];
      if (blocks.some(b => b.kind === 'text' && b.body?.includes(`fixture:started:${name}:${n}`)) && (delay || interrupt)) {
        const running = await client.request('GET', `/api/conversations/${conversation.id}/turns`, { expected: 200, signal });
        ensure(running.body.data.some(t => t.turn_number === number && t.status === 'running'), 'Fixture output arrived after turn completion');
        observedRunning = true;
        if (interrupt && !interrupted) {
          await client.request('POST', `/api/conversations/${conversation.id}/interrupt`, { expected: 204, signal });
          interrupted = true;
        }
      }
      const permission = blocks.find(b => b.kind === 'permission_request');
      if (permission && !permissionAnswered) {
        ensure(answer && permission.options.some(o => o.optionId === answer), 'Fixture requested an unexpected permission');
        const path = `/api/conversations/${conversation.id}/requests/${encodeURIComponent(permission.request_id)}`;
        await client.request('POST', path, { key: config.secondaryKey, body: { option_id: answer }, expected: 404, signal });
        await client.request('POST', path, { body: { option_id: 'not-offered' }, expected: 422, signal });
        await client.request('POST', path, { body: { option_id: answer }, expected: 200, signal });
        permissionAnswered = true;
      }
      const meta = turnMetadata(event);
      if (meta?.turn_number === number && ['done', 'failed', 'interrupted'].includes(event.state)) { terminal = event; break; }
    }
    ensure(terminal?.state === { completed: 'done', failed: 'failed', interrupted: 'interrupted' }[expected], 'Fixture turn ended in an unexpected SSE state');
    ensure(!answer || permissionAnswered, 'Fixture never requested public permission');
    ensure(!interrupt || interrupted, 'Fixture was not interrupted through the public API');
    ensure(!(delay || interrupt) || observedRunning, 'Fixture did not prove incremental output while running');
    const turns = await waitFor(client, `/api/conversations/${conversation.id}/turns`, signal,
      rows => rows.some(t => t.turn_number === number && t.status === expected));
    ensure(turns.length === number && turns.every(t => t.status !== 'running'), 'Fixture left an extra or active turn');
    const turn = turns.find(t => t.turn_number === number);
    ensure(turn.prompt === prompt && turn.id === (turnMetadata(terminal)?.turn_id ?? terminal.turn_id), 'Fixture turn identity differs from accepted work');
    const detail = await client.request('GET', `/api/conversations/${conversation.id}`, { expected: 200, signal });
    if (sessionId) ensure(detail.body.data.runtime_session_id === sessionId, 'Fixture lost the persisted ACP session');
    else sessionId = detail.body.data.runtime_session_id;
    ensure(typeof sessionId === 'string', 'Fixture did not expose a runtime session');
    const stored = await history(client, conversation.id, signal);
    report.turns.push({ number, scenario: name, id: turn.id, status: turn.status, permission_answer: answer ?? null,
      observed_running: observedRunning, interrupted, session_id: sessionId });
    return { events, cursor, stored: stored.events };
  }
  if (!await check('fixture/artifact-and-incremental-output', async () => {
    first = await scenario('write', nonce, { delay: 1500 });
    ensure((await readFile(artifact(nonce))).toString() === `${nonce}\n`, 'Fixture artifact bytes differ');
  })) return;
  if (!await check('fixture/follow-up-and-replay', async () => {
    second = await scenario('read', nonce);
    ctx.report.streaming = { provision_cursor: provision.cursor, reconnect_cursor: first.cursor };
    await verifyReplay(ctx, conversation.id, first, second, phaseSignal(ctx.signal, settings.turn_ms));
  })) return;
  for (const answer of ['allow-once', 'reject-once']) {
    if (!await check(`fixture/permission-${answer}`, async () => {
      const n = randomUUID();
      await scenario('permission', n, { answer });
      if (answer === 'allow-once') ensure((await readFile(artifact(n))).toString() === `${n}\n`, 'Approved permission did not write the artifact');
      else await readFile(artifact(n), 404);
    })) return;
  }
  if (!await check('fixture/cancellation', async () => {
    const n = randomUUID();
    await scenario('wait', n, { interrupt: true, expected: 'interrupted' });
    await readFile(artifact(n), 404);
  })) return;
  if (!await check('fixture/explicit-failure', async () => {
    await scenario('fail', randomUUID(), { expected: 'failed' });
  })) return;
  await check('fixture/resume-after-failure', async () => {
    const last = await scenario('read', nonce);
    ensure((await readFile(artifact(nonce))).toString() === `${nonce}\n`, 'Resume lost the artifact');
    const text = last.events.flatMap(f => f.event.blocks ?? []).filter(b => b.kind === 'text').map(b => b.body ?? '').join('');
    ensure(text.includes(`writes=1:turns=${settings.max_turns}:`), 'Resume did not preserve fixture side-effect/turn accounting');
  });
}
