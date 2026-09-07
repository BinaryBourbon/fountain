import { createHash } from 'node:crypto';
import { readFileSync, readdirSync, lstatSync } from 'node:fs';
import { resolve, relative, sep } from 'node:path';
import { ensure } from './execution.mjs';

export const APP_LOCK_VERSION = 'fountain-browser-app/1';
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const maxFile = 4 * 1024 * 1024;
const maxTotal = 24 * 1024 * 1024;
const mime = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon', '.woff2': 'font/woff2' };

export function appUrl(value) {
  const url = new URL(value);
  ensure((url.protocol === 'https:' || (url.protocol === 'http:' && ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname))) &&
    !url.username && !url.password && !url.search && !url.hash && url.pathname.endsWith('/') && assetPath(url.pathname), 'App URL must be HTTPS (or local loopback), without credentials/query/fragment, ending in /');
  return url;
}

function assetPath(path) {
  return typeof path === 'string' && path.length <= 240 && path.startsWith('/') && !path.includes('//') &&
    !path.split('/').some(part => ['.', '..'].includes(part)) && /^\/[a-zA-Z0-9_./-]*$/.test(path);
}

export function validateAppLock(lock) {
  ensure(lock && Object.keys(lock).every(k => ['version', 'url', 'source_revision', 'assets'].includes(k)) && lock.version === APP_LOCK_VERSION, 'Unknown browser app lock');
  const url = appUrl(lock.url);
  lock.url = url.href;
  ensure(/^[a-f0-9]{40}$/.test(lock.source_revision), 'App source revision must be a full commit SHA');
  ensure(Array.isArray(lock.assets) && lock.assets.length > 0 && lock.assets.length <= 128, 'App lock requires 1-128 assets');
  let total = 0;
  const paths = new Set();
  for (const asset of lock.assets) {
    ensure(asset && Object.keys(asset).every(k => ['path', 'sha256', 'bytes', 'content_type'].includes(k)) &&
      assetPath(asset.path) && asset.path.startsWith(url.pathname) && !paths.has(asset.path) &&
      /^[a-f0-9]{64}$/.test(asset.sha256) && Number.isSafeInteger(asset.bytes) && asset.bytes > 0 && asset.bytes <= maxFile &&
      Object.values(mime).includes(asset.content_type), 'Invalid, duplicate, or unbounded app asset');
    paths.add(asset.path); total += asset.bytes;
  }
  ensure(total <= maxTotal && lock.assets.some(a => a.path === url.pathname && a.content_type === 'text/html'), 'App lock must contain its entry page and fit the bundle budget');
  return lock;
}

export function buildAppLock(root, urlString, revision) {
  const url = appUrl(urlString);
  root = resolve(root);
  ensure(lstatSync(root).isDirectory() && !lstatSync(root).isSymbolicLink(), 'Bundle root must be a real directory');
  const assets = [];
  function visit(directory) {
    for (const name of readdirSync(directory).sort()) {
      const file = resolve(directory, name), stat = lstatSync(file);
      ensure(!stat.isSymbolicLink(), 'Bundle cannot contain symbolic links');
      if (stat.isDirectory()) { visit(file); continue; }
      ensure(stat.isFile(), 'Bundle contains a non-file');
      if (name.endsWith('.map')) continue; // Debug source maps are not served by this fixture.
      const extension = name.slice(name.lastIndexOf('.'));
      ensure(mime[extension] && stat.size > 0 && stat.size <= maxFile, 'Unsupported or oversized bundle asset');
      const local = relative(root, file).split(sep).join('/');
      const path = url.pathname + (local === 'index.html' ? '' : local);
      ensure(assetPath(path), 'Bundle asset path is not canonical');
      assets.push({ path, sha256: digest(readFileSync(file)), bytes: stat.size, content_type: mime[extension] });
      ensure(assets.length <= 128, 'Bundle asset count exceeded');
    }
  }
  visit(root);
  return validateAppLock({ version: APP_LOCK_VERSION, url: url.href, source_revision: revision, assets });
}

