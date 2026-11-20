// A session's terminal over the socket (the wire contract's §9; js/terminal.js): the binary frames both ways, and the
// stream's life on a fake feed and a fake emulator: the replay held and drawn whole, then live; a resync drawn the same
// way, the old screen kept until then; a reconnect opening the session again; and a connection that has no terminal
// (the user's own node, LW-D12) showing the pane's words, with no emulator. Then the same through socket.js itself, on
// a scripted socket. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { FRAME, INPUT_CHUNK, frame, parseFrame, clampSize, resizeFrame, inputFrames, createTerminal } from '../js/terminal.js';
import { createStore } from '../js/store.js';
import { connectSocket } from '../js/socket.js';
import { validate } from '../wire/validators.js';

const SESSION = 'local:7d1f0a52-4f6e-4d0b-9a8c-3e2b1c0d9f8e';
const bytes = (text) => new TextEncoder().encode(text);
const text = (data) => new TextDecoder().decode(data);
// A frame from the node, as the socket hands it over (an ArrayBuffer).
const fromNode = (type, stream, payload = '') => frame(type, stream, bytes(payload)).buffer;

// ---- The frames ----

test('a frame is its type, its stream in four big-endian bytes, and its payload', () => {
  const made = frame(FRAME.bytes, 0x01020304, bytes('hi'));
  assert.deepEqual([...made], [1, 1, 2, 3, 4, 104, 105]);
  const parsed = parseFrame(made.buffer);
  assert.equal(parsed.type, 1);
  assert.equal(parsed.stream, 0x01020304);
  assert.equal(text(parsed.payload), 'hi');
  assert.equal(parseFrame(frame(FRAME.replayed, 0xfffffffe)).stream, 0xfffffffe, 'a stream past 2^31 stays unsigned');
  assert.equal(parseFrame(new Uint8Array([2, 0, 0, 1]).buffer), null, 'four bytes are no frame');
  // A typed array that is a window on a bigger buffer reads from its own start.
  const window = new Uint8Array([9, 9, ...frame(FRAME.resync, 7)]).subarray(2);
  assert.deepEqual({ ...parseFrame(window), payload: undefined }, { type: 4, stream: 7, payload: undefined });
});

test('a resize is columns and rows in 16 bits each, big-endian, inside the node’s ranges', () => {
  assert.deepEqual([...resizeFrame(5, { cols: 300, rows: 40 })], [3, 0, 0, 0, 5, 1, 44, 0, 40]);
  assert.deepEqual(clampSize({ cols: 4, rows: 2 }), { cols: 10, rows: 5 });
  assert.deepEqual(clampSize({ cols: 5000, rows: 900 }), { cols: 1000, rows: 300 });
  assert.deepEqual(clampSize({ cols: 80.7, rows: NaN }), { cols: 80, rows: 5 });
});

test('input is UTF-8, cut into frames the node takes', () => {
  const [one] = inputFrames(3, 'é\r');
  assert.deepEqual([...one], [1, 0, 0, 0, 3, 0xc3, 0xa9, 13]);
  const paste = inputFrames(3, 'x'.repeat(INPUT_CHUNK * 2 + 5));
  assert.deepEqual(paste.map((each) => each.length - 5), [INPUT_CHUNK, INPUT_CHUNK, 5]);
  assert.ok(paste.every((each) => each[0] === FRAME.bytes && parseFrame(each).stream === 3));
});

// ---- The stream's life, on a fake feed ----

function rig({ kinds = ['term.open', 'term.close'], binary = true } = {}) {
  const sent = [];
  const requests = [];
  const listeners = { binary: new Set(), link: new Set() };
  const feed = {
    request(message) {
      return new Promise((resolve) => requests.push({ message, resolve }));
    },
    ...(binary ? {
      sendBinary(data) { sent.push(data); return true; },
      onBinary(fn) { listeners.binary.add(fn); return () => listeners.binary.delete(fn); },
      onLink(fn) { listeners.link.add(fn); return () => listeners.link.delete(fn); },
    } : {}),
  };
  const screen = { resets: 0, text: '', writes: 0, sizes: [] };
  const emulator = {
    reset() { screen.resets += 1; screen.text = ''; },
    write(data) { screen.writes += 1; screen.text += text(data); },
    resize(cols, rows) { screen.sizes.push([cols, rows]); },
  };
  const phases = [];
  const term = createTerminal({ feed, can: (kind) => kinds.includes(kind), log: () => {} });
  term.attach(emulator);
  term.onChange((state) => phases.push(state.phase));
  const node = {
    say: (type, stream, payload) => { for (const fn of listeners.binary) fn(fromNode(type, stream, payload)); },
    link: (how) => { for (const fn of listeners.link) fn(how); },
    // The last request of `kind`, answered.
    answer: async (kind, reply) => {
      const asked = requests.filter((each) => each.message.kind === kind).pop();
      asked.resolve({ v: 1, re: asked.message.id, ...reply });
      await new Promise((resolve) => setImmediate(resolve));
      return asked.message;
    },
  };
  return { term, feed, sent, requests, screen, phases, node };
}

