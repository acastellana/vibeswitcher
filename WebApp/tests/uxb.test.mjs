// The UX review's U3, U4, U5 and U16 (2026-11-25), each held here on tests/fakedom.mjs's stand-in DOM: what blocks
// comes first and open, "What waits on me" takes the centre, Push and Decline wait a few seconds with an Undo and leave
// a line in the conversation, and the Approve button names what it approves. Every wait is the injected clock
// (`app.later`), never a real one. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { installDom, find, findAll, byClass, button } from './fakedom.mjs';

process.env.TZ = 'UTC';
const here = dirname(fileURLToPath(import.meta.url));
installDom();
const { setLanguage } = await import('../js/i18n.js');
const cards = await import('../js/views/cards.js');

const P = 'local:project:site';
const ROOT = '/home/dev/projects/example-site';
const COMMIT = '4e1c9a7b2d6f8035a1c4e7b9d2f60813a5c7e9b1';
const ago = (minutes) => new Date(Date.now() - minutes * 60000).toISOString();

// An app as the views read it: a store over `state`, the requests sent (each answered by `reply`), and a clock the
// test turns by hand (`timers`, each { fn, ms, cancelled }).
function fakeApp({ state = {}, kinds = null, acts = true, reply = () => ({ ok: true, result: {} }), route = { name: 'project', id: P, view: 'lead', show: 'decisions' } } = {}) {
  const sent = [];
  const timers = [];
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
  const ui = { state: { route }, subscribe() {}, go() {} };
  const later = (fn, ms) => { const timer = { fn, ms, cancelled: false }; timers.push(timer); return () => { timer.cancelled = true; }; };
  return { store, sent, timers, ui, later };
}
// The clock's next wait that is still on, run.
const runNext = (app) => { const timer = app.timers.find((one) => !one.cancelled && !one.ran); timer.ran = true; timer.fn(); return timer; };
const settle = () => new Promise((resolve) => setImmediate(resolve));

function question(id, priority, at, extra = {}) {
  return { id: `local:card:${id}`, kind: 'question', project: P, root: ROOT, open: true, closed: null, notice: null, at, blocking: priority === 'blocking',
    question: { id, short: id, text: `Question ${id}: ship it on Thursday?`, options: ['Thursday', 'Wait'], priority, whyNow: null, version: 1, revisionNote: null,
      proposal: null, decideBy: null, state: 'open', answer: null, task: null }, ...extra };
}
function approval(at) {
  return { ...question('appr', 'blocking', at), kind: 'approval',
    question: { ...question('appr', 'blocking', at).question, text: 'The clean-up passed its audit. It deletes files, so the merge is yours to approve.', options: [`Approve ${COMMIT}`, 'Not yet'] },
    approval: { commit: COMMIT, tasks: ['cleanup'], base: 'landing-base', files: ['tools/cleanup.py'], diffstat: '1 file changed', subject: 'Clean up', verdicts: {}, sensitive: [], problems: [] } };
}
function leadWithPush(id = 'p1', extra = {}) {
  return { project: P, root: ROOT, session: 'local:lead', named: null, bound: 'local:lead', replaced: [], held: 0, reportsWaiting: 0, notice: null, starting: false, looks: 1,
    questions: { open: 0, blocking: 0 }, cards: [], told: [],
    push: { id, commit: 'c41d7e09b2a65f38d1e0c7b94a2f6e1d3b8c5a70', short: 'c41d7e09', branch: 'landing-base', remote: 'origin', target: 'origin/landing-base',
      url: 'git@example.invalid:x.git', ahead: 2, subjects: ['c41d7e0 Landing copy'], askedAt: ago(10), ...extra } };
}
const cardsOf = (el) => findAll(el, (node) => node.tag === 'article');
const head = (card) => find(card, byClass('card-question'))?.textContent || find(card, byClass('card-closed'))?.textContent || '';

// U3 ---------------------------------------------------------------------------------------------------------------

