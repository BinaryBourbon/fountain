import { randomUUID } from 'node:crypto';
import { setTimeout as sleep } from 'node:timers/promises';
import { ensure, phaseSignal, watchUntil, waitFor, history, turnMetadata } from '../lib/execution.mjs';
import { scheduleTime, createSchedule, armSchedule, readSchedule, disableSchedule, discoverScheduledConversations } from '../lib/scheduled-fixtures.mjs';

export function verifyFiredSchedule(source, row, conversationId, startMs) {
  ensure(row.id === source.id && row.agent_id === source.agent_id && row.name === source.name && row.cron === source.cron &&
    row.prompt === source.prompt && row.one_off === true && row.enabled === false && row.last_error === null && row.last_conversation_id === conversationId,
  'Scheduled firing identity, configuration or outcome differs');
  const at = Date.parse(row.last_run_at), due = Date.parse(source.due_at);
  ensure(Number.isFinite(at) && at >= due && at <= due + startMs && Date.parse(row.next_run_at) > due + 86400000,
    'Schedule did not fire within its UTC window or failed to advance past this date');
}
export function verifyScheduledTurn(turns, events, prompt, nonce, startedId) {
  ensure(turns.length === 1 && turns[0].turn_number === 1 && turns[0].status === 'completed' && turns[0].prompt === prompt &&
    turns[0].id === startedId && [0, null].includes(turns[0].exit_code), 'Scheduled conversation did not complete exactly the authorized turn');
  const blocks = events.filter(e => e.turn_id === startedId).flatMap(e => e.blocks ?? []);
  const uses = blocks.filter(b => b.kind === 'tool_use');
  ensure(uses.some(use => blocks.some(b => b.kind === 'tool_result' && b.tool_id === use.id && !b.error && b.body?.includes(nonce))),
    'Scheduled turn has no paired durable tool result containing the nonce');
  return { id: startedId, number: 1, status: turns[0].status, usage: turns[0].usage ?? null, tools: uses.map(b => b.name) };
}
export async function schedules(ctx) {
  const { config, report, fixtures, client, check } = ctx;
  report.schedules = { required: { schedule_api: 'required', timed_execution: 'required', bounded_duplicates: 'required' },
    semantics: 'date-specific annual UTC cron; fresh conversation per firing; disabled on first observed conversation', observations: [] };
  report.execution = { runtime: config.execution.runtime, model: config.execution.model, sandbox_provider: config.execution.sandbox_provider,
    sandbox_mode: 'ephemeral', turns: [] };
  let agent, environment, conversation, completion, fired;
  ctx.beforeCleanup.push(async () => {
    if (!fixtures.manifest.schedule?.id) return;
    try { report.schedules.final_record = await readSchedule(fixtures, AbortSignal.timeout(10000)); }
    catch (error) { report.schedules.final_record_error = ctx.redactor.text(error.message); }
  });
  const file = `fountain-schedule-${report.run_id}.txt`, nonce = randomUUID();
  const prompt = `Use a shell tool once to write exactly ${nonce} followed by one newline into the relative file ${file}, then read the file with that tool to verify it. Do nothing else. Do not start background work, create schedules, spawn agents or access the network.`;
  if (!await check('schedules/setup', async () => {
    const { body } = await client.request('GET', '/api/auth/me', { key: config.secondaryKey, expected: 200 });
    ensure(body.email_verified && body.id !== report.owner_id, 'Schedules require a distinct verified second tenant');
    const listed = await client.request('GET', '/api/team/schedules', { expected: 200 });
    ensure(Array.isArray(listed.body.data), 'Schedule capability listing is absent');
    report.schedules.required.schedule_api = 'passed';
  })) { report.status = 'setup_failed'; report.schedules.failure_category = 'schedule_api_or_identity'; return; }
  if (!await check('schedules/disabled-fixture', async () => {
    environment = await fixtures.create('environment');
    agent = await fixtures.create('agent', { environment_id: environment.id, runtime: config.execution.runtime, model: config.execution.model,
      sandbox_provider: config.execution.sandbox_provider, sandbox_mode: 'ephemeral', permission_policy: { default: 'auto_allow' },
      system: 'Perform only the supplied tiny nonce file task with a shell tool. Do not access the network, spawn agents or start background work.' });
    const timing = scheduleTime();
    const row = await createSchedule(fixtures, { agentId: agent.id, environmentId: environment.id, prompt, ...timing });
    report.schedules.schedule_id = row.id; report.schedules.due_at = timing.due_at; report.schedules.cron = timing.cron;
    ensure((await discoverScheduledConversations(fixtures, ctx.signal)).length === 0 && row.last_run_at === null && row.last_conversation_id === null, 'Disabled schedule unexpectedly ran');
    const path = `/api/team/${agent.id}/schedules/${row.id}`;
    for (const method of ['GET', 'PATCH', 'DELETE']) await client.request(method, path, { key: config.secondaryKey, expected: 404,
      ...(method === 'PATCH' ? { body: { enabled: true } } : {}) });
  })) { report.schedules.failure_category = 'fixture_configuration'; return; }
  if (!await check('schedules/timed-firing', async () => {
    await armSchedule(fixtures);
    const source = fixtures.manifest.schedule;
    const signal = phaseSignal(ctx.signal, Math.max(1, Date.parse(source.due_at) - Date.now() + config.schedules.start_ms));
    while (true) {
      signal.throwIfAborted();
      const rows = await discoverScheduledConversations(fixtures, signal);
      const row = await readSchedule(fixtures, signal);
      if (rows.length > 0) {
        await disableSchedule(fixtures, signal); // Stop recurrence before verifying or waiting for completion.
        ensure(rows.length === 1, 'Schedule created additional conversations');
        conversation = rows[0]; break;
      }
      ensure(!row.last_error && row.last_run_at === null, 'Scheduler recorded a failed firing; see public schedule evidence');
      await sleep(1000, undefined, { signal });
    }
    while (true) {
      fired = await readSchedule(fixtures, signal);
      if (fired.last_conversation_id) break;
      await sleep(250, undefined, { signal });
    }
    verifyFiredSchedule(source, fired, conversation.id, config.schedules.start_ms);
    report.schedules.firing = fired;
    report.execution.conversation_id = conversation.id;
    const { body } = await client.request('GET', `/api/conversations/${conversation.id}`, { expected: 200, signal });
    conversation = body.data;
    ensure(conversation.runtime === config.execution.runtime && conversation.sandbox?.provider === config.execution.sandbox_provider && conversation.sandbox.mode === 'ephemeral' &&
      conversation.sandbox.environment_id === environment.id && conversation.environment_id === null && conversation.channel_id === null && conversation.vault_id === null,
    'Scheduled conversation did not inherit the recorded agent defaults');
    report.execution.sandbox_id = conversation.sandbox_id;
  })) { report.schedules.failure_category = 'scheduler_or_dispatch'; return; }
  if (!await check('schedules/completion-and-artifact', async () => {
    const signal = phaseSignal(ctx.signal, config.execution.provision_ms + config.execution.turn_ms);
    let startedId;
    completion = await watchUntil(client, conversation.id, signal, event => {
      const meta = turnMetadata(event);
      if (meta?.turn_number !== 1) return false;
      if (event.state === 'started') startedId = meta.turn_id ?? event.turn_id;
      return event.state === 'done';
    });
    const turns = await waitFor(client, `/api/conversations/${conversation.id}/turns`, signal, rows => rows.some(t => t.status === 'completed'));
    const stored = await history(client, conversation.id, signal);
    const turn = verifyScheduledTurn(turns, stored.events, prompt, nonce, startedId);
    report.execution.turns.push(turn);
    const response = await client.request('GET', `/api/sandboxes/${conversation.sandbox_id}/file?path=${file}&max_bytes=1024`, { expected: 200, signal });
    const value = response.body.data;
    const contents = value.encoding === 'base64' ? Buffer.from(value.content, 'base64').toString('utf8') : value.content;
    ensure(value.truncated === false && contents === nonce + '\n', 'Scheduled artifact differs from the authorized nonce');
    report.schedules.artifact = { path: file, verified: true };
    report.schedules.required.timed_execution = 'passed';
    await client.request('GET', `/api/conversations/${conversation.id}`, { key: config.secondaryKey, expected: 404 });
    await client.request('GET', `/api/sandboxes/${conversation.sandbox_id}/file?path=${file}`, { key: config.secondaryKey, expected: 404 });
  })) { report.schedules.failure_category = 'provision_or_turn'; return; }
  await check('schedules/no-additional-executions', async () => {
    const started = Date.now(), deadline = started + config.schedules.observe_ms;
    do {
      const rows = await discoverScheduledConversations(fixtures, ctx.signal);
      ensure(rows.length === 1 && rows[0].id === conversation.id && rows[0].turn_count === 1, 'Schedule produced additional execution during the observation window');
      const row = await readSchedule(fixtures, ctx.signal);
      verifyFiredSchedule(fixtures.manifest.schedule, row, conversation.id, config.schedules.start_ms);
      ensure(row.last_run_at === fired.last_run_at, 'Schedule fired again during observation');
      const turns = await client.request('GET', `/api/conversations/${conversation.id}/turns`, { expected: 200 });
      ensure(turns.body.data.length === 1 && turns.body.data[0].id === report.execution.turns[0].id && turns.body.data[0].status === 'completed', 'Scheduled turn count or outcome changed');
      report.schedules.observations.push({ at: new Date().toISOString(), conversation_ids: rows.map(c => c.id), turn_count: 1, enabled: row.enabled, last_run_at: row.last_run_at });
      if (Date.now() >= deadline) break;
      await sleep(Math.min(1000, deadline - Date.now()), undefined, { signal: ctx.signal });
    } while (true);
    report.schedules.observation_window = { started_at: new Date(started).toISOString(), ended_at: new Date().toISOString(), minimum_ms: config.schedules.observe_ms,
      schedule_disabled: true, claim: 'No additional execution observed during this bounded window; no unbounded exactly-once claim' };
    report.schedules.required.bounded_duplicates = 'passed';
    const { body } = await client.request('GET', `/api/conversations/${conversation.id}`, { expected: 200 });
    report.execution.usage_total = body.data.usage_total;
  });

}
