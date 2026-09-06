import test from 'node:test';
import assert from 'node:assert/strict';
import { checkIn } from '../monitor.mjs';

const env = { GITHUB_REPOSITORY: 'example/fountain', GITHUB_RUN_ID: '123', GITHUB_RUN_ATTEMPT: '1',
  SUITE_MONITOR_URL: 'https://monitor.example.test/api/1/cron/canary/private-material/' };
test('monitor correlates start/end and separates retried workflow attempts', async () => {
  const requests = [];
  const send = async (url, options) => { requests.push({ url, options }); return new Response(''); };
  await checkIn('in_progress', env, send);
  await checkIn('error', env, send);
  await checkIn('ok', { ...env, GITHUB_RUN_ATTEMPT: '2' }, send);
  const ids = requests.map(r => r.url.searchParams.get('check_in_id'));
  assert.equal(ids[0], ids[1]);
  assert.notEqual(ids[1], ids[2]);
  assert.equal(requests[1].url.searchParams.get('status'), 'error');
  assert.equal(requests[0].options.redirect, 'error');
});
test('monitor rejects missing credentials and does not expose URL in delivery failures', async () => {
  let sent = false;
  await assert.rejects(checkIn('in_progress', { ...env, SUITE_MONITOR_URL: '' }, async () => { sent = true; }), /monitor check-in failed/);
  assert.equal(sent, false);
  await assert.rejects(checkIn('ok', env, async () => { throw new Error(env.SUITE_MONITOR_URL); }), error =>
    !error.message.includes('private-material') && /monitor check-in failed/.test(error.message));
  await assert.rejects(checkIn('ok', env, async () => new Response('', { status: 503 })), /monitor check-in failed/);
});
