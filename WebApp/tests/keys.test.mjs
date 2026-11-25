// The left column's keys, as v1 had them before the redesign dropped them (js/keys.js): the first nine, next and
// previous, next needing you (your own sessions as well as projects), and the filter by typing grouped by what needs
// you; never while typing in a field, never on a combination the browser keeps; in the palette beside their commands
// and in the README's key table. Drawn on tests/fakedom.test.mjs's stand-in DOM. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { installDom, find, findAll, byClass } from './fakedom.test.mjs';

installDom();
const { setLanguage, t } = await import('../js/i18n.js');
const { shortcut, typing, keyNames, stepTo, needingHref, nthHref, stepHref, keyCommands } = await import('../js/keys.js');
const { leftColumn, leftOrder, filterItems, ownSession } = await import('../js/views/left.js');
const { projectHref, sessionHref } = await import('../js/ui.js');

// A keydown as the browser gives it: `code`, `key`, its modifiers, its target.
const key = (code, mods = {}, target = null) => ({ code, key: mods.key ?? (code.startsWith('Digit') ? code.slice(5) : code.startsWith('Key') ? code.slice(3).toLowerCase() : code),
  altKey: false, metaKey: false, ctrlKey: false, shiftKey: false, target, getModifierState: (name) => name === 'AltGraph' && !!mods.altGraph, ...mods });
const field = (tag) => ({ closest: (selector) => (selector.includes(tag) ? {} : null) });

test('the keys: ⌥1–9, ⌥↓ ⌥↑, ⌘J or ⌥J and ⌥F on a Mac; Ctrl+Shift+1–9, Alt+↓ ↑ and Alt+J elsewhere, and none the browser keeps', () => {
  const mac = (event) => shortcut(event, { mac: true });
  const pc = (event) => shortcut(event, { mac: false });
  assert.deepEqual(mac(key('Digit1', { altKey: true })), { do: 'nth', n: 1 });
  assert.deepEqual(mac(key('Digit9', { altKey: true })), { do: 'nth', n: 9 });
  assert.deepEqual(mac(key('ArrowDown', { altKey: true, key: 'ArrowDown' })), { do: 'step', by: 1 });
  assert.deepEqual(mac(key('ArrowUp', { altKey: true, key: 'ArrowUp' })), { do: 'step', by: -1 });
  assert.deepEqual(mac(key('KeyJ', { metaKey: true })), { do: 'needing' });
  assert.deepEqual(mac(key('KeyJ', { altKey: true })), { do: 'needing' });
  assert.deepEqual(mac(key('KeyF', { altKey: true })), { do: 'filter' });
  // The browser's: ⌘1–9 its tabs, ⌥⌘J Chrome's console, ⌘⇧J and ⌃J left alone.
  for (const event of [key('Digit1', { metaKey: true }), key('Digit1', { ctrlKey: true }), key('KeyJ', { metaKey: true, altKey: true }), key('KeyJ', { metaKey: true, shiftKey: true }),
    key('KeyJ', { ctrlKey: true }), key('Digit1', { altKey: true, shiftKey: true }), key('ArrowLeft', { altKey: true, key: 'ArrowLeft' })]) assert.equal(mac(event), null, JSON.stringify(event));
  assert.deepEqual(pc(key('Digit3', { ctrlKey: true, shiftKey: true })), { do: 'nth', n: 3 });
  assert.deepEqual(pc(key('ArrowDown', { altKey: true, key: 'ArrowDown' })), { do: 'step', by: 1 });
  assert.deepEqual(pc(key('KeyJ', { altKey: true })), { do: 'needing' });
  // Ctrl+1–9 and Alt+1–9 the tabs, Ctrl+J Downloads, Alt+F the browser's menu, Alt+← Back.
  for (const event of [key('Digit1', { ctrlKey: true }), key('Digit1', { altKey: true }), key('KeyJ', { ctrlKey: true }), key('KeyF', { altKey: true }),
    key('ArrowLeft', { altKey: true, key: 'ArrowLeft' }), key('Digit1', { ctrlKey: true, altKey: true })]) assert.equal(pc(event), null, JSON.stringify(event));
  // AltGr types a character.
  assert.equal(pc(key('Digit2', { ctrlKey: true, shiftKey: true, altGraph: true })), null);
});

