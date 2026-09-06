#!/usr/bin/env node
import { parseArgs } from 'node:util';
import { resolve } from 'node:path';
import { run } from './lib/runner.mjs';

const help = `Fountain deployed-instance suite (Node 24+)\n\n  node deployed/cli.mjs run --config target.json --out /tmp/fountain-run-001\n  node deployed/cli.mjs cleanup --config target.json --manifest /tmp/fountain-run-001/cleanup.json --out /tmp/fountain-cleanup-001\n\nCredentials are read only from environment variables named in target.json.\nExit codes: 0 passed, 1 assertion/runtime failure, 2 setup, 3 cleanup, 130 interrupted.\n`;
const controller = new AbortController();
const cancel = () => controller.abort(new Error('Interrupted'));
process.on('SIGINT', cancel);
process.on('SIGTERM', cancel);
try {
  const { values, positionals } = parseArgs({ allowPositionals: true, options: {
    config: { type: 'string' }, out: { type: 'string' }, manifest: { type: 'string' }, help: { type: 'boolean', short: 'h' },
  } });
  if (values.help) console.log(help);
  else {
    const [command] = positionals;
    if (positionals.length !== 1 || !['run', 'cleanup'].includes(command) || !values.config || !values.out ||
        (command === 'cleanup') !== Boolean(values.manifest)) throw new Error(help);
    process.exitCode = await run({ configPath: resolve(values.config), out: resolve(values.out),
      manifestPath: values.manifest ? resolve(values.manifest) : undefined, signal: controller.signal });
  }
} catch (error) { console.error(error.message); process.exitCode = 2; }
finally { process.off('SIGINT', cancel); process.off('SIGTERM', cancel); }
