import { randomUUID } from 'node:crypto';
import { ensure, phaseSignal, performTurn, watchUntil } from '../lib/execution.mjs';
import { verifyReplay } from '../lib/replay.mjs';

export function verifyBrowserCors(requestOrigin, allowOrigin, appOrigin) {
  ensure(requestOrigin === appOrigin && [appOrigin, '*'].includes(allowOrigin), 'App request origin or server CORS response disagrees with the configured app');
}

export function verifyOAuthDenialRequest(rawUrl, baseUrl, appUrl) {
  const url = new URL(rawUrl);
  ensure(url.origin === new URL(baseUrl).origin && url.pathname === '/oauth/authorize' &&
    url.searchParams.get('client_id') === 'fountain-conversations' &&
    url.searchParams.get('redirect_uri') === appUrl && url.searchParams.get('response_type') === 'code' &&
    url.searchParams.get('code_challenge_method') === 'S256' && /^[A-Za-z0-9_-]{43}$/.test(url.searchParams.get('code_challenge')) &&
    /^[A-Za-z0-9_-]{16,128}$/.test(url.searchParams.get('state')), 'App OAuth request does not match the pinned client, redirect and PKCE flow');
  ensure([...url.searchParams.keys()].length === 6 && new Set(url.searchParams.keys()).size === 6, 'OAuth request contains unexpected or repeated parameters');
  return url.searchParams.get('state');
}

