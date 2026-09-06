#!/usr/bin/env node
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { randomBytes } from 'node:crypto';
import { FreshCompose } from '../lib/fresh-compose.mjs';
import { BrowserEvidence } from '../lib/browser-evidence.mjs';
import { browserBootstrap } from '../profiles/browser-bootstrap.mjs';

// Separate from the deployed-instance CLI: this case needs no existing user
// or API key and cannot enable registration on an existing instance.
let fixture, engine;
try {
  const { values, positionals } = parseArgs({ allowPositionals: true, options: { config: { type: 'string' }, out: { type: 'string' } } });
  if (positionals.length !== 1 || !['run', 'prepare', 'cleanup'].includes(positionals[0]) || !values.out) throw new Error('Use bootstrap.mjs run|prepare --config FILE --out DIRECTORY, or cleanup --out DIRECTORY');
  const action = positionals[0];
  const out = resolve(values.out);
  if (action === 'cleanup') {
    await FreshCompose.load(out).cleanup();
    console.log('Bootstrap cleanup complete');
  } else {
    if (!values.config) throw new Error('Bootstrap configuration is required');
    if (process.env.DEBUG || process.env.PWDEBUG || process.env.PW_TRACE) throw new Error('Disable browser debug/native tracing before bootstrap');
    fixture = await FreshCompose.prepare(out, JSON.parse(readFileSync(values.config)));
    await fixture.up();
    if (action === 'prepare') {
      console.log(`Fresh Compose ready at ${fixture.manifest.url}; use cleanup --out with this directory after browser checks`);
      fixture = undefined; // Explicit prepared-fixture mode retains its journal.
    } else {
      const { chromium } = await import('./node_modules/playwright/index.mjs');
      engine = await chromium.launch({ headless: true });
      const context = await engine.newContext({ acceptDownloads: false, serviceWorkers: 'block' });
      const page = await context.newPage();
      page.setDefaultTimeout(30000); page.setDefaultNavigationTimeout(30000);
      const evidence = new BrowserEvidence(resolve(out, 'browser'), [fixture.manifest.url]);
      await browserBootstrap(fixture, page, evidence, {
        email: `bootstrap-${fixture.manifest.run_id}@example.test`, password: randomBytes(24).toString('base64url'),
      });
      console.log('Fresh Compose registration, first-admin sign-in and sign-out passed');
    }
  }
} catch {
  console.error('Bootstrap failed; inspect bootstrap.json and named steps in browser/browser.jsonl. Raw browser/command errors are withheld.');
  process.exitCode = 1;
} finally {
  if (engine) await engine.close().catch(() => { process.exitCode = 1; });
  if (fixture) await fixture.cleanup().catch(() => {
    console.error('Bootstrap cleanup incomplete; retain the private fixture directory and run cleanup --out again.');
    process.exitCode = 1;
  });
}
