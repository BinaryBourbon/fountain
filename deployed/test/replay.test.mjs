import test from 'node:test';
import assert from 'node:assert/strict';
import { compareEvents } from '../lib/replay.mjs';

const events = [3, 9, 41].map(id => ({ id, kind: 'output', stream: 'acp', data: `event ${id}`, stage: null, state: null, turn_id: 'turn', ts: '2026-09-06T00:00:00Z', blocks: [] }));

test('replay compares a fixed durable prefix while allowing later live events', () => {
  assert.equal(compareEvents(events, events, { through: 9 }), 2);
  assert.equal(compareEvents(events.slice(1), events, { after: 3, through: 41 }), 2);
  assert.equal(compareEvents(events, events.map(e => ({ ...e, duration_ms: 8 })), { through: 41 }), 3);
});

test('replay rejects gaps, duplicates, reordered IDs and ignored Last-Event-ID', () => {
  assert.throws(() => compareEvents([events[0], events[2]], events, { through: 41 }), /count differs/);
  assert.throws(() => compareEvents([events[0], events[0], events[1]], events, { through: 41 }), /duplicated/);
  assert.throws(() => compareEvents([events[1], events[0], events[2]], events, { through: 41 }), /reordered/);
  assert.throws(() => compareEvents(events, events, { after: 3, through: 41 }), /ignored/);
});

test('matching event IDs cannot hide different SSE and history payloads', () => {
  const changed = structuredClone(events); changed[1].state = '';
  assert.throws(() => compareEvents(changed, events, { through: 41 }), /payload differs at event 9/);
  changed[1] = { ...events[1], data: 'different output' };
  assert.throws(() => compareEvents(changed, events, { through: 41 }), /payload differs at event 9/);
});

test('a missing high-water event or invalid boundary cannot produce a vacuous pass', () => {
  assert.throws(() => compareEvents(events, events, {}), /bounds/);
  assert.throws(() => compareEvents([], [], { through: 41 }), /high-water/);
});

test('nested JSON property order is immaterial but timestamp precision is preserved', () => {
  const stored = [{ ...events[0], blocks: [{ kind: 'text', text: 'hello' }] }];
  const replayed = [{ ...events[0], blocks: [{ text: 'hello', kind: 'text' }] }];
  assert.equal(compareEvents(replayed, stored, { through: 3 }), 1);
  replayed[0].ts = '2026-09-06T00:00:00.094866Z';
  assert.throws(() => compareEvents(replayed, stored, { through: 3 }), /payload differs at event 3 \(ts\)/);
});
