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
async function page({ rights, kinds, act = undefined, flags = {}, build = null, assets = undefined, phrase = undefined, rebuild = null }) {
  const store = createStore();
  const sockets = [];
  const stored = [];
  const kept = new Map([['vibeswitcher.token', 'token'], ...Object.entries(flags)]);
  const reloads = [];
  const timers = [];
  class FakeSocket {
    constructor() { this.sent = []; this.readyState = 0; sockets.push(this); }
    send(text) { this.sent.push(JSON.parse(text)); }
    close() { this.readyState = 3; this.onclose?.(); }
  }
  const feed = connectSocket(store, {
    url: 'ws://127.0.0.1:47830/ws', WebSocket: FakeSocket, storage: { getItem: (key) => kept.get(key) ?? null, setItem: (key, value) => { stored.push([key, value]); kept.set(key, value); }, removeItem: (key) => kept.delete(key) }, validate: () => null,
    build: Promise.resolve(build), rebuild, setTimeout: (run) => { timers.push(run); return timers.length; }, clearTimeout: () => {}, location: { hash: '', pathname: '/', search: '' },
    history: { replaceState() {} }, reload: () => reloads.push(true), log: () => {},
  });
  store.connect(feed);
  await feed.start();
  const socket = sockets[0];
  socket.readyState = 1;
  socket.onopen();
  const hello = structuredClone(vectors['hello.web']);
  hello.auth = { ...(hello.auth || {}), rights, ...(act ? { act } : {}), ...(phrase ? { phrase } : {}) };
  if (assets !== undefined) hello.assets = assets;
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
  return { store, socket, sockets, stored, kept, reloads, feed, hello, reconnect, app: { store } };
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

test('the settings a page may not set even when it acts stay the terminal’s: web_acts raised, a floor, the policy', () => {
  assert.equal(pageMaySet('web_acts', 'off'), true, 'off, the one value');
  assert.equal(pageMaySet('web_acts', ' OFF '), true);
  assert.equal(pageMaySet('web_acts', 'on'), false);
  assert.equal(pageMaySet('floor_audit_finders', '1'), false);
  assert.equal(pageMaySet('policy', 'auto'), false);
  assert.equal(pageMaySet('max_workers', '3'), true);
  assert.equal(refusalWords({ code: 'voice', message: 'not the user' }), 'A page can’t do this one: run it in a terminal. Nothing was done.');
  assert.equal(refusalWords({ code: 'acts-ended', message: 'this page doesn’t act' }), 'This page no longer acts: pair it again with `vibeswitcher web` to act. Nothing was done.');
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

// The node refuses `kind` with `code`: the reply to the newest request of that kind on `socket`.
async function refuse(store, socket, kind, args, code) {
  const asked = store.request(kind, args);
  const sent = socket.sent.filter((message) => message.kind === kind).pop();
  socket.onmessage({ data: JSON.stringify({ v: 1, re: sent.id, ok: false, error: { code, message: 'refused' } }) });
  return asked;
}
const authOf = (socket) => socket.sent.find((message) => message.kind === 'auth')?.args || {};
const CONFIRMED = ['read', 'draft', 'watch', 'act'];

test('the act secret is kept in memory only, sent with the token on a reconnect, and dropped when acting ends', async () => {
  const secret = 'a'.repeat(43);
  const { store, sockets, stored, hello, reconnect } = await page({ rights: CONFIRMED, kinds: ACTING, act: secret });
  const welcome = (socket) => socket.onmessage({ data: JSON.stringify({ ...hello, auth: { ...hello.auth, act: undefined, rights: CONFIRMED } }) });
  assert.equal(store.acts(), true);
  assert.equal(stored.some(([, value]) => String(value).includes(secret)), false, 'never in storage');
  // The socket drops; the page connects again without a reload: the auth carries the token and the act secret.
  const again = reconnect();
  assert.notEqual(again, sockets[0]);
  assert.deepEqual({ token: authOf(again).token, act: authOf(again).act }, { token: hello.auth.token, act: secret });
  welcome(again);
  // A voice refusal (the terminal's kind or setting) changes nothing.
  await refuse(store, again, 'set', { key: 'policy', value: 'x' }, 'voice');
  assert.equal(store.acts(), true);
  const third = reconnect();
  assert.equal(authOf(third).act, secret);
  welcome(third);
  // acts-ended: the page reads and drafts, and the next auth carries no secret.
  await refuse(store, third, 'tell', { folder: '/f', text: 'hi' }, 'acts-ended');
  assert.equal(store.acts(), false);
  assert.equal(store.watches(), false);
  assert.equal('act' in authOf(reconnect()), false);
});

test('a hello without "watch" drops the secret; one with watch but not act keeps it (the level was lowered)', async () => {
  const { store, sockets, hello, reconnect } = await page({ rights: CONFIRMED, kinds: ACTING, act: 'b'.repeat(43) });
  sockets[0].onmessage({ data: JSON.stringify({ ...hello, auth: { ...hello.auth, act: undefined, rights: ['read', 'draft', 'watch'] }, kinds: ['status', 'term.open'] }) });
  assert.equal(store.acts(), false);
  assert.equal(store.watches(), true);
  const again = reconnect();
  assert.equal(authOf(again).act, 'b'.repeat(43));
  again.onmessage({ data: JSON.stringify({ ...hello, auth: { ...hello.auth, act: undefined, rights: ['read', 'draft'] }, kinds: ['status'] }) });
  assert.equal(store.watches(), false);
  assert.equal('act' in authOf(reconnect()), false);
});

test('a redeemed code shows its phrase until the terminal confirms the page; `paired` brings the secret and the rights', async () => {
  const { store, sockets, stored, hello, reconnect } = await page({ rights: ['read', 'draft'], kinds: ['status'] });
  sockets[0].onmessage({ data: JSON.stringify({ ...hello, auth: { ...hello.auth, rights: ['read', 'draft'], phrase: 'amber fox lantern' }, kinds: ['status'] }) });
  assert.equal(store.state.phrase, 'amber fox lantern');
  assert.equal(store.acts(), false);
  // Confirmed with the kinds: rights and kinds at once, on the same connection.
  sockets[0].onmessage({ data: JSON.stringify({ v: 1, kind: 'paired', act: 'c'.repeat(43), rights: CONFIRMED, kinds: ACTING }) });
  assert.equal(store.state.phrase, null);
  assert.equal(store.acts(), true);
  assert.equal(store.can('answer'), true);
  assert.equal(sockets.length, 1, 'no reconnect');
  assert.equal(stored.some(([, value]) => String(value).includes('c'.repeat(43))), false, 'never in storage');
  assert.equal(authOf(reconnect()).act, 'c'.repeat(43));
});

test('`paired` without kinds: the page connects again with its secret for a hello that lists them', async () => {
  const { store, sockets, hello } = await page({ rights: ['read', 'draft'], kinds: ['status'] });
  sockets[0].onmessage({ data: JSON.stringify({ ...hello, auth: { ...hello.auth, rights: ['read', 'draft'], phrase: 'amber fox lantern' }, kinds: ['status'] }) });
  sockets[0].onmessage({ data: JSON.stringify({ v: 1, kind: 'paired', act: 'd'.repeat(43), rights: CONFIRMED }) });
  assert.equal(sockets[0].readyState, 3, 'closed to connect again');
  assert.equal(store.state.phrase, null);
});

// The node confirms the page: its `paired` on the connection that redeemed the code.
const confirm = (socket, act = 'e'.repeat(43)) => socket.onmessage({ data: JSON.stringify({ v: 1, kind: 'paired', act, rights: CONFIRMED, kinds: ACTING }) });

test('a tab that acted says why it no longer does: reloaded (its pairing was in memory), or its pairing ended', async () => {
  // Reloaded: the tab's flag says it acted; the hello brings no act.
  const reloaded = await page({ rights: ['read', 'draft'], kinds: ['status'], flags: { 'vibeswitcher.acted': '1' } });
  assert.equal(reloaded.store.state.actsLost, 'reloaded');
  reloaded.store.forgetActsLost();
  assert.equal(reloaded.store.state.actsLost, null);
  assert.equal(reloaded.kept.has('vibeswitcher.acted'), false, 'dismissed: not said again after another reload');
  // Confirmed: the flag kept (never the secret), nothing to say; then a hello without "watch": its pairing ended.
  const paired = await page({ rights: ['read', 'draft'], kinds: ['status'], phrase: 'amber fox lantern' });
  confirm(paired.socket);
  assert.equal(paired.kept.get('vibeswitcher.acted'), '1');
  assert.equal(paired.store.state.actsLost, null);
  paired.socket.onmessage({ data: JSON.stringify({ ...paired.hello, auth: { ...paired.hello.auth, phrase: undefined, rights: ['read', 'draft'] }, kinds: ['status'] }) });
  assert.equal(paired.store.state.actsLost, 'ended');
  // acts-ended on a request: ended too.
  const refused = await page({ rights: ['read', 'draft'], kinds: ['status'], phrase: 'amber fox lantern' });
  confirm(refused.socket);
  await refuse(refused.store, refused.socket, 'tell', { folder: '/f', text: 'hi' }, 'acts-ended');
  assert.equal(refused.store.state.actsLost, 'ended');
});

test('a newer page on the node: an acting tab isn’t reloaded behind the user’s back; a tab that doesn’t act is', async () => {
  const acting = await page({ rights: ['read', 'draft'], kinds: ['status'], phrase: 'amber fox lantern', build: 'A', assets: 'A' });
  confirm(acting.socket);
  const again = acting.reconnect();
  again.onmessage({ data: JSON.stringify({ ...acting.hello, assets: 'B', auth: { ...acting.hello.auth, phrase: undefined, rights: CONFIRMED }, kinds: ACTING }) });
  assert.equal(acting.reloads.length, 0, 'not reloaded while it acts');
  assert.equal(acting.store.state.newerBuild, true);
  assert.equal(acting.store.acts(), true);
  acting.store.reloadNow();
  assert.equal(acting.reloads.length, 1, 'reloaded when the user asks');
  const reading = await page({ rights: ['read', 'draft'], kinds: ['status'], build: 'A', assets: 'B' });
  assert.equal(reading.reloads.length, 1, 'a tab that only reads reloads at once');
});

test('a code redeemed by a page older than the node’s is reloaded before its phrase shows, and the reloaded page says the address is used up', async () => {
  const older = await page({ rights: ['read', 'draft'], kinds: ['status'], phrase: 'amber fox lantern', build: 'A', assets: 'B' });
  assert.equal(older.reloads.length, 1);
  assert.equal(older.store.state.phrase, null, 'no phrase shown');
  assert.equal(older.kept.get('vibeswitcher.unconfirmed'), '1');
  const reloaded = await page({ rights: ['read', 'draft'], kinds: ['status'], flags: { 'vibeswitcher.unconfirmed': '1' } });
  assert.equal(reloaded.store.state.actsLost, 'unconfirmed');
  assert.equal(reloaded.kept.has('vibeswitcher.unconfirmed'), false);
});

test('a tab from an older build never sits there looking current: held off by its own action it says so, then reloads once that settles', async () => {
  const { store, socket, hello, reloads } = await page({ rights: ['read', 'draft', 'act'], kinds: ACTING, build: 'A', assets: 'A' });
  // An action of its own out (no reply yet), then the node's hello names a newer build.
  const asked = store.request('tell', { folder: '/f', text: 'hi' });
  const sent = socket.sent.filter((message) => message.kind === 'tell').pop();
  socket.onmessage({ data: JSON.stringify({ ...hello, assets: 'B' }) });
  assert.equal(reloads.length, 0, 'held off while its action waits');
  assert.equal(store.state.newerBuild, true, 'and says so meanwhile');
  socket.onmessage({ data: JSON.stringify({ v: 1, re: sent.id, ok: true, result: {} }) });
  await asked;
  assert.equal(reloads.length, 1, 'reloaded once the action settled');
});

test('a page whose own build is unknown asks for it again at a hello, so the next switch is seen', async () => {
  let asked = 0;
  const { store, socket, hello, reloads } = await page({ rights: ['read', 'draft'], kinds: ['status'], build: null, assets: 'A', rebuild: () => { asked += 1; return 'A'; } });
  assert.equal(asked, 1);
  await new Promise((resolve) => setImmediate(resolve));
  socket.onmessage({ data: JSON.stringify({ ...hello, assets: 'B' }) });
  assert.equal(reloads.length, 1, 'the switch to B is seen');
  assert.equal(store.state.newerBuild, false);
});

test('a confirmed page’s words are its name, never a pending confirmation; a waiting one’s are to be typed in the terminal', async () => {
  const waiting = await page({ rights: ['read', 'draft'], kinds: ['status'], phrase: 'amber fox lantern' });
  assert.equal(waiting.store.state.phrase, 'amber fox lantern');
  assert.equal(waiting.store.state.pageWords, null);
  waiting.socket.onmessage({ data: JSON.stringify({ v: 1, kind: 'paired', act: 'f'.repeat(43), rights: CONFIRMED, kinds: ACTING, phrase: 'amber fox lantern' }) });
  assert.equal(waiting.store.state.phrase, null, 'confirmed: no banner');
  assert.equal(waiting.store.state.pageWords, 'amber fox lantern');
  // A confirmed page's reconnect: its hello carries the words with "watch".
  const again = waiting.reconnect();
  again.onmessage({ data: JSON.stringify({ ...waiting.hello, auth: { ...waiting.hello.auth, rights: CONFIRMED, phrase: 'amber fox lantern' }, kinds: ACTING }) });
  assert.equal(waiting.store.state.phrase, null);
  assert.equal(waiting.store.state.pageWords, 'amber fox lantern');
  assert.equal(waiting.store.acts(), true);
});

test('a confirmed page whose node has a newer build isn’t taken for one redeeming a code: no reload before a phrase', async () => {
  const confirmed = await page({ rights: CONFIRMED, kinds: ACTING, phrase: 'amber fox lantern', build: 'A', assets: 'B' });
  assert.equal(confirmed.kept.has('vibeswitcher.unconfirmed'), false);
  assert.equal(confirmed.store.state.phrase, null);
});
