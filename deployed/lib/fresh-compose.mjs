import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { resolve } from 'node:path';
import { randomBytes, randomUUID, createHash } from 'node:crypto';
import { atomicJson } from './fixtures.mjs';

const exec = promisify(execFile);
const label = 'io.fountain.deployed-bootstrap';
const sha = value => createHash('sha256').update(value).digest('hex');
const imagePin = /^[a-z0-9./_-]+@sha256:[a-f0-9]{64}$/;
const uuid = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/;
const assert = (ok, message) => { if (!ok) throw new Error(message); };

export function validateBootstrap(options) {
  assert(options && Object.keys(options).sort().join(',') === 'app_image,context,port,postgres_image', 'Expected explicit bootstrap image pins, local context and port');
  assert(imagePin.test(options.app_image) && imagePin.test(options.postgres_image), 'Bootstrap images must use immutable registry digests');
  assert(/^[a-zA-Z0-9_.-]{1,64}$/.test(options.context), 'Invalid Docker context');
  assert(Number.isInteger(options.port) && options.port >= 1024 && options.port <= 65535, 'Bootstrap port must be 1024-65535');
}

// Start from the actual repository Compose configuration, resolved without the
// operator's .env or service credentials. Only these two stock services run.
export function isolateCompose(config, options, runId) {
  validateBootstrap(options);
  assert(uuid.test(runId), 'Invalid bootstrap run ID');
  const project = `fountain-bootstrap-${runId}`;
  assert(config.name === project && config.services?.app && config.services?.postgres, 'Unexpected resolved Compose project');
  const app = structuredClone(config.services.app);
  const postgres = structuredClone(config.services.postgres);
  assert(!app.volumes?.length && postgres.volumes?.length === 1 && postgres.volumes[0].type === 'volume' &&
    postgres.volumes[0].source === 'postgres_data', 'Bootstrap refuses unexpected mounts');
  for (const service of [app, postgres]) {
    assert(!service.privileged && !service.network_mode && !service.container_name && !service.build &&
      !service.devices && !service.secrets && !service.configs && !service.external_links && !service.volumes_from &&
      Object.keys(service.networks ?? { default: null }).every(name => name === 'default'), 'Bootstrap refuses unexpected service access');
    service.labels = { ...service.labels, [label]: runId };
    service.restart = 'no';
  }
  app.image = options.app_image; postgres.image = options.postgres_image;
  app.ports = [{ target: 4000, published: String(options.port), host_ip: '127.0.0.1', protocol: 'tcp' }];
  postgres.ports = [];
  assert(app.environment.EMAIL_DELIVERY === 'none' && app.environment.FIRST_USER_ADMIN === 'true' &&
    app.environment.REGISTRATION_ENABLED === 'true', 'Resolved Compose bootstrap defaults differ');
  return {
    name: project, services: { app, postgres },
    volumes: { postgres_data: { name: `${project}_postgres_data`, labels: { [label]: runId } } },
    networks: { default: { name: `${project}_default`, labels: { [label]: runId } } },
  };
}

