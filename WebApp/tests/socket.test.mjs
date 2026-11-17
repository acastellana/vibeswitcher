// The live feed against the wire contract (docs/superpowers/specs/2026-11-17-v2-live-wire-contract.md §2 to §4, §10),
// on a scripted socket and clock and the vectors generated from the node's own encoders (wire/vectors.json): pairing,
// the client's four-row table per subscription, reconnecting without losing a row, and every frame validated first.
// Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createStore } from '../js/store.js';
import { connectSocket, TOKEN_KEY } from '../js/socket.js';
import { validate } from '../wire/validators.js';

const vectors = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'wire', 'vectors.json'), 'utf8'));
const vector = (name) => structuredClone(vectors[name]);
const EPOCH = vector('hello.web').epoch;
const LEAD = 'local:3f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f';
const CARD = vector('snapshot.cards').entries[0].id;

// A page on a fake socket and clock. `hash`: the address's fragment; `token`: one this tab kept.
function rig({ hash = '#pair=k3J1mZ0vY8q2Xw5rT7uB9A', token = null, build = vector('hello.web').assets } = {}) {
  const store = createStore();
  const sockets = [];
  const timers = [];
  const kept = new Map(token ? [[TOKEN_KEY, token]] : []);
  const page = { replaced: [], reloads: 0, warnings: [], renders: [] };
  class FakeSocket {
    constructor(url) { this.url = url; this.sent = []; this.readyState = 0; sockets.push(this); }
    send(text) { this.sent.push(JSON.parse(text)); }
    close() { if (this.readyState === 3) return; this.readyState = 3; this.onclose?.(); }
    // The server's side.
    accept() { this.readyState = 1; this.onopen?.(); }
    say(message) { this.onmessage?.({ data: typeof message === 'string' ? message : JSON.stringify(message) }); }
  }
  const storage = {
    getItem: (key) => kept.get(key) ?? null,
    setItem: (key, value) => kept.set(key, value),
    removeItem: (key) => kept.delete(key),
  };
  const feed = connectSocket(store, {
    url: 'ws://127.0.0.1:47830/ws', WebSocket: FakeSocket, storage, validate, build: Promise.resolve(build),
    setTimeout: (fn, ms) => { timers.push({ fn, ms }); return timers.length; }, clearTimeout: () => {},
    location: { hash, pathname: '/', search: '' },
    history: { replaceState: (state, title, url) => page.replaced.push(url) },
    reload: () => { page.reloads += 1; },
    log: (...args) => page.warnings.push(args.join(' ')),
  });
  store.connect(feed);
  for (const topic of ['sessions', 'leads', 'cards', 'node']) store.subscribe(topic, (changes) => page.renders.push([topic, changes]));
  const socket = () => sockets[sockets.length - 1];
  // The next timer the feed set, run.
  const tick = () => { const timer = timers.shift(); timer.fn(); return timer.ms; };
  // The requests the current socket sent of `kind`.
  const sent = (kind) => socket().sent.filter((message) => message.kind === kind);
  return { store, feed, sockets, socket, timers, tick, sent, kept, page };
}

// Open, hello, and each subscription answered: by a snapshot from the vectors, or as `modes` says.
function serve(r, { epoch = EPOCH, snapshots = {}, hello = {} } = {}) {
  r.socket().accept();
  r.socket().say({ ...vector('hello.web'), epoch, ...hello });
  const subscribes = r.sent('subscribe').slice(-4);
  for (const request of subscribes) {
    const { sub, collection } = request.args;
    const given = snapshots[collection];
    if (given === 'resume') {
      r.socket().say({ v: 1, re: request.id, ok: true, result: { sub, mode: 'resume' } });
      continue;
    }
    r.socket().say({ v: 1, re: request.id, ok: true, result: { sub, mode: 'snapshot' } });
    const snapshot = given || vector('snapshot.' + collection);
    r.socket().say({ ...snapshot, sub, epoch });
  }
}

async function live(options) {
  const r = rig(options);
  await r.feed.start();
  serve(r);
  return r;
}

const statusOf = (r) => r.store.state.sessions.get(LEAD)?.status;

test('thePairCodeLeavesTheAddressBar', async () => {
  const r = rig();
  assert.deepEqual(r.page.replaced, ['/'], 'the fragment is gone before anything is sent');
  await r.feed.start();
  r.socket().accept();
  const auth = r.socket().sent[0];
  assert.equal(auth.kind, 'auth');
  assert.equal(auth.id, '0');
  assert.equal(auth.args.pair, 'k3J1mZ0vY8q2Xw5rT7uB9A');
  assert.equal(auth.args.client, 'webapp');
  assert.equal(auth.args.assets, vector('hello.web').assets);
  assert.equal(validate('frame', auth), null);
});

