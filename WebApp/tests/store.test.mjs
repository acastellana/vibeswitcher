// The store's contract with its feed: a snapshot, then deltas in order; a gap asks for a new snapshot; a new epoch
// replaces everything; what this client sent is never shown twice. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { createStore } from '../js/store.js';

const session = (id, status = 'idle') => ({ id, terminal: 'pts/1', agent: 'claude', cwd: '/home/dev/projects/example', status, since: '2026-11-17T09:00:00.000Z', hosted: true, role: null });
const snapshot = (epoch, seq, sessions = []) => ({ v: 1, kind: 'snapshot', epoch, seq, state: { node: { node: 'local', notices: [] }, sessions, leads: [], cards: [], boards: [] } });

function feed(store) {
  const calls = { resync: 0, chats: [], requests: [] };
  store.connect({
    resync() { calls.resync += 1; },
    subscribeChat(id) { calls.chats.push(id); },
    request(message) { calls.requests.push(message); return calls.reply ?? new Promise(() => {}); },
  });
  return calls;
}

test('a snapshot fills the collections, in the node’s order, and the connection is live', () => {
  const store = createStore();
  assert.equal(store.state.connection, 'connecting');
  store.apply(snapshot('e1', 4, [session('local:b'), session('local:a')]));
  assert.equal(store.state.connection, 'live');
  assert.deepEqual([...store.state.sessions.keys()], ['local:b', 'local:a']);
  assert.equal(store.state.seq, 4);
});

test('a delta puts, replaces and removes by id, and tells only the topics it touched', () => {
  const store = createStore();
  store.apply(snapshot('e1', 0, [session('local:a')]));
  const heard = [];
  store.subscribe('sessions', (changes) => heard.push(['sessions', changes.length]));
  store.subscribe('cards', () => heard.push(['cards']));
  assert.equal(store.apply({ v: 1, kind: 'delta', seq: 1, changes: [
    { in: 'sessions', id: 'local:a', value: session('local:a', 'working') },
    { in: 'sessions', id: 'local:b', value: session('local:b') },
  ] }), 'ok');
  assert.equal(store.state.sessions.get('local:a').status, 'working');
  assert.deepEqual(heard, [['sessions', 2]]);
  store.apply({ v: 1, kind: 'delta', seq: 2, changes: [{ in: 'sessions', id: 'local:a', value: null }] });
  assert.deepEqual([...store.state.sessions.keys()], ['local:b']);
});

test('a gap asks the feed for a snapshot and applies nothing; a delta already applied is passed over', () => {
  const store = createStore();
  const calls = feed(store);
  store.apply(snapshot('e1', 5, [session('local:a')]));
  assert.equal(store.apply({ v: 1, kind: 'delta', seq: 7, changes: [{ in: 'sessions', id: 'local:a', value: null }] }), 'gap');
  assert.equal(calls.resync, 1);
  assert.equal(store.state.sessions.size, 1);
  assert.equal(store.apply({ v: 1, kind: 'delta', seq: 5, changes: [{ in: 'sessions', id: 'local:a', value: null }] }), 'stale');
  assert.equal(store.state.sessions.size, 1);
});

test('a collection this client doesn’t know is ignored (rule 3)', () => {
  const store = createStore();
  store.apply(snapshot('e1', 0));
  assert.equal(store.apply({ v: 1, kind: 'delta', seq: 1, changes: [{ in: 'wallets', id: 'w', value: {} }] }), 'ok');
  assert.equal(store.state.seq, 1);
});

test('a chat takes its rows, then appends, grows a streaming row’s text, replaces and removes', () => {
  const store = createStore();
  feed(store);
  store.apply(snapshot('e1', 0, [session('local:a')]));
  store.openChat('local:a');
  store.apply({ v: 1, kind: 'chat', session: 'local:a', items: [{ id: 'm1', kind: 'prompt', text: 'Hi' }] });
  const seen = [];
  store.subscribe('chat:local:a', (changes) => seen.push(...changes.map((change) => change.type)));
  store.apply({ v: 1, kind: 'delta', seq: 1, changes: [{ in: 'chat', session: 'local:a', id: 'm2', value: { id: 'm2', kind: 'reply', text: '', streaming: true } }] });
  store.apply({ v: 1, kind: 'delta', seq: 2, changes: [{ in: 'chat', session: 'local:a', id: 'm2', append: { text: 'Hel' } }, { in: 'chat', session: 'local:a', id: 'm2', append: { text: 'lo' } }] });
  const chat = store.state.chats.get('local:a');
  assert.equal(chat.items[1].text, 'Hello');
  store.apply({ v: 1, kind: 'delta', seq: 3, changes: [{ in: 'chat', session: 'local:a', id: 'm1', value: null }] });
  assert.deepEqual(chat.items.map((item) => item.id), ['m2']);
  assert.equal(chat.index.get('m2'), 0);
  assert.deepEqual(seen, ['put', 'append', 'append', 'remove']);
});

test('a message sent from here shows at once, and the transcript’s own row takes its place', () => {
  const store = createStore();
  const calls = feed(store);
  store.apply(snapshot('e1', 0, [session('local:a')]));
  store.openChat('local:a');
  store.apply({ v: 1, kind: 'chat', session: 'local:a', items: [] });
  store.send('local:a', 'Run the tests');
  const chat = store.state.chats.get('local:a');
  assert.equal(chat.items.length, 1);
  assert.equal(chat.items[0].pending, true);
  const action = calls.requests[0].action;
  store.apply({ v: 1, kind: 'delta', seq: 1, changes: [{ in: 'chat', session: 'local:a', id: 'm9', value: { id: 'm9', kind: 'prompt', text: 'Run the tests', action } }] });
  assert.deepEqual(chat.items.map((item) => item.id), ['m9']);
  assert.equal(chat.index.get('m9'), 0);
});

test('an answer shows at once; a refusal takes it back with the reason; the card’s own delta clears it', async () => {
  const store = createStore();
  const calls = feed(store);
  store.apply(snapshot('e1', 0));
  store.apply({ v: 1, kind: 'delta', seq: 1, changes: [{ in: 'cards', id: 'c1', value: { id: 'c1', open: true } }] });
  calls.reply = Promise.resolve({ ok: false, error: { code: 'refused', message: 'Already answered.' } });
  const done = store.act('c1', 'answer', { answer: 'Thursday' });
  assert.deepEqual(store.state.acting.get('c1'), { kind: 'answer', answer: 'Thursday' });
  await done;
  assert.deepEqual(store.state.acting.get('c1'), { refused: 'Already answered.' });
  store.apply({ v: 1, kind: 'delta', seq: 2, changes: [{ in: 'cards', id: 'c1', value: { id: 'c1', open: false } }] });
  assert.equal(store.state.acting.has('c1'), false);
});

test('a snapshot from another server start replaces everything and asks for the open chats again', () => {
  const store = createStore();
  const calls = feed(store);
  store.apply(snapshot('e1', 9, [session('local:a')]));
  store.openChat('local:a');
  store.setConnection('reconnecting');
  assert.equal(store.apply({ v: 1, kind: 'delta', seq: 10, changes: [] }), 'stale');
  store.apply(snapshot('e2', 0, [session('local:z')]));
  assert.equal(store.state.connection, 'live');
  assert.deepEqual([...store.state.sessions.keys()], ['local:z']);
  assert.deepEqual(calls.chats, ['local:a', 'local:a']);
});
