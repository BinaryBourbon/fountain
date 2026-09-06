import test from 'node:test';
import assert from 'node:assert/strict';
import { verifyAdvertisement } from '../lib/advertisement.mjs';

const contract = { operations: { 'GET /api/widgets': { responses: { 200: { 'application/json': { ref: 'Widget' } } } } },
  schemas: { Widget: { type: 'object', properties: { id: { type: 'string', required: true }, count: { type: 'integer', required: false } } } } };
const spec = { openapi: '3.0.0', paths: { '/api/widgets': { get: { responses: { 200: {
  content: { 'application/json': { schema: { $ref: '#/components/schemas/Widget' } } },
} } } } }, components: { schemas: { Widget: { type: 'object', required: ['id'], properties: { id: { type: 'string' }, count: { type: 'integer' } } } } } };
const operations = ['GET /api/widgets'];

test('advertised contract can add fields without redefining the pinned contract', () => {
  const changed = structuredClone(spec);
  changed.components.schemas.Widget.properties.extra = { type: 'boolean' };
  assert.doesNotThrow(() => verifyAdvertisement(changed, contract, operations));
});

test('advertised schema cannot remove an operation, required field, or change its type', () => {
  const removedOperation = structuredClone(spec);
  delete removedOperation.paths['/api/widgets'];
  assert.throws(() => verifyAdvertisement(removedOperation, contract, operations), /operation missing/);
  const removedField = structuredClone(spec);
  delete removedField.components.schemas.Widget.properties.id;
  assert.throws(() => verifyAdvertisement(removedField, contract, operations), /schema missing/);
  const optional = structuredClone(spec);
  optional.components.schemas.Widget.required = [];
  assert.throws(() => verifyAdvertisement(optional, contract, operations), /requiredness/);
  const changedType = structuredClone(spec);
  changedType.components.schemas.Widget.properties.count.type = 'string';
  assert.throws(() => verifyAdvertisement(changedType, contract, operations), /type differs/);
});
