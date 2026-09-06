import { ensure } from './execution.mjs';

const collections = { agent: '/api/agents', api_key: '/api/auth/api-keys' };
const uuid = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;

// UI creation has the same lost-response problem as POST. Record the intent
// before clicking, then recover its unique name through the public owner list.
// The ordinary cleanup command already understands these manifest entries.
export function reserveBrowserFixture(fixtures, kind) {
  ensure(Object.hasOwn(collections, kind), 'Unsupported browser fixture kind');
  ensure(fixtures.manifest.resources.length < fixtures.maxResources, 'Fixture resource budget exhausted');
  const resource = { kind, name: `suite-${fixtures.manifest.run_id}-${kind}-${fixtures.manifest.resources.length}`, state: 'pending' };
  fixtures.manifest.resources.push(resource);
  fixtures.save();
  return resource;
}

export async function adoptBrowserFixture(fixtures, resource, signal) {
  ensure(fixtures.manifest.resources.includes(resource) && resource.state === 'pending', 'Browser intent is not pending');
  const { body } = await fixtures.client.request('GET', collections[resource.kind], { expected: 200, recordBody: false, signal });
  const found = body.data.filter(item => item.name === resource.name);
  ensure(found.length === 1 && uuid.test(found[0].id), 'UI fixture is missing or its ownership is ambiguous');
  resource.id = found[0].id;
  resource.state = 'created';
  fixtures.save();
  return found[0];
}
