// The one message box (js/views/composer.js; the reviews' U9 and D9): each key and state, the input method's Enter, a
// phone's soft keyboard, growth, the draft kept per box, a refusal beside it with Try again; then the session's box
// (send, steer, queue where the page acts; a draft and why where it doesn't), the lead's and a card's on it.
// Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { installDom, find, findAll, byClass } from './fakedom.test.mjs';

const dom = installDom();
// A pointer and a keyboard, unless a test says it is a phone.
let touch = false;
globalThis.matchMedia = (query) => ({ matches: query.includes('pointer: coarse') ? touch : false, addEventListener() {} });
globalThis.MutationObserver ??= class { observe() {} disconnect() {} };
globalThis.ResizeObserver ??= class { observe() {} unobserve() {} disconnect() {} };
const { keyAction, composer, MAX_HEIGHT } = await import('../js/views/composer.js');
const { setLanguage, t } = await import('../js/i18n.js');
const flush = () => new Promise((resolve) => setImmediate(resolve));

const key = (input, init) => {
  let prevented = false;
  input.dispatch('keydown', { key: 'Enter', shiftKey: false, altKey: false, metaKey: false, ctrlKey: false, isComposing: false, keyCode: 13, ...init, preventDefault() { prevented = true; } });
  return prevented;
};
function memory() {
  const kept = new Map();
  return { kept, getItem: (k) => kept.get(k) ?? null, setItem: (k, v) => kept.set(k, String(v)), removeItem: (k) => kept.delete(k) };
}

test('keys: Enter sends, Shift+Enter is a new line, ⌥ after and ⌘/Ctrl now, Escape leaves; a composing Enter never sends', () => {
  const base = { key: 'Enter', shiftKey: false, altKey: false, metaKey: false, ctrlKey: false, isComposing: false, keyCode: 13 };
  assert.equal(keyAction(base), 'send');
  assert.equal(keyAction({ ...base, shiftKey: true }), null);
  assert.equal(keyAction({ ...base, altKey: true }), 'after');
  assert.equal(keyAction({ ...base, metaKey: true }), 'now');
  assert.equal(keyAction({ ...base, ctrlKey: true }), 'now');
  assert.equal(keyAction({ ...base, key: 'Escape', keyCode: 27 }), 'leave');
  assert.equal(keyAction({ ...base, key: 'a', keyCode: 65 }), null);
  // An input method choosing a word: its Enter confirms the word, as Chrome says (isComposing) and as Safari does (229).
  assert.equal(keyAction({ ...base, isComposing: true }), null);
  assert.equal(keyAction({ ...base, keyCode: 229 }), null);
  assert.equal(keyAction({ ...base, key: 'Escape', isComposing: true }), null);
  // A phone's soft keyboard: Enter is a new line, Send is the button.
  assert.equal(keyAction(base, { soft: true }), null);
});

test('the box: Enter sends its words the way its mode says; Shift+Enter, a composing Enter and an empty box send nothing', () => {
  setLanguage('en');
  const sent = [];
  const box = composer({ label: 'Message', onSend: (way, text) => { sent.push([way, text]); }, storage: null });
  box.setMode({ word: t('cmSteer'), title: 'Steer Claude', way: 'now' });
  assert.equal(find(box.button, byClass('send-word')).textContent, 'Steer', 'the button’s word says what Enter does');
  assert.equal(box.button.getAttribute('aria-label'), 'Steer Claude');
  assert.ok(box.button.disabled, 'nothing to send yet');
  key(box.input, {});
  assert.deepEqual(sent, [], 'an empty box sends nothing');
  box.input.value = 'first line\nsecond line';
  box.input.dispatch('input');
  assert.ok(!box.button.disabled);
  assert.equal(key(box.input, { shiftKey: true }), false, 'Shift+Enter is the browser’s new line');
  assert.equal(key(box.input, { isComposing: true }), false, 'a composing Enter is the input method’s');
  assert.equal(key(box.input, { keyCode: 229 }), false);
  assert.deepEqual(sent, []);
  assert.equal(key(box.input, {}), true);
  assert.equal(key(box.input, { altKey: true }), true);
  assert.equal(key(box.input, { metaKey: true }), true);
  assert.deepEqual(sent, [['now', 'first line\nsecond line'], ['after', 'first line\nsecond line'], ['now', 'first line\nsecond line']], 'a paste’s lines are kept');
  // The button sends as Enter does.
  box.el.dispatch('submit');
  assert.deepEqual(sent.at(-1), ['now', 'first line\nsecond line']);
  // Disabled (no lead to tell): nothing goes.
  box.setMode({ disabled: true });
  key(box.input, {});
  assert.equal(sent.length, 4);
});

