// Server-rendered controls can be visible before LiveView installs its event
// handlers. Wait for the connection before filling or submitting those forms;
// Playwright's visibility/actionability checks do not establish hydration.
export async function waitForLiveView(page) {
  await page.locator('[data-phx-main].phx-connected').waitFor({ state: 'attached' });
}
