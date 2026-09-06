import { readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

export class SecretEvidence {
  constructor(values) { this.values = values; this.inspected = { http: 0, sse: 0 }; this.leaks = []; this.throwOnLeak = true; }
  inspect(value, { path, transport = 'http' }) {
    this.inspected[transport]++;
    const raw = JSON.stringify(value) ?? '';
    const file = value?.data?.encoding === 'base64' && typeof value.data.content === 'string' ? Buffer.from(value.data.content, 'base64').toString('utf8') : '';
    if (this.values.some(secret => raw.includes(secret) || file.includes(secret))) {
      this.leaks.push({ path, transport });
      if (this.throwOnLeak) throw new Error(`Synthetic secret disclosed in public ${transport} response at ${path}`);
    }
  }
  scanArtifacts(out, redactor) {
    let files = 0, leaks = 0;
    for (const item of readdirSync(out, { withFileTypes: true })) {
      if (!item.isFile() || !/\.(json|jsonl|xml)$/.test(item.name)) continue;
      const path = join(out, item.name), content = readFileSync(path, 'utf8'); files++;
      if (this.values.some(secret => content.includes(secret))) {
        leaks++;
        // Preserve a failing verdict without publishing the disclosed bytes.
        writeFileSync(path, redactor.text(content), { mode: 0o600 });
      }
    }
    if (leaks) throw new Error(`Synthetic secret found in ${leaks} suite artifact(s); disclosed bytes scrubbed`);
    return { files, leaks };
  }
}
