// What the lead's review of the mock found (2026-11-25), each held here: drawn on tests/fakedom.mjs's stand-in DOM
// with the node's own shapes (wire/vectors.json), in English and in Spanish. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { installDom, find, findAll, byClass, button } from './fakedom.mjs';

process.env.TZ = 'UTC';
const here = dirname(fileURLToPath(import.meta.url));
const vectors = JSON.parse(readFileSync(join(here, '..', 'wire', 'vectors.json'), 'utf8'));
const nodeValue = () => structuredClone(vectors['snapshot.node'].entries[0].value);

const dom = installDom();
const { setLanguage } = await import('../js/i18n.js');

// An app as the views read it: a store over `state`, the kinds this connection may send, whether it acts, and the
// requests sent (each answered by `reply`).
function fakeApp({ route = { name: 'node' }, state = {}, kinds = null, acts = true, reply = () => ({ ok: true, result: {} }) } = {}) {
  const sent = [];
  const store = {
    state: { node: null, connection: 'live', phrase: null, pageWords: null, sessions: new Map(), leads: new Map(), boards: new Map(), cards: new Map(),
      cardKeys: new Map(), acting: new Map(), draftRefused: new Map(), plugins: null, ...state },
    acts: () => acts,
    can: (kind) => kinds === null || kinds.includes(kind),
    subscribe() {},
    read: () => Promise.resolve({ ok: false, error: { code: 'unknown-kind' } }),
    request: (kind, args) => { sent.push({ kind, args }); return Promise.resolve(reply(kind, args)); },
    act: (card, kind, args) => sent.push({ kind, args: { card, ...args } }),
    cardKey: (id) => id,
    draftOf: () => null,
  };
  // The route's listeners, so a test can leave a view (`app.leave()`), which stops its timers.
  const listeners = [];
  const ui = { state: { route }, subscribe(fn) { listeners.push(fn); }, go() {} };
  const leave = () => { ui.state.route = { name: 'home' }; for (const fn of listeners) fn('route'); };
  return { store, sent, ui, leave, listeners };
}

// This node shows one group at a time beside its list (views/node.js): the text of every group, each chosen in turn.
function everyGroup(nodeView, app) {
  const view = nodeView(app);
  const keys = findAll(view.columns.rows, byClass('tc-row')).map((row) => row.dataset.key);
  let text = '';
  for (const group of keys) {
    app.ui.state.route = { name: 'node', group };
    for (const fn of app.listeners) fn('route');
    text += view.columns.detail.textContent;
  }
  return text;
}

