// A drafted answer from the page (the wire contract's §8, "Optimistic actions"; the live plan's D4): shown at once as
// an overlay keyed by its action id, kept until the cards stream reaches the ack's `applied`, taken back on a refusal,
// sent again with the same action id after a reconnect, and dropped when the card closes. On the same scripted socket
// and the vectors generated from the node's own encoders as socket.test.mjs.
// Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createStore } from '../js/store.js';
import { connectSocket } from '../js/socket.js';
import { validate } from '../wire/validators.js';

const vectors = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'wire', 'vectors.json'), 'utf8'));
const vector = (name) => structuredClone(vectors[name]);
const CARD = vector('snapshot.cards').entries[0].id;
const SEQ = vector('snapshot.cards').seq;

// A page on a fake socket and clock, live: hello, and each subscription's snapshot from the vectors.
async function live() {
  const store = createStore();
  const sockets = [];
  const timers = [];
  const kept = new Map();
  class FakeSocket {
    constructor(url) { this.url = url; this.sent = []; this.readyState = 0; sockets.push(this); }
    send(text) { this.sent.push(JSON.parse(text)); }
    close() { if (this.readyState === 3) return; this.readyState = 3; this.onclose?.(); }
    accept() { this.readyState = 1; this.onopen?.(); }
    say(message) { this.onmessage?.({ data: JSON.stringify(message) }); }
  }
  const feed = connectSocket(store, {
    url: 'ws://127.0.0.1:47830/ws', WebSocket: FakeSocket, validate, build: Promise.resolve(vector('hello.web').assets),
    storage: { getItem: (key) => kept.get(key) ?? null, setItem: (key, value) => kept.set(key, value), removeItem: (key) => kept.delete(key) },
    setTimeout: (fn) => { timers.push(fn); return timers.length; }, clearTimeout: () => {},
    location: { hash: '#pair=k3J1mZ0vY8q2Xw5rT7uB9A', pathname: '/', search: '' }, history: { replaceState() {} },
    reload: () => {}, log: () => {},
  });
  store.connect(feed);
  const socket = () => sockets[sockets.length - 1];
  const serve = ({ cards = 'snapshot' } = {}) => {
    socket().accept();
    socket().say(vector('hello.web'));
    for (const request of socket().sent.filter((message) => message.kind === 'subscribe').slice(-4)) {
      const { sub, collection } = request.args;
      const mode = collection === 'cards' && cards === 'resume' ? 'resume' : 'snapshot';
      socket().say({ v: 1, re: request.id, ok: true, result: { sub, mode } });
      if (mode === 'snapshot') socket().say({ ...vector('snapshot.' + collection), sub });
    }
  };
  await feed.start();
  serve();
  const sent = (kind) => socket().sent.filter((message) => message.kind === kind);
  const card = () => store.state.cards.get(CARD);
  return { store, feed, socket, serve, sent, card, reconnect: () => timers.shift()() };
}

// The cards delta a node sends once it took `request`: the card with its draft, at `seq`.
function drafted(request, seq, prev = SEQ) {
  const delta = vector('draft.acked')[1];
  delta.prev = prev;
  delta.seq = seq;
  delta.changes[0].value.draft = { text: request.args.text, version: request.args.version, at: '2026-11-17T09:15:11.898Z', action: request.action };
  return delta;
}

const flush = () => new Promise((resolve) => setImmediate(resolve));

test('a draft is sent as the contract’s request, and shows on its card at once', async () => {
  const r = await live();
  r.store.draft(CARD, 'Wait for the audit');
  const [request] = r.sent('draft');
  assert.equal(validate('frame', request), null);
  assert.deepEqual(request.args, { card: CARD, text: 'Wait for the audit', version: r.card().question.version });
  assert.match(request.action, /^[0-9a-f-]{36}$/);
  assert.deepEqual(r.store.draftOf(CARD), { text: 'Wait for the audit', sending: true, mine: true }, 'shown before any answer');
});

test('theOverlayStaysUntilTheStreamReachesApplied', async () => {
  const r = await live();
  const done = r.store.draft(CARD, 'Yes, merge it');
  const [request] = r.sent('draft');
  // The ack first, for a seq the stream hasn't reached: the overlay stays, no longer sending.
  r.socket().say({ v: 1, re: request.id, ok: true, result: { applied: { cards: SEQ + 2 }, card: CARD } });
  await flush();
  assert.deepEqual(r.store.draftOf(CARD), { text: 'Yes, merge it', sending: false, mine: true });
  assert.equal(r.card().draft, null, 'the stream doesn’t hold it yet');
  // Another change of the cards, before the draft's: still the overlay, never the old value.
  const other = drafted(request, SEQ + 1);
  other.changes[0].value.draft = null;
  r.socket().say(other);
  await flush();
  assert.equal(r.store.draftOf(CARD)?.mine, true, 'the overlay outlives a delta that isn’t yet the one acked');
  assert.equal(r.store.draftOf(CARD)?.text, 'Yes, merge it');
  // The stream reaches `applied`: the overlay goes, and the node's draft reads the same.
  r.socket().say(drafted(request, SEQ + 2, SEQ + 1));
  await done;
  assert.equal(r.store.state.drafts.has(CARD), false);
  assert.deepEqual(r.store.draftOf(CARD), { text: 'Yes, merge it', sending: false, mine: false });
});

