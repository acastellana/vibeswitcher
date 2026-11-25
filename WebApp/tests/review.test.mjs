// What the lead's review of the mock found (2026-11-25), each held here: drawn on tests/fakedom.mjs's stand-in DOM
// with the node's own shapes (wire/vectors.json), in English and in Spanish. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
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
  return { store, sent, ui: { state: { route }, subscribe() {}, go() {} } };
}

test('This node: a request it took as yours says how long ago as the other rows do, never an element’s name', async () => {
  setLanguage('en');
  const { nodeView } = await import('../js/views/node.js');
  const node = nodeValue();
  node.accepted = [{ kind: 'lead', action: 'b7e0c2d4-5a61-4f38-9c0b-1e2d3f4a5b6c', at: new Date(Date.now() - 90 * 60000).toISOString(), pid: 51022, cgroup: '/init.scope',
    commandLine: ['vibeswitcher', 'lead', '/home/dev/projects/example-site'] }];
  const app = fakeApp({ state: { node } });
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
    // Your own sessions: how many there are, plain; what waits among them, apart and in the asking colour.
    const own = find(left.el, (node) => node.dataset.place === 'ownSessions');
    assert.equal(find(own, byClass('place-count')).textContent, '5');
    const waits = find(own, byClass('place-waiting'));
    assert.equal(waits.textContent, '1');
    assert.equal(waits.title, code === 'en' ? '1 needs you' : '1 te necesita');
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
  const store = { apply() {}, setConnection() {}, chatSnapshot() {}, chatOps() {}, setKinds(list) { kinds = list; } };
  const mock = createMock(store, { still: true });
  mock.start();
  await new Promise((resolve) => { const wait = () => (kinds ? resolve() : setImmediate(wait)); wait(); });
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
  const fine = editor(slots, null, editing, app);
  assert.match(fine.textContent, /vibeswitcher set node_heavy_slots 4/);
});
