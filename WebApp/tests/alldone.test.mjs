// The all-done mark dismissed (P-s1, the app's `AllDoneWatch.see`): the card at the end of a project's lead
// conversation has Dismiss, which takes the card and the left column's "all done" away at once and asks the node to
// keep it seen (`seen {project}`); the node's seen mark keeps it gone after a reload; the next batch's mark shows again;
// a refusal gives it back and says why. Drawn on tests/fakedom.test.mjs's stand-in DOM.
// Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { installDom, find, findAll, byClass } from './fakedom.test.mjs';

process.env.TZ = 'UTC';
installDom();
globalThis.matchMedia = () => ({ matches: false, addEventListener() {} });
globalThis.ResizeObserver ??= class { observe() {} unobserve() {} disconnect() {} };
globalThis.requestAnimationFrame ??= (fn) => setTimeout(fn, 0);
const { setLanguage, t } = await import('../js/i18n.js');
const { projectView } = await import('../js/views/project.js');
const { projectLine } = await import('../js/views/left.js');
const { unseenAllDone } = await import('../js/views/alldone.js');

const P = 'local:project:site';
const ROOT = '/home/dev/projects/example-site';
const at = (minutes) => new Date(Date.UTC(2026, 10, 26, 9, minutes)).toISOString();
const lead = { project: P, root: ROOT, session: 'local:lead', named: null, bound: 'local:lead', replaced: [], held: 0, reportsWaiting: 0, notice: null,
  starting: false, looks: 1, questions: { open: 0, blocking: 0 }, cards: [], told: [] };
const mark = (id, seen = false) => ({ id, at: at(30), summary: { headline: 'The landing page shipped', bullets: ['Hero on main', 'Images lazy'], byModel: true },
  tasks: [{ title: 'Hero', outcome: 'merged' }, { title: 'Images', outcome: 'merged' }], merged: 2, receipts: '$1.20 · 2 tasks', pricesAsOf: '2026-11-01', seen });
const board = (allDone) => ({ project: P, root: ROOT, baseBranch: 'main', counts: { attention: 0, running: 0, waiting: 0, done: 2 }, more: 0, unreadable: null,
  tasks: [], answered: [], results: [{ id: 'r1', title: 'Shipped', body: '', at: at(20) }], decisions: [], allDone });

// The store as the views use it: `seen` answered by `answer`, every request kept, `boards` redrawn through `change`.
function fakeApp({ allDone, kinds = ['seen'], answer = () => ({ ok: true, result: { changed: true } }) }) {
  const requests = [];
  const redraws = [];
  const store = {
    state: { node: null, connection: 'live', phrase: null, pageWords: null, sessions: new Map(), leads: new Map([[P, lead]]), boards: new Map([[P, board(allDone)]]),
      cards: new Map(), cardKeys: new Map(), acting: new Map(), draftRefused: new Map(), plugins: null },
    acts: () => false, can: (kind) => kinds.includes(kind), follows: () => true, watches: () => true, subscribe() {}, read: () => Promise.resolve({ ok: false }),
    request: (kind, args) => { requests.push({ kind, args }); return Promise.resolve(answer(kind, args)); },
    change: (name, changes) => redraws.push({ name, changes }),
    act() {}, cardKey: (id) => id, draftOf: () => null, sessionDraft() {}, chatOf: () => null,
  };
  const ui = { state: { route: { name: 'project', id: P, view: 'lead', show: 'decisions', tab: 'team', task: null, open: [] } }, subscribe() {}, go() {}, setPalette() {},
    pane: () => 'chat', setPane() {}, inspectorShown: () => false, inspectorWide: () => true, toggleInspector() {} };
  return { app: { store, ui, drawer() {} }, requests, redraws };
}
const sheet = { open() {}, close() {}, shown: () => false };
const settle = () => new Promise((resolve) => setImmediate(resolve));
const cardOf = (view) => find(view.el, byClass('lead-all-done'));
const lineOf = (store) => projectLine({ project: P, waiting: 0, motion: 0, lead: true, live: true, board: store.state.boards.get(P) }).words;