test('This node: a request it took as yours says how long ago as the other rows do, never an element’s name', async () => {
  setLanguage('en');
  const { nodeView } = await import('../js/views/node.js');
  const node = nodeValue();
  node.accepted = [{ kind: 'lead', action: 'b7e0c2d4-5a61-4f38-9c0b-1e2d3f4a5b6c', at: new Date(Date.now() - 90 * 60000).toISOString(), pid: 51022, cgroup: '/init.scope',
    commandLine: ['vibeswitcher', 'lead', '/home/dev/projects/example-site'] }];
  const app = fakeApp({ route: { name: 'node', group: 'accepted' }, state: { node } });
  const text = nodeView(app).el.textContent;
  assert.doesNotMatch(text, /\[object /);
  assert.match(text, /vibeswitcher lead \/home\/dev\/projects\/example-site · 1h 30m ago · \/init\.scope/);
});

// A project whose lead asks two things (a question and its push), and five sessions of the user's own of which one
// needs them: three things wait in all.
function waitingState() {
  const P = 'local:project:site';
  const lead = { project: P, root: '/home/dev/projects/example-site', session: 'local:lead', named: null, bound: 'local:lead', replaced: [], held: 0, reportsWaiting: 0,
    notice: null, starting: false, looks: 1, questions: { open: 1, blocking: 1 }, cards: ['local:card:q1'], told: [],
    push: { id: 'p1', commit: 'c41d7e09b2a65f38d1e0c7b94a2f6e1d3b8c5a70', short: 'c41d7e09', branch: 'landing-base', remote: 'origin', target: 'origin/landing-base', url: 'git@example.invalid:x.git', ahead: 2, subjects: ['c41d7e0 Landing copy'], askedAt: new Date().toISOString() } };
  const card = { id: 'local:card:q1', kind: 'question', project: P, root: lead.root, open: true, closed: null, notice: null, at: new Date().toISOString(), blocking: true,
    question: { id: 'q1', short: 'ship', text: 'Ship the hero on Thursday?', options: ['Thursday', 'Wait'], priority: 'blocking', whyNow: null, version: 1, revisionNote: null, proposal: null, decideBy: null, state: 'open', answer: null, task: null } };
  const sessions = new Map([['local:lead', { id: 'local:lead', role: 'lead', lead: P, status: 'needs-you', cwd: lead.root }]]);
  for (let i = 0; i < 5; i += 1) sessions.set(`local:own${i}`, { id: `local:own${i}`, role: null, status: i === 0 ? 'needs-you' : 'idle', cwd: '/home/dev' });
  return { P, state: { leads: new Map([[P, lead]]), cards: new Map([[card.id, card]]), sessions } };
}

test('the counts say what they count: the project’s things against everything that needs you; the sessions row coloured by what waits', async () => {
  for (const [code, project, all] of [['en', '2 things in this project need you', '3 need you in all'], ['es', '2 cosas de este proyecto te necesitan', '3 te necesitan en total']]) {
    setLanguage(code);
    const { P, state } = waitingState();
    const { leftColumn } = await import('../js/views/left.js');
    const app = fakeApp({ route: { name: 'project', id: P, view: 'lead' }, state });
    const left = leftColumn(app, { brief() {} });
    left.render();
    assert.equal(find(left.el, byClass('summary-count')).textContent, all);
    // Your own sessions: what waits among them, in words and in the asking colour (how many there are, in its title).
    const own = find(left.el, (node) => node.dataset.place === 'ownSessions');
    assert.equal(find(own, byClass('place-count')).hidden, true);
    const waits = find(own, byClass('place-waiting'));
    assert.equal(waits.textContent, code === 'en' ? '1 needs you' : '1 te necesita');
    assert.equal(own.title, code === 'en' ? '5 sessions of yours' : '5 sesiones tuyas');
    const { projectView } = await import('../js/views/project.js');
    const view = projectView(app, { sheet: { open() {}, close() {} } });
    view.render();
    assert.equal(find(view.el, byClass('big')).textContent, project);
  }
  setLanguage('en');
  // The count of sessions is never in the asking colour; only what waits is.
  const css = readFileSync(join(here, '..', 'style.css'), 'utf8');
  assert.doesNotMatch(css, /\.place\.asked \.place-count/);
  assert.match(css, /\.place-waiting \{[^}]*color: var\(--asked\)/);
});

test('the mock lists the kinds it answers, as a node’s hello does, and answers each: push, its decline, set and stop among them', async () => {
  const { createMock } = await import('../js/mock.js');
  let kinds = null;
  let snapshot = null;
  const shown = new Promise((resolve) => { snapshot = resolve; });
  const store = { apply() { snapshot(); }, setConnection() {}, chatSnapshot() {}, chatOps() {}, setKinds(list) { kinds = list; } };
  const mock = createMock(store, { still: true });
  mock.start();
  // A node says its kinds in its hello, before its snapshot.
  await shown;
  assert.ok(Array.isArray(kinds), 'no kinds before the snapshot: the page takes the mock to answer anything');
  for (const kind of ['push', 'push.decline', 'set', 'stop', 'answer', 'settings']) assert.ok(kinds.includes(kind), kind);
  for (const kind of ['lead', 'session.new', 'plugin.on', 'approve', 'term.open', 'draft']) assert.ok(!kinds.includes(kind), `${kind}: the mock doesn’t answer it, so it isn’t listed`);
  const push = await mock.request({ kind: 'push', args: { folder: '/home/dev/projects/example-site', request: '3c9e1f20' } });
  assert.equal(push.ok, true, JSON.stringify(push));
  assert.equal(push.result.settled, 'pushed');
  const set = await mock.request({ kind: 'set', args: { key: 'web_acts', value: 'off' } });
  assert.equal(set.ok, true, JSON.stringify(set));
  const slots = await mock.request({ kind: 'set', args: { key: 'node_heavy_slots', value: '4' } });
  assert.equal(slots.ok, true, JSON.stringify(slots));
  const settings = await mock.request({ kind: 'settings', args: {} });
  assert.equal(settings.result.node.settings.find((one) => one.key === 'node_heavy_slots').value, '4', 'read back as set');
  for (const kind of kinds.filter((one) => one !== 'chat.page' && one !== 'stop')) {
    const reply = await mock.request({ kind, args: {} });
    assert.notEqual(reply.error?.code, 'unknown-kind', `${kind} is listed and refused as unknown`);
  }
  mock.stop();
});

test('the push card offers Push only where the node lists it, else its terminal lines; a refusal of an unknown kind is plain words', async () => {
  const { pushCard } = await import('../js/views/cards.js');
  const { refusalWords } = await import('../js/acting.js');
  setLanguage('en');
  const lead = waitingState().state.leads.get('local:project:site');
  const without = pushCard(lead, fakeApp({ kinds: ['answer', 'settings'] }));
  assert.equal(find(without, button('Push')), null);
  assert.match(without.textContent, /vibeswitcher push/);
  const app = fakeApp({ kinds: ['push', 'push.decline'], reply: () => ({ ok: false, error: { code: 'unknown-kind', message: 'This node doesn’t take push.' } }) });
  const offered = pushCard(lead, app);
  find(offered, (node) => node.tag === 'button' && node.textContent === 'Push').click();
  assert.deepEqual(app.sent, [{ kind: 'push', args: { folder: lead.root, request: 'p1' } }]);
  await Promise.resolve();
  const said = find(offered, byClass('act-said')).textContent;
  assert.equal(said, 'This node doesn’t take “Push” from a page: use its line in a terminal. Nothing was done.');
  assert.equal(refusalWords({ code: 'unknown-kind', message: 'This node doesn’t take set.' }, 'Turn off'), 'This node doesn’t take “Turn off” from a page: use its line in a terminal. Nothing was done.');
  setLanguage('es');
  assert.equal(refusalWords({ code: 'unknown-kind', message: 'This node doesn’t take set.' }, 'Desactivar'), 'Este nodo no acepta «Desactivar» desde una página: usa su línea en una terminal. No se hizo nada.');
  assert.doesNotMatch(refusalWords({ code: 'unknown-kind' }), /take/);
  setLanguage('en');
});

test('a setting’s value out of its range, or not a number, says the range beside the box and offers no line to copy', async () => {
  setLanguage('en');
  const { draftProblem } = await import('../js/settings.js');
  const { editor } = await import('../js/views/settings.js');
  const slots = { key: 'node_heavy_slots', title: 'Test and build slots at once', form: 'count', scope: 'node', limits: '1 to 12', value: '3', default: '2' };
  const load = { key: 'boost_load_threshold', title: 'Start nothing above a load of, while boosted', form: 'number', scope: 'node', limits: 'above 0, at most 48', value: '36', default: '36' };
  assert.equal(draftProblem(slots, '4'), null);
  assert.equal(draftProblem(slots, 'default'), null);
  for (const value of ['99', '0', 'many', '3.5', '']) assert.match(draftProblem(slots, value) || '', /1 to 12/, value);
  assert.equal(draftProblem(load, '48'), null);
  assert.match(draftProblem(load, '49') || '', /at most 48/);
  assert.match(draftProblem({ ...slots, limits: '0 to 100' }, '101') || '', /0 to 100/);
  const app = fakeApp({ kinds: ['set'] });
  const editing = new Map([[slots.key, '99']]);
  const box = editor(slots, null, editing, app);
  const problem = find(box, byClass('card-notice'));
  assert.equal(problem.hidden, false);
  assert.match(problem.textContent, /1 to 12/);
  assert.equal(findAll(box, (node) => node.tag === 'button' && /Set|Copy/.test(node.textContent + (node.attrs['aria-label'] || ''))).length, 0, 'nothing to set or copy');
  assert.doesNotMatch(box.textContent, /vibeswitcher set/);
  editing.set(slots.key, '4');
  // A page that acts for you sets it with Set (the line is the terminal's way, shown where the page doesn't act).
  const fine = editor(slots, null, editing, app);
  assert.ok(find(fine, button('Set')));
  assert.match(editor(slots, null, editing, fakeApp({ kinds: ['set'], acts: false })).textContent, /vibeswitcher set node_heavy_slots 4/);
});

test('in Spanish the page’s own words are Spanish, its dates the page’s language without seconds; the node’s own sentences stay as sent', async () => {
  setLanguage('es');
  const { nodeView } = await import('../js/views/node.js');
  const { dateTime } = await import('../js/words.js');
  const node = nodeValue();
  node.usage.limits.push({ name: 'seven_day', label: 'the weekly limit', model: null, usedPercent: 84, reached: false, resetsAt: '2026-11-27T14:54:08.000Z', holds: true, text: 'the weekly limit (every model): 84% used' },
    { name: 'five_hour', label: 'the 5-hour limit', model: null, usedPercent: 31, reached: false, resetsAt: '2026-11-25T13:54:00.000Z', holds: false, text: 'the 5-hour limit (every model): 31% used' });
  node.web = { state: 'listening', port: 8765, tokens: 1, connections: 1, acts: { on: true, level: 'trust', since: '2026-11-25T13:54:00.000Z', pages: 1, keys: [{ id: 'k1', added: '2026-11-25T13:54:00.000Z', lastUsed: null }] } };
  const text = everyGroup(nodeView, fakeApp({ state: { node } }));
  for (const english of ['The weekly limit', 'The 5-hour limit', '(every model)', 'on in Settings', 'ModoOn', 'Modoon', ' AM', ' PM', '11/27/2026', 'Nov ']) {
    assert.ok(!text.includes(english), `${english} in: ${text}`);
  }
  for (const spanish of ['El límite semanal (todos los modelos)', 'El límite de 5 horas (todos los modelos)', 'Activado: activado en Ajustes', 'ModoActivado', dateTime('2026-11-27T14:54:08.000Z')]) {
    assert.ok(text.includes(spanish), `${spanish} not in: ${text}`);
  }
  assert.equal(dateTime('2026-11-27T14:54:08.000Z'), '27 nov 2026, 14:54');
  setLanguage('en');
  assert.equal(dateTime('2026-11-27T14:54:08.000Z'), 'Nov 27, 2026, 2:54 PM');
});

test('every word the page asks for is in the tables, and the Spanish says líder where the English says lead', () => {
  const root = join(here, '..');
  const files = ['app.js', ...readdirSync(join(root, 'js'), { recursive: true }).filter((name) => name.endsWith('.js') && name !== 'mock.js').map((name) => join('js', name))];
  const asked = new Set();
  for (const name of files) for (const found of readFileSync(join(root, name), 'utf8').matchAll(/\bt(?:Parts)?\('([A-Za-z0-9]+)'/g)) asked.add(found[1]);
  return import('../js/i18n.js').then(({ TABLES }) => {
    assert.deepEqual([...asked].filter((key) => !(key in TABLES.en)).sort(), []);
    const english = Object.entries(TABLES.es).filter(([, word]) => /\blead\b/.test(JSON.stringify(word).replace(/vibeswitcher lead|`lead`|lead_[a-z]+/g, '')));
    assert.deepEqual(english.map(([key]) => key), []);
  });
});

test('a Blocking card’s answer shows “Sending … · Undo” for a few seconds before it goes; Undo takes it back; a card not Blocking goes at once', async () => {
  setLanguage('en');
  const { questionCard, UNDO_MS } = await import('../js/views/cards.js');
  const timers = [];
  const app = fakeApp({ kinds: ['answer', 'hold'] });
  app.later = (fn, ms) => { const timer = { fn, ms, cancelled: false }; timers.push(timer); return () => { timer.cancelled = true; }; };
  const card = waitingState().state.cards.get('local:card:q1');
  const view = questionCard(app, card);
  view.update(card);
  find(view.el, button('Thursday')).click();
  assert.deepEqual(app.sent, [], 'not sent yet');
  assert.match(view.el.textContent, /Sending “Thursday”… · Undo/);
  assert.equal(timers.length, 1);
  assert.ok(UNDO_MS >= 3000 && UNDO_MS <= 8000, `a few seconds: ${UNDO_MS}`);
  find(view.el, byClass('card-undo')).click();
  assert.equal(timers[0].cancelled, true);
  assert.ok(find(view.el, button('Thursday')), 'its options again');
  find(view.el, button('Wait')).click();
  timers[1].fn();
  assert.deepEqual(app.sent.map((one) => [one.kind, one.args.text]), [['answer', 'Wait']]);
  // Reworded while it waits: what was picked doesn't go as the answer to a question the user didn't read.
  const asked = { ...card, seen: 'v1-seen', question: { ...card.question, version: 1 } };
  const changing = questionCard(app, asked);
  changing.update(asked);
  find(changing.el, button('Thursday')).click();
  const reworded = { ...asked, seen: 'v2-seen', question: { ...asked.question, version: 2, text: 'Ship the hero and the pricing page on Thursday?' } };
  changing.update(reworded);
  assert.equal(timers[2].cancelled, true, 'the wait is dropped');
  assert.ok(find(changing.el, button('Thursday')), 'the reworded question, with its options');
  assert.deepEqual(app.sent.map((one) => one.args.text), ['Wait'], 'nothing more sent');
  // One that goes carries the version and seen it was picked on.
  find(changing.el, button('Wait')).click();
  timers[3].fn();
  assert.deepEqual([app.sent.at(-1).args.version, app.sent.at(-1).args.seen], [2, 'v2-seen']);
  // Not Blocking: the click is the answer, as before.
  const calm = { ...card, id: 'local:card:q2', blocking: false, question: { ...card.question, priority: 'important' } };
  const other = questionCard(app, calm);
  other.update(calm);
  find(other.el, button('Thursday')).click();
  assert.deepEqual(app.sent.map((one) => one.args.text), ['Wait', 'Wait', 'Thursday']);
  setLanguage('es');
  const es = questionCard(app, { ...card, id: 'local:card:q3' });
  es.update({ ...card, id: 'local:card:q3' });
  find(es.el, button('Thursday')).click();
  assert.match(es.el.textContent, /Enviando «Thursday»… · Deshacer/);
  setLanguage('en');
});

test('Stop the node is a plain button in the danger colour, never the primary blue, and asks in place before it sends', async () => {
  setLanguage('en');
  const { nodeView } = await import('../js/views/node.js');
  const timers = [];
  const app = fakeApp({ route: { name: 'node', group: 'stop' }, kinds: ['stop'], state: { node: nodeValue() } });
  app.later = (fn) => { timers.push(fn); return () => {}; };
  const el = nodeView(app).el;
  const stop = find(el, (node) => node.tag === 'button' && node.textContent === 'Stop the node');
  assert.ok(stop.classList.contains('quiet') && stop.classList.contains('danger'), stop.className);
  stop.click();
  assert.deepEqual(app.sent, []);
  assert.equal(stop.textContent, 'Click again to stop the node');
  const cancel = find(el, button('Cancel'));
  assert.equal(cancel.hidden, false);
  cancel.click();
  assert.equal(stop.textContent, 'Stop the node');
  assert.equal(cancel.hidden, true);
  stop.click();
  stop.click();
  assert.deepEqual(app.sent.map((one) => one.kind), ['stop']);
  const css = readFileSync(join(here, '..', 'style.css'), 'utf8');
  assert.match(css, /\.button\.danger \{ color: var\(--needs-you\); \}/);
});

test('the smaller ones: New project’s Where fits its box with its hint below, a page not paired says nothing needs you nor offers Brief me, a settings search hides the terminal section', async () => {
  setLanguage('en');
  const { newProjectForm } = await import('../js/views/drive.js');
  const form = newProjectForm(fakeApp({ route: { name: 'new' } }));
  const where = find(form.el, (node) => node.tag === 'input' && node.attrs['aria-label'] === 'Where');
  assert.equal(where.attrs.placeholder, 'Where (optional)');
  assert.match(find(form.el, byClass('where-hint')).textContent, /node’s projects folder/);
  const { leftColumn } = await import('../js/views/left.js');
  for (const connection of ['unpaired', 'revoked']) {
    const left = leftColumn(fakeApp({ route: { name: 'home' }, state: { connection } }), { brief() {} });
    left.render();
    assert.equal(left.el.shownText.includes('Nothing needs you'), false, connection);
    assert.equal(find(left.el, byClass('summary-brief')).hidden, true, connection);
  }
  const live = leftColumn(fakeApp({ route: { name: 'home' } }), { brief() {} });
  live.render();
  assert.ok(live.el.shownText.includes('Nothing needs you'));
  const { settingsView } = await import('../js/views/settings.js');
  const app = fakeApp({ route: { name: 'settings' }, reply: () => ({ ok: true, result: { node: { root: '/home/u/.vibeswitcher', settings: [] }, project: null, leftOut: [], usage: null } }) });
  const view = settingsView(app);
  // The node's settings answered (each section of the list is the node's, or this browser's terminal).
  await new Promise((resolve) => setImmediate(resolve));
  const search = find(view.el, byClass('tc-search'));
  assert.ok(view.el.shownText.includes('Terminal'), 'the terminal section, before a search');
  search.value = 'no such setting';
  search.dispatch('input');
  assert.ok(!view.el.shownText.includes('Terminal · this browser'), view.el.shownText);
  search.value = '';
  search.dispatch('input');
  assert.ok(view.el.shownText.includes('Terminal · this browser'));
  app.leave();
});
