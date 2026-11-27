// Find in a session's terminal (P4): xterm.js's search add-on, vendored (vendor/addon-search.mjs, its hash in
// vendor/README.md, checked by tests/vendor.test.mjs) and loaded with xterm.js; a find bar that highlights every match,
// steps next and previous, says "3 of 12", and closes with Escape; the platform's key opens it only while a terminal
// shows, never taking the browser's own find anywhere else. The bar is driven over a stand-in of the add-on (its
// findNext, findPrevious, clearDecorations, onDidChangeResults); the add-on itself is the vendored module.
// Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { installDom, find, byClass, FakeNode } from './fakedom.test.mjs';

installDom();
globalThis.matchMedia = () => ({ matches: false, addEventListener() {} });
globalThis.MutationObserver ??= class { observe() {} disconnect() {} };
const { findKey, findKeys, terminalFind, findDecorations, findTheme, FIND_COLOURS } = await import('../js/views/terminal.js');
const { setLanguage, t } = await import('../js/i18n.js');
const here = dirname(fileURLToPath(import.meta.url));

// The add-on's surface the bar uses, recording each call; `results` is what it says after a search.
function fakeSearch(results = { resultIndex: 0, resultCount: 0 }) {
  const calls = [];
  let listener = null;
  return {
    calls,
    set results(value) { results = value; },
    onDidChangeResults(fn) { listener = fn; return { dispose() {} }; },
    findNext(term, options) { calls.push(['next', term, options]); listener?.(results); return results.resultCount > 0; },
    findPrevious(term, options) { calls.push(['previous', term, options]); listener?.(results); return results.resultCount > 0; },
    clearDecorations() { calls.push(['clear']); },
  };
}
const key = (fields) => ({ key: '', altKey: false, ctrlKey: false, metaKey: false, shiftKey: false, ...fields });
const typeInto = (input, value) => { input.value = value; input.dispatch('input'); };
const press = (input, fields) => { const said = { prevented: false }; input.dispatch('keydown', { ...key(fields), preventDefault() { said.prevented = true; }, stopPropagation() {} }); return said; };

test('P4: the platform’s key: ⌘F on a Mac; Ctrl+Shift+F elsewhere, Ctrl+F only where the keyboard isn’t the program’s', () => {
  assert.equal(findKey(key({ key: 'f', metaKey: true }), { mac: true }), 'open');
  assert.equal(findKey(key({ key: 'f', metaKey: true }), { mac: true, typing: true }), 'open', 'a Mac’s ⌘ keys are never the program’s');
  assert.equal(findKey(key({ key: 'f', ctrlKey: true }), { mac: true }), null, 'Ctrl+F on a Mac is the program’s');
  assert.equal(findKey(key({ key: 'f', metaKey: true, altKey: true }), { mac: true }), null);
  assert.equal(findKey(key({ key: 'g', metaKey: true }), { mac: true, open: true }), 'next');
  assert.equal(findKey(key({ key: 'G', metaKey: true, shiftKey: true }), { mac: true, open: true }), 'previous');
  assert.equal(findKey(key({ key: 'g', metaKey: true }), { mac: true, open: false }), null, '⌘G is the browser’s while find is closed');
  assert.equal(findKey(key({ key: 'F', ctrlKey: true, shiftKey: true }), { mac: false, typing: true }), 'open');
  assert.equal(findKey(key({ key: 'f', ctrlKey: true }), { mac: false, typing: true }), null, 'Ctrl+F is the shell’s while you type into it');
  assert.equal(findKey(key({ key: 'f', ctrlKey: true }), { mac: false, typing: false }), 'open');
  assert.equal(findKey(key({ key: 'F3' }), { mac: false, open: true }), 'next');
  assert.equal(findKey(key({ key: 'F3', shiftKey: true }), { mac: false, open: true }), 'previous');
  for (const other of [key({ key: 'k', metaKey: true }), key({ key: 'f' }), key({ key: 'Escape' }), key({ key: 'f', ctrlKey: true, metaKey: true })]) {
    assert.equal(findKey(other, { mac: true }), null);
    assert.equal(findKey(other, { mac: false }), null);
  }
});

