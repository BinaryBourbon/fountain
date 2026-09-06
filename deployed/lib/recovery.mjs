import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { isDeepStrictEqual } from 'node:util';
import { RecoveryDeployment, validateRecoveryDeployment } from '../adapters/recovery-kubernetes.mjs';
import { ControlledReceiverSession, controlledOrigin } from './controlled-receiver.mjs';
import { RELAY_VERSION } from '../receivers/runner-relay.mjs';
import { ensure } from './execution.mjs';

export function validateRecovery(config, env) {
  const settings = config.recovery;
  ensure(config.profiles.length === 1 && !config.execution && !config.deployment && !config.fixture,
    'Run recovery independently with its own staging deployment configuration');
  ensure(settings && Object.keys(settings).every(k => ['deployment', 'relay', 'runner_id', 'provision_ms', 'turn_ms', 'idle_wait_ms', 'max_turns'].includes(k)),
    'Expected explicit recovery settings');
  validateRecoveryDeployment(settings.deployment);
  ensure(settings.deployment.base_url === config.base_url, 'Recovery control and public API targets differ');
  ensure(/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(settings.runner_id), 'Recovery requires a dedicated runner ID');
  const relay = settings.relay;
  ensure(relay && Object.keys(relay).every(k => ['receiver_url', 'admin_credential', 'runner_name', 'disconnect_ms'].includes(k)), 'Expected explicit runner relay settings');
  controlledOrigin(relay);
  ensure(/^[A-Z][A-Z0-9_]*$/.test(relay.admin_credential) && typeof env[relay.admin_credential] === 'string' &&
    env[relay.admin_credential].length >= 32, 'Missing runner relay admin credential');
  ensure(/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$/.test(relay.runner_name), 'Invalid dedicated runner name');
  ensure(Number.isInteger(relay.disconnect_ms) && relay.disconnect_ms >= 5000 && relay.disconnect_ms <= 60000,
    'Recovery requires a 5–60 second runner disconnection');
  for (const [key, minimum, maximum] of [['provision_ms', 1000, 300000], ['turn_ms', 10000, 360000], ['idle_wait_ms', 60000, 600000]]) {
    ensure(Number.isInteger(settings[key]) && settings[key] >= minimum && settings[key] <= maximum, `Invalid recovery ${key}`);
  }
  ensure(settings.turn_ms >= settings.deployment.timeout_ms + 30000 && settings.max_turns === 4,
    'Recovery requires four fixture prompts and a turn window covering rollout plus 30 seconds');
  config.fixture = { sandbox_provider: 'runner', provision_ms: settings.provision_ms, turn_ms: settings.turn_ms, max_turns: 4 };
}

export function recoveryRelay(ctx, directory, runId, signal = ctx.signal) {
  return new ControlledReceiverSession({ settings: ctx.config.recovery.relay,
    adminKey: ctx.env[ctx.config.recovery.relay.admin_credential], path: resolve(directory, 'runner-relay.json'),
    runId, redactor: ctx.redactor, signal, version: RELAY_VERSION });
}

// Also used before public identity lookup on an interrupted cleanup run: the
// API may be unavailable until its control plane and runner route are restored.
export async function restoreRecoveryControls(ctx, directory, runId) {
  const report = ctx.report.recovery ??= {};
  let ok = true;
  if (existsSync(resolve(directory, 'runner-relay.json'))) {
    const cleaned = await ctx.check('recovery/relay-cleanup', async () => {
      const relay = recoveryRelay(ctx, directory, runId, AbortSignal.timeout(15000));
      relay.loadCleanup(); await relay.cleanup(AbortSignal.timeout(15000));
    });
    ok &&= cleaned;
  }
  if (existsSync(resolve(directory, 'recovery.json'))) {
    const restored = await ctx.check('recovery/deployment-cleanup', async () => {
      const control = await RecoveryDeployment.resume(resolve(directory, 'recovery.json'));
      ensure(control.record.run_id === runId && isDeepStrictEqual(control.config, ctx.config.recovery.deployment),
        'Recovery journal differs from the selected run or staging target');
      report.restored = await control.restore(AbortSignal.timeout(ctx.config.recovery.deployment.timeout_ms + 30000));
    });
    ok &&= restored;
  }
  report.cleanup_failed = !ok;
  return ok;
}
