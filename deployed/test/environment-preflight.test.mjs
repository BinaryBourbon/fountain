import test from 'node:test';
import assert from 'node:assert/strict';
import { requireProtectedEnvironment } from '../validate-environment.mjs';

const env = { GITHUB_REF: 'refs/heads/main', REQUESTED_TARGET: 'staging', GITHUB_REPOSITORY: 'owner/repo', GH_TOKEN: 'fixture-token' };
const approved = type => ({ name: 'deployed-staging', protection_rules: [
  { type: 'required_reviewers', reviewers: [{ type, reviewer: { id: 123 } }] },
] });
const reply = data => async () => ({ ok: true, json: async () => data });

for (const [type, target] of [['User', 'staging'], ['Team', 'staging'], ['User', 'production'], ['Team', 'production']]) {
  test(`a configured ${type} reviewer permits a read-only ${target} preflight`, async () => {
    const calls = [];
    const request = async (url, options) => {
      calls.push({ url, options });
      return reply({ ...approved(type), name: `deployed-${target}` })();
    };
    assert.equal(await requireProtectedEnvironment({ ...env, REQUESTED_TARGET: target }, request), `deployed-${target}`);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].url, `https://api.github.com/repos/owner/repo/environments/deployed-${target}`);
    assert.equal(calls[0].options.method, 'GET');
    assert.equal(calls[0].options.headers.Authorization, 'Bearer fixture-token');
  });
}

for (const [name, metadata] of [
  ['no metadata', null], ['wrong environment', { ...approved('User'), name: 'deployed-production' }],
  ['no protection rules', { name: 'deployed-staging' }],
  ['timer only', { name: 'deployed-staging', protection_rules: [{ type: 'wait_timer', wait_timer: 30 }] }],
  ['empty reviewers', { name: 'deployed-staging', protection_rules: [{ type: 'required_reviewers', reviewers: [] }] }],
  ['malformed reviewer', { name: 'deployed-staging', protection_rules: [{ type: 'required_reviewers', reviewers: [{}] }] }],
]) {
  test(`refuses ${name}`, async () => {
    await assert.rejects(requireProtectedEnvironment(env, reply(metadata)), /configured required reviewers/);
  });
}

for (const status of [403, 404]) {
  test(`HTTP ${status} fails before an environment job can run`, async () => {
    await assert.rejects(requireProtectedEnvironment(env, async () => ({ ok: false, status })), /create the environment with required reviewers/);
  });
}

for (const changes of [{ GITHUB_REF: 'refs/heads/topic' }, { REQUESTED_TARGET: 'arbitrary' }, { GH_TOKEN: '' }]) {
  test(`rejects invalid input ${Object.keys(changes)[0]} before any API call`, async () => {
    let calls = 0;
    await assert.rejects(requireProtectedEnvironment({ ...env, ...changes }, async () => { calls++; }));
    assert.equal(calls, 0);
  });
}

test('API and JSON errors do not print response contents or credentials', async () => {
  for (const request of [async () => { throw new Error('private-response'); },
    async () => ({ ok: true, json: async () => { throw new Error('private-response'); } })]) {
    await assert.rejects(requireProtectedEnvironment(env, request), error => !/private-response|fixture-token/.test(error.message));
  }
});
