#!/usr/bin/env node
import { parseArgs } from 'node:util';
import { resolve } from 'node:path';
import { RecoveryDeployment } from './adapters/recovery-kubernetes.mjs';

const controller = new AbortController();
const stop = () => controller.abort(new Error('Restoration interrupted; retain the journal and run cleanup again'));
process.on('SIGINT', stop); process.on('SIGTERM', stop);
try {
  const { values } = parseArgs({ options: { journal: { type: 'string' } } });
  if (!values.journal) throw new Error('Usage: node deployed/recovery-cleanup.mjs --journal /absolute/path/recovery.json');
  const control = await RecoveryDeployment.resume(resolve(values.journal));
  const restored = await control.restore(controller.signal);
  console.log(JSON.stringify({ restored: true, deployment: restored }));
} catch (error) { console.error(error.message); process.exitCode = 3; }
finally { process.off('SIGINT', stop); process.off('SIGTERM', stop); }
