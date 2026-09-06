import { setTimeout as sleep } from 'node:timers/promises';
import { ensure } from './execution.mjs';

const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
const states = ['pending', 'created', 'cleaned'];
export function scheduleTime(now = Date.now()) {
  ensure(Number.isFinite(now), 'Invalid schedule clock');
  const due = new Date(Math.ceil((now + 120000) / 60000) * 60000);
  return { due_at: due.toISOString(), cron: `${due.getUTCMinutes()} ${due.getUTCHours()} ${due.getUTCDate()} ${due.getUTCMonth() + 1} *` };
}
export function validateScheduleManifest(manifest) {
  const s = manifest.schedule;
  if (!s) return;
  ensure(s.version === 1 && s.name === `suite-${manifest.run_id}-schedule` && uuid(s.agent_id) && uuid(s.environment_id) &&
    (s.id === undefined || uuid(s.id)) && states.includes(s.state) && typeof s.deleted === 'boolean' && typeof s.armed === 'boolean' &&
    typeof s.prompt === 'string' && s.prompt.length > 0 && typeof s.cron === 'string' && Number.isFinite(Date.parse(s.due_at)) &&
    Array.isArray(s.conversations) && s.conversations.length <= 100 && new Set(s.conversations.map(c => c.id)).size === s.conversations.length,
  'Invalid schedule cleanup manifest');
  for (const kind of ['agent', 'environment']) ensure(manifest.resources.some(r => r.kind === kind && r.id === s[`${kind}_id`] &&
    r.name.startsWith(`suite-${manifest.run_id}-`)), 'Schedule must reference recorded run-owned parents');
  for (const c of s.conversations) ensure(uuid(c.id) && c.agent_id === s.agent_id && c.environment_id === null && c.name === null &&
    c.vault_id === null && c.sandbox_mode === 'ephemeral' && (c.sandbox_id === undefined || uuid(c.sandbox_id)) && states.includes(c.state),
  'Scheduled conversation identity is invalid');
  ensure(s.state !== 'cleaned' || s.deleted && s.conversations.every(c => c.state === 'cleaned'), 'Schedule cleanup is not complete');
}
const path = s => `/api/team/${s.agent_id}/schedules${s.id ? `/${s.id}` : ''}`;
function ownedSchedule(s, value) {
  ensure(value?.agent_id === s.agent_id && value.name === s.name && uuid(value.id) && (!s.id || value.id === s.id), 'Schedule ownership differs');
}
async function ownedParents(fixtures, signal) {
  const s = fixtures.manifest.schedule;
  for (const kind of ['agent', 'environment']) {
    const record = fixtures.manifest.resources.find(r => r.kind === kind && r.id === s[`${kind}_id`]);
    ensure(record?.state === 'created', 'Scheduled cleanup requires live recorded parents');
    const { body } = await fixtures.client.request('GET', `/api/${kind}s/${record.id}`, { expected: 200, signal });
    ensure(body.data?.id === record.id && body.data.name === record.name, 'Scheduled parent ownership differs');
    if (kind === 'agent') ensure(body.data.environment_id === s.environment_id && body.data.sandbox_mode === 'ephemeral', 'Scheduled agent environment or mode changed');
  }
}
export async function createSchedule(fixtures, { agentId, environmentId, prompt, cron, due_at }) {
  ensure(!fixtures.manifest.schedule && fixtures.manifest.resources.length + 2 <= fixtures.maxResources, 'Schedule and generated conversation exceed fixture budget');
  const s = { version: 1, name: `suite-${fixtures.manifest.run_id}-schedule`, agent_id: agentId, environment_id: environmentId,
    prompt, cron, due_at, state: 'pending', deleted: false, armed: false, conversations: [] };
  fixtures.manifest.schedule = s;
  validateScheduleManifest(fixtures.manifest); fixtures.save();
  await ownedParents(fixtures);
  const response = await fixtures.client.request('POST', path(s), { body: { name: s.name, cron, prompt, one_off: true, enabled: false }, validate: false });
  if (response.status >= 400 && response.status < 500) { s.deleted = true; s.state = 'cleaned'; fixtures.save(); }
  ensure(response.status === 201 && uuid(response.body?.data?.id), 'Schedule creation did not return an identity; cleanup intent retained');
  s.id = response.body.data.id; s.state = 'created'; fixtures.save();
  fixtures.client.contract?.check('POST', `/api/team/${s.agent_id}/schedules`, response.status, response.body);
  ownedSchedule(s, response.body.data);
  verifyScheduleConfiguration(s, response.body.data, false);
  return response.body.data;
}
export function verifyScheduleConfiguration(s, value, enabled) {
  ownedSchedule(s, value);
  ensure(value.one_off === true && value.enabled === enabled && value.cron === s.cron && value.prompt === s.prompt &&
    Date.parse(value.next_run_at) === Date.parse(s.due_at), 'Schedule timing, prompt, mode or enabled state differs');
}
export async function armSchedule(fixtures) {
  const s = fixtures.manifest.schedule;
  ensure(s?.state === 'created' && !s.armed && !s.deleted && (fixtures.manifest.inference_attempts ?? 0) === 0, 'Schedule firing was already authorized');
  ensure(Date.parse(s.due_at) - Date.now() >= 30000, 'Schedule due time is too close; refusing to enable a stale timer');
  const current = await fixtures.client.request('GET', path(s), { expected: 200 });
  verifyScheduleConfiguration(s, current.body.data, false);
  s.armed = true; fixtures.manifest.inference_attempts = 1; fixtures.save(); // Lost enable replies still consume authorization.
  const { body } = await fixtures.client.request('PATCH', path(s), { body: { enabled: true }, expected: 200 });
  verifyScheduleConfiguration(s, body.data, true);
  return body.data;
}
export async function readSchedule(fixtures, signal) {
  const s = fixtures.manifest.schedule;
  const { body } = await fixtures.client.request('GET', path(s), { expected: 200, signal });
  ownedSchedule(s, body.data); return body.data;
}
export async function disableSchedule(fixtures, signal) {
  const s = fixtures.manifest.schedule;
  await readSchedule(fixtures, signal);
  const { body } = await fixtures.client.request('PATCH', path(s), { body: { enabled: false }, expected: 200, signal });
  ownedSchedule(s, body.data); ensure(body.data.enabled === false, 'Schedule did not disable');
  return body.data;
}
export async function discoverScheduledConversations(fixtures, signal) {
  const s = fixtures.manifest.schedule;
  await ownedParents(fixtures, signal);
  const { body } = await fixtures.client.request('GET', `/api/conversations?agent_id=${s.agent_id}`, { expected: 200, signal });
  ensure(Array.isArray(body.data) && body.data.length <= 100, 'Scheduled conversation scan exceeded its bound');
  for (const value of body.data) {
    ensure(uuid(value.id) && value.agent_id === s.agent_id && value.environment_id === null && value.channel_id === null &&
      value.vault_id === null && value.parent_conversation_id === null, 'Generated conversation is outside the recorded schedule ownership');
    if (value.sandbox) ensure(value.sandbox.agent_id === s.agent_id && value.sandbox.environment_id === s.environment_id &&
      value.sandbox.mode === 'ephemeral' && value.sandbox.vault_id === null, 'Generated sandbox ownership differs');
    let r = s.conversations.find(c => c.id === value.id);
    if (!r) {
      ensure(s.conversations.length < 100, 'Scheduled cleanup identity budget exceeded');
      r = { id: value.id, agent_id: s.agent_id, environment_id: null, name: null, vault_id: null, sandbox_mode: 'ephemeral', state: 'created' };
      s.conversations.push(r);
    }
    ensure(r.state !== 'cleaned', 'A cleaned scheduled conversation reappeared');
    if (value.sandbox_id) {
      ensure(uuid(value.sandbox_id) && (!r.sandbox_id || r.sandbox_id === value.sandbox_id), 'Scheduled sandbox identity changed');
      r.sandbox_id = value.sandbox_id;
    }
  }
  fixtures.save(); return body.data;
}
export async function cleanupSchedule(fixtures, signal) {
  const s = fixtures.manifest.schedule;
  if (!s || s.state === 'cleaned') return [];
  const failures = [];
  try {
    validateScheduleManifest(fixtures.manifest);
    await ownedParents(fixtures, signal);
    if (!s.deleted) {
      let value;
      if (!s.id) {
        const { body } = await fixtures.client.request('GET', path(s), { expected: 200, signal });
        ensure(Array.isArray(body.data), 'Schedule cleanup list is absent');
        const matches = body.data.filter(row => row.name === s.name);
        ensure(matches.length === 1, 'Unresolved or ambiguous schedule creation intent');
        value = matches[0];
      } else {
        const result = await fixtures.client.request('GET', path(s), { expected: [200, 404], signal });
        value = result.status === 404 ? null : result.body.data;
      }
      if (value) {
        ownedSchedule(s, value); s.id = value.id; fixtures.save();
        // Deletion still runs if disabling was rejected or its reply was lost.
        await fixtures.client.request('PATCH', path(s), { body: { enabled: false }, expected: [200, 404], signal }).catch(() => {});
        await fixtures.client.request('DELETE', path(s), { expected: [204, 404], signal });
        await fixtures.client.request('GET', path(s), { expected: 404, signal });
      }
      s.deleted = true; fixtures.save();
    }
  } catch (error) { failures.push({ kind: 'schedule', id: s.id, error: error.message }); }
  // Even if source deletion failed, stop every already-created run we can
  // prove we own. Retain the parents until source AND children are gone.
  try {
    let quietSince;
    while (true) {
      signal?.throwIfAborted();
      const rows = await discoverScheduledConversations(fixtures, signal);
      for (const record of s.conversations.filter(c => c.state !== 'cleaned')) {
        const row = rows.find(c => c.id === record.id);
        if (row) {
          await fixtures.terminateConversation(record, row, signal);
          await fixtures.client.request('DELETE', `/api/conversations/${record.id}`, { expected: [204, 404], signal });
          await fixtures.client.request('GET', `/api/conversations/${record.id}`, { expected: 404, signal });
        } else if (record.sandbox_id) await fixtures.cleanSandbox(record, signal);
        record.state = 'cleaned'; fixtures.save();
      }
      if (rows.length === 0) quietSince ??= Date.now(); else quietSince = undefined;
      // The source was deleted first. A short additional scan catches a worker
      // that had fetched it just before deletion and was inserting its rows.
      if (!s.deleted || quietSince && Date.now() - quietSince >= 2000) break;
      await sleep(250, undefined, { signal });
    }
    const { body } = await fixtures.client.request('GET', '/api/sandboxes', { expected: 200, signal });
    ensure(Array.isArray(body.data), 'Cannot inspect scheduled sandbox cleanup');
    const live = body.data.filter(row => row.agent_id === s.agent_id && !['terminated', 'failed'].includes(row.status));
    s.remaining_sandbox_ids = live.map(row => row.id); fixtures.save();
    ensure(live.length === 0, 'Scheduled agent still has a live sandbox, including a possible orphan');
  } catch (error) { failures.push({ kind: 'scheduled_conversation', id: s.id, error: error.message }); }
  if (!failures.length && s.deleted && s.conversations.every(c => c.state === 'cleaned')) { s.state = 'cleaned'; fixtures.save(); }
  return failures;
}