const asked = (r, kind) => r.requests.filter((each) => each.message.kind === kind).map((each) => each.message);

test('term.open names the session and the pane’s size, and asks nothing back after a reconnect', async () => {
  const r = rig();
  r.term.show(SESSION, { cols: 120, rows: 2 });
  const [open] = asked(r, 'term.open');
  assert.deepEqual(open.args, { session: SESSION, cols: 120, rows: 5 }, 'the size inside the node’s range');
  assert.equal(open.action, undefined, 'no action id: socket.js never sends it again by itself on a new connection');
  assert.equal(validate('frame', open), null);
  assert.equal(r.term.state.phase, 'opening');
});

test('the replay is held until its end, then drawn whole over a reset screen; live bytes follow as they come', async () => {
  const r = rig();
  r.term.show(SESSION, { cols: 80, rows: 24 });
  await r.node.answer('term.open', { ok: true, result: { stream: 7 } });
  assert.equal(r.term.state.phase, 'replaying');
  r.node.say(FRAME.bytes, 7, 'before ');
  r.node.say(FRAME.bytes, 9, 'another stream’s ');
  r.node.say(FRAME.bytes, 7, 'the page');
  assert.equal(r.screen.writes, 0, 'nothing is drawn mid-replay');
  r.node.say(FRAME.replayed, 7);
  assert.equal(r.term.state.phase, 'live');
  assert.equal(r.screen.resets, 1);
  assert.equal(r.screen.text, 'before the page');
  assert.equal(r.screen.writes, 1, 'the replay in one write');
  r.node.say(FRAME.bytes, 7, '\r\n$ ');
  assert.equal(r.screen.text, 'before the page\r\n$ ');
  assert.equal(r.term.drawn(SESSION), true);
  assert.deepEqual(r.phases, ['opening', 'replaying', 'live']);
});

test('a resync keeps the old screen up until the new replay is whole, then resets and draws it', async () => {
  const r = rig();
  r.term.show(SESSION, { cols: 80, rows: 24 });
  await r.node.answer('term.open', { ok: true, result: { stream: 3 } });
  r.node.say(FRAME.bytes, 3, 'old');
  r.node.say(FRAME.replayed, 3);
  r.node.say(FRAME.bytes, 3, ' and live');
  r.node.say(FRAME.resync, 3);
  assert.equal(r.term.state.phase, 'replaying');
  assert.equal(r.screen.text, 'old and live', 'the stale screen stays');
  r.node.say(FRAME.bytes, 3, 'the whole ');
  r.node.say(FRAME.bytes, 3, 'screen again');
  assert.equal(r.screen.text, 'old and live');
  r.node.say(FRAME.replayed, 3);
  assert.equal(r.screen.resets, 2);
  assert.equal(r.screen.text, 'the whole screen again');
  assert.equal(r.term.state.phase, 'live');
});

test('keys go as type 1 on the stream, a resize as type 3, and nothing goes before the stream is open', async () => {
  const r = rig();
  r.term.show(SESSION, { cols: 80, rows: 24 });
  assert.equal(r.term.input('early'), false);
  r.term.resize({ cols: 90, rows: 30 });
  assert.equal(r.sent.length, 0, 'the size waits for term.open: the open carries it');
  assert.deepEqual(asked(r, 'term.open')[0].args, { session: SESSION, cols: 80, rows: 24 });
  await r.node.answer('term.open', { ok: true, result: { stream: 4 } });
  assert.equal(r.term.input('ls\r'), true);
  r.term.input(new Uint8Array([0x1b, 0x5b, 0x4d, 0xff]));
  r.term.resize({ cols: 90, rows: 30 });
  r.term.resize({ cols: 100, rows: 30 });
  assert.deepEqual(r.sent.map((each) => [...each]), [
    [1, 0, 0, 0, 4, 108, 115, 13],
    [1, 0, 0, 0, 4, 0x1b, 0x5b, 0x4d, 0xff],
    [3, 0, 0, 0, 4, 0, 100, 0, 30],
  ], 'the same size twice is sent once');
});

