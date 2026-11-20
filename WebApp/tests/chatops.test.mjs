// A chat's ops (the wire contract §6), as the store applies them and the mock makes them: the node's own pair, held to
// each other. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { applyOps, diffOps, newSince, sinceSummary } from '../js/chatops.js';

const reply = (id, text, more = {}) => ({ id, type: 'reply', at: null, text, ...more });
const chatOf = (items) => ({ items: structuredClone(items), index: new Map(items.map((item, i) => [item.id, i])) });

test('the ops made from two lists take the first to the second', () => {
  const cases = [
    [[], [reply('a', 'A')]],
    [[reply('a', 'It reads')], [reply('a', 'It reads the header')]],
    [[reply('a', 'It reads')], [reply('a', 'It read')]],
    [[reply('a', 'A'), reply('b', 'B')], [reply('b', 'B'), reply('c', 'C')]],
    [[reply('a', 'A'), reply('c', 'C')], [reply('a', 'A'), reply('b', 'B'), reply('c', 'C')]],
    [[reply('a', 'A')], [reply('a', 'A', { streaming: true })]],
    [[reply('a', '😀')], [reply('a', '😀😀 and more')]],
  ];
  for (const [before, after] of cases) {
    const chat = chatOf(before);
    const done = applyOps(chat, diffOps(before, after));
    assert.equal(done.gap, undefined, JSON.stringify([before, after]));
    assert.deepEqual(chat.items, after);
    assert.deepEqual([...chat.index], after.map((item, i) => [item.id, i]));
  }
});

test('text that only grew is a text op at the old length, in UTF-16 code units; anything else is a set', () => {
  assert.deepEqual(diffOps([reply('a', 'ok 😀')], [reply('a', 'ok 😀!')]), [{ op: 'text', id: 'a', at: 5, append: '!' }]);
  assert.deepEqual(diffOps([reply('a', 'It reads')], [reply('a', 'It read')]), [{ op: 'set', item: reply('a', 'It read') }]);
  assert.deepEqual(diffOps([reply('a', 'A')], [reply('a', 'AB', { streaming: false })]), [{ op: 'set', item: reply('a', 'AB', { streaming: false }) }]);
});

test('an op this client doesn’t know is skipped (rule 3)', () => {
  const chat = chatOf([reply('a', 'A')]);
  assert.deepEqual(applyOps(chat, [{ op: 'pin', id: 'a' }, { op: 'text', id: 'a', at: 1, append: 'B' }]).touched, [{ type: 'text', id: 'a' }]);
  assert.equal(chat.items[0].text, 'AB');
});

test('"New since you looked" goes after the last item seen, when something followed it', () => {
  const items = [{ id: 'a', type: 'prompt' }, { id: 'b', type: 'reply' }, { id: 'c', type: 'tools', tools: [] }, { id: 'd', type: 'reply' }];
  assert.equal(newSince(items, 'b'), 2);
  assert.equal(newSince(items, 'd'), -1, 'nothing after it');
  assert.equal(newSince(items, 'gone'), -1, 'not among the items');
  assert.equal(newSince(items, undefined), -1, 'nothing seen yet');
});

test('what came since, in a line: the tools as a fold says them, then the replies', () => {
  const command = { detail: { type: 'command' } };
  const edit = { detail: { type: 'edit' } };
  assert.equal(sinceSummary([{ type: 'tools', tools: [command, command, edit] }, { type: 'reply' }, { type: 'reply' }]), 'Ran 2 commands · edited 1 file · 2 replies');
  assert.equal(sinceSummary([{ type: 'reply' }]), '1 reply');
  assert.equal(sinceSummary([{ type: 'prompt' }]), '');
});