test('the keys never fire while typing in a field, a text box or a terminal', () => {
  for (const tag of ['input', 'textarea', 'select', 'contenteditable', '.terminal-screen']) {
    assert.equal(typing(field(tag)), true, tag);
    for (const event of [key('Digit1', { altKey: true }), key('KeyJ', { metaKey: true }), key('KeyF', { altKey: true }), key('ArrowDown', { altKey: true, key: 'ArrowDown' })]) {
      assert.equal(shortcut({ ...event, target: field(tag) }, { mac: true }), null, `${tag} ${event.code}`);
    }
    assert.equal(shortcut(key('Digit1', { ctrlKey: true, shiftKey: true }, field(tag)), { mac: false }), null);
  }
  assert.equal(typing({ closest: () => null }), false, 'a link or the page');
});

// Two projects (example-api waits on you), and three sessions of yours (one needs you), as the store holds them.
const API = 'local:project:api';
const SITE = 'local:project:site';
const ASKING = 'local:aa000001-0000-4000-8000-000000000001';
function state() {
  const lead = (project, root) => ({ project, root, session: `${project}:lead`, cards: [] });
  return {
    leads: new Map([[SITE, lead(SITE, '/home/dev/projects/example-site')], [API, lead(API, '/home/dev/projects/example-api')]]),
    boards: new Map(),
    cards: new Map([['local:card:q', { id: 'local:card:q', kind: 'question', project: API, open: true, question: { state: 'open', priority: 'blocking', options: [] } }]]),
    sessions: new Map([
      [`${SITE}:lead`, { id: `${SITE}:lead`, role: 'lead', lead: SITE, status: 'working', cwd: '/home/dev/projects/example-site' }],
      [`${API}:lead`, { id: `${API}:lead`, role: 'lead', lead: API, status: 'working', cwd: '/home/dev/projects/example-api' }],
      [ASKING, { id: ASKING, role: null, status: 'needs-you', title: 'Why does the payout job run twice?', cwd: '/home/dev/projects/payouts', agent: 'claude' }],
      ['local:bb000002-0000-4000-8000-000000000002', { id: 'local:bb000002-0000-4000-8000-000000000002', role: null, status: 'working', title: 'Sync the docs', cwd: '/home/dev/projects/docs', agent: 'claude' }],
    ]),
    node: null, connection: 'live',
  };
}

test('next needing you reaches your own sessions that need you as well as the projects, round again', () => {
  const s = state();
  const first = needingHref(s, { name: 'home' }, ownSession);
  assert.equal(first, projectHref(API), 'the project that waits first');
  assert.equal(needingHref(s, { name: 'project', id: API }, ownSession), sessionHref(ASKING), 'then your own session that needs you');
  assert.equal(needingHref(s, { name: 'session', id: ASKING }, ownSession), projectHref(API), 'round again');
  s.cards.clear();
  s.sessions.get(ASKING).status = 'idle';
  assert.equal(needingHref(s, { name: 'home' }, ownSession), null, 'nothing waits: nowhere to go');
});

test('the first nine and next and previous follow the left column’s order, the filter’s rows while it holds words', () => {
  const s = state();
  const items = leftOrder(s);
  assert.deepEqual(items.map((item) => item.id), [SITE, API], 'the projects, as the column lists them');
  assert.equal(nthHref(items, 1), projectHref(SITE));
  assert.equal(nthHref(items, 2), projectHref(API));
  assert.equal(nthHref(items, 3), null, 'no third');
  assert.equal(stepHref(items, { name: 'project', id: SITE }, 1), projectHref(API));
  assert.equal(stepHref(items, { name: 'project', id: API }, 1), projectHref(SITE), 'round again');
  assert.equal(stepHref(items, { name: 'project', id: SITE }, -1), projectHref(API));
  assert.equal(stepHref(items, { name: 'node' }, 1), projectHref(SITE), 'from elsewhere: the first');
  assert.equal(stepHref(items, { name: 'node' }, -1), projectHref(API), 'or the last, going back');
  assert.equal(stepTo([], null, 1), null);
  // Filtering: what needs you first (example-api, the asking session), then the rest.
  const filtered = leftOrder(s, 'example');
  assert.deepEqual(filtered.map((item) => item.id), [API, SITE]);
  const projects = leftOrder(s, 'projects');
  assert.deepEqual(projects.map((item) => [item.kind, item.needs]), [['project', true], ['session', true], ['project', false], ['session', false]]);
  assert.equal(nthHref(projects, 2), sessionHref(ASKING));
});