test('watched (the user’s node): drawn at the session’s size from type 5, and no key or resize goes up', async () => {
  const r = rig();
  r.term.show(SESSION, { cols: 80, rows: 24 });
  await r.node.answer('term.open', { ok: true, result: { stream: 6, readOnly: true, cols: 132, rows: 43 } });
  assert.equal(r.term.state.readOnly, true);
  assert.equal(r.term.input('ls\r'), false, 'a watched stream takes no key');
  r.term.resize({ cols: 90, rows: 30 });
  r.node.say(FRAME.size, 6, '\u0000\u0064\u0000\u001e');
  r.node.say(FRAME.bytes, 6, 'the session');
  r.node.say(FRAME.replayed, 6);
  assert.deepEqual(r.screen.sizes, [[100, 30]], 'the size type 5 said, before the replay is drawn');
  assert.deepEqual(r.term.state.size, { cols: 100, rows: 30 });
  assert.equal(r.screen.text, 'the session');
  // A resync whose type 5 says nothing new resizes nothing; the open's size stands where no type 5 comes.
  r.node.say(FRAME.resync, 6);
  r.node.say(FRAME.size, 6, '\u0000\u0064\u0000\u001e');
  r.node.say(FRAME.replayed, 6);
  assert.equal(r.term.input(new Uint8Array([0x03])), false);
  assert.equal(r.sent.length, 0, 'nothing went to the node');
});

test('the open’s size stands for a watched replay without type 5; type 5 on a typed stream is ignored', async () => {
  const watched = rig();
  watched.term.show(SESSION, { cols: 80, rows: 24 });
  await watched.node.answer('term.open', { ok: true, result: { stream: 2, readOnly: true, cols: 132, rows: 43 } });
  watched.node.say(FRAME.replayed, 2);
  assert.deepEqual(watched.screen.sizes, [[132, 43]]);

  const typed = rig();
  typed.term.show(SESSION, { cols: 80, rows: 24 });
  await typed.node.answer('term.open', { ok: true, result: { stream: 2 } });
  typed.node.say(FRAME.size, 2, '\u0000\u0064\u0000\u001e');
  typed.node.say(FRAME.replayed, 2);
  assert.deepEqual(typed.screen.sizes, []);
  assert.equal(typed.term.state.readOnly, false);
  assert.equal(typed.term.input('x'), true);
});

test('leaving the pane closes the stream; another session’s screen is opened anew', async () => {
  const r = rig();
  r.term.show(SESSION, { cols: 80, rows: 24 });
  await r.node.answer('term.open', { ok: true, result: { stream: 1 } });
  r.node.say(FRAME.replayed, 1);
  r.term.hide();
  assert.deepEqual(asked(r, 'term.close').map((each) => each.args), [{ stream: 1 }]);
  assert.equal(r.term.state.phase, 'idle');
  assert.equal(r.term.input('x'), false);
  // Back to it: the screen it drew is still its own, shown while the replay comes again.
  r.term.show(SESSION);
  assert.equal(r.term.drawn(SESSION), true);
  await r.node.answer('term.open', { ok: true, result: { stream: 2 } });
  r.term.show('local:another');
  assert.deepEqual(asked(r, 'term.close').map((each) => each.args), [{ stream: 1 }, { stream: 2 }]);
  assert.equal(r.term.drawn('local:another'), false);
});

test('a reply that comes after the pane moved on closes what it opened', async () => {
  const r = rig();
  r.term.show(SESSION, { cols: 80, rows: 24 });
  r.term.hide();
  await r.node.answer('term.open', { ok: true, result: { stream: 12 } });
  assert.deepEqual(asked(r, 'term.close').map((each) => each.args), [{ stream: 12 }]);
  r.node.say(FRAME.bytes, 12, 'late');
  r.node.say(FRAME.replayed, 12);
  assert.equal(r.screen.writes, 0);
  assert.equal(r.term.state.phase, 'idle');
});

test('a session that ended sends no term.close: its stream went with it on the node', async () => {
  const r = rig();
  r.term.show(SESSION, { cols: 80, rows: 24 });
  await r.node.answer('term.open', { ok: true, result: { stream: 5 } });
  r.node.say(FRAME.bytes, 5, 'last words');
  r.node.say(FRAME.replayed, 5);
  r.term.hide({ ended: true });
  assert.deepEqual(asked(r, 'term.close'), []);
  assert.equal(r.screen.text, 'last words', 'what it showed last stays for the view to keep');
});

