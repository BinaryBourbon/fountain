import { writeFileSync, renameSync, readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';

const collections = { agent: '/api/agents', environment: '/api/environments', vault: '/api/vaults', api_key: '/api/auth/api-keys' };
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function atomicJson(path, value) {
  const temp = `${path}.${randomUUID()}.tmp`;
  writeFileSync(temp, JSON.stringify(value, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
  renameSync(temp, path);
}

export class Fixtures {
  constructor(path, client, { runId, baseUrl, ownerId, maxResources = 20, existing } = {}) {
    this.path = path;
    this.client = client;
    this.maxResources = maxResources;
    this.manifest = existing ?? { version: 1, run_id: runId, base_url: baseUrl, owner_id: ownerId, resources: [] };
    this.save();
  }
  static load(path, client, ownerId) {
    const existing = JSON.parse(readFileSync(path, 'utf8'));
    if (existing.version !== 1 || existing.base_url !== client.baseUrl || existing.owner_id !== ownerId ||
        !uuid.test(existing.run_id) || !Array.isArray(existing.resources) || existing.resources.length > 100) {
      throw new Error('Cleanup manifest version, target, owner, run ID, or resource count does not match');
    }
    for (const r of existing.resources) {
      if (!collections[r.kind] || typeof r.name !== 'string' || !r.name.startsWith(`suite-${existing.run_id}-`) ||
          (r.id !== undefined && !uuid.test(r.id)) || !['pending', 'created', 'cleaned'].includes(r.state)) {
        throw new Error('Invalid cleanup resource; refusing the manifest');
      }
    }
    return new Fixtures(path, client, { existing });
  }
  save() { atomicJson(this.path, this.manifest); }
  async create(kind, attrs = {}) {
    if (!collections[kind]) throw new Error('Unsupported fixture kind');
    if (this.manifest.resources.length >= this.maxResources) throw new Error('Fixture resource budget exhausted');
    const resource = { kind, name: `suite-${this.manifest.run_id}-${kind}-${this.manifest.resources.length}`, state: 'pending' };
    this.manifest.resources.push(resource);
    this.save(); // Intent survives a response lost after the server commits.
    const result = await this.client.request('POST', collections[kind], {
      body: { ...attrs, name: resource.name }, validate: false,
    });
    if (result.status >= 400 && result.status < 500) {
      resource.state = 'cleaned'; this.save();
      throw new Error(`Create ${kind}: received ${result.status}`);
    }
    const value = kind === 'api_key' ? result.body : result.body?.data;
    if (result.status !== 201 || !uuid.test(value?.id)) throw new Error(`Create ${kind}: no successful resource identity; cleanup intent retained`);
    resource.id = value.id;
    resource.state = 'created';
    this.save(); // Record ID before schema assertions can fail.
    this.client.contract?.check('POST', collections[kind], result.status, result.body);
    if (value.name !== resource.name) throw new Error(`Create ${kind}: returned name differs; cleanup will require ownership evidence`);
    return value;
  }
  async cleanup(signal) {
    const failures = [];
    for (const r of [...this.manifest.resources].reverse()) {
      if (r.state === 'cleaned') continue;
      try {
        signal?.throwIfAborted();
        const collection = collections[r.kind];
        let value;
        if (!r.id || r.kind === 'api_key') {
          const response = await this.client.request('GET', collection, { expected: 200, validate: false, signal });
          if (!Array.isArray(response.body?.data)) throw new Error('Cannot read cleanup ownership evidence');
          const matches = response.body.data.filter(item => r.id ? item.id === r.id : item.name === r.name);
          if (matches.length > 1) throw new Error('Ambiguous cleanup intent');
          value = matches[0];
          if (!value && !r.id) throw new Error('Unresolved create intent; retry cleanup after the server settles');
        } else {
          const response = await this.client.request('GET', `${collection}/${r.id}`, { expected: [200, 404], validate: false, signal });
          value = response.status === 404 ? undefined : response.body?.data;
          if (response.status === 200 && !value) throw new Error('Missing cleanup ownership evidence');
        }
        if (value) {
          if (value.name !== r.name || !uuid.test(value.id)) throw new Error('Cleanup ownership evidence does not match');
          r.id = value.id; this.save();
          await this.client.request('DELETE', `${collection}/${r.id}`, { expected: [204, 404], validate: false, signal });
        }
        r.state = 'cleaned'; this.save();
      } catch (error) { failures.push({ kind: r.kind, id: r.id, error: error.message }); }
    }
    return failures;
  }
}
