#!/usr/bin/env node
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Runs before a job names an environment: GitHub otherwise creates a missing
// environment without protection rules when the job first references it.
export async function requireProtectedEnvironment(env, request = fetch) {
  if (env.GITHUB_REF !== 'refs/heads/main') throw new Error('Verification requires main');
  if (!['staging', 'production'].includes(env.REQUESTED_TARGET)) throw new Error('Target is not approved');
  if (!/^[\w.-]+\/[\w.-]+$/.test(env.GITHUB_REPOSITORY || '') || !env.GH_TOKEN) throw new Error('Environment preflight requires repository read credentials');
  const name = `deployed-${env.REQUESTED_TARGET}`;
  const api = (env.GITHUB_API_URL || 'https://api.github.com').replace(/\/$/, '');
  let response;
  try {
    response = await request(`${api}/repos/${env.GITHUB_REPOSITORY}/environments/${name}`, {
      method: 'GET',
      headers: { Accept: 'application/vnd.github+json', 'X-GitHub-Api-Version': '2026-03-10', Authorization: `Bearer ${env.GH_TOKEN}` },
      signal: AbortSignal.timeout(15000),
    });
  } catch {
    throw new Error(`Cannot inspect ${name}; check GitHub API access before verification`);
  }
  if (!response.ok) throw new Error(`Cannot read ${name} (HTTP ${response.status}); create the environment with required reviewers before verification`);
  let environment;
  try { environment = await response.json(); }
  catch { throw new Error(`Invalid environment metadata for ${name}`); }
  const protectedTarget = environment?.name === name && Array.isArray(environment.protection_rules) &&
    environment.protection_rules.some(rule => rule?.type === 'required_reviewers' &&
      Array.isArray(rule.reviewers) && rule.reviewers.some(entry =>
        ['User', 'Team'].includes(entry?.type) && Number.isInteger(entry.reviewer?.id) && entry.reviewer.id > 0));
  if (!protectedTarget) throw new Error(`${name} must have configured required reviewers before verification`);
  return name;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { console.log(`Environment preflight passed: ${await requireProtectedEnvironment(process.env)}`); }
  catch (error) { console.error(error.message); process.exitCode = 2; }
}