test('theTokenIsKeptForTheTabOnly', async () => {
  const r = await live();
  assert.equal(r.kept.get(TOKEN_KEY), vector('hello.web').auth.token);
  r.socket().close();
  r.tick();
  r.socket().accept();
  const auth = r.socket().sent[0];
  assert.equal(auth.args.token, vector('hello.web').auth.token, 'the next connection sends the token');
  assert.equal(auth.args.pair, undefined, 'and never the used code');
});

test('a page with neither a code nor a token says it isn’t paired and opens nothing', async () => {
  const r = rig({ hash: '' });
  await r.feed.start();
  assert.equal(r.sockets.length, 0);
  assert.equal(r.store.state.connection, 'unpaired');
});

test('the four subscriptions are asked after hello, and the page is live once each has its snapshot', async () => {
  const r = rig();
  await r.feed.start();
  r.socket().accept();
  r.socket().say(vector('hello.web'));
  assert.deepEqual(r.sent('subscribe').map((m) => [m.args.sub, m.args.collection]), [['s0', 'node'], ['s1', 'sessions'], ['s2', 'leads'], ['s3', 'cards']]);
  for (const message of r.sent('subscribe')) assert.equal(validate('frame', message), null);
  assert.equal(r.store.state.connection, 'connecting', 'no half-loaded list');
  serveSnapshotsOnly(r);
  assert.equal(r.store.state.connection, 'live');
  assert.equal(statusOf(r), 'needs-you', 'the list shows shownStatus');
  assert.equal(r.store.state.sessions.get(LEAD).lead, vector('snapshot.leads').entries[0].id, 'a lead session knows its project');
  assert.equal(r.store.state.node.node, 'local');
  assert.ok(r.store.state.cards.has(CARD));
  assert.deepEqual(r.store.state.kinds, vector('hello.web').kinds);
  assert.equal(r.store.can('answer'), false);
});

function serveSnapshotsOnly(r) {
  for (const request of r.sent('subscribe')) {
    const { sub, collection } = request.args;
    r.socket().say({ v: 1, re: request.id, ok: true, result: { sub, mode: 'snapshot' } });
    r.socket().say({ ...vector('snapshot.' + collection), sub });
  }
}

test('a delta whose prev is mine is applied in place', async () => {
  const r = await live();
  const delta = vector('delta.session-status');
  delta.changes[0].value.shownStatus = 'working';
  r.socket().say(delta);
  assert.equal(statusOf(r), 'working');
  assert.equal(r.store.state.sessions.size, 2, 'nothing else moved');
});

test('aDuplicateDeltaIsDropped', async () => {
  const r = await live();
  r.socket().say(vector('delta.session-status'));
  const delta = vector('delta.session-status');
  delta.changes[0].value.shownStatus = 'idle';
  r.socket().say(delta);
  assert.equal(statusOf(r), 'needs-you', 'seq 42 held already: not applied twice');
  assert.equal(r.sent('subscribe').length, 4, 'and it’s no gap');
});

test('aDeltaOutOfOrderIsNeverApplied', async () => {
  const r = await live();
  r.socket().say(vector('delta.session-gone')); // prev 42, and this page holds 41
  assert.ok(r.store.state.sessions.has('local:pts/9'), 'the later delta is not applied');
  r.socket().say(vector('delta.session-status'));
  // The page asked again; the old subscription's 42 may still come, and it does apply (prev = mine).
  assert.ok(r.store.state.sessions.has('local:pts/9'));
});

test('aGapSubscribesAgainWithSince', async () => {
  const r = await live();
  r.socket().say(vector('delta.session-gone'));
  const again = r.sent('subscribe').slice(4);
  assert.equal(again.length, 1);
  assert.deepEqual(again[0].args, { sub: 's1', collection: 'sessions', since: { epoch: EPOCH, seq: 41 } });
  // One ask per gap, not one per delta that follows it.
  r.socket().say({ ...vector('delta.session-gone'), prev: 45, seq: 46 });
  assert.equal(r.sent('subscribe').length, 5);
  // Answered as a resume: the catch-up delta from 41 applies.
  r.socket().say({ v: 1, re: again[0].id, ok: true, result: { sub: 's1', mode: 'resume' } });
  r.socket().say({ ...vector('delta.session-gone'), prev: 41, seq: 47 });
  assert.equal(r.store.state.sessions.has('local:pts/9'), false);
});