test('P4: the bar highlights every match as you type, steps next and previous, says where it is, and closes with Escape', () => {
  setLanguage('en');
  const search = fakeSearch({ resultIndex: 2, resultCount: 12 });
  let closed = 0;
  let opened = 0;
  const bar = terminalFind({ search, dark: () => false, opened: () => { opened += 1; }, closed: ({ refocus }) => { if (refocus) closed += 1; } });
  assert.ok(bar.el.hidden, 'closed until asked');
  assert.equal(bar.el.attrs.role, 'search');
  bar.open();
  assert.ok(!bar.el.hidden);
  assert.equal(opened, 1, 'the terminal takes find’s look');
  bar.open();
  assert.equal(opened, 1, 'once, while it stays open');
  const input = find(bar.el, byClass('find-input'));
  assert.equal(input.attrs.placeholder, t('teFindInTerminal'));
  typeInto(input, 'error');
  const [kind, term, options] = search.calls.at(-1);
  assert.deepEqual([kind, term, options.incremental], ['next', 'error', true], 'found as you type, from where it is');
  assert.deepEqual(options.decorations, findDecorations(false), 'every match highlighted, the current one stronger');
  const count = find(bar.el, byClass('find-count'));
  assert.equal(count.textContent, t('chOf', { a: 3, b: '12' }));
  search.results = { resultIndex: 3, resultCount: 12 };
  press(input, { key: 'Enter' });
  assert.deepEqual(search.calls.at(-1).slice(0, 2), ['next', 'error']);
  assert.equal(search.calls.at(-1)[2].incremental, false);
  assert.equal(count.textContent, t('chOf', { a: 4, b: '12' }));
  search.results = { resultIndex: 2, resultCount: 12 };
  press(input, { key: 'Enter', shiftKey: true });
  assert.deepEqual(search.calls.at(-1).slice(0, 2), ['previous', 'error']);
  assert.equal(count.textContent, t('chOf', { a: 3, b: '12' }));
  // The buttons do the same.
  const buttons = bar.el.children.filter((node) => node.tag === 'button');
  buttons[1].dispatch('click');
  assert.equal(search.calls.at(-1)[0], 'next');
  buttons[0].dispatch('click');
  assert.equal(search.calls.at(-1)[0], 'previous');
  const escape = press(input, { key: 'Escape' });
  assert.ok(escape.prevented);
  assert.ok(bar.el.hidden, 'Escape closes it');
  assert.deepEqual(search.calls.at(-1), ['clear'], 'and takes the highlights away');
  assert.equal(closed, 1, 'the focus goes back to the terminal');
  assert.equal(count.textContent, '');
  // Closed as the pane goes: its look back, the focus left where it is.
  bar.open();
  bar.close({ refocus: false });
  assert.equal(closed, 1);
  // While open, the selection (the current match) is the current match's orange, focused or not; the rest of the
  // theme as it was.
  const theme = { background: '#1E1E1E', foreground: '#FFFFFF', selectionBackground: '#444444' };
  const finding = findTheme(theme, true);
  assert.equal(finding.selectionBackground, FIND_COLOURS.dark.border);
  assert.equal(finding.selectionInactiveBackground, FIND_COLOURS.dark.border);
  assert.equal(finding.background, theme.background);
  assert.equal(theme.selectionBackground, '#444444', 'the theme itself unchanged');
});

