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

test('the node’s plain fields: each item’s `what`, the rules’ `changed`/`old`/`records`, `holds`, `recordsAll`, `summary`', () => {
  assert.equal(itemLabel({ name: '~/.local/bin/claude', kind: 'claude-update', what: 'Claude Code’s link moved to 2.1.332', from: '2.1.331', to: '2.1.332' }), 'Claude Code’s link moved to 2.1.332');
  assert.equal(itemLabel({ name: 'x', what: 'the plugin genlayernode updated', from: '0.4.0', to: '0.4.1' }), 'the plugin genlayernode updated (0.4.0 → 0.4.1)');
  assert.deepEqual(railState({ changed: 'changed', old: 'true', value: 'false' }), { state: 'changed', before: 'true' });
  assert.deepEqual(railState({ changed: 'changed', value: 'x' }), { state: 'new', before: null }, 'not set at the last accept');
  assert.deepEqual(railState({ changed: 'same' }), { state: 'same', before: null });
  assert.deepEqual(railState({ changed: 'unknown', records: true }), { state: 'records', before: null });
  const card = heldSummary({ items: [{ name: 'a', what: 'one' }, { name: 'b', what: 'two' }],
    guarded: [{ key: 'k', value: 'v', changed: 'same' }], holds: 'example-app', summary: 'one; and 1 more', pageMayAccept: true });
  assert.deepEqual([card.title, card.line, card.holds, card.summary, card.terminal], ['2 things changed', 'one, two', 'example-app', 'one; and 1 more', false], 'the node’s word on accepting');
});

test('the node’s newer words for what it can’t vouch for: “can’t be compared with your last accept … the node restarted since”', () => {
  const words = 'can\'t be compared with your last accept (2026-11-25T10:00:00Z): the node restarted since';
  assert.deepEqual(railState({ sinceAccept: words }), { state: 'unknown', before: null });
  assert.deepEqual(heldSummary({ items: [{ name: '~/.zshrc', kind: 'other', what: '~/.zshrc changed', sinceAccept: words }], guarded: [] }).lines,
    ['~/.zshrc changed (can’t be compared with your last accept)']);
});

test('the reviewed rules: every non-update named, updates only while under three lines, the rest counted', async () => {
  const { itemLines } = await import('../js/heldconfig.js');
  const items = [
    { kind: 'claude-update', what: '~/.local/bin/claude now points to 2.1.332 (looks like Claude Code’s own update)' },
    { kind: 'git-config', what: '.git/config: the tracking entry of branch v2-x' },
    { kind: 'plugin-update', what: 'plugin genlayernode updated' },
    { kind: 'build-switch', what: 'VibeSwitcher’s unit starts build 3e9df41a now' },
    { kind: 'startup', what: 'the Windows Startup folder: X.lnk added' },
  ];
  assert.deepEqual(itemLines(items), { lines: ['.git/config: the tracking entry of branch v2-x', 'the Windows Startup folder: X.lnk added',
    '~/.local/bin/claude now points to 2.1.332 (looks like Claude Code’s own update)'], moreUpdates: 2 });
  const many = Array.from({ length: 5 }, (_, i) => ({ kind: 'settings', what: `s${i}` }));
  assert.deepEqual(itemLines([...many, items[0]]), { lines: ['s0', 's1', 's2', 's3', 's4'], moreUpdates: 1 }, 'no cap on what isn’t an update');
});

test('a first accept: the rules set away from their defaults (sandbox_ first, eight), then the defaults counted; unknown rules not shown', () => {
  const guarded = [...Array.from({ length: 9 }, (_, i) => ({ key: `k${i}`, value: 'v', changed: 'unknown', atDefault: false })), { key: 'sandbox_read', value: '~/x', changed: 'unknown', atDefault: false },
    ...Array.from({ length: 5 }, (_, i) => ({ key: `d${i}`, value: 'v', changed: 'unknown', atDefault: true }))];
  const card = heldSummary({ items: [{ kind: 'settings', what: 'x' }], guarded, recordsAll: true, pageMayAccept: false });
  assert.deepEqual([card.first.shown[0].key, card.first.shown.length, card.first.more, card.first.defaults, card.unknown, card.terminal], ['sandbox_read', 8, 2, 5, 0, true]);
});
