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

// U4 ---------------------------------------------------------------------------------------------------------------

test('U4: at “What waits on me” the conversation pane is hidden and the waiting block takes the centre with no height of its own', async () => {
  setLanguage('en');
  const { projectView } = await import('../js/views/project.js');
  const asks = { name: 'project', id: P, view: 'lead', show: 'asks' };
  const state = { cards: new Map([[question('q', 'blocking', ago(5)).id, question('q', 'blocking', ago(5))]]), leads: new Map([[P, leadWithPush()]]) };
  const app = fakeApp({ kinds: ['answer'], state, route: asks });
  const view = projectView(app, { sheet: { open() {}, close() {} } });
  view.render();
  assert.equal(view.el.classList.contains('show-asks'), true);
  assert.equal(find(view.el, byClass('wait-box')).hidden, false);
  // The other levels keep the conversation.
  app.ui.state.route = { ...asks, show: 'decisions' };
  view.render();
  assert.equal(view.el.classList.contains('show-asks'), false);
  // Nothing waiting: the block still holds the centre, and says so.
  const calm = fakeApp({ state: { leads: new Map([[P, { ...leadWithPush(), push: null }]]) }, route: asks });
  const empty = projectView(calm, { sheet: { open() {}, close() {} } });
  empty.render();
  const box = find(empty.el, byClass('wait-box'));
  assert.equal(box.hidden, false);
  assert.match(box.textContent, /\S/);
  assert.equal(find(empty.el, byClass('talk')).textContent, '', 'nothing in the hidden pane');
  // The rules: the pane gone, the block the one thing that scrolls (no cap of its own), at every width.
  const css = readFileSync(join(here, '..', 'style.css'), 'utf8');
  assert.match(css, /\.project-view\.show-asks \.talk \{ display: none; \}/);
  assert.match(css, /\.project-view\.show-asks \.wait-box \{ flex: 1; min-height: 0; max-height: none;/);
});

// U5 ---------------------------------------------------------------------------------------------------------------

function pushApp(reply) {
  return fakeApp({ kinds: ['push', 'push.decline'], state: { leads: new Map([[P, leadWithPush()]]) }, reply });
}
const pushed = (kind, args) => ({ ok: true, result: { request: args.request, settled: kind === 'push' ? 'pushed' : 'declined', ok: true, said: '', target: kind === 'push' ? 'origin/landing-base' : null } });

test('U5: Push waits the same seconds as a Blocking answer with “Pushing <sha> to <target>… · Undo”; Undo sends nothing and gives the buttons back', () => {
  setLanguage('en');
  const app = pushApp(pushed);
  const block = cards.pushBlock(app);
  block.update(app.store.state.leads.get(P));
  find(block.el, button('Push')).click();
  assert.deepEqual(app.sent, [], 'nothing sent yet');
  assert.match(block.el.textContent, /Pushing c41d7e09 to origin\/landing-base… · Undo/);
  assert.equal(app.timers[0].ms, cards.UNDO_MS, 'the Blocking answer’s seconds');
  find(block.el, byClass('card-undo')).click();
  assert.equal(app.timers[0].cancelled, true);
  assert.ok(find(block.el, button('Push')) && find(block.el, button('Decline')), 'the buttons back');
  assert.deepEqual(app.sent, []);
  assert.deepEqual(block.receipts(), []);
});

test('U5: once the wait runs out the same request goes, taken at the click; the card leaves and a line says “Pushed: <target> at <sha>”', async () => {
  setLanguage('en');
  const app = pushApp(pushed);
  let changes = 0;
  const block = cards.pushBlock(app, { onChange: () => { changes += 1; } });
  const lead = app.store.state.leads.get(P);
  block.update(lead);
  find(block.el, button('Push')).click();
  runNext(app);
  assert.deepEqual(app.sent, [{ kind: 'push', args: { folder: ROOT, request: 'p1' } }], 'the same request as ever');
  assert.match(block.el.textContent, /Pushing c41d7e09 to origin\/landing-base…/);
  assert.doesNotMatch(block.el.textContent, /Undo/, 'gone: no Undo once sent');
  await settle();
  assert.equal(block.el.firstChild, null, 'the card leaves before the node’s delta');
  assert.ok(changes >= 1, 'the holder is told');
  const { pushReceipt } = await import('../js/push.js');
  assert.deepEqual(block.receipts().map(pushReceipt), ['Pushed: origin/landing-base at c41d7e09']);
  // The node's delta: the request settled. Nothing comes back.
  block.update({ ...lead, push: null });
  assert.equal(block.el.firstChild, null);
});

test('U5: a request that changes while the push waits is not pushed: the wait is dropped and the new request shows with a word saying so', () => {
  setLanguage('en');
  const app = pushApp(pushed);
  const block = cards.pushBlock(app);
  block.update(app.store.state.leads.get(P));
  find(block.el, button('Push')).click();
  block.update(leadWithPush('p2', { commit: 'aa11bb22cc33dd44ee55ff6600112233445566', short: 'aa11bb22', ahead: 3 }));
  assert.equal(app.timers[0].cancelled, true);
  assert.deepEqual(app.sent, []);
  assert.match(block.el.textContent, /aa11bb22/);
  assert.match(block.el.textContent, /changed its request while yours waited: nothing was sent/);
  // The lead withdrew it instead: nothing goes, and no card.
  find(block.el, button('Push')).click();
  block.update({ ...leadWithPush(), push: null });
  assert.equal(app.timers[1].cancelled, true);
  assert.equal(block.el.firstChild, null);
  assert.deepEqual(app.sent, []);
});

test('U5: Decline the same way: “Declining the push of … · Undo”, then push.decline and the line “Push declined”', async () => {
  setLanguage('en');
  const app = pushApp(pushed);
  const block = cards.pushBlock(app);
  block.update(app.store.state.leads.get(P));
  find(block.el, button('Decline')).click();
  assert.match(block.el.textContent, /Declining the push of c41d7e09 to origin\/landing-base… · Undo/);
  assert.deepEqual(app.sent, []);
  runNext(app);
  assert.deepEqual(app.sent, [{ kind: 'push.decline', args: { folder: ROOT, request: 'p1' } }]);
  await settle();
  const { pushReceipt } = await import('../js/push.js');
  assert.deepEqual(block.receipts().map(pushReceipt), ['Push declined']);
});

test('U5: a refusal stays on the card in the node’s words with the buttons back; a push git refused stays too, with nothing left to press', async () => {
  setLanguage('en');
  const busy = 'a push of /home/dev/projects/example-site’s is under way: wait for it';
  const app = pushApp(() => ({ ok: false, error: { code: 'refused', message: busy } }));
  const block = cards.pushBlock(app);
  const lead = app.store.state.leads.get(P);
  block.update(lead);
  find(block.el, button('Push')).click();
  runNext(app);
  await settle();
  assert.equal(find(block.el, byClass('push-refused')).textContent, busy);
  assert.ok(find(block.el, button('Push')), 'the buttons back');
  assert.deepEqual(block.receipts(), []);
  // Again, and git refuses it: the node closes the request and says why; the card keeps its words.
  const said = 'Not pushed: origin/landing-base has commits c41d7e09 lacks (not a fast-forward; nothing forced).';
  const git = pushApp(() => ({ ok: true, result: { request: 'p1', settled: 'notFastForward', ok: false, said, target: 'origin/landing-base' } }));
  const other = cards.pushBlock(git);
  other.update(lead);
  find(other.el, button('Push')).click();
  runNext(git);
  await settle();
  other.update({ ...lead, push: null });
  assert.equal(find(other.el, byClass('push-refused')).textContent, said);
  assert.equal(find(other.el, button('Push')), null, 'nothing to settle: the request is gone');
  assert.deepEqual(other.receipts(), []);
  // A newer request takes its place.
  other.update(leadWithPush('p2'));
  assert.equal(find(other.el, byClass('push-refused')), null);
  assert.ok(find(other.el, button('Push')));
});

test('U5: in Spanish, “Haciendo push de … · Deshacer”, then “Push hecho: …” or “Push rechazado”', async () => {
  setLanguage('es');
  const app = pushApp(pushed);
  const block = cards.pushBlock(app);
  block.update(app.store.state.leads.get(P));
  find(block.el, button('Hacer push')).click();
  assert.match(block.el.textContent, /Haciendo push de c41d7e09 a origin\/landing-base… · Deshacer/);
  runNext(app);
  await settle();
  const decline = pushApp(pushed);
  const other = cards.pushBlock(decline);
  other.update(decline.store.state.leads.get(P));
  find(other.el, button('Rechazar')).click();
  assert.match(other.el.textContent, /Rechazando el push de c41d7e09 a origin\/landing-base… · Deshacer/);
  runNext(decline);
  await settle();
  const { pushReceipt } = await import('../js/push.js');
  assert.deepEqual([...block.receipts(), ...other.receipts()].map(pushReceipt), ['Push hecho: origin/landing-base en c41d7e09', 'Push rechazado']);
  setLanguage('en');
});

test('U5: the lead view: Push from the waiting block, and its line stays in the conversation', async () => {
  setLanguage('en');
  const { projectView } = await import('../js/views/project.js');
  const app = pushApp(pushed);
  const view = projectView(app, { sheet: { open() {}, close() {} } });
  view.render();
  find(find(view.el, byClass('wait-box')), button('Push')).click();
  runNext(app);
  await settle();
  app.store.state.leads.set(P, { ...app.store.state.leads.get(P), push: null });
  view.render();
  const line = find(find(view.el, byClass('talk')), byClass('kind-push'));
  assert.ok(line, 'a line in the conversation');
  assert.match(line.textContent, /Pushed: origin\/landing-base at c41d7e09/);
  assert.equal(find(view.el, byClass('wait-box')).hidden, true, 'nothing waits');
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

test('U16: an approval answered in the conversation reads as its button did, not as the bare option', async () => {
  const { projectView } = await import('../js/views/project.js');
  const card = { ...approval(ago(30)), open: false, closed: 'answered', question: { ...approval(ago(30)).question, state: 'answered', answer: `Approve ${COMMIT}` } };
  const said = (state, code) => {
    setLanguage(code);
    const app = fakeApp({ state: { leads: new Map([[P, { ...leadWithPush(), push: null }]]), ...state } });
    const view = projectView(app, { sheet: { open() {}, close() {} } });
    view.render();
    return find(find(view.el, byClass('talk')), byClass('mine'))?.textContent;
  };
  const board = (answer) => new Map([[P, { project: P, root: ROOT, tasks: [], answered: [{ id: 'appr', card: card.id, version: 1, state: 'answered', text: card.question.text, answer,
    proposal: null, why: null, reworded: false, task: 'cleanup', at: ago(20), delivered: null, replaceable: false }] }]]);
  const withCard = { boards: board(`Approve ${COMMIT}`), cards: new Map([[card.id, card]]) };
  assert.equal(said(withCard, 'en'), 'Approve merging 4e1c9a7b into landing-base');
  assert.equal(said(withCard, 'es'), 'Aprobar la fusión de 4e1c9a7b en landing-base');
  assert.equal(said({ ...withCard, boards: board('Not yet') }, 'es'), 'Todavía no');
  // The card gone from the snapshot: the answer that names a commit to approve is still said in words.
  assert.equal(said({ boards: board(`Approve ${COMMIT}`) }, 'en'), 'Approve merging 4e1c9a7b');
  // Any other answer as it was.
  assert.equal(said({ boards: board('A year, with hashed names') }, 'en'), 'A year, with hashed names');
  setLanguage('en');
});
