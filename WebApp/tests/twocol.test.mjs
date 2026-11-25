// Your own sessions, This node and Settings as two columns (views/twocol.js): a list with a search beside the chosen
// one's detail, the choice in the address, the keys, the fold under 760 px; each page drawn on tests/fakedom.test.mjs's
// stand-in DOM with the node's own shapes (wire/vectors.json). Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { installDom, find, findAll, byClass, button } from './fakedom.test.mjs';

process.env.TZ = 'UTC';
const here = dirname(fileURLToPath(import.meta.url));
const vectors = JSON.parse(readFileSync(join(here, '..', 'wire', 'vectors.json'), 'utf8'));
const settingsReply = () => structuredClone(vectors.settings[1].result);
const nodeValue = () => structuredClone(vectors['snapshot.node'].entries[0].value);

installDom();
const { setLanguage } = await import('../js/i18n.js');
const { parseRoute } = await import('../js/ui.js');
const { twoColumns, wantsSearch, marked } = await import('../js/views/twocol.js');
const { settingsView, settingsList, chosenSection, settingsHref } = await import('../js/views/settings.js');
const { nodeView } = await import('../js/views/node.js');
const { ownSessionsView, ownItems } = await import('../js/views/own.js');
const settle = () => new Promise((resolve) => setImmediate(resolve));

// An app as the views read it: a store over `state` (its topics' listeners kept, so a test can say a snapshot
// changed), the route and its listeners, the addresses gone to, the requests sent.
function fakeApp({ route, state = {}, kinds = null, acts = false, reply = () => ({ ok: true, result: {} }) } = {}) {
  const sent = [];
  const topics = new Map();
  const store = {
    state: { node: null, connection: 'live', phrase: null, pageWords: null, sessions: new Map(), leads: new Map(), boards: new Map(), cards: new Map(),
      cardKeys: new Map(), acting: new Map(), draftRefused: new Map(), ...state },
    acts: () => acts,
    can: (kind) => kinds === null || kinds.includes(kind),
    subscribe(topic, fn) { if (!topics.has(topic)) topics.set(topic, []); topics.get(topic).push(fn); },
    read: () => Promise.resolve({ ok: false, error: { code: 'unknown-kind' } }),
    request: (kind, args) => { sent.push({ kind, args }); return Promise.resolve(reply(kind, args)); },
  };
  const listeners = [];
  const went = [];
  const ui = { state: { route }, subscribe(fn) { listeners.push(fn); }, go(hash) { went.push(hash); } };
  const changed = (topic) => { for (const fn of topics.get(topic) || []) fn(); };
  const goTo = (next) => { ui.state.route = next; for (const fn of listeners) fn('route'); };
  return { store, ui, sent, went, changed, goTo, leave: () => goTo({ name: 'home' }) };
}
const rowsOf = (view) => findAll(view.columns.rows, byClass('tc-row'));
const listText = (view) => rowsOf(view).map((row) => `${find(row, byClass('tc-name')).textContent}${find(row, byClass('tc-meta')).hidden ? '' : ' ' + find(row, byClass('tc-meta')).textContent}`);
const type = (view, text) => { const box = view.columns.search; box.value = text; box.dispatch('input'); };
const chosenRow = (view) => rowsOf(view).find((row) => row.getAttribute('aria-current') === 'page');

// ---- Settings ----

test('Settings: the list is the node’s sections, then each project’s, then Terminal, each with its number of settings', () => {
  setLanguage('en');
  const result = settingsReply();
  const project = { project: 'local:project:acme', root: result.project.root, result: result.project };
  const items = settingsList(result, '', { projects: [project], leftOut: result.leftOut });
  assert.deepEqual(items.map((item) => `${item.group} / ${item.title} ${item.meta ?? ''}`.trim()), [
    'This node · every project / Machine-wide limits 1', 'This node · every project / Usage limits 1', 'This node · every project / Boost 1',
    'This node · every project / Leads 1', 'This node · every project / Working policy 1', 'This node · every project / Not on a node 2',
    'Project acme-site / Models 1', 'Project acme-site / Team 1', 'Project acme-site / Review rules floor 1', 'This browser / Terminal']);
  assert.equal(items[0].href, '#/settings/node/machine-wide-limits');
  assert.equal(items[6].href, '#/settings/local%3Aproject%3Aacme/models');
  assert.equal(items.at(-1).href, '#/settings/terminal');
});