export async function browserHandoff(ctx, page, evidence, agent, key, appGuard) {
  const app = ctx.config.browser.conversations;
  const appOrigin = new URL(app.lock.url).origin;
  const settings = { ...ctx.config.browser.agent, ...app, sandbox_mode: 'ephemeral' };
  const turnCtx = { ...ctx, config: { ...ctx.config, execution: settings } };
  ctx.report.execution = { runtime: settings.runtime, model: settings.model, sandbox_provider: settings.sandbox_provider, sandbox_mode: 'ephemeral', turns: [] };
  const report = ctx.report.browser.app = { status: 'running', authentication: 'ui_created_api_key', oauth: 'not_run', turns: [] };
  let conversation, provision, first, second;
  const file = `fountain-suite-${ctx.report.run_id}.txt`, nonce = randomUUID();

  await evidence.step('app/owned-conversation', async () => {
    const environment = await ctx.fixtures.create('environment');
    conversation = await ctx.fixtures.create('conversation', { agent_id: agent.id, environment_id: environment.id, sandbox_mode: 'ephemeral' });
    const signal = phaseSignal(ctx.signal, settings.provision_ms);
    provision = await watchUntil(ctx.client, conversation.id, signal, e => e.kind === 'stage' && e.stage === 'provision' && e.state === 'done');
    const { body } = await ctx.client.request('GET', `/api/conversations/${conversation.id}`, { expected: 200, signal });
    conversation = body.data;
    ensure(conversation.agent_id === agent.id && conversation.environment_id === environment.id &&
      conversation.sandbox?.status === 'ready' && conversation.sandbox.mode === 'ephemeral' && conversation.sandbox.provider === settings.sandbox_provider,
    'App conversation did not provision the UI agent on its pinned provider');
    const turns = await ctx.client.request('GET', `/api/conversations/${conversation.id}/turns`, { expected: 200, signal });
    ensure(turns.body.data.length === 0, 'App fixture invoked inference before browser submission');
    report.conversation_id = conversation.id;
    ctx.report.streaming = { provision_cursor: provision.cursor };
  });

  async function handoff() {
    await page.goto(`${ctx.config.base_url}/conversations/${conversation.id}`);
    await page.waitForURL(app.lock.url + `#/c/${conversation.id}`);
    appGuard.verify();
  }

  await evidence.step('app/oauth-denial', async () => {
    await handoff();
    await page.getByLabel('Fountain URL', { exact: true }).fill(ctx.config.base_url);
    await page.getByRole('button', { name: 'Sign in with Fountain', exact: true }).click();
    await page.waitForURL(url => url.origin === new URL(ctx.config.base_url).origin && url.pathname === '/oauth/authorize');
    appGuard.expectDeniedCallback(verifyOAuthDenialRequest(page.url(), ctx.config.base_url, app.lock.url));
    await page.getByRole('button', { name: 'Deny', exact: true }).click();
    await page.getByText('Sign-in was denied.', { exact: true }).waitFor({ state: 'visible' });
    report.oauth = 'denial_verified';
    report.oauth_authorization = 'not_run'; // This journey authenticates with the UI-created run-owned key.
  });

  await evidence.step('app/key-sign-in-and-cors', async () => {
    await handoff();
    await page.getByLabel('Fountain URL', { exact: true }).fill(ctx.config.base_url);
    await page.getByRole('button', { name: 'or paste an API key', exact: true }).click();
    await page.getByLabel('API key', { exact: true }).fill(key);
    const [response] = await Promise.all([
      page.waitForResponse(response => response.url() === ctx.config.base_url + '/api/auth/me' && response.request().method() === 'GET'),
      page.getByRole('button', { name: 'Connect with key', exact: true }).click(),
    ]);
    ensure(response.status() === 200, 'App key sign-in did not authenticate');
    const me = await response.json();
    ensure(me.id === ctx.report.owner_id, 'App authenticated as another account');
    verifyBrowserCors((await response.request().allHeaders()).origin, response.headers()['access-control-allow-origin'], appOrigin);
    // The app only renders its composer after consuming the CORS-protected response.
    await page.getByPlaceholder('Follow-up prompt… (Enter to send, Shift+Enter for a new line)', { exact: true }).waitFor({ state: 'visible' });
    report.cors = { request_origin: appOrigin, response_allowed_origin: response.headers()['access-control-allow-origin'], browser_consumed_identity: true };
  });

  const submit = async ({ prompt, signal }) => {
    // A turn deadline also cancels browser actionability waits: an element
    // becoming clickable later must not submit work after its phase expired.
    const abort = () => { void page.close().catch(() => {}); };
    signal.addEventListener('abort', abort, { once: true });
    try {
      signal.throwIfAborted();
      const path = `${ctx.config.base_url}/api/conversations/${conversation.id}/prompts`;
      const [response] = await Promise.all([
        page.waitForResponse(response => response.url() === path && response.request().method() === 'POST'),
        (async () => {
          await page.getByPlaceholder('Follow-up prompt… (Enter to send, Shift+Enter for a new line)', { exact: true }).fill(prompt);
          signal.throwIfAborted();
          await page.getByRole('button', { name: 'Send', exact: true }).click();
        })(),
      ]);
      signal.throwIfAborted();
      verifyBrowserCors((await response.request().allHeaders()).origin, response.headers()['access-control-allow-origin'], appOrigin);
      ensure(response.status() === 200 && response.request().postDataJSON().prompt === prompt, 'Browser submitted another prompt or did not receive acceptance');
      await page.getByText('Queued', { exact: true }).waitFor({ state: 'visible' });
      return { status: response.status(), body: await response.json() };
    } finally { signal.removeEventListener('abort', abort); }
  };
  async function artifact() {
    const { body } = await ctx.client.request('GET', `/api/sandboxes/${conversation.sandbox_id}/file?path=${file}&max_bytes=1024`, { expected: 200 });
    const value = body.data;
    const contents = value.encoding === 'base64' ? Buffer.from(value.content, 'base64').toString('utf8') : value.content;
    ensure(!value.truncated && contents === nonce + '\n', 'Browser artifact bytes do not match the requested nonce');
  }
  await evidence.step('app/write-artifact', async () => {
    first = await performTurn(turnCtx, conversation,
      `Use a shell tool to write exactly the text ${nonce} followed by one newline into the relative file ${file}. Read the file with the tool to verify it. Do nothing else.`, 1, provision.cursor, { submit });
    await artifact();
    ctx.report.streaming.reconnect_cursor = first.cursor;
  });
  await evidence.step('app/read-artifact-and-render', async () => {
    second = await performTurn(turnCtx, conversation,
      `Use a shell tool to read the existing relative file ${file}. Do not rewrite it or infer its contents from history. Reply with the file contents. Do nothing else.`, 2, first.cursor, { submit });
    await artifact();
    const text = second.stored.filter(e => e.turn_id === second.turn.id).flatMap(e => e.blocks ?? []).filter(b => b.kind === 'text').map(b => b.body ?? '').join('');
    ensure(text.includes(nonce), 'App follow-up did not persist the read nonce');
    // Scope to the second assistant reply, excluding the user's echoed prompt.
    await page.locator('.turn').nth(1).locator('.bubble.them').filter({ hasText: nonce }).first().waitFor({ state: 'visible' });
    await verifyReplay(turnCtx, conversation.id, first, second, phaseSignal(ctx.signal, settings.turn_ms));
    report.turns = [first.turn.id, second.turn.id];
    report.assistant_nonce_rendered = true;
    report.bundle = appGuard.verify();
  });
  await evidence.step('app/sign-out', async () => {
    await page.getByRole('button', { name: 'Sign out', exact: true }).click();
    await page.getByRole('button', { name: 'Sign in with Fountain', exact: true }).waitFor({ state: 'visible' });
    // Pasted credentials remain valid until the console revokes this exact key.
    await page.goto(`${ctx.config.base_url}/api-keys`);
    await page.getByRole('heading', { name: 'API keys', exact: true }).waitFor({ state: 'visible' });
    report.status = 'passed';
  });
}