test('the box: on a touch screen Enter is a new line and the button sends; Escape leaves the box', () => {
  touch = true;
  const sent = [];
  const box = composer({ label: 'Message', onSend: (way, text) => sent.push([way, text]), storage: null });
  assert.equal(box.input.getAttribute('enterkeyhint'), 'enter');
  box.input.value = 'hola';
  box.input.dispatch('input');
  assert.equal(key(box.input, {}), false);
  assert.deepEqual(sent, []);
  box.el.dispatch('submit');
  assert.deepEqual(sent, [['send', 'hola']]);
  touch = false;
  let left = 0;
  box.input.blur = () => { left++; };
  key(box.input, { key: 'Escape', keyCode: 27 });
  assert.equal(left, 1);
});

test('the box grows with its lines up to its limit, then scrolls inside', () => {
  const box = composer({ label: 'Message', storage: null });
  box.input.scrollHeight = 60;
  box.input.dispatch('input');
  assert.equal(box.input.style.height, '60px');
  box.input.scrollHeight = 900;
  box.input.dispatch('input');
  assert.equal(box.input.style.height, `${MAX_HEIGHT}px`);
});

test('what was typed and not sent is kept per box, across another box and a reload, and goes once sent', () => {
  const storage = memory();
  const box = composer({ label: 'Message', storage });
  box.setKey('session:a');
  box.input.value = 'half a thought';
  box.input.dispatch('input');
  box.setKey('session:b');
  assert.equal(box.input.value, '', 'another session’s box starts empty: nothing typed for one goes to another');
  box.setKey('session:a');
  assert.equal(box.input.value, 'half a thought');
  // A reload: a new box on the same storage.
  const again = composer({ label: 'Message', storage });
  again.setKey('session:a');
  assert.equal(again.input.value, 'half a thought');
  again.clear();
  assert.equal(storage.kept.size, 0);
  // Storage that refuses: for this page only, no error.
  const refusing = { getItem() { throw new Error('no'); }, setItem() { throw new Error('no'); }, removeItem() { throw new Error('no'); } };
  const quiet = composer({ label: 'Message', storage: refusing });
  quiet.setKey('x');
  quiet.input.value = 'y';
  quiet.input.dispatch('input');
  assert.equal(quiet.input.value, 'y');
});

test('a refusal is said beside the box with Try again, the words back in it', () => {
  setLanguage('es');
  let again = 0;
  const box = composer({ label: 'Mensaje', storage: null });
  box.refused(t('cmRefused', { why: 'la sesión terminó' }), 'mi mensaje', () => { again++; });
  assert.equal(box.input.value, 'mi mensaje');
  assert.ok(!box.notice.hidden);
  assert.match(box.notice.textContent, /No se envió: la sesión terminó/);
  assert.ok(box.notice.classList.contains('refused'));
  const retry = find(box.notice, byClass('composer-retry'));
  assert.equal(retry.textContent, 'Reintentar');
  retry.onclick();
  assert.equal(again, 1);
  assert.ok(box.notice.hidden, 'Try again clears what was said');
});

// ---- The session's box ----

const SID = 'local:e91d05a3-4f6a-4c1e-9b7d-2e5a8c0d1f3b';
async function sessionChat({ rights = ['read', 'draft', 'watch', 'act'], session: fields = {}, reply = () => ({ ok: true, result: { session: SID, when: 'step' } }) } = {}) {
  const { chatView } = await import('../js/views/chat.js');
  const { createStore } = await import('../js/store.js');
  const session = { id: SID, terminal: 'pts/7', agent: 'claude', cwd: '/home/dev/projects/example-api', status: 'idle', hosted: true, sendWays: ['step', 'now'], ...fields };
  const store = createStore();
  const sent = [];
  store.connect({ request(message) { sent.push({ kind: message.kind, args: message.args }); return Promise.resolve(reply(message.kind, message.args)); },
    subscribeChat() {}, unsubscribeChat() {}, resync() {}, reached: () => new Promise(() => {}) });
  store.setKinds(['send', 'session.draft', 'chat.page'], null, rights);
  store.apply({ v: 1, kind: 'snapshot', epoch: 'e', seq: 0, state: { node: { home: '/home/dev', ended: [] }, sessions: [session], leads: [], cards: [], boards: [] } });
  const app = { store, ui: { state: { route: { name: 'session', id: SID } }, subscribe() {}, go() {} } };
  const chat = chatView(app);
  chat.show(SID);
  const input = find(chat.el, (node) => node.tag === 'textarea');
  const word = () => find(chat.el, byClass('send-word')).textContent;
  const type = (text) => { input.value = text; input.dispatch('input'); };
  return { chat, input, sent, word, type, store };
}