export class FreshCompose {
  constructor(out, manifest, command) {
    this.out = resolve(out); this.manifest = manifest;
    this.command = command ?? (async args => {
      try {
        const { stdout } = await exec('docker', ['--context', manifest.options.context, ...args], {
          cwd: this.out, env: { PATH: process.env.PATH, HOME: process.env.HOME },
          timeout: 180000, maxBuffer: 8 * 1024 * 1024,
        });
        return stdout.trim();
      } catch { throw new Error(`Bootstrap Docker ${args[0]} operation failed; raw command output withheld`); }
    });
  }
  save() { atomicJson(resolve(this.out, 'bootstrap.json'), this.manifest); }
  compose(...args) {
    return this.command(['compose', '--project-name', this.manifest.project, '--env-file', resolve(this.out, 'fixture.env'),
      '--file', resolve(this.out, 'compose.json'), ...args]);
  }
  static async prepare(out, options, { source = new URL('../../docker-compose.yml', import.meta.url), command } = {}) {
    validateBootstrap(options);
    mkdirSync(out, { mode: 0o700 }); // Exclusive directory; never adopt a previous run.
    const runId = randomUUID();
    const manifest = { version: 'fountain-bootstrap/1', run_id: runId, project: `fountain-bootstrap-${runId}`,
      options, state: 'preparing', url: `http://127.0.0.1:${options.port}` };
    const fixture = new FreshCompose(out, manifest, command);
    fixture.save();
    try {
      const endpoint = JSON.parse(await fixture.command(['context', 'inspect', options.context, '--format', '{{json .Endpoints.docker.Host}}']));
      assert(typeof endpoint === 'string' && endpoint.startsWith('unix:///'), 'Bootstrap requires a local Unix-socket Docker context');
      manifest.endpoint = endpoint;
      assert((await fixture.inventory()).length === 0, 'Fresh bootstrap project already has resources');
      manifest.images = {};
      for (const [service, pin] of [['app', options.app_image], ['postgres', options.postgres_image]]) {
        const info = JSON.parse(await fixture.command(['image', 'inspect', pin, '--format', '{{json .}}']));
        assert(/^sha256:[a-f0-9]{64}$/.test(info.Id) && info.RepoDigests?.includes(pin), 'Pinned image must already exist locally with its expected digest');
        manifest.images[service] = { id: info.Id, pin, revision: info.Config?.Labels?.['org.opencontainers.image.revision'] ?? null };
      }
      assert(/^[a-f0-9]{40}$/.test(manifest.images.app.revision), 'App image must record its source revision');
      const sourceBytes = readFileSync(source);
      manifest.source_sha256 = sha(sourceBytes);
      writeFileSync(resolve(out, 'source-compose.yml'), sourceBytes, { flag: 'wx', mode: 0o600 });
      const env = [
        `SECRET_KEY_BASE=${randomBytes(48).toString('base64')}`, `MASTER_SECRETS_KEY=${randomBytes(32).toString('base64url')}`,
        `POSTGRES_PASSWORD=${randomBytes(24).toString('hex')}`, `PUBLIC_URL=${manifest.url}`,
        'EMAIL_DELIVERY=none', 'FIRST_USER_ADMIN=true', 'REGISTRATION_ENABLED=true', 'CREDITS_ENABLED=false',
        'CONVERSATIONS_APP_URL=', 'TEAM_APP_URL=', 'API_CORS_ORIGINS=', 'OAUTH_CLIENTS=[]',
      ].join('\n') + '\n';
      writeFileSync(resolve(out, 'fixture.env'), env, { flag: 'wx', mode: 0o600 });
      const baseline = JSON.parse(await fixture.command(['compose', '--project-name', manifest.project, '--env-file', resolve(out, 'fixture.env'),
        '--file', resolve(out, 'source-compose.yml'), 'config', '--format', 'json']));
      const config = JSON.stringify(isolateCompose(baseline, options, runId), null, 2) + '\n';
      writeFileSync(resolve(out, 'compose.json'), config, { flag: 'wx', mode: 0o600 });
      manifest.config_sha256 = sha(config);
      manifest.state = 'prepared'; fixture.save();
      return fixture;
    } catch (error) {
      // Preparation never starts Docker resources. Remove generated secrets
      // even if interpolation, image inspection or validation failed.
      for (const file of ['fixture.env', 'compose.json']) rmSync(resolve(out, file), { force: true });
      manifest.state = 'prepare_failed'; fixture.save();
      throw error;
    }
  }
  static load(out, command) {
    const manifest = JSON.parse(readFileSync(resolve(out, 'bootstrap.json')));
    validateBootstrap(manifest.options);
    assert(manifest.version === 'fountain-bootstrap/1' && uuid.test(manifest.run_id) &&
      manifest.project === `fountain-bootstrap-${manifest.run_id}` && manifest.url === `http://127.0.0.1:${manifest.options.port}`,
    'Invalid bootstrap cleanup manifest');
    return new FreshCompose(out, manifest, command);
  }
  async inventory() {
    const found = [];
    for (const [kind, list] of [['container', ['ps', '-aq']], ['volume', ['volume', 'ls', '-q']], ['network', ['network', 'ls', '-q']]]) {
      const ids = (await this.command([...list, '--filter', `label=com.docker.compose.project=${this.manifest.project}`])).split(/\s+/).filter(Boolean);
      assert(ids.length <= (kind === 'container' ? 2 : 1), 'Unexpected bootstrap resource count');
      for (const id of ids) {
        const object = JSON.parse(await this.command([kind, 'inspect', id, '--format', '{{json .}}']));
        const labels = kind === 'container' ? object.Config?.Labels : object.Labels;
        assert(labels?.[label] === this.manifest.run_id && labels?.['com.docker.compose.project'] === this.manifest.project,
          'Refusing resources without both bootstrap ownership labels');
        found.push({ kind, id, image: kind === 'container' ? object.Image : undefined,
          service: labels['com.docker.compose.service'], ports: kind === 'container' ? object.NetworkSettings?.Ports : undefined });
      }
    }
    return found;
  }
  async verifyContext() {
    const endpoint = JSON.parse(await this.command(['context', 'inspect', this.manifest.options.context, '--format', '{{json .Endpoints.docker.Host}}']));
    assert(endpoint === this.manifest.endpoint && endpoint.startsWith('unix:///'), 'Bootstrap Docker endpoint changed');
    assert(sha(readFileSync(resolve(this.out, 'compose.json'))) === this.manifest.config_sha256, 'Bootstrap Compose configuration changed');
  }
  async up() {
    assert(this.manifest.state === 'prepared', 'Bootstrap may start only once');
    await this.verifyContext();
    assert((await this.inventory()).length === 0, 'Bootstrap no longer has a fresh project');
    this.manifest.state = 'starting'; this.save();
    await this.compose('up', '-d', '--pull', 'never', '--wait', '--wait-timeout', '120');
    const resources = await this.inventory();
    for (const service of ['app', 'postgres']) {
      const matches = resources.filter(r => r.kind === 'container' && r.service === service);
      assert(matches.length === 1 && matches[0].image === this.manifest.images[service].id, 'Bootstrap serving image differs from its pin');
      if (service === 'app') {
        const bindings = matches[0].ports?.['4000/tcp'];
        assert(bindings?.length === 1 && bindings[0].HostIp === '127.0.0.1' && bindings[0].HostPort === String(this.manifest.options.port),
          'Bootstrap app is not published exclusively on its pinned loopback port');
      } else assert(Object.values(matches[0].ports ?? {}).every(bindings => !bindings?.length), 'Bootstrap database must not publish a host port');
    }
    await this.probe();
    this.manifest.resources = resources;
    this.manifest.before = await this.databaseStatus();
    assert(this.manifest.before.users === 0 && this.manifest.before.api_keys === 0, 'Bootstrap database is not empty');
    this.manifest.state = 'ready'; this.save();
  }
  async probe() {
    for (const path of ['/health', '/health/ready']) {
      const response = await fetch(this.manifest.url + path, { redirect: 'manual', signal: AbortSignal.timeout(5000) });
      await response.body?.cancel();
      assert(response.status === 200, 'Bootstrap health must answer 200 through the host loopback port');
    }
  }
  async databaseStatus() {
    await this.verifyContext(); await this.inventory();
    // Fixed read-only statement, only inside this run's two-label-owned DB.
    // No hashes, addresses, tokens or credential columns leave Postgres.
    const sql = "SELECT json_build_object('users', (SELECT count(*) FROM users), 'admins', (SELECT count(*) FROM users WHERE role = 'admin'), 'verified', (SELECT count(*) FROM users WHERE email_verified_at IS NOT NULL), 'api_keys', (SELECT count(*) FROM api_keys));";
    const value = JSON.parse(await this.compose('exec', '-T', 'postgres', 'psql', '-U', 'postgres', '-d', 'fountain', '-tA', '-c', sql));
    assert(['users', 'admins', 'verified', 'api_keys'].every(k => Number.isSafeInteger(value[k]) && value[k] >= 0), 'Invalid bootstrap database evidence');
    return value;
  }
  async verifyRegistered() {
    assert(this.manifest.state === 'ready', 'Bootstrap registration requires its fresh ready instance');
    const status = await this.databaseStatus();
    assert(status.users === 1 && status.admins === 1 && status.verified === 1 && status.api_keys === 0, 'Expected one verified first admin and no issued API keys');
    this.manifest.after = status; this.manifest.state = 'registered'; this.save();
    return status;
  }
  async cleanup() {
    if (this.manifest.state !== 'cleaned') {
      await this.verifyContext(); await this.inventory();
      await this.compose('down', '--volumes', '--timeout', '10');
      assert((await this.inventory()).length === 0, 'Bootstrap resources remain after cleanup');
      this.manifest.state = 'cleaned'; this.manifest.remaining = 0; this.save();
    }
    for (const file of ['fixture.env', 'compose.json']) rmSync(resolve(this.out, file), { force: true });
  }
}
