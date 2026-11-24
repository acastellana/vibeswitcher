// Acting from the page (the redesign's "Acting from the page"), its parts with no page in them: whether this
// connection acts (the hello's `auth.rights` holds `act`) and for which kinds (`hello.kinds`), both modes from a mocked
// hello on a fake socket; what a card's request carries (the card, the seen it was drawn with, no code); which settings
// a page may not set even when it acts; the node's refusals in the page's words; a pause's arguments; and a request
// sent with its action id and the card's seen. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createStore } from '../js/store.js';
import { connectSocket } from '../js/socket.js';
import { validate } from '../wire/validators.js';
import { cardArgs, answerArgs, pageMaySet, refusalWords, actsFor } from '../js/acting.js';
import { pauseArgs } from '../js/views/drive.js';
import { setLanguage } from '../js/i18n.js';

const vectors = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'wire', 'vectors.json'), 'utf8'));
setLanguage('en');

// A page on a fake socket whose hello is the node's web hello with `rights` and `kinds` in place of its own.
async function page({ rights, kinds, act = undefined }) {
  const store = createStore();
  const sockets = [];
  const stored = [];
  const timers = [];
  class FakeSocket {
    constructor() { this.sent = []; this.readyState = 0; sockets.push(this); }
    send(text) { this.sent.push(JSON.parse(text)); }
    close() { this.readyState = 3; this.onclose?.(); }
  }
  const feed = connectSocket(store, {
    url: 'ws://127.0.0.1:47830/ws', WebSocket: FakeSocket, storage: { getItem: () => 'token', setItem: (key, value) => stored.push([key, value]), removeItem() {} }, validate: () => null,
    build: Promise.resolve(null), setTimeout: (run) => { timers.push(run); return timers.length; }, clearTimeout: () => {}, location: { hash: '', pathname: '/', search: '' },
    history: { replaceState() {} }, reload() {}, log: () => {},
  });
  store.connect(feed);
  await feed.start();
  const socket = sockets[0];
  socket.readyState = 1;
  socket.onopen();
  const hello = structuredClone(vectors['hello.web']);
  hello.auth = { ...(hello.auth || {}), rights, ...(act ? { act } : {}) };
  hello.kinds = kinds;
  socket.onmessage({ data: JSON.stringify(hello) });
  await new Promise((resolve) => setImmediate(resolve));
  // The socket drops and the page connects again without a reload: the newest socket, opened.
  const reconnect = () => {
    sockets[sockets.length - 1].close();
    timers.pop()?.();
    const again = sockets[sockets.length - 1];
    again.readyState = 1;
    again.onopen?.();
    return again;
  };
  return { store, socket, sockets, stored, feed, hello, reconnect, app: { store } };
}

const ACTING = ['answer', 'hold', 'approve', 'approve.list', 'config.accept', 'base.accept', 'base.keep', 'tell', 'send', 'session.end', 'session.rename', 'session.pause',
  'session.resume', 'session.reopen', 'session.new', 'lead', 'push', 'push.decline', 'set', 'plugin.on', 'plugin.off', 'plugin.remove', 'stop', 'status', 'board'];

test('a hello with "act" makes the page act for each kind it lists; without it the page drafts, as before', async () => {
  const acting = await page({ rights: ['read', 'draft', 'act'], kinds: ACTING });
  assert.equal(acting.store.acts(), true);
  assert.equal(actsFor(acting.app, 'answer'), true);
  assert.equal(actsFor(acting.app, 'tell'), true);
  assert.equal(actsFor(acting.app, 'web.open'), false, 'never listed: web.open, start, build.switch, hooks.install, plugin.add');
  assert.equal(actsFor(acting.app, 'build.switch'), false);

  const drafting = await page({ rights: ['read', 'draft'], kinds: ['status', 'board', 'draft', 'session.draft'] });
  assert.equal(drafting.store.acts(), false);
  assert.equal(actsFor(drafting.app, 'answer'), false);
  assert.equal(drafting.store.can('draft'), true);

  // A kind listed without the right is no button either (a node before acting listing a read the page asks for).
  const listedOnly = await page({ rights: ['read', 'draft'], kinds: ['answer'] });
  assert.equal(actsFor(listedOnly.app, 'answer'), false);

  // The mock (no hello) acts for anything.
  assert.equal(createStore().acts(), true);
});