export function verifyAppBytes(asset, status, headers, bytes) {
  ensure(status === 200, 'Pinned app asset did not return 200 without redirect');
  ensure(!headers['content-encoding'] || headers['content-encoding'] === 'identity', 'Pinned app fixture must honor identity content encoding');
  ensure(bytes.length === asset.bytes && digest(bytes) === asset.sha256, 'Pinned app asset bytes changed');
  const actual = (headers['content-type'] ?? '').split(';')[0].trim().toLowerCase();
  const accepted = asset.content_type === 'text/javascript' ? ['text/javascript', 'application/javascript'] : [asset.content_type];
  ensure(accepted.includes(actual), 'Pinned app asset content type changed');
}

export async function fetchPinnedApp(lock, { signal, fetchImpl = fetch } = {}) {
  validateAppLock(lock);
  const url = appUrl(lock.url), observed = [];
  for (const asset of lock.assets) {
    const response = await fetchImpl(new URL(asset.path, url.origin), { redirect: 'manual', credentials: 'omit', headers: { 'accept-encoding': 'identity' }, signal });
    ensure(response.status === 200, 'Pinned app asset did not return 200 without redirect');
    const chunks = []; let size = 0;
    try {
      for await (const chunk of response.body) {
        size += chunk.length;
        ensure(size <= asset.bytes, 'Pinned app asset exceeded expected byte length');
        chunks.push(chunk);
      }
    } finally { await response.body?.cancel().catch(() => {}); }
    verifyAppBytes(asset, response.status, Object.fromEntries(response.headers), Buffer.concat(chunks));
    observed.push({ path: asset.path, sha256: asset.sha256, bytes: size });
  }
  return { source_revision: lock.source_revision, assets: observed };
}

// Verify the response the browser actually consumes, not just an earlier GET.
// Fulfill with the same bytes, status and headers; never rewrite a broken app.
export async function guardBrowserApp(context, lock, { apiOrigin } = {}) {
  validateAppLock(lock);
  const origin = appUrl(lock.url).origin, observed = new Set();
  let failure, deniedState;
  await context.route('**/*', async route => {
    try {
      const request = route.request(), url = new URL(request.url());
      if (url.origin !== origin) {
        const fromApp = new URL(request.frame().url()).origin === origin;
        ensure(!fromApp || (url.origin === apiOrigin && (request.isNavigationRequest() || url.pathname.startsWith('/api/'))),
          'App requested a resource outside its pinned bundle and Fountain API');
        await route.continue();
        return;
      }
      const asset = lock.assets.find(a => a.path === url.pathname);
      const deniedCallback = url.pathname === appUrl(lock.url).pathname && deniedState && url.searchParams.size === 2 &&
        url.searchParams.get('error') === 'access_denied' && url.searchParams.get('state') === deniedState;
      ensure(request.method() === 'GET' && (!url.search || deniedCallback) && asset, 'Browser requested an unpinned app resource');
      if (deniedCallback) deniedState = undefined;
      // Identity encoding lets the exact verified bytes be fulfilled without
      // changing compression headers or repairing a broken response.
      const response = await route.fetch({ maxRedirects: 0, maxRetries: 0,
        headers: { ...request.headers(), 'accept-encoding': 'identity' } });
      const bytes = await response.body();
      verifyAppBytes(asset, response.status(), response.headers(), bytes);
      observed.add(asset.path);
      await route.fulfill({ response, body: bytes });
    } catch {
      failure = 'Browser app resource failed its immutable bundle check';
      await route.abort().catch(() => {});
    }
  });
  return {
    expectDeniedCallback(state) {
      ensure(/^[A-Za-z0-9_-]{16,128}$/.test(state), 'Invalid expected OAuth denial state');
      deniedState = state;
    },
    verify() {
      ensure(!failure && observed.has(appUrl(lock.url).pathname), failure ?? 'Browser did not load the pinned entry page');
      return { source_revision: lock.source_revision, observed_assets: [...observed].sort() };
    },
  };
}
