import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Fixtures } from '../lib/fixtures.mjs';
import { reserveBrowserFixture } from '../lib/browser-fixtures.mjs';
import { credentialPath, reserveCredential } from '../lib/browser-credentials.mjs';
import { configFrom } from '../lib/runner.mjs';

const ownerId = '7037a408-be33-48db-8766-d7c057b8da75';
const runId = '99ae3e20-6453-4f7b-8c8f-416446e41dde';
const provider = 'anthropic_api_key';
function fixture(t) {
  const dir = mkdtempSync(join(tmpdir(), 'browser-credential-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const path = join(dir, 'cleanup.json');
  const state = { set: false, deletes: 0, loseDeleteReply: false, keepAfterDelete: false };
  const client = { baseUrl: 'https://fountain.test', async request(method, route) {
    if (method === 'GET' && route === credentialPath) return { body: { data: [{ provider, set: state.set }] } };
    assert.equal(method, 'DELETE'); assert.equal(route, `${credentialPath}/${provider}`);
    state.deletes++;
    if (!state.keepAfterDelete) state.set = false;
    if (state.loseDeleteReply) throw new Error('Lost delete response');
    return { status: 204 };
  } };
  const fixtures = new Fixtures(path, client, { runId, ownerId, baseUrl: client.baseUrl, maxResources: 1 });
  return { dir, path, fixtures, client, state };
}

test('credential setup refuses preexisting credentials and requires explicit account reservation', async t => {
  const { fixtures, state, path } = fixture(t);
  await assert.rejects(reserveCredential(fixtures, provider, false), /exclusive-account/);
  state.set = true;
  await assert.rejects(reserveCredential(fixtures, provider, true), /preexisting/);
  assert.equal(JSON.parse(readFileSync(path)).browser_credential, undefined);
  assert.equal(state.deletes, 0);
  state.set = false;
  await reserveCredential(fixtures, provider, true);
  assert.equal(fixtures.remainingCount(), 1);
  assert.throws(() => reserveBrowserFixture(fixtures, 'api_key'), /budget/);
  await assert.rejects(fixtures.create('agent'), /budget/);
  await assert.rejects(reserveCredential(fixtures, provider, true), /one exclusive-account/);
  assert.deepEqual(Object.keys(JSON.parse(readFileSync(path)).browser_credential).sort(), ['exclusive_account', 'initial_set', 'provider', 'state']);
});

test('interrupted browser cleanup retains unset pending submission, then clears its committed value', async t => {
  const { fixtures, state, path, client } = fixture(t);
  await reserveCredential(fixtures, provider, true);
  const reloaded = Fixtures.load(path, client, ownerId);
  const pending = await reloaded.cleanup();
  assert.match(pending[0].error, /Unresolved credential submission/);
  assert.equal(reloaded.remainingCount(), 1);
  assert.equal(state.deletes, 0);
  // The browser never received success, but its single request now commits.
  state.set = true;
  assert.deepEqual(await reloaded.cleanup(), []);
  assert.equal(state.deletes, 1);
  assert.equal(state.set, false);
  assert.equal(reloaded.remainingCount(), 0);
  assert.deepEqual(await Fixtures.load(path, client, ownerId).cleanup(), []);
  assert.equal(state.deletes, 1);
});

test('lost credential delete response survives restart without treating an unset pending save as resolved', async t => {
  const { fixtures, state, path, client } = fixture(t);
  await reserveCredential(fixtures, provider, true);
  state.set = true; state.loseDeleteReply = true;
  assert.match((await fixtures.cleanup())[0].error, /Lost delete response/);
  assert.equal(JSON.parse(readFileSync(path)).browser_credential.state, 'saved');
  const reloaded = Fixtures.load(path, client, ownerId);
  assert.deepEqual(await reloaded.cleanup(), []);
  assert.equal(reloaded.remainingCount(), 0);
  assert.equal(state.deletes, 1);
});

test('credential cleanup reports failed deletion and refuses malformed or differently owned manifests', async t => {
  const { fixtures, state, path, client } = fixture(t);
  await reserveCredential(fixtures, provider, true);
  state.set = true; state.keepAfterDelete = true;
  assert.match((await fixtures.cleanup())[0].error, /remains set/);
  assert.equal(fixtures.remainingCount(), 1);
  assert.throws(() => Fixtures.load(path, client, runId), /owner/);
  assert.throws(() => Fixtures.load(path, { ...client, baseUrl: 'https://other.test' }, ownerId), /target/);
  const original = JSON.parse(readFileSync(path));
  for (const change of [{ provider: '../auth/api-keys' }, { initial_set: true }, { exclusive_account: false }, { state: 'cancelled' }, { value: 'must-not-be-journaled' }]) {
    writeFileSync(path, JSON.stringify({ ...original, browser_credential: { ...original.browser_credential, ...change } }));
    assert.throws(() => Fixtures.load(path, client, ownerId), /credential cleanup intent/);
  }
});

test('provider save/clear is opt-in, secret-referenced, and included in the resource budget', t => {
  const { dir } = fixture(t);
  const config = JSON.parse(readFileSync(new URL('../browser.example.json', import.meta.url)));
  const env = { FOUNTAIN_SUITE_KEY: 'test', FOUNTAIN_BROWSER_EMAIL: 'test@example.test', FOUNTAIN_BROWSER_PASSWORD: 'test', PROVIDER_TEST_KEY: 'synthetic-provider-value' };
  const parse = () => { const path = join(dir, 'target.json'); writeFileSync(path, JSON.stringify(config)); return configFrom(path, env); };
  config.browser.credential_setup = { mode: 'save_and_clear', exclusive_account: true, value: 'PROVIDER_TEST_KEY' };
  assert.throws(parse, /additional resource slot/);
  config.limits.resources = 3;
  assert.equal(parse().browser.credential_setup.value, 'PROVIDER_TEST_KEY');
  config.browser.credential_setup.exclusive_account = false;
  assert.throws(parse, /exclusive-account/);
  config.browser.credential_setup.exclusive_account = true;
  config.browser.credential_setup.value = 'literal-secret';
  assert.throws(parse, /environment variable/);
});
