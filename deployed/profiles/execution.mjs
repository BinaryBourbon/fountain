import { randomUUID } from 'node:crypto';
import { ensure, phaseSignal, performTurn, watchUntil } from '../lib/execution.mjs';
import { verifyReplay } from '../lib/replay.mjs';

export async function execution(ctx) {
  const { client, fixtures, config, check } = ctx;
  const settings = config.execution;
  const streaming = config.profiles.includes('streaming');
  ctx.report.execution = { runtime: settings.runtime, model: settings.model, sandbox_provider: settings.sandbox_provider, turns: [] };
  let environment, agent, conversation, provision, first, second;
  const file = `fountain-suite-${ctx.report.run_id}.txt`;
  const nonce = randomUUID();
  if (!await check('execution/second-tenant', async () => {
    const { body } = await client.request('GET', '/api/auth/me', { key: config.secondaryKey, expected: 200 });
    ensure(body.email_verified && body.id !== ctx.report.owner_id, 'Execution requires two distinct verified accounts');
  })) return;
  if (!await check('execution/fixtures', async () => {
    environment = await fixtures.create('environment');
    agent = await fixtures.create('agent', { runtime: settings.runtime, model: settings.model,
      sandbox_provider: settings.sandbox_provider, sandbox_mode: 'ephemeral', environment_id: environment.id,
      system: 'Perform only the requested small file task. Use a shell tool. Do not access the network or start background work.',
      permission_policy: { default: 'auto_allow' } });
    conversation = await fixtures.create('conversation', { agent_id: agent.id, environment_id: environment.id });
    ctx.report.execution.conversation_id = conversation.id;
    ctx.report.execution.sandbox_id = conversation.sandbox_id;
  })) return;
  if (!await check('execution/provision', async () => {
    const signal = phaseSignal(ctx.signal, settings.provision_ms);
    provision = await watchUntil(client, conversation.id, signal, event => event.kind === 'stage' && event.stage === 'provision' && event.state === 'done');
    const { body } = await client.request('GET', `/api/conversations/${conversation.id}`, { expected: 200, signal });
    conversation = body.data;
    ensure(conversation.sandbox?.status === 'ready' && conversation.sandbox.mode === 'ephemeral' && conversation.sandbox.provider === settings.sandbox_provider,
      'Provisioned sandbox does not match requested provider/mode');
    ensure(conversation.agent_id === agent.id && conversation.environment_id === environment.id, 'Conversation fixture identity changed');
    const turns = await client.request('GET', `/api/conversations/${conversation.id}/turns`, { expected: 200, signal });
    ensure(turns.body.data.length === 0, 'Conversation invoked inference before a prompt was submitted');
    ctx.report.execution.sandbox_id = conversation.sandbox_id;
  })) return;
  const readArtifact = async () => {
    const response = await client.request('GET', `/api/sandboxes/${conversation.sandbox_id}/file?path=${file}&max_bytes=1024`, { expected: 200 });
    const value = response.body.data;
    const contents = value.encoding === 'base64' ? Buffer.from(value.content, 'base64').toString('utf8') : value.content;
    ensure(!value.truncated && contents === nonce + '\n', 'Artifact bytes do not match the requested nonce');
    return contents;
  };
  if (!await check('execution/first-turn-and-artifact', async () => {
    first = await performTurn(ctx, conversation,
      `${streaming ? 'First say you are starting, then include a two-second sleep in your shell command. ' : ''}Use a shell tool to write exactly the text ${nonce} followed by one newline into the relative file ${file}. Read the file with the tool to verify it. Do nothing else.`, 1, provision.cursor, { verifyStreaming: streaming });
    await readArtifact();
  })) return;
  if (!await check('execution/follow-up', async () => {
    second = await performTurn(ctx, conversation,
      `Use a shell tool to read the existing relative file ${file}. Do not rewrite it or infer its contents from history. Reply with the file contents. Do nothing else.`, 2, first.cursor);
    await readArtifact();
    const { body } = await client.request('GET', `/api/conversations/${conversation.id}`, { expected: 200 });
    ensure(body.data.sandbox_id === conversation.sandbox_id && body.data.turn_count === 2, 'Follow-up did not preserve sandbox/turn continuity');
    const text = second.stored.filter(e => e.turn_id === second.turn.id).flatMap(e => e.blocks ?? []).filter(b => b.kind === 'text').map(b => b.body ?? '').join('');
    ensure(text.includes(nonce), 'Follow-up response did not contain the file nonce');
    ctx.report.execution.usage_total = body.data.usage_total;
  })) return;
  if (streaming) await check('streaming/replay-and-history', async () => {
    await verifyReplay(ctx, conversation.id, first, second, phaseSignal(ctx.signal, settings.turn_ms));
  });
  await check('execution/tenant-isolation', async () => {
    for (const path of [`/api/conversations/${conversation.id}`, `/api/conversations/${conversation.id}/events`,
      `/api/conversations/${conversation.id}/stream?wait=false`, `/api/sandboxes/${conversation.sandbox_id}`,
      `/api/sandboxes/${conversation.sandbox_id}/file?path=${file}`]) {
      await client.request('GET', path, { key: config.secondaryKey, expected: 404 });
    }
    for (const action of ['interrupt', 'terminate']) await client.request('POST', `/api/conversations/${conversation.id}/${action}`, { key: config.secondaryKey, expected: 404 });
  });
  await check('execution/terminate', async () => {
    const resource = fixtures.manifest.resources.find(r => r.kind === 'conversation' && r.id === conversation.id);
    await fixtures.terminateConversation(resource, conversation, phaseSignal(ctx.signal, settings.provision_ms));
  });
}
