import { readFileSync } from 'node:fs';
import { Client } from './http.mjs';
import { atomicJson } from './fixtures.mjs';
import { ensure } from './execution.mjs';
import { MCP_VERSION } from '../receivers/mcp.mjs';

export function mcpOrigin(settings) {
  const url = new URL(settings.receiver_url);
  ensure(url.protocol === 'https:' && !url.username && !url.password && !url.search && !url.hash && url.pathname === '/' &&
    /^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$/i.test(url.hostname) && !url.hostname.endsWith('.internal'),
  'MCP receiver requires an explicit HTTPS origin on a public hostname');
  return url;
}
export class McpReceiverSession {
  constructor({ settings, adminKey, path, runId, redactor, signal, trace = () => {} }) {
    this.origin = mcpOrigin(settings);
    ensure(typeof adminKey === 'string' && adminKey.length >= 32, 'Missing MCP receiver admin credential');
    this.path = path; this.runId = runId;
    this.manifest = { version: MCP_VERSION, run_id: runId, base_url: this.origin.origin, state: 'pending' };
    this.client = new Client({ baseUrl: this.origin.origin, key: adminKey, redactor, signal, timeoutMs: 10000, trace });
  }
  async verify() {
    const { body } = await this.client.request('GET', '/_suite/identity', { key: '', expected: 200 });
    ensure(body.version === MCP_VERSION && /^[0-9a-f-]{36}$/.test(body.instance_id), 'MCP receiver identity differs');
    this.manifest.instance_id = body.instance_id;
    return body;
  }
  async create(spec) {
    atomicJson(this.path, this.manifest);
    const { body } = await this.client.request('PUT', `/_suite/runs/${this.runId}`, { expected: 201, body: spec });
    this.assertIdentity(body);
    this.manifest.state = 'created'; atomicJson(this.path, this.manifest);
  }
  assertIdentity(body) {
    ensure(body.id === this.runId && body.version === MCP_VERSION && body.instance_id === this.manifest.instance_id, 'MCP receiver run identity differs');
  }
  async evidence(signal) {
    const { body } = await this.client.request('GET', `/_suite/runs/${this.runId}`, { expected: 200, signal });
    this.assertIdentity(body);
    ensure(Array.isArray(body.observations), 'MCP observations missing');
    return body.observations;
  }
  async cleanup(signal) {
    // UUID-scoped deletion is safe after a receiver restart; a reused origin
    // cannot make us delete a different run or accept different evidence.
    await this.client.request('DELETE', `/_suite/runs/${this.runId}`, { expected: 204, signal });
    await this.client.request('GET', `/_suite/runs/${this.runId}`, { expected: 404, signal });
    this.manifest.state = 'cleaned'; atomicJson(this.path, this.manifest);
  }
  loadCleanup() {
    const existing = JSON.parse(readFileSync(this.path));
    ensure(existing.version === MCP_VERSION && existing.base_url === this.origin.origin && existing.run_id === this.runId &&
      /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(existing.run_id) &&
      ['pending', 'created', 'cleaned'].includes(existing.state), 'MCP cleanup manifest does not match run and target');
    this.manifest = existing;
  }
}
