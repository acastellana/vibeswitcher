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
// The collections a page follows (socket.js): node, sessions, leads, cards and the leads' boards.
const FOLLOWED = 5;

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
  const subscribes = r.sent('subscribe').slice(-FOLLOWED);
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

test('the five subscriptions are asked after hello, and the page is live once each has its snapshot', async () => {
  const r = rig();
  await r.feed.start();
  r.socket().accept();
  r.socket().say(vector('hello.web'));
  assert.deepEqual(r.sent('subscribe').map((m) => [m.args.sub, m.args.collection]), [['s0', 'node'], ['s1', 'sessions'], ['s2', 'leads'], ['s3', 'cards'], ['s4', 'boards']]);
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
  assert.equal(r.sent('subscribe').length, FOLLOWED, 'and it’s no gap');
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
  const again = r.sent('subscribe').slice(FOLLOWED);
  assert.equal(again.length, 1);
  assert.deepEqual(again[0].args, { sub: 's1', collection: 'sessions', parts: true, since: { epoch: EPOCH, seq: 41 } });
  // One ask per gap, not one per delta that follows it.
  r.socket().say({ ...vector('delta.session-gone'), prev: 45, seq: 46 });
  assert.equal(r.sent('subscribe').length, FOLLOWED + 1);
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

// Snapshots in parts (the contract's §4): the page asks for them on every keyed collection (a chat's snapshot is bounded
// by its own items), holds the parts, and takes them together when the last comes, as one snapshot.
test('the keyed subscriptions ask for snapshots in parts, as the vector does', async () => {
  const r = rig();
  await r.feed.start();
  r.socket().accept();
  r.socket().say(vector('hello.web'));
  assert.ok(r.sent('subscribe').every((m) => m.args.parts === true), 'every keyed collection asks for parts');
  const asked = r.sent('subscribe').find((m) => m.args.collection === 'sessions');
  assert.deepEqual(asked.args, vector('subscribe.parts').args);
});

test('a snapshot in parts is taken whole when its last part comes, nothing before', async () => {
  const r = await live();
  const [first, last] = vector('snapshot.parts');
  // A change the parts replace: a row the new snapshot doesn't hold.
  const lead = vector('snapshot.sessions').entries[0];
  r.socket().say({ ...vector('snapshot.sessions'), sub: 's1', seq: 40,
    entries: [{ id: 'local:pts/40', value: { ...lead.value, id: 'local:pts/40', terminal: 'pts/40', role: null } }] });
  assert.deepEqual([...r.store.state.sessions.keys()], ['local:pts/40']);
  r.page.renders.length = 0;
  r.socket().say({ ...first, sub: 's1', epoch: EPOCH, seq: 41 });
  assert.deepEqual([...r.store.state.sessions.keys()], ['local:pts/40'], 'nothing of a part is shown before the last');
  assert.equal(r.page.renders.filter(([topic]) => topic === 'sessions').length, 0);
  r.socket().say({ ...last, sub: 's1', epoch: EPOCH, seq: 41 });
  assert.deepEqual([...r.store.state.sessions.keys()].sort(), [first.entries[0].id, last.entries[0].id].sort(), 'both parts, the old row gone');
  assert.equal(r.page.renders.filter(([topic]) => topic === 'sessions').length, 1, 'one render for the whole snapshot');
  assert.ok(r.page.warnings.some((w) => w.includes('too large to send') && w.includes('local:pts/9')), 'the withheld entry is said');
  // Deltas go on from its seq.
  const delta = vector('delta.session-status');
  delta.changes[0].value.shownStatus = 'working';
  r.socket().say(delta);
  assert.equal(statusOf(r), 'working');
});

test('a card too large for a part comes withheld whole: its stub takes its place, nothing of what it asks', async () => {
  const r = await live();
  assert.ok(r.store.state.cards.get(CARD).question, 'the whole card first');
  const part = vector('snapshot.parts-card');
  r.socket().say({ ...part, sub: 's3', epoch: EPOCH });
  const card = r.store.state.cards.get(CARD);
  assert.ok(card, 'the card keeps its place');
  assert.equal(card.tooLarge.command, 'vibeswitcher questions');
  assert.equal(card.question, undefined, 'nothing of what it asks, cut or whole');
  assert.equal(card.project, vector('snapshot.cards').entries[0].value.project);
  assert.equal(card.open, true);
  assert.ok(!r.page.warnings.some((w) => w.includes('too large to send')), 'a stub shown is not a warning');
});

test('a part out of its place takes nothing and asks again', async () => {
  const r = await live();
  const before = [...r.store.state.sessions.keys()];
  const [, last] = vector('snapshot.parts');
  const asked = r.sent('subscribe').length;
  r.socket().say({ ...last, sub: 's1', epoch: EPOCH, seq: 41 });
  assert.deepEqual([...r.store.state.sessions.keys()], before, 'a lone last part changes nothing');
  assert.equal(r.sent('subscribe').length, asked + 1);
  assert.equal(r.sent('subscribe').at(-1).args.sub, 's1');
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
  // Your name for it heads its row; a pause greys it out.
  assert.equal(session({ ...value, task: 'Fix the build', name: null }, new Map()).title, 'Fix the build');
  assert.equal(session({ ...value, task: 'Fix the build', name: 'Release' }, new Map()).title, 'Release');
  assert.equal(session({ ...value, pausedUntil: null }, new Map()).paused, false);
  assert.equal(session({ ...value, pausedUntil: '2026-11-21T09:00:00.000Z' }, new Map()).paused, true);
});

// ---- Chats (the contract §6) ----

// A live page following the lead's chat: its subscribe, answered with the chat's snapshot vector.
async function chatting() {
  const r = await live();
  r.store.openChat(LEAD);
  const ask = r.sent('subscribe').at(-1);
  r.socket().say({ v: 1, re: ask.id, ok: true, result: { sub: ask.args.sub, mode: 'snapshot' } });
  r.socket().say({ ...vector('snapshot.chat'), sub: ask.args.sub, key: LEAD });
  return { r, ask, chat: r.store.state.chats.get(LEAD) };
}

const ids = (chat) => chat.items.map((item) => item.id);

test('a chat is followed by its session, its snapshot taken and its ops applied in place', async () => {
  const { r, ask, chat } = await chatting();
  assert.deepEqual(ask.args, { sub: 'c1', collection: 'chat', key: LEAD });
  assert.equal(validate('frame', ask), null);
  assert.deepEqual(ids(chat), ['m_01', 'm_02.0']);
  assert.equal(chat.more, true);
  const item = chat.items[1];
  r.socket().say(vector('delta.chat'));
  assert.equal(chat.items[1], item, 'the grown reply is the same item, its text appended');
  assert.equal(item.text, "I'll start by reading the test. It reads the token from the wrong header.");
  assert.deepEqual(ids(chat), ['m_01', 'm_02.0', 'tools:t_07']);
  r.socket().say(vector('delta.chat-set'));
  assert.deepEqual(ids(chat), ['m_01', 'tools:t_07', 'm_09']);
  assert.equal(chat.items[1].tools[0].result.output, 'import Testing\n…');
  assert.equal(chat.items[2].type, 'team');
  assert.deepEqual(r.page.warnings, []);
});

test('aTextOpWhoseOffsetIsntMineIsAGap', async () => {
  const { r, chat } = await chatting();
  const delta = vector('delta.chat');
  delta.ops[0].at = 7;
  r.socket().say(delta);
  assert.deepEqual(ids(chat), ['m_01', 'm_02.0'], 'nothing of the delta is applied: not its add either');
  assert.equal(chat.items[1].text, "I'll start by reading the test.");
  const again = r.sent('subscribe').at(-1);
  assert.deepEqual(again.args, { sub: 'c1', collection: 'chat', key: LEAD, after: 'm_02.0' }, 'the item asked for again, and what follows it');
  // The tail that answers it replaces the item and what followed.
  r.socket().say({ v: 1, re: again.id, ok: true, result: { sub: 'c1', mode: 'tail' } });
  const tail = vector('resume.chat-tail')[2];
  r.socket().say({ ...tail, epoch: EPOCH, seq: 321, after: 'm_02.0',
    items: [{ id: 'm_02.0', type: 'reply', at: null, text: "I'll start by reading the test. It reads the token from the wrong header." }] });
  assert.deepEqual(ids(chat), ['m_01', 'm_02.0']);
  assert.match(chat.items[1].text, /wrong header\.$/);
});

test('aChatTailReplacesFromItsItemOn', async () => {
  const { r, chat } = await chatting();
  r.socket().say(vector('delta.chat'));
  r.socket().close();
  assert.deepEqual(ids(chat), ['m_01', 'm_02.0', 'tools:t_07'], 'reconnecting: every item stays');
  r.tick();
  const restarted = vector('resume.chat-tail')[2].epoch;
  r.socket().accept();
  r.socket().say({ ...vector('hello.web'), epoch: restarted });
  const ask = r.sent('subscribe').find((message) => message.args.collection === 'chat');
  assert.deepEqual(ask.args, { sub: 'c1', collection: 'chat', key: LEAD, since: { epoch: EPOCH, seq: 320 }, after: 'tools:t_07' });
  r.socket().say({ v: 1, re: ask.id, ok: true, result: { sub: 'c1', mode: 'tail' } });
  r.socket().say(vector('resume.chat-tail')[2]);
  assert.deepEqual(ids(chat), ['m_01', 'm_02.0', 'tools:t_07', 'm_03.0'], 'nothing lost, nothing twice');
  assert.equal(chat.items[2].tools[0].result.output, 'import Testing\n…', 'the item `after` as it is now');
  // The next delta follows the tail's seq, in the new epoch.
  r.socket().say({ ...vector('delta.chat-set'), prev: 2, seq: 3, ops: [{ op: 'remove', id: 'm_03.0' }] });
  assert.deepEqual(ids(chat), ['m_01', 'm_02.0', 'tools:t_07']);
});

test('a chat no longer shown is let go, keeps its items, and resumes when shown again', async () => {
  const { r, chat } = await chatting();
  r.store.closeChat(LEAD);
  const left = r.sent('unsubscribe').at(-1);
  assert.deepEqual(left.args, { sub: 'c1' });
  r.socket().say({ ...vector('delta.chat') });
  assert.deepEqual(ids(chat), ['m_01', 'm_02.0'], 'a late event of a chat let go is dropped');
  r.store.openChat(LEAD);
  const back = r.sent('subscribe').at(-1);
  assert.deepEqual(back.args, { sub: 'c1', collection: 'chat', key: LEAD, since: { epoch: EPOCH, seq: 318 }, after: 'm_02.0' });
  r.socket().say({ v: 1, re: back.id, ok: true, result: { sub: 'c1', mode: 'resume' } });
  r.socket().say(vector('delta.chat'));
  assert.deepEqual(ids(chat), ['m_01', 'm_02.0', 'tools:t_07']);
});

test('older items page in before the first, once at a time, while there are more', async () => {
  const { r, chat } = await chatting();
  r.store.pageChat(LEAD);
  r.store.pageChat(LEAD);
  const pages = r.sent('chat.page');
  assert.equal(pages.length, 1, 'one page asked at a time');
  assert.deepEqual(pages[0].args, { session: LEAD, before: 'm_01', limit: 200 });
  assert.equal(validate('frame', pages[0]), null);
  r.socket().say({ ...vector('chat.page')[1], re: pages[0].id });
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(ids(chat), ['m_00.0', 'm_01', 'm_02.0']);
  assert.equal(chat.more, false);
  r.store.pageChat(LEAD);
  assert.equal(r.sent('chat.page').length, 1, 'nothing more to ask for');
});

test('a new session’s chat before its transcript: no conversation yet, nothing logged, and followed once there is one', async () => {
  const sessions = vector('snapshot.sessions');
  sessions.entries[0].value.hasTranscript = false;
  const r = rig();
  await r.feed.start();
  serve(r, { snapshots: { sessions } });
  r.store.openChat(LEAD);
  const ask = r.sent('subscribe').at(-1);
  r.socket().say({ v: 1, re: ask.id, ok: false, error: { code: 'gone', message: 'no such session, or it has no transcript' } });
  await new Promise((resolve) => setImmediate(resolve));
  const chat = r.store.state.chats.get(LEAD);
  assert.equal(chat.loaded, true, 'shown as a conversation with nothing in it yet');
  assert.deepEqual(ids(chat), []);
  assert.deepEqual(r.page.warnings, []);
  // A change that isn't its transcript asks nothing.
  const asked = r.sent('subscribe').length;
  const other = vector('delta.session-status');
  other.changes[0].value.hasTranscript = false;
  r.socket().say(other);
  assert.equal(r.sent('subscribe').length, asked);
  // Its transcript written: followed again, from nothing.
  const written = vector('delta.session-status');
  written.prev = 42;
  written.seq = 43;
  r.socket().say(written);
  const again = r.sent('subscribe').at(-1);
  assert.equal(r.sent('subscribe').length, asked + 1);
  assert.deepEqual(again.args, { sub: 'c1', collection: 'chat', key: LEAD });
  r.socket().say({ v: 1, re: again.id, ok: true, result: { sub: 'c1', mode: 'snapshot' } });
  r.socket().say({ ...vector('snapshot.chat'), sub: 'c1', key: LEAD });
  assert.deepEqual(ids(chat), ['m_01', 'm_02.0']);
  // Another refusal (a session the node doesn't know) is still logged.
  r.store.openChat('local:00000000-0000-4000-8000-000000000000');
  const unknown = r.sent('subscribe').at(-1);
  r.socket().say({ v: 1, re: unknown.id, ok: false, error: { code: 'gone', message: 'no such session, or it has no transcript' } });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(r.page.warnings.length, 1);
});

test('every chat frame the page reads passes its validator', () => {
  for (const name of ['snapshot.chat', 'delta.chat', 'delta.chat-set']) {
    const frame = vector(name);
    assert.equal(validate('frame', frame), null, name);
  }
  assert.equal(validate('reply.chat.page', vector('chat.page')[1]), null);
});

test('“Try again now” (the design review’s D21): retryNow opens the node’s socket at once while it waits between two tries, never reloads, never doubles an attempt', async () => {
  const r = rig();
  await r.feed.start();
  assert.equal(r.sockets.length, 1);
  assert.equal(r.feed.retryNow(), false, 'an attempt is open: nothing to hurry');
  r.socket().close();
  assert.equal(r.timers.length, 1, 'the next try is waiting');
  assert.equal(r.feed.retryNow(), true);
  assert.equal(r.sockets.length, 2, 'a new socket, now');
  assert.equal(r.page.reloads, 0, 'the page is never reloaded (the node out of reach would take it away)');
  assert.equal(r.feed.retryNow(), false, 'and not a second one while that is open');
});