test('a card’s request carries the card, the seen the page drew it with and its own arguments, never a code', async () => {
  const card = { id: 'local:card:c1', seen: 'v3:1a2b', question: { version: 2, text: 'Thursday?' } };
  assert.deepEqual(cardArgs(card), { card: 'local:card:c1', seen: 'v3:1a2b' });
  assert.deepEqual(answerArgs(card, 'Thursday'), { card: 'local:card:c1', seen: 'v3:1a2b', text: 'Thursday', version: 2 });
  assert.deepEqual(cardArgs({ id: 'x' }, { extra: 1 }), { card: 'x', seen: null, extra: 1 });
  assert.deepEqual(answerArgs({ id: 'p', seen: 's1', plugin: { plugin: 'shell' } }, 'run'), { card: 'p', seen: 's1', text: 'run' }, 'a plugin’s card: its word, no version');

  const { store, socket } = await page({ rights: ['read', 'draft', 'act'], kinds: ACTING });
  store.apply({ v: 1, kind: 'snapshot', epoch: 'e', seq: 0, state: { node: null, sessions: [], leads: [], cards: [{ id: card.id, open: true, seen: card.seen, question: card.question }], boards: [] } });
  store.act(card.id, 'answer', { text: 'Thursday', version: 2, seen: card.seen });
  const sent = socket.sent.find((message) => message.kind === 'answer');
  assert.deepEqual(sent.args, { card: card.id, text: 'Thursday', version: 2, seen: card.seen });
  assert.match(sent.action, /^[0-9a-f-]{36}$/, 'with an action id');
  assert.equal('code' in sent.args, false);
  // The node's `changed`: nothing was done, the card is drawn again, and the page says why in its own words.
  socket.onmessage({ data: JSON.stringify({ v: 1, re: sent.id, ok: false, error: { code: 'changed', message: 'card C changed since the page drew it: look again' } }) });
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(store.state.acting.get(card.id), { refused: 'card C changed since the page drew it: look again', code: 'changed' });
  assert.equal(refusalWords({ code: 'changed' }), 'This changed since the page drew it: look again. Nothing was done.');
});

test('the settings a page may not set even when it acts stay the terminal’s: web_acts on, a floor, the policy', () => {
  assert.equal(pageMaySet('web_acts', 'off'), true, 'off, the one value');
  assert.equal(pageMaySet('web_acts', ' OFF '), true);
  assert.equal(pageMaySet('web_acts', 'on'), false);
  assert.equal(pageMaySet('floor_audit_finders', '1'), false);
  assert.equal(pageMaySet('policy', 'auto'), false);
  assert.equal(pageMaySet('max_workers', '3'), true);
  assert.equal(refusalWords({ code: 'voice', message: 'this page doesn’t act' }), 'Acting from this page ended: pair it again with `vibeswitcher web` to act. Nothing was done.');
  assert.equal(refusalWords({ code: 'gone', message: 'That card is gone.' }), 'That card is gone.', 'any other: the node’s own words');
  assert.equal(refusalWords(null), 'The node refused it.');
});

test('a pause’s arguments are the command line’s, as the node takes them', () => {
  assert.deepEqual(pauseArgs('indefinitely'), { for: 'indefinitely' });
  assert.deepEqual(pauseArgs('hour'), { for: 'hours', hours: 1 });
  assert.deepEqual(pauseArgs('morning'), { for: 'morning' });
  assert.deepEqual(pauseArgs('week'), { for: 'hours', hours: 168 });
  assert.deepEqual(pauseArgs('off'), { for: 'off' });
});

test('the act secret is kept in memory only, sent with the token on a reconnect, and dropped when acting ends', async () => {
  const secret = 'a'.repeat(43);
  const { store, sockets, stored, hello, reconnect } = await page({ rights: ['read', 'draft', 'act'], kinds: ACTING, act: secret });
  assert.equal(store.acts(), true);
  assert.equal(stored.some(([, value]) => String(value).includes(secret)), false, 'never in storage');
  // The socket drops; the page connects again without a reload: the auth carries the token and the act secret.
  const again = reconnect();
  assert.notEqual(again, sockets[0]);
  const auth = again.sent.find((message) => message.kind === 'auth');
  assert.deepEqual({ token: auth?.args.token, act: auth?.args.act }, { token: 'token', act: secret });
  // An acting request refused by voice: acting ended, the page reads and drafts, and the next auth carries no secret.
  again.onmessage({ data: JSON.stringify({ ...hello, auth: { ...hello.auth, act: undefined, rights: ['read', 'draft', 'act'] } }) });
  const asked = store.request('tell', { folder: '/f', text: 'hi' });
  const sent = again.sent.find((message) => message.kind === 'tell');
  again.onmessage({ data: JSON.stringify({ v: 1, re: sent.id, ok: false, error: { code: 'voice', message: 'this page doesn’t act: pair it again with `vibeswitcher web` (acting from the page is on) to act' } }) });
  await asked;
  assert.equal(store.acts(), false);
  const third = reconnect();
  assert.equal('act' in (third.sent.find((message) => message.kind === 'auth')?.args || {}), false);
});

test('a hello without "act" drops the secret: a page that doesn’t act shows no acting control', async () => {
  const { store, sockets, hello, reconnect } = await page({ rights: ['read', 'draft', 'act'], kinds: ACTING, act: 'b'.repeat(43) });
  sockets[0].onmessage({ data: JSON.stringify({ ...hello, auth: { ...hello.auth, act: undefined, rights: ['read', 'draft'] }, kinds: ['status'] }) });
  assert.equal(store.acts(), false);
  const again = reconnect();
  assert.equal('act' in (again.sent.find((message) => message.kind === 'auth')?.args || {}), false);
});