test('the palette lists each key beside its command, and the first nine projects’ keys beside theirs', () => {
  setLanguage('en');
  const s = state();
  for (const mac of [true, false]) {
    const went = [];
    const { entries, nth } = keyCommands({ mac, state: s, route: { name: 'home' }, items: leftOrder(s), own: ownSession, go: (href) => went.push(href), filter: () => went.push('filter') });
    const names = keyNames(mac);
    assert.deepEqual(entries.map((entry) => [entry.title, entry.keys]), [
      ['Next needing you', names.needing], ['Next in the list', names.next], ['Previous in the list', names.previous], ['Filter the projects and sessions', names.filter]]);
    assert.deepEqual([...nth], [[SITE, names.nth(1)], [API, names.nth(2)]]);
    entries[0].run();
    entries[3].run();
    assert.deepEqual(went, [projectHref(API), 'filter']);
  }
  assert.deepEqual([keyNames(true).next, keyNames(true).needing, keyNames(true).filter, keyNames(true).nth(1)], ['⌥↓', '⌘J', '⌥F', '⌥1']);
  assert.equal(keyNames(false).nth(4), 'Ctrl+Shift+4');
});

test('the README’s key table lists every one of them, on both', () => {
  const readme = readFileSync(new URL('../README.md', import.meta.url), 'utf8');
  const table = readme.slice(readme.indexOf('## Keys'), readme.indexOf('## The inspector'));
  for (const words of ['⌥1–9', 'Ctrl+Shift+1–9', '⌥↓ ⌥↑', 'Alt+↓ Alt+↑', '⌘J', '⌥J', 'Alt+J', '⌥F']) assert.ok(table.includes(words), words);
  // Each row's keys, its first cell: Ctrl+J (the browser's Downloads) is none of them.
  const cells = table.split('\n').filter((line) => line.startsWith('| ')).map((line) => line.split('|')[1]);
  assert.ok(cells.some((cell) => cell.includes('⌘J')));
  assert.ok(!cells.some((cell) => cell.includes('Ctrl+J')), 'Ctrl+J is the browser’s Downloads');
});

// The left column over `s`, with the store and route a view reads.
function column(s, route = { name: 'home' }) {
  const went = [];
  const app = { store: { state: s, acts: () => false, can: () => true, subscribe() {} }, ui: { state: { route }, go: (href) => went.push(href), setPalette() {} }, drawer() {} };
  const view = leftColumn(app, { brief() {} });
  view.render();
  return { view, went };
}

test('the left column’s filter: a letter typed in it starts it; what needs you first, under its name; ↓ and ↩ open one; Esc clears it', () => {
  for (const code of ['es', 'en']) {
    setLanguage(code);
    const { view, went } = column(state());
    const filter = find(view.el, byClass('left-filter'));
    assert.equal(filter.hidden, true, 'hidden until asked for');
    // A letter typed while the keyboard is on a project: the filter, with that letter.
    view.el.dispatch('keydown', { key: 'p', target: { closest: () => null } });
    assert.equal(filter.hidden, false);
    assert.equal(filter.value, 'p');
    filter.value = 'projects';
    filter.dispatch('input');
    const results = find(view.el, byClass('left-results'));
    assert.equal(find(view.el, byClass('projects')).hidden, true, 'its rows stand in for the projects');
    assert.deepEqual(findAll(results, byClass('left-group')).map((head) => head.textContent), [t('lfNeedsYou'), t('lfTheRest')]);
    assert.deepEqual(findAll(results, byClass('left-result')).map((row) => row.getAttribute('href')),
      [projectHref(API), sessionHref(ASKING), projectHref(SITE), sessionHref('local:bb000002-0000-4000-8000-000000000002')]);
    assert.ok(findAll(results, byClass('left-result'))[0].classList.contains('active'));
    filter.dispatch('keydown', { key: 'ArrowDown' });
    assert.ok(findAll(results, byClass('left-result'))[1].classList.contains('active'));
    filter.dispatch('keydown', { key: 'Enter' });
    assert.deepEqual(went, [sessionHref(ASKING)]);
    assert.equal(filter.hidden, true, 'closed once one opened');
    view.focusFilter();
    filter.value = 'nothing like it';
    filter.dispatch('input');
    assert.match(view.el.textContent, new RegExp(t('lfNoMatch', { query: 'nothing like it' })));
    filter.dispatch('keydown', { key: 'Escape' });
    assert.equal(filter.hidden, true);
    assert.equal(find(view.el, byClass('projects')).hidden, false);
    assert.deepEqual(view.order().map((item) => item.id), [SITE, API], 'the keys follow the projects again');
  }
  setLanguage('en');
});

test('the filter by typing doesn’t take a letter typed in a field, nor one with a modifier', () => {
  const { view } = column(state());
  const filter = find(view.el, byClass('left-filter'));
  view.el.dispatch('keydown', { key: 'p', target: field('input') });
  view.el.dispatch('keydown', { key: 'p', metaKey: true, target: { closest: () => null } });
  view.el.dispatch('keydown', { key: 'ArrowDown', target: { closest: () => null } });
  assert.equal(filter.hidden, true);
  assert.deepEqual(filterItems(state(), ''), []);
});
