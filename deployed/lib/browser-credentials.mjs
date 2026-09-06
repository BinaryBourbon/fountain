const providers = ['anthropic_api_key', 'claude_code_oauth_token', 'openai_api_key', 'gemini_api_key'];
export const credentialPath = '/api/account/inference-credentials';

export function validateCredentialManifest(manifest) {
  const entry = manifest.browser_credential;
  if (entry === undefined) return;
  if (!entry || Object.keys(entry).sort().join(',') !== 'exclusive_account,initial_set,provider,state' ||
      entry.exclusive_account !== true || entry.initial_set !== false || !providers.includes(entry.provider) ||
      !['pending', 'saved', 'cleaned'].includes(entry.state)) {
    throw new Error('Invalid browser credential cleanup intent');
  }
}

export async function credentialStatus(client, provider, signal) {
  const { body } = await client.request('GET', credentialPath, { expected: 200, recordBody: false, signal });
  const rows = body?.data?.filter(row => row.provider === provider);
  if (rows?.length !== 1 || typeof rows[0].set !== 'boolean') throw new Error('Cannot establish provider credential status');
  return rows[0].set;
}

export async function reserveCredential(fixtures, provider, exclusiveAccount, signal) {
  if (exclusiveAccount !== true || !providers.includes(provider) || fixtures.manifest.browser_credential) {
    throw new Error('Credential setup requires one exclusive-account intent');
  }
  if (fixtures.manifest.resources.length >= fixtures.maxResources) throw new Error('Fixture resource budget exhausted');
  if (await credentialStatus(fixtures.client, provider, signal)) throw new Error('Refusing to replace a preexisting provider credential');
  const entry = { provider, exclusive_account: true, initial_set: false, state: 'pending' };
  fixtures.manifest.browser_credential = entry;
  fixtures.save(); // No value is persisted. Record intent before the UI submission.
  return entry;
}

// The singleton API has no revision/CAS or run marker. The operator must reserve
// this account exclusively through cleanup. This is not safe on a shared account.
export async function cleanupCredential(fixtures, signal) {
  const entry = fixtures.manifest.browser_credential;
  if (!entry || entry.state === 'cleaned') return [];
  try {
    validateCredentialManifest(fixtures.manifest);
    const set = await credentialStatus(fixtures.client, entry.provider, signal);
    if (!set && entry.state === 'pending') throw new Error('Unresolved credential submission; retain account reservation until it settles');
    if (set) {
      // Seeing the one submitted value establishes that its save has committed,
      // including when the browser lost the success response. Never resubmit it.
      entry.state = 'saved'; fixtures.save();
      await fixtures.client.request('DELETE', `${credentialPath}/${entry.provider}`, { expected: 204, recordBody: false, signal });
      if (await credentialStatus(fixtures.client, entry.provider, signal)) throw new Error('Provider credential remains set after cleanup');
    }
    entry.state = 'cleaned'; fixtures.save();
    return [];
  } catch (error) {
    return [{ kind: 'browser_credential', provider: entry.provider, error: error.message }];
  }
}