test('Settings: the chosen section is in the address; #/settings and #/settings/<project> still open their first section', () => {
  assert.deepEqual(parseRoute('#/settings'), { name: 'settings', id: null });
  assert.deepEqual(parseRoute('#/settings/node/boost'), { name: 'settings', id: null, section: 'boost' });
  assert.deepEqual(parseRoute('#/settings/terminal'), { name: 'settings', id: null, section: 'terminal' });
  assert.deepEqual(parseRoute(settingsHref('local:project:acme')), { name: 'settings', id: 'local:project:acme' });
  assert.deepEqual(parseRoute(settingsHref('local:project:acme', 'team')), { name: 'settings', id: 'local:project:acme', section: 'team' });
  const result = settingsReply();
  const items = settingsList(result, '', { projects: [{ project: 'local:project:acme', root: result.project.root, result: result.project }] });
  assert.equal(chosenSection(items, parseRoute('#/settings')).title, 'Machine-wide limits');
  assert.equal(chosenSection(items, parseRoute('#/settings/local%3Aproject%3Aacme')).title, 'Models');
  assert.equal(chosenSection(items, parseRoute('#/settings/node/boost')).title, 'Boost');
  assert.equal(chosenSection(items, parseRoute('#/settings/terminal')).kind, 'terminal');
  // A section that isn't there (a renamed one, an old link): the first, never nothing.
  assert.equal(chosenSection(items, parseRoute('#/settings/node/gone')).title, 'Machine-wide limits');
});

// The Settings page over the vector's settings, with one project led.
function settingsPage(route) {
  const result = settingsReply();
  const lead = { project: 'local:project:acme', root: result.project.root };
  const app = fakeApp({ route, state: { leads: new Map([[lead.project, lead]]) },
    reply: (kind, args) => ({ ok: true, result: { ...result, project: args.folder ? result.project : null } }) });
  return { app, view: settingsView(app) };
}

test('Settings: choosing a section shows only its settings, and Change still drafts the vibeswitcher set line', async () => {
  setLanguage('en');
  const { app, view } = settingsPage({ name: 'settings', id: 'local:project:acme', section: 'team' });
  await settle();
  assert.equal(chosenRow(view).getAttribute('href'), '#/settings/local%3Aproject%3Aacme/team');
  const detail = view.columns.detail;
  assert.equal(find(detail, byClass('tc-dtitle')).textContent, 'Team');
  assert.deepEqual(findAll(detail, byClass('setting-title')).map((one) => one.textContent), ['Workers at once, at most']);
  find(detail, button('Change')).click();
  assert.match(detail.textContent, /vibeswitcher set \/home\/u\/acme-site max_workers 4/);
  app.goTo({ name: 'settings', id: null, section: 'boost' });
  assert.deepEqual(findAll(view.columns.detail, byClass('setting-title')).map((one) => one.textContent), ['Boost']);
  app.leave();
});

test('Settings: a search lists only the sections with a match and their counts, shows the matches with the words marked, and says when nothing matches', async () => {
  setLanguage('en');
  const { app, view } = settingsPage({ name: 'settings', id: null });
  await settle();
  // "at once" is in two sections' settings: the node's machine-wide limits and the project's team.
  type(view, 'at once');
  assert.deepEqual(listText(view), ['Machine-wide limits 1', 'Team 1']);
  assert.equal(chosenRow(view).dataset.key, 'node/machine-wide-limits');
  app.goTo({ name: 'settings', id: 'local:project:acme', section: 'team' });
  const detail = view.columns.detail;
  assert.deepEqual(findAll(detail, byClass('setting-title')).map((one) => one.textContent), ['Workers at once, at most']);
  assert.deepEqual(findAll(detail, (node) => node.tag === 'mark').map((one) => one.textContent), ['at', 'once', 'at', 'at', 'once'], 'the words found are marked');
  assert.match(find(detail, byClass('tc-dsub')).textContent, /1 match$/);
  // A section the search leaves out isn't shown: the first that holds a match is.
  app.goTo({ name: 'settings', id: null, section: 'boost' });
  assert.equal(chosenRow(view).dataset.key, 'node/machine-wide-limits');
  type(view, 'zebra quartz');
  assert.deepEqual(listText(view), []);
  assert.equal(find(view.columns.list, byClass('tc-none')).shownText, 'No setting matches “zebra quartz”.');
  assert.match(detail.shownText, /No setting matches “zebra quartz”\. Try fewer words/);
  type(view, '');
  assert.equal(rowsOf(view).length, 10);
  app.leave();
});

