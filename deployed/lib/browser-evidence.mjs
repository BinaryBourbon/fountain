import { appendFileSync, mkdirSync } from 'node:fs';
import { resolve } from 'node:path';

// Browser engines' native traces include form values, cookies and response
// bodies. Keep a deliberately small action/network trace instead. Values and
// exception messages never enter this recorder, even on a failed sign-in.
export class BrowserEvidence {
  constructor(directory, origins) {
    this.directory = directory;
    this.origins = new Set(origins);
    this.entries = [];
    mkdirSync(directory, { recursive: true, mode: 0o700 });
  }
  write(entry) {
    if (this.entries.length >= 500) throw new Error('Browser evidence budget exhausted');
    this.entries.push(entry);
    appendFileSync(resolve(this.directory, 'browser.jsonl'), JSON.stringify(entry) + '\n', { mode: 0o600 });
  }
  action(step, state) {
    if (!/^[a-z][a-z0-9/-]{0,79}$/.test(step) || !['started', 'passed', 'failed'].includes(state)) {
      throw new Error('Invalid browser evidence action');
    }
    this.write({ kind: 'action', step, state, at: new Date().toISOString() });
  }
  response(method, rawUrl, status) {
    let url;
    try { url = new URL(rawUrl); } catch { return; }
    if (!this.origins.has(url.origin)) return;
    // Only fixed, nonsensitive routes. Queries contain OAuth codes/state and
    // cannot be retained; arbitrary paths can contain credentials too.
    const route = ['/api/auth/me', '/api/oauth/token', '/api/oauth/revoke', '/auth/login', '/oauth/authorize']
      .find(path => url.pathname === path);
    if (!route || !['GET', 'POST', 'OPTIONS'].includes(method) || !Number.isInteger(status)) return;
    this.write({ kind: 'response', method, origin: url.origin, route, status });
  }
  async step(name, fn) {
    this.action(name, 'started');
    try {
      const value = await fn();
      this.action(name, 'passed');
      return value;
    } catch {
      this.action(name, 'failed');
      // Playwright's error/call log can contain fill() arguments and page text.
      throw new Error(`Browser step ${name} failed; inspect browser.jsonl`);
    }
  }
  async heading(page, name, text) {
    if (!/^[a-z][a-z0-9-]{0,59}$/.test(name)) throw new Error('Invalid screenshot name');
    // Capture only a known static heading after checking exact text. Neither
    // the page's form values nor the one-time key modal is in the crop.
    const heading = page.getByRole('heading', { name: text, exact: true });
    if ((await heading.innerText()).trim() !== text) throw new Error('Screenshot heading changed');
    await heading.screenshot({ path: resolve(this.directory, `${name}.png`) });
  }
}
