import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BrowserEvidence } from '../lib/browser-evidence.mjs';
import { reserveBrowserFixture, adoptBrowserFixture } from '../lib/browser-fixtures.mjs';
import { configFrom } from '../lib/runner.mjs';

test('browser failure trace discards secret arguments, query codes and unapproved paths', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'browser-evidence-'));
  try {
    const evidence = new BrowserEvidence(dir, ['https://fountain.test']);
    evidence.response('POST', 'https://fountain.test/api/oauth/token?code=private-code', 200);
    evidence.response('GET', 'https://fountain.test/private-secret', 200);
    evidence.response('POST', 'https://elsewhere.test/api/oauth/token', 200);
    await assert.rejects(evidence.step('console/sign-in', async () => { throw new Error('fill(private-password) failed'); }), /console\/sign-in failed/);
    const trace = readFileSync(join(dir, 'browser.jsonl'), 'utf8');
    assert.ok(!trace.includes('private-'));
    assert.deepEqual(evidence.entries.map(e => e.kind), ['response', 'action', 'action']);
    assert.equal(evidence.entries[0].route, '/api/oauth/token');
    await assert.rejects(evidence.heading({ getByRole: () => ({ innerText: async () => 'API keys private-secret' }) }, 'keys', 'API keys'), /heading changed/);
    assert.equal(evidence.entries.at(-1).state, 'failed');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('UI fixture intent survives a lost create reply and refuses ambiguous owner lists', async () => {
  let saved, rows = [];
  const fixtures = { maxResources: 2, manifest: { run_id: '99ae3e20-6453-4f7b-8c8f-416446e41dde', resources: [] },
    save() { saved = structuredClone(this.manifest); },
    client: { async request() { return { body: { data: rows } }; } } };
  const resource = reserveBrowserFixture(fixtures, 'agent');
  assert.equal(saved.resources[0].state, 'pending');
  const row = { id: '7037a408-be33-48db-8766-d7c057b8da75', name: resource.name };
  rows = [row, row];
  await assert.rejects(adoptBrowserFixture(fixtures, resource), /ambiguous/);
  assert.equal(saved.resources[0].state, 'pending');
  rows = [row];
  await adoptBrowserFixture(fixtures, resource);
  assert.equal(saved.resources[0].id, row.id);
  assert.equal(saved.resources[0].state, 'created');
  assert.throws(() => reserveBrowserFixture(fixtures, 'conversation'), /Unsupported/);
});

test('browser profile is explicit, bounded, credential-referenced and rejects an unpinned app', () => {
  const dir = mkdtempSync(join(tmpdir(), 'browser-config-'));
  const example = JSON.parse(readFileSync(new URL('../browser.example.json', import.meta.url), 'utf8'));
  const env = { FOUNTAIN_SUITE_KEY: 'test-key', FOUNTAIN_BROWSER_EMAIL: 'dedicated@example.test', FOUNTAIN_BROWSER_PASSWORD: 'private-password' };
  const parse = (change = {}, variables = env) => {
    const path = join(dir, 'target.json');
    writeFileSync(path, JSON.stringify({ ...structuredClone(example), ...change }));
    return configFrom(path, variables);
  };
  try {
    assert.deepEqual(parse().profiles, ['browser']);
    assert.throws(() => parse({ profiles: ['browser', 'probe'] }), /independently/);
    assert.throws(() => parse({}, { ...env, DEBUG: 'pw:api' }), /trace environment/);
    assert.throws(() => parse({}, { ...env, FOUNTAIN_BROWSER_PASSWORD: '' }), /populated/);
    assert.throws(() => parse({ browser: { ...example.browser, conversations: { url: 'https://app.example.test' } } }), /Unknown Conversations/);
    assert.throws(() => parse({ browser: { ...example.browser, step_ms: 60001 } }), /step_ms/);
    assert.throws(() => parse({ limits: { run_ms: 600001, resources: 2 } }), /ten-minute/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