test('Settings: a project known by its board alone (its lead not running) still has its sections, asked with its folder', async () => {
  setLanguage('en');
  const result = settingsReply();
  const board = { project: 'local:project:acme', root: result.project.root, tasks: [] };
  const app = fakeApp({ route: { name: 'settings', id: board.project }, state: { boards: new Map([[board.project, board]]) },
    reply: (kind, args) => ({ ok: true, result: { ...result, project: args.folder ? result.project : null } }) });
  const view = settingsView(app);
  await settle();
  assert.ok(app.sent.some((one) => one.kind === 'settings' && one.args.folder === board.root), 'asked with the board’s folder');
  assert.equal(chosenRow(view).getAttribute('href'), '#/settings/local%3Aproject%3Aacme/models');
  app.leave();
});

test('a found word is marked as an element, never as markup', () => {
  const parts = marked('Workers at once, at most', ['at', 'work']);
  assert.deepEqual(parts.map((part) => (typeof part === 'string' ? part : `[${part.textContent}]`)).join(''), '[Work]ers [at] once, [at] most');
  assert.deepEqual(marked('<b>x</b>', ['b']).filter((part) => typeof part !== 'string').map((part) => part.textContent), ['b', 'b']);
});

// ---- This node ----

test('This node: the list is the page’s groups with a count or a one-word state, what needs you in the asking colour and chosen first', async () => {
  setLanguage('en');
  const node = nodeValue();
  node.notices = ['example-site: landing-base moved'];
  const app = fakeApp({ route: { name: 'node' }, state: { node }, kinds: ['approve', 'approve.list'], acts: true });
  app.store.read = (kind) => Promise.resolve(kind === 'approve.list' ? { ok: true, result: { batch: 'b1', items: [{ kind: 'config', subject: 'max_workers 3 → 5', seen: 1, reasons: [] }], own: [] } } : { ok: false, error: { code: 'unknown-kind' } });
  const view = nodeView(app);
  await settle();
  const names = listText(view);
  assert.deepEqual(rowsOf(view).slice(0, 2).map((row) => row.dataset.key), ['approve', 'notices']);
  assert.equal(names[1], 'Notices 1');
  assert.match(names[0], / 1$/);
  assert.ok(names.includes('Session host Connected'), names.join(' | '));
  assert.ok(names.some((one) => /^Build [0-9a-f]{8}$/.test(one)), names.join(' | '));
  const first = rowsOf(view)[0];
  assert.ok(first.classList.contains('asked'), 'what needs you, in the asking colour');
  assert.equal(chosenRow(view), first, '#/node opens what needs you');
  assert.equal(parseRoute('#/node/usage').group, 'usage');
  assert.deepEqual(parseRoute('#/node'), { name: 'node' });
  app.goTo({ name: 'node', group: 'host' });
  assert.equal(chosenRow(view).dataset.key, 'host');
  assert.equal(find(view.columns.detail, byClass('tc-dtitle')).textContent, 'Session host');
  assert.match(view.columns.detail.textContent, /Live sessions/);
  assert.doesNotMatch(view.columns.detail.textContent, /State folder/, 'only the chosen group');
});

test('This node: with nothing that needs you, #/node opens the first group; a search filters the groups and their rows', () => {
  setLanguage('en');
  const node = nodeValue();
  node.notices = [];
  const app = fakeApp({ route: { name: 'node' }, state: { node } });
  const view = nodeView(app);
  assert.equal(chosenRow(view), rowsOf(view)[0]);
  type(view, 'pid');
  const listed = rowsOf(view).map((row) => row.dataset.key);
  assert.deepEqual(listed, ['host', 'server']);
  const facts = findAll(view.columns.detail, byClass('fact')).filter((row) => !row.hidden);
  assert.deepEqual(facts.map((row) => row.children[0].textContent), ['Process']);
  assert.deepEqual(findAll(view.columns.detail, (one) => one.tag === 'mark').map((one) => one.textContent), ['pid'], 'the word found, marked');
  type(view, 'zebra quartz');
  assert.deepEqual(rowsOf(view), []);
  assert.match(view.columns.detail.shownText, /Nothing on this node matches “zebra quartz”/);
  type(view, '');
  assert.ok(findAll(view.columns.detail, byClass('fact')).every((row) => !row.hidden), 'every row back once the search is cleared');
  assert.deepEqual(findAll(view.el, (one) => one.tag === 'mark'), [], 'and nothing marked');
});

// ---- Your own sessions ----