test('U3: the waiting block puts Blocking first (oldest first), then Important, then Whenever, then the push; Blocking cards are open, only the rest fold', () => {
  setLanguage('en');
  const all = [question('whenever', 'whenever', ago(30)), question('important', 'important', ago(20)), question('block-new', 'blocking', ago(5)), approval(ago(1)), question('block-old', 'blocking', ago(15))];
  const app = fakeApp({ kinds: ['answer', 'push', 'push.decline'], state: { cards: new Map(all.map((card) => [card.id, card])), leads: new Map([[P, leadWithPush()]]) } });
  // A held config change the project view draws, placed by its priority (Blocking) and its time.
  const config = { key: 'local:card:config', at: ago(10), priority: 'blocking', el: (() => { const el = document.createElement('article'); el.className = 'card'; el.append('Held config'); return el; })() };
  const stack = cards.questionStack(app, P, { others: () => [config] });
  assert.equal(stack.update(), 7, 'five questions, the held config and the push');
  const shown = cardsOf(stack.el);
  assert.deepEqual(shown.map((card) => (card.classList.contains('push-card') ? 'push' : card === config.el ? 'config' : head(card).replace(/^Question (\S+):.*/, '$1').replace(/^The clean-up.*/, 'appr'))),
    ['block-old', 'config', 'block-new', 'appr', 'important', 'whenever', 'push']);
  const folded = (name) => shown.find((card) => head(card).startsWith(`Question ${name}`))?.classList.contains('folded');
  assert.equal(folded('block-old'), false);
  assert.equal(folded('block-new'), false);
  assert.equal(shown[3].classList.contains('folded'), false, 'the blocking approval arrives open');
  assert.ok(find(shown[3], button('Not yet')), 'with its options');
  assert.equal(folded('important'), true);
  assert.equal(folded('whenever'), true);
  // Every option of the first blocking question is there to press.
  assert.ok(find(shown[0], button('Thursday')) && find(shown[0], button('Wait')));
  // Opening a folded one opens it in place; the order holds.
  find(shown[5], byClass('card-unfold')).click();
  assert.equal(cardsOf(stack.el)[5].classList.contains('folded'), false);
  assert.equal(cardsOf(stack.el)[4].classList.contains('folded'), true);
  assert.equal(cardsOf(stack.el).at(-1).classList.contains('push-card'), true);
});

test('U3: with nothing Blocking the oldest of the rest shows whole and the others fold; a held config the project draws sits among the Blocking cards', async () => {
  setLanguage('en');
  const all = [question('important', 'important', ago(20)), question('whenever', 'whenever', ago(30))];
  const app = fakeApp({ kinds: ['answer'], state: { cards: new Map(all.map((card) => [card.id, card])) } });
  const stack = cards.questionStack(app, P);
  stack.update();
  assert.deepEqual(cardsOf(stack.el).map((card) => [head(card).slice(9, 18), card.classList.contains('folded')]), [['important', false], ['whenever:', true]]);
  // The project view: its held config card in the stack, before an Important question though asked after it.
  const { projectView } = await import('../js/views/project.js');
  const held = { id: 'local:card:config', kind: 'config', project: P, root: ROOT, open: true, at: ago(5), seen: 's', config: { items: [{ name: 'lead.md', change: 'edited', files: [] }], guarded: [] } };
  const state = { cards: new Map([...all, held].map((card) => [card.id, card])), leads: new Map([[P, { ...leadWithPush(), push: null }]]) };
  const view = projectView(fakeApp({ kinds: ['answer'], state }), { sheet: { open() {}, close() {} } });
  view.render();
  const box = find(view.el, byClass('wait-box'));
  assert.deepEqual(cardsOf(box).map((card) => head(card).slice(0, 18)), ['Changed settings f', 'Question important', 'Question whenever:']);
});

// U16 --------------------------------------------------------------------------------------------------------------

test('U16: the Approve option says what it approves in words with 8 characters of the commit; the whole one on hover and in what is sent', () => {
  setLanguage('en');
  const card = approval(ago(1));
  const app = fakeApp({ kinds: ['answer'] });
  const view = cards.questionCard(app, card);
  view.update(card);
  const approve = find(view.el, button('Approve merging 4e1c9a7b into landing-base'));
  assert.ok(approve);
  assert.doesNotMatch(approve.textContent, new RegExp(COMMIT));
  assert.equal(approve.title, `Approve ${COMMIT}`, 'the whole option on hover');
  assert.ok(view.el.textContent.includes(COMMIT), 'the whole commit in its row, to copy');
  approve.click();
  assert.match(view.el.textContent, /Sending “Approve merging 4e1c9a7b into landing-base”… · Undo/);
  runNext(app);
  assert.deepEqual(app.sent.map((one) => one.args.text), [`Approve ${COMMIT}`], 'the node gets its whole option');
  // The keys answer with the option too.
  const keyed = cards.questionCard(app, card);
  keyed.update(card);
  keyed.el.dispatch('keydown', { key: '1' });
  runNext(app);
  assert.equal(app.sent.at(-1).args.text, `Approve ${COMMIT}`);
  // Answered: the receipt in the same words.
  const answered = { ...card, open: false, question: { ...card.question, state: 'answered', answer: `Approve ${COMMIT}` } };
  keyed.update(answered);
  assert.match(keyed.el.textContent, /You answered Approve merging 4e1c9a7b into landing-base/);
  // A question that isn't an approval keeps its words as they are.
  assert.equal(cards.optionWords(question('q', 'blocking', ago(1)), `Approve ${COMMIT}`), `Approve ${COMMIT}`);
  setLanguage('es');
  const es = cards.questionCard(app, card);
  es.update(card);
  assert.ok(find(es.el, button('Aprobar la fusión de 4e1c9a7b en landing-base')));
  assert.ok(find(es.el, button('Todavía no')));
  find(es.el, button('Todavía no')).click();
  runNext(app);
  assert.equal(app.sent.at(-1).args.text, 'Not yet', 'the node’s own option');
  setLanguage('en');
});