test('an ack for a seq the stream already holds drops the overlay at once', async () => {
  const r = await live();
  const done = r.store.draft(CARD, 'Yes, merge it');
  const [request] = r.sent('draft');
  r.socket().say(drafted(request, SEQ + 1));
  r.socket().say({ v: 1, re: request.id, ok: true, result: { applied: { cards: SEQ + 1 }, card: CARD } });
  await done;
  assert.equal(r.store.state.drafts.has(CARD), false);
  assert.equal(r.store.draftOf(CARD)?.text, 'Yes, merge it');
});

test('aRefusalTakesTheOverlayBack', async () => {
  const r = await live();
  const changes = [];
  r.store.subscribe('cards', () => changes.push(r.store.draftOf(CARD)));
  const done = r.store.draft(CARD, 'Yes, merge it');
  const [request] = r.sent('draft');
  r.socket().say({ ...vector('draft.refused'), re: request.id });
  const reply = await done;
  assert.equal(reply.ok, false);
  assert.equal(r.store.draftOf(CARD), null, 'the card shows no draft');
  assert.equal(r.store.state.draftRefused.get(CARD), vector('draft.refused').error.message, 'and says why');
  assert.equal(changes[0]?.text, 'Yes, merge it', 'it showed at once');
  // The next draft takes the reason off.
  r.store.draft(CARD, 'Wait for the audit');
  assert.equal(r.store.state.draftRefused.has(CARD), false);
});

test('aPendingActionIsSentAgainWithTheSameId', async () => {
  const r = await live();
  const done = r.store.draft(CARD, 'Yes, merge it');
  const [first] = r.sent('draft');
  // The socket drops before the answer: the overlay stays, and the request goes again after the next hello.
  r.socket().close();
  assert.equal(r.store.draftOf(CARD)?.text, 'Yes, merge it', 'nothing is taken back while reconnecting');
  r.reconnect();
  r.serve({ cards: 'resume' });
  const [again] = r.sent('draft');
  assert.equal(again.action, first.action, 'the same action id');
  assert.deepEqual(again.args, first.args);
  r.socket().say(drafted(again, SEQ + 1));
  r.socket().say({ v: 1, re: again.id, ok: true, result: { applied: { cards: SEQ + 1 }, card: CARD } });
  await done;
  assert.equal(r.store.draftOf(CARD)?.text, 'Yes, merge it');
});

test('a card that closes drops what was drafted on it, and shows no draft', async () => {
  const r = await live();
  r.store.draft(CARD, 'Yes, merge it');
  const [request] = r.sent('draft');
  const closed = drafted(request, SEQ + 1);
  Object.assign(closed.changes[0].value, { open: false, closed: 'answered', draft: null });
  closed.changes[0].value.question.state = 'answered';
  closed.changes[0].value.question.answer = 'Yes, merge it';
  r.socket().say(closed);
  assert.equal(r.store.state.drafts.has(CARD), false);
  assert.equal(r.store.draftOf(CARD), null);
});

test('a clear sends draft.clear and shows no draft at once', async () => {
  const r = await live();
  const delta = drafted({ args: { text: 'Yes, merge it', version: 2 }, action: '6f1d2a34-9b8c-4e7d-a1f0-3c5b7d9e2f46' }, SEQ + 1);
  r.socket().say(delta);
  assert.equal(r.store.draftOf(CARD)?.mine, false, 'a draft left elsewhere shows as the node’s');
  r.store.draft(CARD, null);
  const [request] = r.sent('draft.clear');
  assert.equal(validate('frame', request), null);
  assert.deepEqual(request.args, { card: CARD });
  assert.equal(r.store.draftOf(CARD), null);
});

test('a draft’s id never meets a subscription’s: each reply reaches its own request', async () => {
  const r = await live();
  const done = r.store.draft(CARD, 'Yes, merge it');
  const [request] = r.sent('draft');
  const subscribes = r.sent('subscribe').map((message) => message.id);
  assert.ok(!subscribes.includes(request.id), `${request.id} among ${subscribes}`);
  r.socket().say(drafted(request, SEQ + 1));
  r.socket().say({ v: 1, re: request.id, ok: true, result: { applied: { cards: SEQ + 1 }, card: CARD } });
  assert.equal((await done).ok, true);
});

test('a draft goes in as the free-text answer of a single question that takes words, not a command, a multi-select or images', async () => {
  const { answersQuestion } = await import('../js/views/drive.js');
  const prompt = { question: 'Which name?', options: ['Parser', 'Reader', 'Type something.'], text: [2], multiSelect: false };
  assert.equal(answersQuestion(prompt, { text: 'Tokenizer', images: [] }), true);
  assert.equal(answersQuestion(prompt, { text: '/model', images: [] }), false);
  assert.equal(answersQuestion(prompt, { text: 'See this', images: ['/x.png'] }), false);
  assert.equal(answersQuestion({ ...prompt, multiSelect: true }, { text: 'Tokenizer' }), false);
  assert.equal(answersQuestion({ ...prompt, text: [] }, { text: 'Tokenizer' }), false);
  assert.equal(answersQuestion(null, { text: 'Tokenizer' }), false);
});