test('P4: no match says so; an empty field finds nothing; a dark terminal gets the dark highlights', () => {
  setLanguage('en');
  const search = fakeSearch({ resultIndex: -1, resultCount: 0 });
  const bar = terminalFind({ search, dark: () => true });
  bar.open();
  const input = find(bar.el, byClass('find-input'));
  typeInto(input, 'nothing-here');
  assert.equal(find(bar.el, byClass('find-count')).textContent, t('chNoMatches'));
  assert.deepEqual(search.calls.at(-1)[2].decorations, findDecorations(true));
  assert.equal(findDecorations(true).matchBackground, FIND_COLOURS.dark.match);
  typeInto(input, '');
  assert.deepEqual(search.calls.at(-1), ['clear']);
  assert.equal(find(bar.el, byClass('find-count')).textContent, '');
  // More than the add-on highlights: the count says so.
  search.results = { resultIndex: 0, resultCount: 1000 };
  typeInto(input, 'a');
  assert.equal(find(bar.el, byClass('find-count')).textContent, t('chOf', { a: 1, b: '1000+' }));
  for (const { match, active, border } of Object.values(FIND_COLOURS)) {
    for (const colour of [match, active]) assert.match(colour, /^#[0-9A-F]{8}$/, 'a hex xterm.js takes');
    assert.match(border, /^#[0-9A-F]{6}$/, 'the current match’s outline, opaque');
  }
  assert.equal(findDecorations(false).activeMatchBorder, FIND_COLOURS.light.border);
});

test('P4: the key opens find only while a terminal shows, the focus in it or in nothing; anywhere else it stays the browser’s', () => {
  const pane = new FakeNode('div');
  const screen = new FakeNode('div');
  const textarea = new FakeNode('textarea');
  screen.append(textarea);
  pane.append(screen);
  const elsewhere = new FakeNode('input');
  let opened = 0;
  let stepped = [];
  const bar = { open: () => { opened += 1; }, step: (by) => stepped.push(by), shown: () => opened > 0 };
  let shown = true;
  let readOnly = false;
  const handler = findKeys({ pane, screen, finder: () => bar, shown: () => shown, readOnly: () => readOnly, mac: true });
  const fire = (target, fields) => { const event = { ...key(fields), target, prevented: false, preventDefault() { this.prevented = true; } }; handler(event); return event; };
  // In the terminal: ⌘F is find, the browser's find doesn't open.
  assert.ok(fire(textarea, { key: 'f', metaKey: true }).prevented);
  assert.equal(opened, 1);
  // With nothing focused (the page's body) while the terminal shows: find too.
  assert.ok(fire(globalThis.document.body, { key: 'f', metaKey: true }).prevented);
  // ⌘G steps while it is open.
  assert.ok(fire(textarea, { key: 'g', metaKey: true }).prevented);
  assert.deepEqual(stepped, [1]);
  // In another field of the page: the browser's.
  const other = fire(elsewhere, { key: 'f', metaKey: true });
  assert.ok(!other.prevented);
  // No terminal shown (the chat, a placeholder, another page): the browser's, from anywhere.
  shown = false;
  for (const target of [textarea, globalThis.document.body, elsewhere]) assert.ok(!fire(target, { key: 'f', metaKey: true }).prevented);
  assert.equal(opened, 2);
  // Elsewhere than a Mac: Ctrl+F stays the shell's while you type into the terminal, Ctrl+Shift+F is find.
  shown = true;
  const linux = findKeys({ pane, screen, finder: () => bar, shown: () => shown, readOnly: () => readOnly, mac: false });
  const fireLinux = (target, fields) => { const event = { ...key(fields), target, prevented: false, preventDefault() { this.prevented = true; } }; linux(event); return event; };
  assert.ok(!fireLinux(textarea, { key: 'f', ctrlKey: true }).prevented);
  assert.ok(fireLinux(textarea, { key: 'F', ctrlKey: true, shiftKey: true }).prevented);
  readOnly = true;
  assert.ok(fireLinux(textarea, { key: 'f', ctrlKey: true }).prevented, 'watched: Ctrl+F is find');
  // Before the emulator is made there is nothing to find in.
  const none = findKeys({ pane, screen, finder: () => null, shown: () => true, readOnly: () => false, mac: true });
  const early = { ...key({ key: 'f', metaKey: true }), target: textarea, prevented: false, preventDefault() { this.prevented = true; } };
  none(early);
  assert.ok(!early.prevented);
});

test('P4: the vendored add-on is xterm.js’s SearchAddon, loaded with xterm.js and fit, with the highlights’ API on', async () => {
  const { SearchAddon } = await import('../vendor/addon-search.mjs');
  assert.equal(typeof SearchAddon, 'function');
  const addon = new SearchAddon();
  for (const method of ['activate', 'findNext', 'findPrevious', 'clearDecorations', 'dispose']) assert.equal(typeof addon[method], 'function', method);
  assert.equal(typeof addon.onDidChangeResults, 'function');
  const source = readFileSync(join(here, '..', 'js', 'views', 'terminal.js'), 'utf8');
  assert.match(source, /import\('\.\.\/\.\.\/vendor\/addon-search\.mjs'\)/);
  assert.match(source, /allowProposedApi: true/);
  assert.match(source, /term\.loadAddon\(search\)/);
});
