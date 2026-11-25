// The held-config card in plain words (js/heldconfig.js): the title from what changed, the rails that changed only,
// and whether accepting is the terminal's.
import test from 'node:test';
import assert from 'node:assert/strict';
import { itemLabel, heldTitle, railState, heldSummary } from '../js/heldconfig.js';
import { setLanguage } from '../js/i18n.js';

setLanguage('en');
const unvouched = "can't be compared with your last accept (2026-11-24T13:28:34.630Z)";

test('each held thing in a few words: the node’s own label first, else read off its name', () => {
  assert.equal(itemLabel({ name: 'x', what: { label: 'Claude Code updated itself', from: '2.1.331', to: '2.1.332' } }), 'Claude Code updated itself (2.1.331 → 2.1.332)');
  assert.equal(itemLabel({ name: 'plugin genlayernode@genlayer-plugins' }), 'A plugin updated: genlayernode');
  assert.equal(itemLabel({ name: '~/.vibeswitcher/bin' }), 'VibeSwitcher switched to a new build');
  assert.equal(itemLabel({ name: '.git/config (main checkout)' }), 'This checkout’s git config changed');
  assert.equal(itemLabel({ name: '~/.claude/settings.json’s scripts'.replace('’', "'") }), 'The scripts your Claude Code settings run changed');
  assert.equal(itemLabel({ name: '~/.zshrc' }), 'Your shell’s startup file changed: .zshrc');
  assert.equal(itemLabel({ name: '~/.local/bin/claude' }), 'Files changed in ~/.local/bin');
});

test('the title: one thing in its own words; several, their count and a line naming three, then how many more', () => {
  assert.deepEqual(heldTitle([{ name: '~/.vibeswitcher/bin' }]), { title: 'VibeSwitcher switched to a new build', line: null });
  assert.deepEqual(heldTitle([{ name: 'x', what: { label: 'Claude Code updated itself', from: '2.1.331', to: '2.1.332' } }]), { title: 'Claude Code updated itself (2.1.331 → 2.1.332)', line: null });
  assert.deepEqual(heldTitle([{ name: '.git/config (main checkout)' }, { name: '~/.bashrc' }, { name: '~/.claude/settings.json' }, { name: '~/.zshrc' }, { name: '~/.gitconfig' }, { name: 'plugin a@m' }, { name: '~/.vibeswitcher/bin' }]),
    { title: '7 things changed', line: 'this checkout’s git config, your shell’s startup file (.bashrc), Claude’s settings, and 4 more' });
  assert.deepEqual(heldTitle([{ name: '~/.zshrc' }, { name: 'plugin a@m', what: { label: 'A plugin updated: a', short: 'the plugin a (1.2 → 1.3)' } }]), { title: '2 things changed', line: 'your shell’s startup file (.zshrc), the plugin a (1.2 → 1.3)' });
});

test('nothing held and no rule changed, only rules that can’t be compared: the node wants them confirmed once', () => {
  const restarted = heldSummary({ items: [], guarded: [{ key: 'test_command', value: 'true', sinceAccept: unvouched }] });
  assert.deepEqual([restarted.confirmOnly, restarted.terminal], [true, true]);
  assert.equal(heldSummary({ items: [{ name: '~/.zshrc' }], guarded: [{ key: 'k', value: 'v', sinceAccept: unvouched }] }).confirmOnly, false);
  assert.equal(heldSummary({ items: [{ name: '~/.zshrc' }], guarded: [], pageMayAccept: false }).terminal, true, 'the node’s own word');
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

test('the node’s `firstLook`: nothing held, no sealed accept: confirm the rules once, whatever the rules say', () => {
  const first = heldSummary({ items: [], guarded: [{ key: 'test_command', value: 'true', sinceAccept: null }], firstLook: true });
  assert.deepEqual([first.confirmOnly, first.terminal], [true, false]);
});