const ago = (minutes) => new Date(Date.now() - minutes * 60000).toISOString();
function ownState() {
  const sessions = new Map();
  const add = (id, status, minutes, extra = {}) => sessions.set(id, { id, status, since: ago(minutes), agent: 'claude', hosted: true, cwd: `/home/dev/projects/${extra.folder || 'site'}`, title: extra.title || id, role: extra.role || null, lead: extra.lead || null, terminal: 'pts/1' });
  add('local:idle', 'idle', 90, { title: 'Tidy the README', folder: 'docs' });
  add('local:work', 'working', 2, { title: 'Retry bank webhooks', folder: 'payouts' });
  add('local:ask', 'needs-you', 1, { title: 'Why does the payout job fail', folder: 'api' });
  add('local:old', 'working', 30, { title: 'Preview the docs', folder: 'docs' });
  add('local:worker', 'working', 3, { title: 'A worker', role: 'worker', lead: 'local:project:site' });
  return { sessions, node: { ...nodeValue(), home: '/home/dev' } };
}

test('Your own sessions: the rows are those that need you, then working, then idle, each with its name, state, folder and when it moved', () => {
  setLanguage('en');
  const { sessions } = ownState();
  const own = [...sessions.values()].filter((one) => !one.role);
  const items = ownItems(own, '', '/home/dev');
  assert.deepEqual(items.map((item) => `${item.group}: ${item.title} · ${item.sub} · ${item.meta}`), [
    'Need you: Why does the payout job fail · Needs you · api · 1m',
    'Working: Retry bank webhooks · Working · payouts · 2m', 'Working: Preview the docs · Working · docs · 30m',
    'Idle or ended: Tidy the README · Idle · docs · 1h 30m']);
  assert.equal(items[0].tone, 'asked');
  assert.deepEqual(ownItems(own, 'docs', '/home/dev').map((item) => item.title), ['Preview the docs', 'Tidy the README'], 'by folder');
  assert.deepEqual(ownItems(own, 'idle', '/home/dev').map((item) => item.title), ['Tidy the README'], 'by state');
  assert.deepEqual(ownItems(own, 'payout job', '/home/dev').map((item) => item.title), ['Why does the payout job fail'], 'by name');
});

test('Your own sessions: #/s/<session> shows the session beside the list with it chosen; a team’s session shows alone; New session and New project at the list’s head', () => {
  setLanguage('en');
  const session = { el: installDomNode('section', 'session') };
  const app = fakeApp({ route: { name: 'session', id: 'local:work' }, state: ownState() });
  const view = ownSessionsView(app, { session });
  view.render();
  assert.equal(chosenRow(view).getAttribute('href'), '#/s/local%3Awork');
  assert.equal(view.columns.detail.children[0], session.el, 'the session view itself, not a copy');
  assert.equal(view.el.dataset.pane, 'detail');
  assert.equal(view.alone(), false);
  app.goTo({ name: 'session', id: 'local:worker' });
  assert.equal(view.alone(), true, 'a worker’s chat shows alone, as before');
  app.goTo({ name: 'sessions' });
  assert.equal(view.el.dataset.pane, 'list');
  assert.equal(find(view.columns.detail, byClass('tc-dtitle')).textContent, 'New session');
  const head = find(view.columns.list, byClass('tc-head'));
  assert.deepEqual(findAll(head, (node) => node.tag === 'a').map((link) => link.getAttribute('href')), ['#/sessions/new', '#/new']);
  assert.deepEqual(parseRoute('#/sessions/new'), { name: 'sessions', start: true });
});

test('Your own sessions: a snapshot leaves the start form where it is, so a field being typed in keeps its focus', () => {
  setLanguage('en');
  const state = ownState();
  const app = fakeApp({ route: { name: 'sessions' }, state });
  const view = ownSessionsView(app, { session: { el: installDomNode('section', 'session') } });
  view.render();
  const body = view.columns.detailBody;
  const form = body.children[0];
  let moved = 0;
  const replace = body.replaceChildren.bind(body);
  body.replaceChildren = (...nodes) => { moved += 1; replace(...nodes); };
  state.sessions.get('local:work').status = 'idle';
  app.changed('sessions');
  app.changed('node');
  assert.equal(moved, 0, 'never taken out and put back');
  assert.equal(body.children[0], form);
});

test('Your own sessions: with none, the list says what to do', () => {
  setLanguage('en');
  const app = fakeApp({ route: { name: 'sessions' }, state: { node: nodeValue() } });
  const view = ownSessionsView(app, { session: { el: installDomNode('section', 'session') } });
  view.render();
  assert.match(find(view.columns.list, byClass('tc-none')).shownText, /No sessions of your own yet\. Start one with \+ above/);
  setLanguage('es');
  const es = ownSessionsView(app, { session: { el: installDomNode('section', 'session') } });
  es.render();
  assert.match(find(es.columns.list, byClass('tc-none')).shownText, /Aún no tienes sesiones propias/);
  setLanguage('en');
});

