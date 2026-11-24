// The tabs of one origin share acting, memory to memory (js/socket.js's `share`, a BroadcastChannel in the page): two
// or three fake tabs on one fake channel, each with its own fake socket and storage.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createStore } from '../js/store.js';
import { connectSocket } from '../js/socket.js';

const vectors = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'wire', 'vectors.json'), 'utf8'));
const CONFIRMED = ['read', 'draft', 'watch', 'act'];
const ACTING = ['answer', 'tell', 'send', 'set', 'status'];
const settle = () => new Promise((resolve) => setImmediate(resolve));

// One origin's channel: what a tab posts reaches the others (never itself), a turn later, as a BroadcastChannel does.
function bus() {
  const tabs = [];
  return {
    channel() {
      const end = { onmessage: null, postMessage: (data) => queueMicrotask(() => { for (const other of tabs) if (other !== end) other.onmessage?.({ data: structuredClone(data) }); }) };
      tabs.push(end);
      return end;
    },
  };
}

// A tab: its store, its sockets, its storage (`token` in it or not), on `channel`.
async function tab(channel, { token = 'token-a' } = {}) {
  const store = createStore();
  const sockets = [];
  const kept = new Map(token ? [['vibeswitcher.token', token]] : []);
  const timers = [];
  class FakeSocket {
    constructor() { this.sent = []; this.readyState = 0; sockets.push(this); }
    send(text) { this.sent.push(JSON.parse(text)); }
    close() { this.readyState = 3; this.onclose?.(); }
  }
  const feed = connectSocket(store, {
    url: 'ws://127.0.0.1:47830/ws', WebSocket: FakeSocket, validate: () => null, share: channel,
    storage: { getItem: (key) => kept.get(key) ?? null, setItem: (key, value) => kept.set(key, value), removeItem: (key) => kept.delete(key) },
    build: Promise.resolve(null), setTimeout: (run) => { timers.push(run); return timers.length; }, clearTimeout: () => {},
    location: { hash: '', pathname: '/', search: '' }, history: { replaceState() {} }, reload() {}, log: () => {},
  });
  store.connect(feed);
  await feed.start();
  const latest = () => sockets[sockets.length - 1];
  // The newest socket opened, and the node's hello on it with `rights`.
  const welcome = (rights, kinds = rights.includes('act') ? ACTING : ['status']) => {
    const socket = latest();
    socket.readyState = 1;
    socket.onopen?.();
    socket.onmessage({ data: JSON.stringify({ ...structuredClone(vectors['hello.web']), auth: { rights }, kinds }) });
    return socket;
  };
  // The socket dropped: the reconnect the page scheduled runs.
  const again = () => { timers.pop()?.(); return latest(); };
  const auth = (socket = latest()) => socket.sent.find((message) => message.kind === 'auth')?.args || {};
  return { store, sockets, kept, latest, welcome, again, auth };
}

test('one pairing makes every open tab act: the confirmed tab hands its secret to the others, which connect again with it', async () => {
  const origin = bus();
  const a = await tab(origin.channel());
  const b = await tab(origin.channel());
  a.welcome(['read', 'draft']);
  b.welcome(['read', 'draft']);
  await settle();
  assert.equal(b.store.acts(), false);
  // A is confirmed in the terminal.
  const secret = 's'.repeat(43);
  a.latest().onmessage({ data: JSON.stringify({ v: 1, kind: 'paired', act: secret, rights: CONFIRMED, kinds: ACTING }) });
  assert.equal(a.store.acts(), true);
  await settle();
  // B closed its socket to connect again: with A's token and the secret.
  const next = b.again();
  next.readyState = 1;
  next.onopen?.();
  assert.deepEqual({ token: b.auth(next).token, act: b.auth(next).act }, { token: 'token-a', act: secret });
  b.welcome(CONFIRMED);
  assert.equal(b.store.acts(), true);
  for (const kept of [a.kept, b.kept]) assert.equal([...kept.values()].some((value) => String(value).includes(secret)), false, 'the secret in no storage');
});