test('aSnapshotIsReconciledByIdInOneRender', async () => {
  const r = await live();
  const before = r.store.state.sessions.get(LEAD);
  r.page.renders.length = 0;
  const snapshot = vector('snapshot.sessions');
  snapshot.seq = 60;
  snapshot.entries = snapshot.entries.filter((entry) => entry.id === LEAD);
  snapshot.entries[0].value.shownStatus = 'working';
  snapshot.entries.push({ id: 'local:pts/12', value: { ...snapshot.entries[0].value, id: 'local:pts/12', terminal: 'pts/12', role: null } });
  r.socket().say({ ...snapshot, sub: 's1' });
  const renders = r.page.renders.filter(([topic]) => topic === 'sessions');
  assert.equal(renders.length, 1, 'one notification for the whole snapshot');
  assert.deepEqual([...r.store.state.sessions.keys()], [LEAD, 'local:pts/12']);
  assert.equal(statusOf(r), 'working');
  assert.notEqual(r.store.state.sessions.get(LEAD), before, 'the value is the new one');
});

test('noRowIsRemovedWhileReconnecting', async () => {
  const r = await live();
  const rows = [...r.store.state.sessions.keys()];
  r.socket().close();
  assert.equal(r.store.state.connection, 'reconnecting');
  assert.deepEqual([...r.store.state.sessions.keys()], rows);
  r.tick();
  r.socket().accept();
  r.socket().say(vector('hello.web'));
  // Each subscription resumes from what it holds.
  const asked = r.sent('subscribe');
  assert.deepEqual(asked.find((m) => m.args.sub === 's1').args.since, { epoch: EPOCH, seq: 41 });
  for (const request of asked) r.socket().say({ v: 1, re: request.id, ok: true, result: { sub: request.args.sub, mode: 'resume' } });
  assert.equal(r.store.state.connection, 'live');
  assert.deepEqual([...r.store.state.sessions.keys()], rows);
});

test('a reconnect tries at 100, 200 and 400 ms, then every second', async () => {
  const r = await live();
  const waits = [];
  for (let i = 0; i < 5; i++) {
    r.socket().close();
    waits.push(r.tick());
  }
  assert.deepEqual(waits, [100, 200, 400, 1000, 1000]);
  r.socket().accept();
  r.socket().say(vector('hello.web'));
  r.socket().close();
  assert.equal(r.tick(), 100, 'a hello starts the count again');
});

test('a server restart is a snapshot of a new epoch, reconciled with no empty frame', async () => {
  const r = await live();
  r.socket().close();
  r.tick();
  r.page.renders.length = 0;
  serve(r, { epoch: '7e2a9d14-5c3b-4f80-8b61-0a9c4d2e6f35' });
  assert.equal(r.store.state.sessions.size, 2);
  for (const [topic, changes] of r.page.renders) assert.ok(changes.every((change) => change.type === 'reset'), `${topic} reconciled whole`);
  assert.equal(r.store.state.connection, 'live');
});

test('aCardKeepsItsPlaceAcrossANewCardId', async () => {
  const r = await live();
  const first = vector('snapshot.cards');
  const other = structuredClone(first.entries[0]);
  other.id = 'local:card:00000000-0000-4000-8000-000000000001';
  other.value.id = other.id;
  other.value.question.id = 'q-8';
  r.socket().say({ ...first, sub: 's3', seq: first.seq + 1, entries: [first.entries[0], other] });
  assert.deepEqual([...r.store.state.cards.keys()], [CARD, other.id]);
  // The server restarts: the same question comes back under a new id, after the other card in the server's order.
  r.socket().close();
  r.tick();
  const reposted = structuredClone(first.entries[0]);
  reposted.id = 'local:card:99999999-9999-4999-8999-999999999999';
  reposted.value.id = reposted.id;
  reposted.value.at = '2026-11-17T10:00:00.000Z';
  serve(r, { epoch: '7e2a9d14-5c3b-4f80-8b61-0a9c4d2e6f35', snapshots: { cards: { ...first, seq: 2, entries: [other, reposted] } } });
  assert.deepEqual([...r.store.state.cards.keys()], [reposted.id, other.id], 'it takes the old card’s place');
  assert.equal(r.store.cardKey(reposted.id), CARD, 'and its row’s key');
  assert.equal(r.store.cardKey(other.id), other.id);
});

