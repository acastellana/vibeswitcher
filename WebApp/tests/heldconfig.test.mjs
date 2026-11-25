// The held-config card in plain words (js/heldconfig.js): the title from what changed, the rails that changed only,
// and whether accepting is the terminal's.
import test from 'node:test';
import assert from 'node:assert/strict';
import { itemLabel, heldTitle, railState, heldSummary } from '../js/heldconfig.js';
import { setLanguage } from '../js/i18n.js';

setLanguage('en');
const unvouched = 'not known to be the same as at your last accept (2026-11-24T13:28:34.630Z): the snapshot that lists it isn’t sealed by this host’s vault (a host restart since, or it was rewritten), so read it';

test('each held thing in a few words: the node’s own label first, else read off its name', () => {
  assert.equal(itemLabel({ name: 'x', what: { label: 'Claude Code updated itself', from: '2.1.331', to: '2.1.332' } }), 'Claude Code updated itself (2.1.331 → 2.1.332)');
  assert.equal(itemLabel({ name: 'plugin genlayernode@genlayer-plugins' }), 'A plugin updated: genlayernode');
  assert.equal(itemLabel({ name: '~/.vibeswitcher/bin' }), 'VibeSwitcher switched to a new build');
  assert.equal(itemLabel({ name: '.git/config (main checkout)' }), 'This checkout’s git config changed');
  assert.equal(itemLabel({ name: '~/.claude/settings.json’s scripts'.replace('’', "'") }), 'The scripts your Claude Code settings run changed');
  assert.equal(itemLabel({ name: '~/.zshrc' }), 'Your shell’s startup file changed: .zshrc');
  assert.equal(itemLabel({ name: '~/.local/bin/claude' }), 'Files changed in ~/.local/bin');
});

test('the title: one thing by its label; several, their count and the first two', () => {
  assert.equal(heldTitle([{ name: '~/.vibeswitcher/bin' }]), 'VibeSwitcher switched to a new build');
  assert.equal(heldTitle([{ name: '~/.zshrc' }, { name: 'plugin a@m' }]), '2 things changed: Your shell’s startup file changed: .zshrc, a plugin updated: a');
  assert.equal(heldTitle([{ name: 'plugin a@m' }, { name: '~/.vibeswitcher/bin' }, { name: '~/.zshrc' }]), '3 things changed: A plugin updated: a, VibeSwitcher switched to a new build, …');
});

test('a rail against the last accept, from the node’s words until it says it in fields', () => {
  assert.deepEqual(railState({ sinceAccept: 'the same as at your last accept (2026-11-24)' }), { state: 'same', before: null });
  assert.deepEqual(railState({ sinceAccept: 'changed since your last accept (2026-11-24), from “true”' }), { state: 'changed', before: 'true' });
  assert.deepEqual(railState({ sinceAccept: 'not in your last accept (2026-11-24)' }), { state: 'new', before: null });
  assert.deepEqual(railState({ sinceAccept: unvouched }), { state: 'unknown', before: null });
  assert.deepEqual(railState({ state: 'changed', before: '2' }), { state: 'changed', before: '2' });
});

test('the face: only the rails that changed; the ones that can’t be compared counted; then it is the terminal’s', () => {
  const unchanged = heldSummary({ items: [{ name: '~/.vibeswitcher/bin' }], guarded: [{ key: 'test_command', value: 'true', sinceAccept: 'the same as at your last accept (x)' }] });
  assert.deepEqual([unchanged.changed.length, unchanged.unknown, unchanged.terminal], [0, 0, false]);
  const changed = heldSummary({ items: [], guarded: [{ key: 'auto_advance', value: 'false', sinceAccept: 'changed since your last accept (x), from “true”' }, { key: 'test_command', value: 'true', sinceAccept: 'the same as at your last accept (x)' }] });
  assert.deepEqual(changed.changed.map((rail) => [rail.key, rail.before, rail.value]), [['auto_advance', 'true', 'false']]);
  assert.equal(changed.terminal, true);
  const restarted = heldSummary({ items: [], guarded: Array.from({ length: 19 }, (_, i) => ({ key: `k${i}`, value: 'v', sinceAccept: unvouched })) });
  assert.deepEqual([restarted.changed.length, restarted.unknown, restarted.terminal], [0, 19, true]);
});