test('P-s1: an unseen all-done mark shows at the conversation’s end with Dismiss; the left column says all done', () => {
  setLanguage('en');
  const { app } = fakeApp({ allDone: mark('m1') });
  const view = projectView(app, { sheet });
  view.render();
  const card = cardOf(view);
  assert.ok(card, 'the card, in the lead conversation');
  assert.ok(card.textContent.includes('The landing page shipped'));
  const dismiss = find(card, byClass('all-done-dismiss'));
  assert.equal(dismiss.textContent, t('adDismiss'));
  assert.equal(lineOf(app.store), t('allDone'));
});

test('P-s1: Dismiss takes the mark away at once, asks the node to keep it seen, and says what it did', async () => {
  setLanguage('en');
  let reply = null;
  const { app, requests, redraws } = fakeApp({ allDone: mark('m2'), answer: () => new Promise((resolve) => { reply = resolve; }) });
  const view = projectView(app, { sheet });
  view.render();
  find(cardOf(view), byClass('all-done-dismiss')).dispatch('click');
  // At once, before the node has answered: no card, no "all done" in the left column (told through `boards`).
  assert.equal(cardOf(view), null, 'the card went at once');
  assert.notEqual(lineOf(app.store), t('allDone'));
  assert.ok(redraws.some((one) => one.name === 'boards' && one.changes[0].id === P), 'the left column is told');
  assert.deepEqual(requests, [{ kind: 'seen', args: { project: P } }]);
  const said = find(view.el, byClass('all-done-said'));
  assert.ok(said?.textContent.includes(t('adDismissed')), 'it says what it did');
  reply({ ok: true, result: { changed: true } });
  await settle();
  assert.equal(cardOf(view), null);
});

test('P-s1: after a reload the node’s seen keeps it gone; the next batch’s mark shows again', () => {
  setLanguage('en');
  // A new page, the node's board saying the mark was seen.
  const seen = fakeApp({ allDone: mark('m3', true) });
  const view = projectView(seen.app, { sheet });
  view.render();
  assert.equal(cardOf(view), null);
  assert.notEqual(lineOf(seen.app.store), t('allDone'));
  assert.equal(unseenAllDone(seen.app.store.state.boards.get(P)), null);
  // The project is done again: a new mark, unseen.
  seen.app.store.state.boards.set(P, board(mark('m4')));
  view.render();
  assert.ok(cardOf(view), 'the next mark shows');
  assert.equal(lineOf(seen.app.store), t('allDone'));
  // A mark dismissed on this page earlier doesn't hide a newer one.
  const again = fakeApp({ allDone: mark('m2') });
  assert.equal(unseenAllDone(again.app.store.state.boards.get(P)), null, 'm2 was dismissed above');
  again.app.store.state.boards.set(P, board(mark('m5')));
  assert.equal(unseenAllDone(again.app.store.state.boards.get(P))?.id, 'm5');
});

test('P-s1: a refused dismissal gives the mark back and says why, in words', async () => {
  setLanguage('en');
  const { app } = fakeApp({ allDone: mark('m6'), answer: () => ({ ok: false, error: { code: 'gone', message: 'no lead’s project local:project:site on this node' } }) });
  const view = projectView(app, { sheet });
  view.render();
  find(cardOf(view), byClass('all-done-dismiss')).dispatch('click');
  await settle();
  const card = cardOf(view);
  assert.ok(card, 'the mark is back');
  assert.equal(lineOf(app.store), t('allDone'));
  const note = find(card, byClass('refused'));
  assert.equal(note.textContent, t('adDismissFailed', { why: 'no lead’s project local:project:site on this node' }));
  assert.equal(findAll(view.el, byClass('all-done-said')).length, 0);
});

test('P-s1: a page the node doesn’t take `seen` from shows the card without Dismiss', () => {
  setLanguage('en');
  const { app } = fakeApp({ allDone: mark('m7'), kinds: [] });
  const view = projectView(app, { sheet });
  view.render();
  assert.ok(cardOf(view));
  assert.equal(findAll(cardOf(view), byClass('all-done-dismiss')).length, 0);
});

test('P-s1: the words in Spanish', () => {
  setLanguage('es');
  for (const key of ['adDismiss', 'adDismissTitle', 'adDismissed', 'adDismissFailed']) assert.notEqual(t(key), key);
  assert.equal(t('adDismiss'), 'Descartar');
  setLanguage('en');
});
