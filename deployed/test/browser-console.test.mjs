import test from 'node:test';
import assert from 'node:assert/strict';
import { selectBrowserProvider, verifyBrowserProvider } from '../profiles/browser-console.mjs';

const pinned = 'sprites';

// Drives the console create-agent provider steps against a fake selector:
// `visible` is whether the form currently renders the provider select,
// `stored` is what the public API reads back for the saved agent.
async function createAgent({ enabled, visible, stored, defaultProvider = pinned }) {
  const selections = [];
  const provider = { async count() { return visible ? 1 : 0; }, async selectOption(value) { selections.push(value); } };
  const catalog = { data: { sandbox_providers: { enabled, default: defaultProvider } } };
  const selected = await selectBrowserProvider(provider, catalog, pinned);
  const agent = { sandbox_provider: stored };
  verifyBrowserProvider(agent, catalog, pinned, selected);
  return { selections, agent };
}

test('multiple providers require the explicit selection to persist even when it equals the default', async () => {
  const scenario = { enabled: ['sprites', 'runner'], visible: true };
  await assert.rejects(createAgent({ ...scenario, stored: null }), /UI agent sandbox provider did not persist/);
  const result = await createAgent({ ...scenario, stored: 'sprites' });
  assert.deepEqual(result.selections, ['sprites']);
  assert.equal(result.agent.sandbox_provider, 'sprites');
});

test('a visible sole-provider selector also requires explicit persistence', async () => {
  await assert.rejects(createAgent({ enabled: ['sprites'], visible: true, stored: null }), /UI agent sandbox provider did not persist/);
});

test('a hidden sole-provider selector permits the effective instance default', async () => {
  const scenario = { enabled: ['sprites'], visible: false, stored: null };
  const result = await createAgent(scenario);
  assert.deepEqual(result.selections, []);
  assert.equal(result.agent.sandbox_provider, null);
  await assert.rejects(createAgent({ ...scenario, defaultProvider: 'runner' }), /UI agent sandbox provider did not persist/);
});
