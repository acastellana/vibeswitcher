// Check for Updates on This node (js/updates.js, the server's UpdateWatch.value).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { updateFacts, checkNowLine } from '../js/updates.js';

const commit = 'a'.repeat(40);

test('up to date says so, with the line that checks now', () => {
  const facts = updateFacts({ checkedAt: '2026-11-22T08:00:00.000Z', commit: null, aheadBy: null, install: null, problem: null });
  assert.equal(facts.tone, 'done');
  assert.match(facts.state, /^Up to date/);
  assert.deepEqual(facts.lines.map((line) => line.text), [checkNowLine]);
  assert.equal(facts.checkedAt, '2026-11-22T08:00:00.000Z');
});

test('a newer build names it, with its install and switch lines first', () => {
  const facts = updateFacts({ checkedAt: '2026-11-22T08:00:00.000Z', commit, aheadBy: 3, install: `scripts/install-node.sh ${commit}`, problem: null });
  assert.equal(facts.tone, 'needs-you');
  // The short hash a person reads (D18): 7 characters.
  assert.match(facts.state, /: aaaaaaa \(3 commits ahead\)/);
  assert.deepEqual(facts.lines.map((line) => line.text), [`scripts/install-node.sh ${commit}`, `vibeswitcher switch ${commit}`, checkNowLine]);
});

test('a failed look says why, and a scratch node shows nothing', () => {
  const failed = updateFacts({ checkedAt: null, commit: null, aheadBy: null, install: null, problem: 'gh has no token' });
  assert.equal(failed.tone, 'unknown');
  assert.equal(failed.problem, 'gh has no token');
  assert.match(failed.state, /last try failed/);
  // Up to date once, then a failed look: still up to date as of then, the problem said.
  const stale = updateFacts({ checkedAt: '2026-11-22T08:00:00.000Z', commit: null, aheadBy: null, install: null, problem: 'offline' });
  assert.equal(stale.tone, 'done');
  assert.equal(stale.problem, 'offline');
  assert.equal(updateFacts(undefined), null);
  assert.equal(updateFacts(null), null);
});