test('a session’s box where the page acts: Enter sends (`send`, at its next step), the box empties; refused, why and Try again', async () => {
  for (const code of ['en', 'es']) {
    setLanguage(code);
    let refuse = false;
    const s = await sessionChat({ reply: () => (refuse ? { ok: false, error: { code: 'refused', message: 'it ended' } } : { ok: true, result: { session: SID, when: 'step' } }) });
    assert.equal(s.word(), t('swSend'));
    s.type('Run the tests');
    key(s.input, {});
    assert.deepEqual(s.sent.at(-1), { kind: 'send', args: { session: SID, text: 'Run the tests', when: 'step' } });
    assert.equal(s.input.value, '', 'the box empties at once');
    await flush();
    refuse = true;
    s.type('Again please');
    key(s.input, {});
    await flush();
    assert.equal(s.input.value, 'Again please', 'refused: the words come back');
    const notice = find(s.chat.el, byClass('composer-notice'));
    assert.match(notice.textContent, new RegExp(t('cmRefused', { why: '' }).slice(0, 8)));
    refuse = false;
    find(notice, byClass('composer-retry')).onclick();
    assert.deepEqual(s.sent.at(-1), { kind: 'send', args: { session: SID, text: 'Again please', when: 'step' } });
    // No `session.draft` was ever sent: Enter sends.
    assert.ok(!s.sent.some((one) => one.kind === 'session.draft'), code);
  }
});

test('a session’s box: Steer for a working Claude (now), Queue behind its open question, ⌥↩ after the turn where it has one', async () => {
  setLanguage('en');
  const working = await sessionChat({ session: { status: 'working' } });
  assert.equal(working.word(), 'Steer');
  working.type('Use the other API');
  key(working.input, {});
  assert.deepEqual(working.sent.at(-1).args, { session: SID, text: 'Use the other API', when: 'now', now: true });
  const asking = await sessionChat({ session: { status: 'needs-you', prompt: { question: 'Proceed?', options: ['Yes', 'No'], text: [] } } });
  assert.equal(asking.word(), 'Queue');
  const codex = await sessionChat({ session: { agent: 'codex', status: 'working', sendWays: ['step', 'now', 'after'] } });
  codex.type('After this, the docs');
  key(codex.input, { altKey: true });
  assert.deepEqual(codex.sent.at(-1).args, { session: SID, text: 'After this, the docs', when: 'after' });
  // ⌥↩ where the agent has no after: its next step.
  working.type('later');
  key(working.input, { altKey: true });
  assert.equal(working.sent.at(-1).args.when, 'step');
});

test('a session’s box where the page doesn’t act: the same box leaves a draft (`session.draft`), says why, shows the line', async () => {
  for (const code of ['en', 'es']) {
    setLanguage(code);
    // The node holds the draft (its ack's `applied` not reached yet: the overlay stays).
    const s = await sessionChat({ rights: ['read', 'draft', 'watch'], reply: () => ({ ok: true, result: { session: SID, applied: { sessions: 99 } } }) });
    assert.equal(s.word(), t('cmDraft'));
    const hint = find(s.chat.el, byClass('composer-hint'));
    assert.ok(!hint.hidden);
    assert.equal(hint.textContent, t('cmDraftsWhy'));
    s.type('Check the logs');
    key(s.input, {});
    assert.deepEqual(s.sent.at(-1), { kind: 'session.draft', args: { session: SID, text: 'Check the logs' } });
    assert.ok(!s.sent.some((one) => one.kind === 'send'), 'nothing is sent where the page doesn’t act');
    await flush();
    // (A page's chat draws again on the store's change; the stand-in DOM is never connected, so it is asked here.)
    s.chat.reveal();
    // The draft over the box, with its line, while the node holds it.
    const drafted = find(s.chat.el, (node) => node.classList.contains('composer-draft') && !node.classList.contains('queued'));
    assert.match(drafted.textContent, /vibeswitcher send/, `${code}: the line that sends it`);
  }
});

test('a session’s box: a composing Enter and Shift+Enter send nothing; typed words stay with their session', async () => {
  setLanguage('en');
  const s = await sessionChat();
  s.type('日本');
  key(s.input, { isComposing: true });
  key(s.input, { keyCode: 229 });
  key(s.input, { shiftKey: true });
  assert.equal(s.sent.filter((one) => one.kind === 'send').length, 0);
  assert.equal(s.input.value, '日本');
});