test('a tab with nothing (opened by hand, or reloaded) gets acting from a sibling instead of pairing again', async () => {
  const origin = bus();
  const a = await tab(origin.channel());
  a.welcome(['read', 'draft']);
  a.latest().onmessage({ data: JSON.stringify({ v: 1, kind: 'paired', act: 'p'.repeat(43), rights: CONFIRMED, kinds: ACTING }) });
  await settle();
  // B: no token at all.
  const b = await tab(origin.channel(), { token: null });
  assert.equal(b.store.state.connection, 'unpaired');
  await settle();
  await settle();
  const socket = b.latest();
  assert.ok(socket, 'connected once given');
  socket.readyState = 1;
  socket.onopen?.();
  assert.deepEqual({ token: b.auth(socket).token, act: b.auth(socket).act }, { token: 'token-a', act: 'p'.repeat(43) });
});

test('`acts-ended` in one tab is told to the others: each drops the secret and connects again without it', async () => {
  const origin = bus();
  const a = await tab(origin.channel());
  const b = await tab(origin.channel());
  a.welcome(['read', 'draft']);
  b.welcome(['read', 'draft']);
  await settle();
  const secret = 'e'.repeat(43);
  a.latest().onmessage({ data: JSON.stringify({ v: 1, kind: 'paired', act: secret, rights: CONFIRMED, kinds: ACTING }) });
  await settle();
  b.again();
  b.welcome(CONFIRMED);
  assert.equal(b.store.acts(), true);
  // A's request is refused: its pairing ended.
  const asked = a.store.request('tell', { folder: '/f', text: 'hi' });
  const sent = a.latest().sent.filter((message) => message.kind === 'tell').pop();
  a.latest().onmessage({ data: JSON.stringify({ v: 1, re: sent.id, ok: false, error: { code: 'acts-ended', message: 'this page doesn’t act' } }) });
  await asked;
  await settle();
  assert.equal(b.store.state.actsLost, 'ended');
  const next = b.again();
  next.readyState = 1;
  next.onopen?.();
  assert.equal('act' in b.auth(next), false, 'B connects again without it');
});

test('a sibling’s secret the node doesn’t take in this tab is dropped here only, and not taken again', async () => {
  const origin = bus();
  const a = await tab(origin.channel());
  const b = await tab(origin.channel());
  a.welcome(['read', 'draft']);
  b.welcome(['read', 'draft']);
  await settle();
  const secret = 'n'.repeat(43);
  a.latest().onmessage({ data: JSON.stringify({ v: 1, kind: 'paired', act: secret, rights: CONFIRMED, kinds: ACTING }) });
  await settle();
  b.again();
  b.welcome(['read', 'draft']);
  await settle();
  assert.equal(a.store.acts(), true, 'A still acts');
  assert.equal(b.store.state.actsLost, null, 'B says nothing of an ending it never had');
  const count = b.sockets.length;
  await settle();
  assert.equal(b.sockets.length, count, 'not taken again');
});

test('a tab holding another pairing’s token never takes a sibling’s: it keeps its own', async () => {
  const origin = bus();
  const a = await tab(origin.channel());
  const b = await tab(origin.channel(), { token: 'token-b' });
  a.welcome(['read', 'draft']);
  b.welcome(['read', 'draft']);
  await settle();
  const count = b.sockets.length;
  a.latest().onmessage({ data: JSON.stringify({ v: 1, kind: 'paired', act: 'o'.repeat(43), rights: CONFIRMED, kinds: ACTING }) });
  await settle();
  assert.equal(b.kept.get('vibeswitcher.token'), 'token-b', 'its own token kept');
  assert.equal(b.sockets.length, count, 'no reconnect with the other pairing');
  assert.equal(b.latest().readyState, 1, 'its socket left open');
});

test('the page shares acting only unframed, on a channel named by host and port', () => {
  const app = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'app.js'), 'utf8');
  assert.match(app, /share: typeof BroadcastChannel === 'function' && !framed\(\) \? new BroadcastChannel\(`vibeswitcher-acting-\$\{location\.host\}`\)/);
  assert.match(app, /function framed\(\) \{\n  try \{ return window\.top !== window; \} catch \{ return true; \}/);
});
