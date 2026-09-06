import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';

// The versioned projection in sdk/contract, not arbitrary JSON Schema. Keep the
// supported vocabulary explicit; never silently accept an unknown projection.
export class Contract {
  constructor(path) {
    const bytes = readFileSync(path);
    this.sha256 = createHash('sha256').update(bytes).digest('hex');
    this.document = JSON.parse(bytes);
    if (this.document.contract_version !== 1 || !this.document.operations || !this.document.schemas) {
      throw new Error('Expected Fountain wire contract version 1');
    }
  }

  check(method, path, status, body) {
    const literal = path.split('?')[0];
    const candidates = Object.entries(this.document.operations).filter(([key]) => {
      const [verb, template] = key.split(' ');
      const parts = template.split('/');
      const actual = literal.split('/');
      return verb === method && parts.length === actual.length &&
        parts.every((part, i) => part === actual[i] || /^\{\w+\}$/.test(part));
    }).sort(([a], [b]) => (a.match(/\{/g)?.length ?? 0) - (b.match(/\{/g)?.length ?? 0));
    const operation = candidates[0]?.[1];
    if (!operation) throw new Error(`Contract has no operation for ${method} ${literal}`);
    const response = operation.responses[String(status)];
    if (!response) throw new Error(`Contract has no ${status} response for ${method} ${literal}`);
    const schema = response['application/json'];
    if (schema) this.validate(body, schema);
    else if (status === 204 && body !== undefined) throw new Error('204 response carried a body');
  }

  validate(value, schema, at = '$', depth = 0) {
    if (depth > 100) throw new Error(`${at}: contract recursion limit`);
    if (schema.ref) {
      const target = this.document.schemas[schema.ref];
      if (!target) throw new Error(`Unknown contract reference ${schema.ref}`);
      return this.validate(value, { ...target, ...schema, ref: undefined }, at, depth + 1);
    }
    if (value === null && schema.nullable) return;
    for (const keyword of ['allOf', 'anyOf', 'oneOf']) {
      if (!schema[keyword]) continue;
      const matches = schema[keyword].filter(member => {
        try { this.validate(value, member, at, depth + 1); return true; } catch { return false; }
      }).length;
      if ((keyword === 'allOf' && matches !== schema[keyword].length) ||
          (keyword === 'anyOf' && matches === 0) || (keyword === 'oneOf' && matches !== 1)) {
        throw new Error(`${at}: does not satisfy ${keyword}`);
      }
    }
    const type = schema.type;
    const matches = {
      object: value !== null && typeof value === 'object' && !Array.isArray(value),
      array: Array.isArray(value), string: typeof value === 'string',
      integer: Number.isInteger(value), number: typeof value === 'number' && Number.isFinite(value),
      boolean: typeof value === 'boolean', null: value === null,
    };
    if (type && !matches[type]) throw new Error(`${at}: expected ${type}`);
    if (schema.enum && !schema.enum.includes(String(value))) throw new Error(`${at}: unexpected enum value`);
    if (Array.isArray(value) && schema.items) {
      value.forEach((item, i) => this.validate(item, schema.items, `${at}[${i}]`, depth + 1));
    }
    if (matches.object) {
      for (const [name, property] of Object.entries(schema.properties ?? {})) {
        if (property.required && !Object.hasOwn(value, name)) throw new Error(`${at}.${name}: missing required property`);
        if (Object.hasOwn(value, name)) this.validate(value[name], property, `${at}.${name}`, depth + 1);
      }
      for (const [name, item] of Object.entries(value)) {
        if (Object.hasOwn(schema.properties ?? {}, name)) continue;
        if (schema.additionalProperties === false) throw new Error(`${at}: unexpected property`);
        if (typeof schema.additionalProperties === 'object') {
          this.validate(item, schema.additionalProperties, `${at}.*`, depth + 1);
        }
      }
    }
    // The projection retains format but drops numeric/string constraints.
    // This verifier intentionally promises structural validation only.
  }
}