test('aByeOfAuthStopsRetrying', async () => {
  const r = rig({ hash: '', token: 'stale-token' });
  await r.feed.start();
  r.socket().accept();
  r.socket().say(vector('bye.auth'));
  r.socket().close();
  assert.equal(r.timers.length, 0, 'no retry');
  assert.equal(r.store.state.connection, 'unpaired');
  assert.equal(r.kept.has(TOKEN_KEY), false, 'the refused token is forgotten');
});

test('a bye of revoked stops retrying, and the rows stay readable', async () => {
  const r = await live();
  r.socket().say(vector('bye.revoked'));
  r.socket().close();
  assert.equal(r.timers.length, 0);
  assert.equal(r.store.state.connection, 'revoked');
  assert.equal(r.store.state.sessions.size, 2);
});

test('a bye of stopping reconnects', async () => {
  const r = await live();
  r.socket().say({ v: 1, kind: 'bye', code: 'stopping', reason: 'the node is stopping' });
  r.socket().close();
  assert.equal(r.tick(), 100);
  assert.equal(r.sockets.length, 2);
});

test('aNewerServersAssetsReloadWhenIdle', async () => {
  const r = rig();
  await r.feed.start();
  serve(r, { hello: { assets: '00000000' } });
  assert.equal(r.page.reloads, 1);
  const same = rig();
  await same.feed.start();
  serve(same);
  assert.equal(same.page.reloads, 0, 'the same build doesn’t');
});

test('anUnknownEventIsSkipped', async () => {
  const r = await live();
  r.socket().say({ v: 1, kind: 'weather', sunny: true });
  assert.equal(r.page.reloads, 0);
  r.socket().say(vector('delta.session-status'));
  assert.equal(r.store.state.sessions.get(LEAD).since, vector('delta.session-status').changes[0].value.since, 'and what follows is taken');
});

test('anUnknownEventMarkedMustReloads', async () => {
  const r = await live();
  r.socket().say({ v: 1, kind: 'weather', must: true });
  assert.equal(r.page.reloads, 1);
});

test('everyFrameReceivedPassesItsValidator', async () => {
  for (const [name, frame] of Object.entries(vectors)) {
    for (const message of Array.isArray(frame) ? frame : [frame]) assert.equal(validate('frame', message), null, name);
  }
  // A frame that fails isn't applied: a session whose status is a number.
  const r = await live();
  const bad = vector('delta.session-status');
  bad.changes[0].value.since = 42;
  r.socket().say(bad);
  assert.equal(r.store.state.sessions.get(LEAD).since, vector('snapshot.sessions').entries[0].value.since);
  assert.equal(r.page.warnings.length, 1);
  r.socket().say('not json');
  assert.equal(r.page.warnings.length, 2);
  // A good one after it still applies: the bad one was dropped, not counted.
  r.socket().say(vector('delta.session-status'));
  assert.equal(r.store.state.sessions.get(LEAD).since, vector('delta.session-status').changes[0].value.since);
});

test('a session’s fields the node doesn’t send stay empty, and its own words show', async () => {
  const r = await live();
  const lead = r.store.state.sessions.get(LEAD);
  assert.equal(lead.title, 'Login fix', 'the task it works on');
  const other = r.store.state.sessions.get('local:pts/9');
  assert.equal(other.title, null, 'nothing invented: the views show its folder');
  assert.equal(other.lead, null);
  assert.equal(other.paused, false);
});

test('a request this page may not send is answered here and never sent', async () => {
  const r = await live();
  const before = r.socket().sent.length;
  const reply = await r.store.request('answer', { card: CARD, answer: 'Yes' });
  assert.equal(reply.ok, false);
  assert.equal(r.socket().sent.length, before);
});

test('aStatusTheNodeCantDateShowsNoDuration', async () => {
  const { session } = await import('../js/wire.js');
  const value = { id: 'local:pts/9', terminal: 'pts/9', agent: 'claude', cwd: '/home/u/notes', status: 'unknown', shownStatus: 'unknown',
    since: '0001-01-01T00:00:00.000Z', role: null, task: null, activity: null, detail: null };
  assert.equal(session(value, new Map()).since, null, 'the start of time is no moment to count from');
  assert.equal(session({ ...value, since: '2026-11-17T09:13:20.000Z' }, new Map()).since, '2026-11-17T09:13:20.000Z');
});
