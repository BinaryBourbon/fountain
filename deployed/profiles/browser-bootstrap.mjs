import { ensure } from '../lib/execution.mjs';

// Only a FreshCompose instance in the ready state can supply this target.
// Registration and sign-in create no API key; account cleanup removes the
// complete disposable database through its recorded Compose ownership.
export async function browserBootstrap(fixture, page, evidence, { email, password }) {
  ensure(fixture.manifest.state === 'ready' && fixture.manifest.before?.users === 0, 'Browser bootstrap requires a newly verified empty Compose instance');
  const url = fixture.manifest.url;
  await evidence.step('bootstrap/register', async () => {
    await page.goto(`${url}/auth/register`);
    await page.locator('input[name="user[email]"]').fill(email);
    await page.locator('input[name="user[password]"]').fill(password);
    await page.getByRole('button', { name: 'Create account', exact: true }).click();
    await page.waitForURL(`${url}/auth/login`);
  });
  await evidence.step('bootstrap/sign-in', async () => {
    await page.locator('input[name="email"]').fill(email);
    await page.locator('input[name="password"]').fill(password);
    await page.getByRole('button', { name: 'Sign in', exact: true }).click();
    await page.waitForURL(`${url}/dashboard`);
    await page.goto(`${url}/admin`);
    await page.getByRole('heading', { name: 'Admin', exact: true }).waitFor({ state: 'visible' });
    await evidence.heading(page, 'bootstrap-admin', 'Admin');
    await fixture.verifyRegistered();
  });
  await evidence.step('bootstrap/sign-out', async () => {
    await page.getByRole('link', { name: 'Sign out', exact: true }).click();
    await page.waitForURL(`${url}/auth/login`);
    await page.goto(`${url}/admin`);
    await page.waitForURL(`${url}/auth/login`);
  });
  fixture.manifest.browser_verified = true; fixture.save();
}
