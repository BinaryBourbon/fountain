import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { performTurn } from '../lib/execution.mjs';
import { Redactor } from '../lib/http.mjs';
import { validateBrowser } from '../lib/browser-config.mjs';
import { conversationAppUrl, verifyBrowserCors, verifyOAuthDenialRequest } from '../profiles/browser-handoff.mjs';

test('handoff configuration requires distinct pinned origins, explicit authentication and prompt/resource budgets', () => {
  const env = { EMAIL: 'dedicated@example.test', PASSWORD: 'test-password' };
  const config = { base_url: 'https://fountain.example.test', profiles: ['browser'], limits: { run_ms: 600000, resources: 4 }, browser: {
    email: 'EMAIL', password: 'PASSWORD', agent: { runtime: 'claude', model: 'anthropic/claude-sonnet-4-6', sandbox_provider: 'sprites' }, credential_provider: 'anthropic_api_key',
    conversations: { lock: { version: 'fountain-browser-app/1', url: 'https://app.example.test/', source_revision: 'a'.repeat(40), assets: [{ path: '/', sha256: 'b'.repeat(64), bytes: 1, content_type: 'text/html' }] }, auth: 'ui_created_api_key', oauth: 'deny', max_turns: 2 },
  } };
  validateBrowser(config, env);
  for (const [change, error] of [
    [c => { c.browser.conversations.max_turns = 3; }, /two-prompt/],
    [c => { c.browser.conversations.auth = 'oauth'; }, /successful OAuth/],
    [c => { c.browser.conversations.lock.url = c.base_url + '/'; }, /separate origin/],
    [c => { c.limits.resources = 3; }, /four resources/],
    [c => { c.limits.run_ms = 120000; }, /time for provision/],
  ]) {
    const copy = structuredClone(config); change(copy); assert.throws(() => validateBrowser(copy, env), error);
  }
});

test('transcript handoff uses the catalog app directly and rejects absent or mismatched configuration', () => {
  const app = 'https://app.example.test/conversations/';
  const catalog = { data: { apps: { conversations: app } } };
  assert.equal(conversationAppUrl(catalog, app, 'c1'), 'https://app.example.test/conversations/#/c/c1');
  for (const conversations of [null, undefined, '', 'https://elsewhere.test/', 'https://fountain.example.test/conversations/']) {
    assert.throws(() => conversationAppUrl({ data: { apps: { conversations } } }, app, 'c1'), /pinned app URL/);
  }
});

test('browser CORS and OAuth denial assertions bind the real app origin and redirect', () => {
  const app = 'https://app.example.test/', base = 'https://fountain.example.test';
  verifyBrowserCors(new URL(app).origin, '*', new URL(app).origin);
  assert.throws(() => verifyBrowserCors('https://elsewhere.test', '*', new URL(app).origin), /origin/);
  assert.throws(() => verifyBrowserCors(new URL(app).origin, 'https://elsewhere.test', new URL(app).origin), /CORS/);
  const url = new URL('/oauth/authorize', base);
  url.search = new URLSearchParams({ client_id: 'fountain-conversations', redirect_uri: app, response_type: 'code', code_challenge: 'c'.repeat(43), code_challenge_method: 'S256', state: 's'.repeat(22) });
  assert.equal(verifyOAuthDenialRequest(url, base, app), 's'.repeat(22));
  url.searchParams.append('state', 'another-state-value');
  assert.throws(() => verifyOAuthDenialRequest(url, base, app), /repeated/);
  url.searchParams.delete('state'); url.searchParams.set('state', 's'.repeat(22));
  url.searchParams.set('redirect_uri', 'https://elsewhere.test/');
  assert.throws(() => verifyOAuthDenialRequest(url, base, app), /redirect/);
});

test('browser submission consumes the prompt budget and still requires independent public turn evidence', async t => {
  const id = randomUUID(), turnId = randomUUID(), prompt = 'read this fixture nonce';
  const order = [];
  const events = [
    { id: 1, kind: 'stage', stage: 'turn', state: 'started', turn_id: turnId, data: JSON.stringify({ turn_id: turnId, turn_number: 1 }) },
    { id: 2, kind: 'output', stream: 'acp', turn_id: turnId, data: '{}', blocks: [{ kind: 'tool_use', name: 'shell' }] },
    { id: 3, kind: 'stage', stage: 'turn', state: 'done', turn_id: turnId, data: JSON.stringify({ turn_id: turnId, turn_number: 1 }) },
  ];
  const server = createServer((_req, res) => {
    order.push('public-stream');
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    for (const event of events) res.write(`id: ${event.id}\nevent: ${event.kind}\ndata: ${JSON.stringify(event)}\n\n`);
    res.end();
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); });
  let storedPrompt = prompt;
  const ctx = {
    config: { execution: { max_turns: 2, turn_ms: 2000 } }, signal: AbortSignal.timeout(10000), report: { execution: { turns: [] } },
    fixtures: { reserveTurn(actual, budget) { assert.equal(actual, id); assert.equal(budget, 2); order.push('budget'); } },
    client: { baseUrl: `http://127.0.0.1:${server.address().port}`, key: 'inert-test-value', redactor: new Redactor(), trace() {}, async request(method, path) {
      assert.equal(method, 'GET', 'Browser journey must not submit via the backend API client');
      if (path.endsWith('/turns')) return { body: { data: [{ id: turnId, turn_number: 1, status: 'completed', prompt: storedPrompt, exit_code: 0 }] } };
      return { body: { data: events, meta: { has_more: false } } };
    } },
  };
  const submit = async ({ prompt: value }) => { assert.equal(value, prompt); order.push('browser-submit'); return { body: { status: 'queued' } }; };
  const result = await performTurn(ctx, { id }, prompt, 1, 0, { submit });
  assert.deepEqual(order.slice(0, 3), ['budget', 'browser-submit', 'public-stream']);
  assert.equal(result.turn.id, turnId);
  storedPrompt = 'another prompt';
  await assert.rejects(performTurn(ctx, { id }, prompt, 1, 0, { submit }), /identity\/prompt/);
  const denied = { ...ctx, fixtures: { reserveTurn() { throw new Error('budget exhausted'); } } };
  let called = false;
  await assert.rejects(performTurn(denied, { id }, prompt, 1, 0, { submit: () => { called = true; } }), /budget exhausted/);
  assert.equal(called, false);
});
