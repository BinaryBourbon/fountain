import { resolve } from 'node:path';
import { BrowserEvidence } from '../lib/browser-evidence.mjs';
import { browserConsole } from './browser-console.mjs';
import { browserHandoff } from './browser-handoff.mjs';
import { fetchPinnedApp, guardBrowserApp } from '../lib/browser-app-lock.mjs';
import { phaseSignal } from '../lib/execution.mjs';

export async function browser(ctx) {
  const evidence = new BrowserEvidence(resolve(ctx.out, 'browser'), [new URL(ctx.config.base_url).origin]);
  const app = ctx.config.browser.conversations;
  if (app && !await ctx.check('browser/app-bundle', async () => {
    ctx.report.browser_bundle = await fetchPinnedApp(app.lock, { signal: phaseSignal(ctx.signal, 60000) });
  })) return;
  await ctx.check('browser/console', async () => {
    let engine, close;
    try {
      const { chromium } = await import('../browser/node_modules/playwright/index.mjs');
      engine = await chromium.launch({ headless: true });
      close = () => { void engine.close().catch(() => {}); };
      ctx.signal.addEventListener('abort', close, { once: true });
      ctx.signal.throwIfAborted();
      const context = await engine.newContext({ acceptDownloads: false, serviceWorkers: 'block' });
      const appGuard = app ? await guardBrowserApp(context, app.lock, { apiOrigin: new URL(ctx.config.base_url).origin }) : undefined;
      // This disposable context has no saved sign-in, cookies or app storage.
      // Native tracing, HAR capture and video stay disabled.
      const page = await context.newPage();
      page.setDefaultTimeout(ctx.config.browser.step_ms);
      page.setDefaultNavigationTimeout(ctx.config.browser.step_ms);
      let traceFailure;
      page.on('response', response => {
        try { evidence.response(response.request().method(), response.url(), response.status()); }
        catch { traceFailure = true; close(); }
      });
      await browserConsole(ctx, page, evidence, { handoff: (agent, key) => browserHandoff(ctx, page, evidence, agent, key, appGuard) });
      ctx.require(!traceFailure, 'Browser evidence exceeded its bounded trace budget');
      if (!app) ctx.report.browser.app = { status: 'not_run', reason: 'No Conversations app journey configured' };
    } catch (error) {
      if (ctx.report.browser?.app?.status === 'running') ctx.report.browser.app.status = 'failed';
      if (/^Browser step [a-z0-9/-]+ failed; inspect browser.jsonl$/.test(error.message)) throw error;
      throw new Error('Browser setup or bounded driver failed; verify the pinned dependency, installed Chromium and browser.jsonl');
    } finally {
      if (close) ctx.signal.removeEventListener('abort', close);
      if (engine) {
        try { await engine.close(); }
        catch { throw new Error('Browser shutdown failed'); }
      }
    }
  });
}