test('a reconnect keeps the screen, marks it, and opens the session again after the next hello', async () => {
  const r = rig();
  r.term.show(SESSION, { cols: 80, rows: 24 });
  await r.node.answer('term.open', { ok: true, result: { stream: 1 } });
  r.node.say(FRAME.bytes, 1, 'kept');
  r.node.say(FRAME.replayed, 1);
  r.node.link('down');
  assert.equal(r.term.state.phase, 'reconnecting');
  assert.equal(r.term.input('lost'), false, 'no stream: nothing is sent');
  r.node.say(FRAME.bytes, 1, 'from the old connection');
  assert.equal(r.screen.text, 'kept');
  r.node.link('up');
  assert.equal(asked(r, 'term.open').length, 2);
  await r.node.answer('term.open', { ok: true, result: { stream: 1 } });
  r.node.say(FRAME.bytes, 1, 'kept, and more');
  assert.equal(r.screen.text, 'kept', 'the old screen until the new replay is whole');
  r.node.say(FRAME.replayed, 1);
  assert.equal(r.screen.text, 'kept, and more');
  assert.deepEqual(r.phases, ['opening', 'replaying', 'live', 'reconnecting', 'opening', 'replaying', 'live']);
});

test('an open the dropped connection never answered is asked again after the next hello', async () => {
  const r = rig();
  r.term.show(SESSION, { cols: 80, rows: 24 });
  r.node.link('down');
  await r.node.answer('term.open', { ok: false, error: { code: 'not-yet', message: 'The node isn’t answering.' } });
  assert.equal(r.term.state.phase, 'reconnecting');
  r.node.link('up');
  assert.equal(asked(r, 'term.open').length, 2);
});

test('a connection without term.open has no terminal: unavailable, nothing asked, nothing drawn', () => {
  for (const r of [rig({ kinds: ['subscribe', 'draft'] }), rig({ binary: false })]) {
    assert.equal(r.term.available(), false);
    r.term.show(SESSION, { cols: 80, rows: 24 });
    assert.equal(r.term.state.phase, 'unavailable');
    assert.deepEqual(r.requests, []);
    r.node.link('up');
    assert.deepEqual(r.requests, []);
  }
});

test('a node that answers term.open unknown-kind is unavailable too; gone and a refusal say why', async () => {
  const r = rig();
  r.term.show(SESSION, { cols: 80, rows: 24 });
  await r.node.answer('term.open', { ok: false, error: { code: 'unknown-kind', message: 'no' } });
  assert.equal(r.term.state.phase, 'unavailable');

  const g = rig();
  g.term.show(SESSION, { cols: 80, rows: 24 });
  await g.node.answer('term.open', { ok: false, error: { code: 'gone', message: 'no session the host runs is x' } });
  assert.deepEqual([g.term.state.phase, g.term.state.message], ['gone', 'no session the host runs is x']);

  const f = rig();
  f.term.show(SESSION, { cols: 80, rows: 24 });
  await f.node.answer('term.open', { ok: false, error: { code: 'voice', message: 'this connection may not read' } });
  assert.deepEqual([f.term.state.phase, f.term.state.message], ['failed', 'this connection may not read']);
  f.term.show(SESSION);
  assert.equal(asked(f, 'term.open').length, 2, 'a failed one may be tried again');
});

// ---- Through socket.js ----

const vectors = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'wire', 'vectors.json'), 'utf8'));
const vector = (name) => structuredClone(vectors[name]);

function socketRig() {
  const store = createStore();
  const sockets = [];
  const timers = [];
  class FakeSocket {
    constructor(url) { this.url = url; this.sent = []; this.binary = []; this.readyState = 0; sockets.push(this); }
    send(data) { if (typeof data === 'string') this.sent.push(JSON.parse(data)); else this.binary.push(new Uint8Array(data.buffer ?? data, data.byteOffset ?? 0, data.byteLength)); }
    close() { if (this.readyState === 3) return; this.readyState = 3; this.onclose?.(); }
    accept() { this.readyState = 1; this.onopen?.(); }
    say(message) { this.onmessage?.({ data: typeof message === 'string' || message instanceof ArrayBuffer ? message : JSON.stringify(message) }); }
  }
  const feed = connectSocket(store, {
    url: 'ws://127.0.0.1:47830/ws', WebSocket: FakeSocket, storage: { getItem: () => 'token', setItem() {}, removeItem() {} }, validate,
    build: Promise.resolve(null), setTimeout: (fn, ms) => { timers.push({ fn, ms }); return timers.length; }, clearTimeout: () => {},
    location: { hash: '', pathname: '/', search: '' }, history: { replaceState() {} }, reload: () => {}, log: () => {},
  });
  store.connect(feed);
  const socket = () => sockets[sockets.length - 1];
  const hello = (kinds) => { socket().accept(); socket().say({ ...vector('hello.web'), kinds }); };
  return { store, feed, socket, hello, timers };
}

