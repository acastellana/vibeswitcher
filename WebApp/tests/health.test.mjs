// The node's health digest on This node (js/health.js, the server's NodeHealth).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { healthFacts } from '../js/health.js';

const quiet = { since: '2026-11-21T08:00:00.000Z', stalled: null, freezes: [], slowRefreshes: 0, slowestRefresh: null, lastSlowRefresh: null,
  serverRestarts: 0, refusedConnections: null, hostRestartAt: null, waiting: [], errors: [] };

test('a quiet node reads as fine, with nothing listed', () => {
  const facts = healthFacts(quiet);
  assert.equal(facts.tone, 'done');
  assert.deepEqual(facts.rows.find(([name]) => name === 'Freezes'), ['Freezes', 'None']);
  assert.equal(facts.lines.length, 0);
  assert.equal(healthFacts(undefined), null);
});

test('a stall, freezes, waiting sessions and errors need a look, each listed', () => {
  const facts = healthFacts({ ...quiet, stalled: 12, freezes: [{ at: '2026-11-21T09:00:00.000Z', seconds: 14 }, { at: '2026-11-21T08:30:00.000Z', seconds: 31 }],
    slowRefreshes: 3, slowestRefresh: 9, refusedConnections: 2, waiting: ['reminder: waiting on you, on ttypts4'],
    errors: [{ at: '2026-11-21T09:10:00.000Z', line: 'set boost: not changed: disk full' }] });
  assert.equal(facts.tone, 'needs-you');
  assert.deepEqual(facts.rows[0], ['Stalled now', 'the engine hasn’t answered for 12 s']);
  assert.deepEqual(facts.rows.find(([name]) => name === 'Freezes'), ['Freezes', '2 freezes, the longest 31 s']);
  assert.deepEqual(facts.rows.find(([name]) => name === 'Refused connections'), ['Refused connections', '2']);
  assert.equal(facts.lines.length, 4);
  assert.ok(facts.lines.some((line) => line.text === 'set boost: not changed: disk full'));
});
