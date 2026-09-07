import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, existsSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { FreshCompose, isolateCompose, validateBootstrap } from '../lib/fresh-compose.mjs';

const pin = `registry.test/fountain@sha256:${'a'.repeat(64)}`;
const options = { app_image: pin, postgres_image: pin, context: 'local', port: 14826 };
const runId = '99ae3e20-6453-4f7b-8c8f-416446e41dde';
function baseline(project) {
  return { name: project, services: {
    app: { image: 'moving-tag', ports: [{ published: '4000', target: 4000 }], environment: { EMAIL_DELIVERY: 'none', FIRST_USER_ADMIN: 'true', REGISTRATION_ENABLED: 'true' }, networks: { default: null } },
    postgres: { image: 'postgres:16', ports: [{ published: '5432', target: 5432 }], volumes: [{ type: 'volume', source: 'postgres_data', target: '/var/lib/postgresql/data' }], networks: { default: null } },
  } };
}

test('fresh Compose pins images, binds only loopback and isolates its network and owned volume', () => {
  const config = isolateCompose(baseline(`fountain-bootstrap-${runId}`), options, runId);
  assert.equal(config.services.app.image, pin);
  assert.deepEqual(config.services.app.ports, [{ target: 4000, published: '14826', host_ip: '127.0.0.1', protocol: 'tcp' }]);
  assert.deepEqual(config.services.postgres.ports, []);
  assert.equal(config.networks.default.name, `fountain-bootstrap-${runId}_default`);
  assert.equal(config.volumes.postgres_data.name, `fountain-bootstrap-${runId}_postgres_data`);
  assert.throws(() => validateBootstrap({ ...options, app_image: 'fountain:latest' }), /immutable/);
  assert.throws(() => validateBootstrap({ ...options, port: 80 }), /port/);
  for (const change of [{ volumes: [{ type: 'bind', source: '/operator-data', target: '/data' }] }, { privileged: true }, { network_mode: 'host' }, { networks: { operator: null } }]) {
    const modified = baseline(`fountain-bootstrap-${runId}`);
    Object.assign(modified.services.app, change);
    assert.throws(() => isolateCompose(modified, options, runId), /refuses/);
  }
});

async function fixture(t) {
  const parent = mkdtempSync(join(tmpdir(), 'fresh-compose-'));
  t.after(() => rmSync(parent, { recursive: true, force: true }));
  const out = join(parent, 'run');
  const state = { endpoint: 'unix:///local.sock', count: 0, wrongOwner: false,
    ports: [{ HostIp: '127.0.0.1', HostPort: '14826' }], database: { users: 0, admins: 0, verified: 0, api_keys: 0 }, calls: [] };
  let project, actualRunId;
  const command = async args => {
    state.calls.push(args);
    if (args[0] === 'context') return JSON.stringify(state.endpoint);
    if (args[0] === 'image') return JSON.stringify({ Id: `sha256:${'b'.repeat(64)}`, RepoDigests: [pin], Config: { Labels: { 'org.opencontainers.image.revision': 'c'.repeat(40) } } });
    if (args[0] === 'ps' || args.includes('ls')) {
      if (state.count === 0) return '';
      return args[0] === 'ps' ? 'app-id\npostgres-id' : args[0] === 'volume' ? 'volume-id' : 'network-id';
    }
    if (args[1] === 'inspect') {
      const labels = { 'com.docker.compose.project': project, 'io.fountain.deployed-bootstrap': state.wrongOwner ? runId : actualRunId,
        'com.docker.compose.service': args[2] === 'app-id' ? 'app' : 'postgres' };
      return JSON.stringify({ Image: `sha256:${'b'.repeat(64)}`, Config: { Labels: labels }, Labels: labels,
        NetworkSettings: { Ports: args[2] === 'app-id' ? { '4000/tcp': state.ports } : { '5432/tcp': null } } });
    }
    if (args[0] === 'compose') {
      project = args[args.indexOf('--project-name') + 1]; actualRunId = project.slice('fountain-bootstrap-'.length);
      if (args.includes('config')) return JSON.stringify(baseline(project));
      if (args.includes('up')) { state.count = 4; return ''; }
      if (args.includes('down')) { state.count = 0; return ''; }
      if (args.includes('exec')) return JSON.stringify(state.database);
    }
    throw new Error('Unexpected test Docker command');
  };
  const prepared = await FreshCompose.prepare(out, options, { command });
  prepared.probe = async () => {};
  return { prepared, state, out, command };
}

test('fresh database proof precedes registration and cleanup removes only labeled project resources', async t => {
  const { prepared, state, out, command } = await fixture(t);
  await prepared.up();
  assert.equal(prepared.manifest.state, 'ready');
  await assert.rejects(prepared.up(), /only once/);
  await assert.rejects(prepared.verifyRegistered(), /one verified/);
  state.database = { users: 1, admins: 1, verified: 1, api_keys: 1 };
  await assert.rejects(prepared.verifyRegistered(), /no issued API keys/);
  state.database.api_keys = 0;
  await prepared.verifyRegistered();
  assert.equal(prepared.manifest.state, 'registered');
  await FreshCompose.load(out, command).cleanup();
  assert.equal(state.count, 0);
  assert.equal(existsSync(join(out, 'fixture.env')), false);
  assert.equal(existsSync(join(out, 'compose.json')), false);
  assert.equal(JSON.parse(readFileSync(join(out, 'bootstrap.json'))).remaining, 0);
  await FreshCompose.load(out, command).cleanup();
  assert.equal(state.calls.filter(args => args.includes('down')).length, 1);
});

test('changed Docker endpoint, configuration and resource ownership prevent destructive cleanup', async t => {
  const { prepared, state, out } = await fixture(t);
  await prepared.up();
  state.endpoint = 'ssh://production';
  await assert.rejects(prepared.cleanup(), /endpoint changed/);
  state.endpoint = 'unix:///local.sock'; state.wrongOwner = true;
  await assert.rejects(prepared.cleanup(), /ownership labels/);
  state.wrongOwner = false;
  writeFileSync(join(out, 'compose.json'), '{}');
  await assert.rejects(prepared.cleanup(), /configuration changed/);
  assert.equal(state.calls.filter(args => args.includes('down')).length, 0);
});

test('nonempty database is refused before any browser registration and remains cleanable', async t => {
  const { prepared, state } = await fixture(t);
  state.database.users = 1;
  await assert.rejects(prepared.up(), /not empty/);
  assert.equal(prepared.manifest.state, 'starting');
  await prepared.cleanup();
  assert.equal(state.count, 0);
});

test('missing or public Docker port binding cannot be reported ready', async t => {
  for (const ports of [null, [{ HostIp: '0.0.0.0', HostPort: '14826' }]]) {
    const { prepared, state } = await fixture(t);
    state.ports = ports;
    await assert.rejects(prepared.up(), /published exclusively/);
    assert.equal(prepared.manifest.before, undefined);
    assert.equal(prepared.manifest.state, 'starting');
    await prepared.cleanup();
  }
});
