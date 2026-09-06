import { reserveBrowserFixture, adoptBrowserFixture } from '../lib/browser-fixtures.mjs';
import { ensure } from '../lib/execution.mjs';
import { browserCredentials } from './browser-credentials.mjs';
import { waitForLiveView } from '../lib/browser-liveview.mjs';

// Called with a fresh browser context by the browser driver. All writes go
// through visible console forms. Public API reads independently establish
// identity, persistence and revocation; they never create the UI fixtures.
export async function browserConsole(ctx, page, evidence, { handoff } = {}) {
  const { config, fixtures, client, env, report, redactor } = ctx;
  const settings = config.browser;
  const email = env[settings.email];
  const password = env[settings.password];
  redactor.add(email); redactor.add(password);
  const identity = await client.request('GET', '/api/auth/me', { expected: 200, recordBody: false });
  ensure(identity.body.id === report.owner_id && identity.body.email === email, 'Browser login must match the dedicated API fixture owner');
  report.browser ??= { console: {}, app: { status: 'not_run' } };

  await evidence.step('console/sign-in', async () => {
    await page.goto(`${config.base_url}/auth/login`);
    await page.locator('input[name="email"]').fill(email);
    await page.locator('input[name="password"]').fill(password);
    await page.getByRole('button', { name: 'Sign in', exact: true }).click();
    await page.waitForURL(`${config.base_url}/dashboard`);
    report.browser.console.sign_in = true;
  });

  const clearCredential = await browserCredentials(ctx, page, evidence);
  let agent;
  await evidence.step('console/create-agent', async () => {
    const intent = reserveBrowserFixture(fixtures, 'agent');
    await page.goto(`${config.base_url}/agents/new`);
    await waitForLiveView(page);
    await page.getByLabel('Name', { exact: true }).fill(intent.name);
    await page.getByLabel('Description', { exact: true }).fill('Dedicated deployed browser fixture');
    await page.getByLabel('System prompt', { exact: true }).fill('Perform only the requested small file task. Use a shell tool. Do not access the network or start background work.');
    await page.locator('select[name="agent[runtime]"]').selectOption(settings.agent.runtime);
    await page.getByLabel('Model', { exact: true }).fill(settings.agent.model);
    const provider = page.locator('select[name="agent[sandbox_provider]"]');
    const { body: catalog } = await client.request('GET', '/api/catalog', { expected: 200 });
    const enabledProviders = catalog.data.sandbox_providers.enabled;
    ensure(enabledProviders.includes(settings.agent.sandbox_provider), 'Pinned browser provider is not enabled');
    // Runtime/model validation can temporarily replace the form. A zero count
    // during that patch is not evidence of a single-provider deployment.
    if (enabledProviders.length > 1 || await provider.count()) await provider.selectOption(settings.agent.sandbox_provider);
    else ensure(JSON.stringify(enabledProviders) === JSON.stringify([settings.agent.sandbox_provider]), 'Hidden provider selector does not imply the pinned sole provider');
    await page.getByRole('button', { name: 'Save', exact: true }).click();
    await page.waitForURL(`${config.base_url}/agents`);
    agent = await adoptBrowserFixture(fixtures, intent, ctx.signal);
    ensure(agent.runtime === settings.agent.runtime && agent.model === settings.agent.model, 'UI agent runtime/model did not persist');
    ensure((agent.sandbox_provider ?? catalog.data.sandbox_providers.default) === settings.agent.sandbox_provider, 'UI agent sandbox provider did not persist');
    report.browser.console.agent_id = agent.id;
  });

  await evidence.step('console/edit-agent', async () => {
    await page.goto(`${config.base_url}/agents/${agent.id}/edit`);
    await waitForLiveView(page);
    const description = `Browser edit verified for ${report.run_id}`;
    await page.getByLabel('Description', { exact: true }).fill(description);
    await page.getByRole('button', { name: 'Save', exact: true }).click();
    await page.waitForURL(`${config.base_url}/agents`);
    const { body } = await client.request('GET', `/api/agents/${agent.id}`, { expected: 200 });
    ensure(body.data.name === agent.name && body.data.description === description, 'UI agent edit did not persist');
    await evidence.heading(page, 'agents', 'Agents');
  });

  await evidence.step('console/api-key-lifecycle', async () => {
    const intent = reserveBrowserFixture(fixtures, 'api_key');
    await page.goto(`${config.base_url}/api-keys`);
    await waitForLiveView(page);
    await page.getByLabel('Key label', { exact: true }).fill(intent.name);
    await page.getByRole('button', { name: 'Create key', exact: true }).click();
    await page.getByText('New API key created', { exact: true }).waitFor({ state: 'visible' });
    // No screenshot, native trace or DOM dump is taken while the key is shown.
    const key = (await page.locator('#new-api-key').innerText()).trim();
    redactor.add(key);
    ensure(key.startsWith('ftn_'), 'UI key reveal did not contain an API key');
    const minted = await adoptBrowserFixture(fixtures, intent, ctx.signal);
    const me = await client.request('GET', '/api/auth/me', { key, expected: 200, recordBody: false });
    ensure(me.body.id === report.owner_id, 'UI key authenticated as another account');
    await page.getByRole('button', { name: "I've copied it, dismiss", exact: true }).click();
    if (settings.conversations) await handoff(agent, key);
    await waitForLiveView(page);
    const row = page.getByRole('row').filter({ hasText: intent.name });
    page.once('dialog', dialog => dialog.accept());
    await row.getByRole('button', { name: 'Revoke', exact: true }).click();
    await page.getByText('Key revoked', { exact: true }).waitFor({ state: 'visible' });
    await client.request('GET', '/api/auth/me', { key, expected: 401, recordBody: false });
    await client.request('GET', '/api/auth/me', { expected: 200, recordBody: false });
    report.browser.console.revoked_key_id = minted.id;
    await evidence.heading(page, 'api-keys', 'API keys');
  });

  await clearCredential();
  return agent;
}
