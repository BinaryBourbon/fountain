#!/usr/bin/env node
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Reuses the Sentry Crons channel already used for backup monitoring. Never log its URL.
export async function checkIn(status, env = process.env, send = fetch) {
  try {
    if (!['in_progress', 'ok', 'error'].includes(status) || !/^\d+$/.test(env.GITHUB_RUN_ID) ||
      !/^\d+$/.test(env.GITHUB_RUN_ATTEMPT) || !env.GITHUB_REPOSITORY) throw new Error();
    const url = new URL(env.SUITE_MONITOR_URL);
    if (url.protocol !== 'https:' || url.username || url.password || url.hash) throw new Error();
    const id = createHash('sha256').update(`${env.GITHUB_REPOSITORY}:${env.GITHUB_RUN_ID}:${env.GITHUB_RUN_ATTEMPT}`).digest('hex').slice(0, 32);
    url.searchParams.set('check_in_id', id);
    url.searchParams.set('status', status);
    const response = await send(url, { redirect: 'error', signal: AbortSignal.timeout(10000) });
    await response.body?.cancel();
    if (!response.ok) throw new Error();
  } catch { throw new Error('Canary monitor check-in failed; check environment configuration and Sentry availability'); }
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { await checkIn(process.argv[2]); console.log(`Canary monitor check-in: ${process.argv[2]}`); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