test('socket.js takes frames as ArrayBuffers once authenticated, hands them over, and sends binary', async () => {
  const s = socketRig();
  await s.feed.start();
  const got = [];
  const links = [];
  s.feed.onBinary((data) => got.push(parseFrame(data)));
  s.feed.onLink((how) => links.push(how));
  assert.equal(s.socket().binaryType, 'arraybuffer');
  s.socket().accept();
  s.socket().say(fromNode(FRAME.bytes, 1, 'before auth'));
  assert.deepEqual(got, [], 'nothing before hello');
  assert.equal(s.feed.sendBinary(frame(FRAME.bytes, 1, bytes('x'))), false, 'nothing sent before hello');
  s.socket().say({ ...vector('hello.web'), kinds: [...vector('hello.web').kinds, 'term.open', 'term.close'] });
  assert.deepEqual(links, ['up']);
  s.socket().say(fromNode(FRAME.replayed, 1));
  assert.deepEqual(got.map((each) => [each.type, each.stream]), [[2, 1]]);
  assert.equal(s.feed.sendBinary(frame(FRAME.bytes, 1, bytes('x'))), true);
  assert.deepEqual([...s.socket().binary[0]], [1, 0, 0, 0, 1, 120]);
  s.socket().close();
  assert.deepEqual(links, ['up', 'down']);
});

test('through socket.js: the user’s node (no term.open in hello.kinds) opens no terminal', async () => {
  const s = socketRig();
  await s.feed.start();
  s.hello(vector('hello.web').kinds.filter((kind) => !kind.startsWith('term.')));
  const term = createTerminal({ feed: s.feed, can: (kind) => s.store.can(kind), log: () => {} });
  term.show(SESSION, { cols: 80, rows: 24 });
  assert.equal(term.state.phase, 'unavailable');
  assert.deepEqual(s.socket().sent.filter((message) => message.kind?.startsWith('term.')), []);
});

test('through socket.js: open, replay, live, a dropped connection, and the session opened again on the next', async () => {
  const s = socketRig();
  await s.feed.start();
  const kinds = [...vector('hello.web').kinds, 'term.open', 'term.close'];
  s.hello(kinds);
  const term = createTerminal({ feed: s.feed, can: (kind) => s.store.can(kind), log: () => {} });
  let shown = '';
  term.attach({ reset() { shown = ''; }, write(data) { shown += text(data); } });
  term.show(SESSION, { cols: 100, rows: 30 });
  const open = s.socket().sent.find((message) => message.kind === 'term.open');
  assert.deepEqual(open.args, { session: SESSION, cols: 100, rows: 30 });
  s.socket().say({ v: 1, re: open.id, ok: true, result: { stream: 2 } });
  await new Promise((resolve) => setImmediate(resolve));
  s.socket().say(fromNode(FRAME.bytes, 2, '$ '));
  s.socket().say(fromNode(FRAME.replayed, 2));
  term.input('a');
  assert.deepEqual([...s.socket().binary.at(-1)], [1, 0, 0, 0, 2, 97]);
  s.socket().say(fromNode(FRAME.bytes, 2, 'a'));
  assert.equal(shown, '$ a');

  s.socket().close();
  assert.equal(term.state.phase, 'reconnecting');
  s.timers.shift().fn();
  s.hello(kinds);
  const again = s.socket().sent.filter((message) => message.kind === 'term.open');
  assert.equal(again.length, 1, 'opened again on the new connection, once');
  s.socket().say({ v: 1, re: again[0].id, ok: true, result: { stream: 1 } });
  await new Promise((resolve) => setImmediate(resolve));
  s.socket().say(fromNode(FRAME.bytes, 1, '$ a'));
  s.socket().say(fromNode(FRAME.replayed, 1));
  assert.equal(shown, '$ a');
  assert.equal(term.state.phase, 'live');
  term.hide();
  assert.deepEqual(s.socket().sent.filter((message) => message.kind === 'term.close').map((each) => each.args), [{ stream: 1 }]);
});