function installDomNode(tag, name) { const node = document.createElement(tag); node.className = name; return node; }

// ---- The shared parts ----

test('the list keeps its rows (and so its scroll and choice) when the node’s snapshot updates', () => {
  setLanguage('en');
  const state = ownState();
  const app = fakeApp({ route: { name: 'session', id: 'local:idle' }, state });
  const view = ownSessionsView(app, { session: { el: installDomNode('section', 'session') } });
  view.render();
  const before = rowsOf(view);
  view.columns.rows.scrollTop = 140;
  state.sessions.get('local:old').since = ago(5);
  state.sessions.set('local:new', { ...state.sessions.get('local:idle'), id: 'local:new', title: 'A new one', status: 'idle', since: ago(200) });
  app.changed('sessions');
  const after = rowsOf(view);
  for (const row of before) assert.ok(after.includes(row), `${row.dataset.key} kept as the same node`);
  assert.equal(after.length, before.length + 1);
  assert.equal(view.columns.rows.scrollTop, 140);
  assert.equal(chosenRow(view).dataset.key, 'local:idle');
});

test('keys: ↑ ↓ move in the list, ↩ in the search opens the first row, Esc clears the search, / focuses it outside a field', () => {
  const app = fakeApp({ route: { name: 'node' } });
  const columns = twoColumns(app, { label: 'L', title: 'T', searchLabel: 'S' });
  columns.setItems([{ key: 'a', href: '#/a', title: 'A' }, { key: 'b', href: '#/b', title: 'B', group: 'G' }, { key: 'c', href: '#/c', title: 'C' }], 'b');
  const rows = findAll(columns.rows, byClass('tc-row'));
  let focused = null;
  for (const one of [...rows, columns.search]) one.focus = () => { focused = one; };
  const press = (on, key) => { let stopped = false; on.dispatch('keydown', { key, target: on, stopPropagation() { stopped = true; } }); return stopped; };
  columns.rows.dispatch('keydown', { key: 'ArrowDown', target: rows[0] });
  assert.equal(focused, rows[1]);
  columns.rows.dispatch('keydown', { key: 'End', target: rows[0] });
  assert.equal(focused, rows[2]);
  columns.rows.dispatch('keydown', { key: 'ArrowUp', target: rows[0] });
  assert.equal(focused, columns.search, 'up from the first row: back to the search');
  press(columns.search, 'ArrowDown');
  assert.equal(focused, rows[1], 'down from the search: the chosen row');
  press(columns.search, 'Enter');
  assert.deepEqual(app.went, ['#/a']);
  let searched = null;
  columns.onSearch((query) => { searched = query; });
  columns.search.value = 'x';
  columns.search.dispatch('input');
  assert.equal(columns.query(), 'x');
  assert.equal(press(columns.search, 'Escape'), true, 'Esc is the search’s while it holds words');
  assert.equal(columns.search.value, '');
  assert.equal(searched, '');
  assert.equal(press(columns.search, 'Escape'), false, 'and the page’s again once it’s empty');
  const field = (tag) => ({ closest: (selector) => (selector.includes(tag) ? {} : null) });
  assert.equal(wantsSearch({ key: '/', target: { closest: () => null } }), true);
  assert.equal(wantsSearch({ key: '/', target: field('input') }), false);
  assert.equal(wantsSearch({ key: '/', target: field('textarea') }), false);
  assert.equal(wantsSearch({ key: '/', metaKey: true, target: { closest: () => null } }), false);
  // The heading is drawn once, before its first row.
  assert.deepEqual(findAll(columns.rows, byClass('tc-group')).map((one) => one.textContent), ['G']);
});

test('one set of rules for the three pages, folding to one column under 760 px with a way back to the list', () => {
  const css = readFileSync(join(here, '..', 'style.css'), 'utf8');
  assert.equal(css.match(/^\.twocol \{/gm).length, 1);
  assert.match(css, /@media \(max-width: 760px\) \{\n {2}\.twocol \{ grid-template-columns: minmax\(0, 1fr\); \}\n {2}\.twocol\[data-pane="list"\] > \.tc-detail, \.twocol\[data-pane="detail"\] > \.tc-list \{ display: none; \}/);
  assert.match(css, /\.tc-back \{ display: inline-flex; \}/);
  // Each page builds on the one component; none draws its own list.
  for (const name of ['own.js', 'node.js', 'settings.js']) {
    const source = readFileSync(join(here, '..', 'js', 'views', name), 'utf8');
    assert.match(source, /twoColumns\(app, \{/, name);
    assert.doesNotMatch(source, /class: 'tc-row'/, name);
  }
});
