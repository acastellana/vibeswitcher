// The mock (`?mock`) held to the wire's shapes: what it shows is what the node would send, so a view that looks right on
// the mock reads the node's own values. Its snapshot's every entity, and a chat's items, pass validators.js (the
// generated twin of the node's WireSchema). The mock isn't in the node's embedded page (scripts/webapp-embed.sh), so
// this is where it is checked. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { validate, collections } from '../wire/validators.js';
import { createMock } from '../js/mock.js';

// A store that keeps what the mock gives it.
function recorder() {
  const got = { applied: [], chats: new Map() };
  return {
    got,
    apply(message) { got.applied.push(structuredClone(message)); },
    setConnection() {},
    chatSnapshot(sid, page) { got.chats.set(sid, structuredClone(page)); },
    chatOps() {},
  };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 20));

// The mock's sessions are in the view's shape, which js/wire.js makes of the node's (`shownStatus` read as `status`,
// `name` as `title`, `pausedUntil` as `paused`): those three are put back as the node sends them; the rest is checked
// as it is.
const asTheNodeSends = { sessions: (s) => ({ ...s, shownStatus: s.status, name: s.title ?? null, pausedUntil: s.paused ? new Date().toISOString() : null }) };

async function stillSnapshot() {
  const store = recorder();
  const mock = createMock(store, { still: true });
  mock.start();
  await settle();
  mock.stop();
  const snapshot = store.got.applied.find((message) => message.kind === 'snapshot');
  assert.ok(snapshot, 'the mock sent no snapshot');
  return { snapshot, mock, store };
}

test('every entity of the mock’s snapshot passes the node’s shape for its collection', async () => {
  const { snapshot } = await stillSnapshot();
  const { node, ...keyed } = snapshot.state;
  const failures = [];
  const node1 = validate('node', node);
  if (node1) failures.push(`node: ${node1}`);
  let checked = 0;
  for (const [collection, entities] of Object.entries(keyed)) {
    const shape = collections[collection];
    assert.ok(shape, `the mock's ${collection} is no collection of the wire's`);
    for (const [index, entity] of entities.entries()) {
      checked += 1;
      const failure = validate(shape, (asTheNodeSends[collection] || ((value) => value))(entity));
      if (failure) failures.push(`${collection}[${index}] (${entity.id ?? entity.root ?? entity.project ?? '?'}): ${failure}`);
    }
  }
  assert.ok(checked > 10, `only ${checked} entities`);
  assert.deepEqual(failures, []);
});

test('a chat the mock shows passes the node’s shape for its items', async () => {
  const store = recorder();
  const mock = createMock(store, { still: true });
  mock.start();
  await settle();
  const sessions = store.got.applied.find((message) => message.kind === 'snapshot').state.sessions;
  for (const session of sessions) mock.subscribeChat(session.id);
  await settle();
  mock.stop();
  const failures = [];
  let items = 0;
  for (const [sid, page] of store.got.chats) {
    for (const [index, item] of page.items.entries()) {
      items += 1;
      const failure = validate('chat.item', item);
      if (failure) failures.push(`${sid} item ${index} (${item.type}): ${failure}`);
    }
  }
  assert.ok(items > 10, `only ${items} chat items`);
  assert.deepEqual(failures, []);
});
