import { credentialPath, credentialStatus, reserveCredential } from '../lib/browser-credentials.mjs';
import { ensure } from '../lib/execution.mjs';

export async function browserCredentials(ctx, page, evidence) {
  const { config, fixtures, client, report, env, redactor, signal } = ctx;
  const settings = config.browser;
  const provider = settings.credential_provider;
  const setup = settings.credential_setup;
  const form = () => page.locator('form').filter({ has: page.locator(`input[name="provider"][value="${provider}"]`) });
  await evidence.step('console/credential-validation', async () => {
    const before = await client.request('GET', credentialPath, { expected: 200, recordBody: false });
    await page.goto(`${config.base_url}/account/inference-credentials`);
    ensure(await form().locator('input[name="value"]').getAttribute('type') === 'password', 'Credential field must hide its value');
    await form().getByRole('button', { name: 'Save', exact: true }).click();
    await page.getByText('Paste a value before saving.', { exact: true }).waitFor({ state: 'visible' });
    const after = await client.request('GET', credentialPath, { expected: 200, recordBody: false });
    ensure(JSON.stringify(before.body) === JSON.stringify(after.body), 'Empty credential submission changed provider configuration');
    report.browser.console.provider_setup = { provider, mode: 'empty_submission', saved_verified: false };
    await evidence.heading(page, 'inference-credentials', 'Inference credentials');
  });
  if (!setup) return async () => {};

  let entry;
  await evidence.step('console/credential-save', async () => {
    const value = env[setup.value].trim();
    redactor.add(value);
    entry = await reserveCredential(fixtures, provider, setup.exclusive_account, signal);
    // No screenshot or native trace captures this field. There is one save
    // attempt: a timeout retains the intent for public-status reconciliation.
    await form().locator('input[name="value"]').fill(value);
    await form().getByRole('button', { name: 'Save', exact: true }).click();
    await page.getByText('Saved and validated.', { exact: true }).waitFor({ state: 'visible' });
    entry.state = 'saved'; fixtures.save();
    ensure(await credentialStatus(client, provider, signal), 'Validated provider credential did not persist');
    report.browser.console.provider_setup = { provider, mode: 'save_and_clear', saved_verified: true, cleared: false };
  });

  return async () => evidence.step('console/credential-clear', async () => {
    await page.goto(`${config.base_url}/account/inference-credentials`);
    await form().getByRole('button', { name: 'Clear', exact: true }).click();
    await page.getByText('Credential cleared.', { exact: true }).waitFor({ state: 'visible' });
    ensure(!await credentialStatus(client, provider, signal), 'Cleared provider credential remains set');
    entry.state = 'cleaned'; fixtures.save();
    report.browser.console.provider_setup.cleared = true;
    await evidence.heading(page, 'inference-credentials-cleared', 'Inference credentials');
  });
}
