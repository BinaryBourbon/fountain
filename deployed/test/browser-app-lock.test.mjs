import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, symlinkSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { buildAppLock, validateAppLock, fetchPinnedApp, guardBrowserApp, verifyAppBytes } from '../lib/browser-app-lock.mjs';

const revision = '862552d8ece9abef20535e9b9c0b19821bf614c4';
function bundle() {
  const root = mkdtempSync(join(tmpdir(), 'fountain-app-lock-'));
  mkdirSync(join(root, 'assets'));
  writeFileSync(join(root, 'index.html'), '<!doctype html><script type="module" src="./assets/app.js"></script>');
  writeFileSync(join(root, 'assets/app.js'), 'document.body.dataset.ready = "yes";');
  writeFileSync(join(root, 'assets/app.js.map'), '{}');
  return root;
}

test('app locks pin actual bytes and reject symlinks, duplicate paths, traversal and excess size', () => {
  const root = bundle();
  try {
    const lock = buildAppLock(root, 'https://app.example.test/console/', revision);
    assert.deepEqual(lock.assets.map(a => a.path).sort(), ['/console/', '/console/assets/app.js']);
    assert.equal(lock.source_revision, revision);
    assert.throws(() => validateAppLock({ ...lock, source_revision: 'main' }), /commit SHA/);
    assert.throws(() => validateAppLock({ ...lock, assets: [...lock.assets, lock.assets[0]] }), /duplicate/);
    assert.throws(() => validateAppLock({ ...lock, assets: [{ ...lock.assets[0], path: '/console/../app.js' }] }), /Invalid/);
    assert.throws(() => validateAppLock({ ...lock, assets: [{ ...lock.assets[0], bytes: 5 * 1024 * 1024 }] }), /unbounded/);
    assert.throws(() => buildAppLock(root, 'http://remote.example.test/', revision), /HTTPS/);
    symlinkSync(join(root, 'index.html'), join(root, 'alias.html'));
    assert.throws(() => buildAppLock(root, 'https://app.example.test/', revision), /symbolic/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('live app preflight and browser response guard reject a changed build after preflight', async () => {
  const root = bundle();
  let changed = false, redirect = false, requests = [];
  const server = createServer((req, res) => {
    requests.push({ url: req.url, authorization: req.headers.authorization, cookie: req.headers.cookie });
    if (redirect) { res.writeHead(302, { location: '/app/' }).end(); return; }
    const html = new URL(req.url, 'http://localhost').pathname === '/app/';
    res.writeHead(200, { 'content-type': html ? 'text/html' : 'application/javascript' });
    res.end(html ? '<!doctype html><script type="module" src="./assets/app.js"></script>' : changed ? 'different application' : 'document.body.dataset.ready = "yes";');
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const origin = `http://127.0.0.1:${server.address().port}`;
  try {
    const lock = buildAppLock(root, origin + '/app/', revision);
    assert.equal((await fetchPinnedApp(lock)).assets.length, 2);
    assert.ok(requests.every(r => r.authorization === undefined && r.cookie === undefined));
    let handler;
    const guard = await guardBrowserApp({ async route(_match, fn) { handler = fn; } }, lock);
    let fulfilled = 0, aborted = 0;
    async function consume(path) {
      await handler({
        request: () => ({ url: () => path.startsWith('http') ? path : origin + path, method: () => 'GET', headers: () => ({}),
          frame: () => ({ url: () => origin + '/app/' }), isNavigationRequest: () => false }),
        async fetch(options) {
          assert.equal(options.maxRedirects, 0); assert.equal(options.maxRetries, 0);
          assert.equal(options.headers['accept-encoding'], 'identity');
          const res = await fetch(origin + path, { redirect: 'manual', headers: options.headers });
          return { status: () => res.status, headers: () => Object.fromEntries(res.headers), body: async () => Buffer.from(await res.arrayBuffer()) };
        },
        async fulfill() { fulfilled++; }, async abort() { aborted++; },
      });
    }
    await consume('/app/');
    changed = true;
    await consume('/app/assets/app.js');
    assert.equal(fulfilled, 1); assert.equal(aborted, 1);
    assert.throws(() => guard.verify(), /immutable bundle/);
    await assert.rejects(fetchPinnedApp(lock), /bytes changed|byte length/);
    redirect = true;
    await assert.rejects(fetchPinnedApp(lock), /without redirect/);
    const js = lock.assets.find(a => a.path.endsWith('.js'));
    assert.throws(() => verifyAppBytes(js, 200, { 'content-type': 'text/html' }, Buffer.from('document.body.dataset.ready = "yes";')), /content type/);
    changed = false; redirect = false; fulfilled = 0; aborted = 0;
    const callbackGuard = await guardBrowserApp({ async route(_match, fn) { handler = fn; } }, lock);
    callbackGuard.expectDeniedCallback('s'.repeat(22));
    const callback = '/app/?error=access_denied&state=' + 's'.repeat(22);
    await consume(callback);
    assert.deepEqual(callbackGuard.verify().observed_assets, ['/app/']);
    await consume(callback);
    assert.equal(fulfilled, 1); assert.equal(aborted, 1);
    assert.throws(() => callbackGuard.verify(), /immutable bundle/);
    const externalGuard = await guardBrowserApp({ async route(_match, fn) { handler = fn; } }, lock);
    await consume('/app/');
    const before = requests.length;
    await consume('https://unpinned.example.test/executable.js');
    assert.equal(requests.length, before, 'Unpinned origin must be refused before fetching');
    assert.throws(() => externalGuard.verify(), /immutable bundle/);
  } finally {
    await new Promise(resolve => server.close(resolve));
    rmSync(root, { recursive: true, force: true });
  }
});