// ---- The lead's and a card's ----

// A page's app over a store that records each request (buttons.test.mjs's, with a card's `act`; that file's own tests
// stay its own).
function fakeApp({ route = { name: 'node' }, state = {}, kinds = null }) {
  const sent = [];
  const answer = (kind, args) => { sent.push({ kind, args }); return Promise.resolve({ ok: true, result: {} }); };
  const store = {
    state: { node: null, connection: 'live', phrase: null, pageWords: null, sessions: new Map(), leads: new Map(), boards: new Map(), cards: new Map(),
      cardKeys: new Map(), acting: new Map(), draftRefused: new Map(), sessionDraftRefused: new Map(), plugins: null, ...state },
    acts: () => true, can: (kind) => kinds === null || kinds.includes(kind), subscribe() { return () => {}; }, notify() {},
    read: answer, request: answer, act: (id, kind, args) => answer(kind, { card: id, ...args }), cardKey: (id) => id, draftOf: () => null, sessionDraftOf: () => null,
  };
  return { store, sent, ui: { state: { route }, subscribe() {}, go() {} } };
}

test('the lead’s box is the same box: a textarea, Enter tells the lead, Shift+Enter a new line, Send in words', async () => {
  setLanguage('en');
  const { projectView } = await import('../js/views/project.js');
  const PROJECT = 'local:project:Zx3kQ0aVtLmN';
  const LEAD = 'local:7d3c9a10-4f6a-4c1e-9b7d-2e5a8c0d1f3b';
  const app = fakeApp({ route: { name: 'project', id: PROJECT, view: 'lead' }, kinds: ['tell', 'send'],
    state: { leads: new Map([[PROJECT, { project: PROJECT, root: '/home/dev/projects/example-site', session: LEAD, questions: { open: 0, blocking: 0 }, cards: [] }]]),
      sessions: new Map([[LEAD, { id: LEAD, agent: 'claude', status: 'working', hosted: true, role: 'lead', lead: PROJECT, sendWays: ['step', 'now'] }]]),
      boards: new Map([[PROJECT, { project: PROJECT, root: '/home/dev/projects/example-site', tasks: [], counts: {} }]]) } });
  const view = projectView(app, { sheet: { open() {}, close() {}, shown: () => false } });
  view.render();
  const box = find(view.el, (node) => node.tag === 'textarea');
  assert.ok(box, 'the lead’s box is a textarea, as a session’s');
  assert.ok(box.classList.contains('composer-input'));
  assert.equal(find(view.el, byClass('send-word'))?.textContent, 'Send');
  box.value = 'Ship it\nafter the tests';
  box.dispatch('input');
  key(box, { shiftKey: true });
  assert.equal(app.sent.length, 0);
  key(box, {});
  assert.deepEqual(app.sent.at(-1), { kind: 'tell', args: { folder: '/home/dev/projects/example-site', text: 'Ship it\nafter the tests' } });
});

test('a card’s answer box is the same box: Enter answers, Shift+Enter a new line, a composing Enter never', async () => {
  setLanguage('en');
  const { questionCard } = await import('../js/views/cards.js');
  const CARD = 'local:card:5b1f0c3e-8a2d-4e6f-b7c9-1d0a2f3e4b5c';
  const card = { id: CARD, kind: 'question', project: 'local:project:Zx3kQ0aVtLmN', root: '/home/dev/projects/example-site', open: true, at: new Date().toISOString(), blocking: false, seen: 3,
    question: { id: 'q1', short: 'Launch?', text: 'When do we launch?', options: ['Thursday', 'Wait'], priority: 'important', version: 1, state: 'open', decideBy: null, proposal: null } };
  const app = fakeApp({ kinds: ['answer'], state: { cards: new Map([[CARD, card]]) } });
  const timers = [];
  app.later = (fn) => { timers.push(fn); return () => {}; };
  const view = questionCard(app, card);
  view.update(card);
  const box = find(view.el, (node) => node.tag === 'textarea' && node.classList.contains('answer-input'));
  assert.ok(box, 'a textarea with the answer box’s class');
  box.value = 'Friday,\nafter the fixes';
  box.dispatch('input');
  key(box, { isComposing: true });
  key(box, { shiftKey: true });
  assert.equal(app.sent.filter((one) => one.kind === 'answer').length, 0);
  key(box, {});
  for (const fn of timers.splice(0)) fn();
  await flush();
  assert.deepEqual(app.sent.filter((one) => one.kind === 'answer').map((one) => one.args.text), ['Friday,\nafter the fixes'], 'Enter answers, its lines kept');
});

test.after(() => dom.restore());
