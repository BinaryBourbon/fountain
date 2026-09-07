#!/usr/bin/env node
import { parseArgs } from 'node:util';
import { writeFileSync } from 'node:fs';
import { buildAppLock } from '../lib/browser-app-lock.mjs';

try {
  const { values } = parseArgs({ options: { root: { type: 'string' }, url: { type: 'string' }, revision: { type: 'string' }, out: { type: 'string' } } });
  if (!values.root || !values.url || !values.revision || !values.out) throw new Error('Usage: node deployed/browser/lock-app.mjs --root DIST --url APP_URL --revision COMMIT_SHA --out LOCK.json');
  writeFileSync(values.out, JSON.stringify(buildAppLock(values.root, values.url, values.revision), null, 2) + '\n', { mode: 0o600, flag: 'wx' });
} catch (error) { console.error(error.message); process.exitCode = 1; }
