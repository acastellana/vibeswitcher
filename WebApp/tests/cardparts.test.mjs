// A card too large for a snapshot's part, read whole in parts (the no-terminal inventory's C7): js/cardparts.js joins
// the node's parts only when every one names the same card, version and count, they come to the length (and, where the
// browser hashes, the SHA-256) the version says, and the JSON is that card; anything else fails closed. The store reads
// it once per stub and again when it changed; the card shows a calm loading line, then the whole card, or says the card
// keeps changing. Drawn on tests/fakedom.test.mjs's stand-in DOM over the real store and the mock (`large`).
// Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { installDom, find, findAll, button } from './fakedom.test.mjs';

installDom();
const { setLanguage } = await import('../js/i18n.js');
const { readCardParts, PART_BYTES, MOST_PARTS, sha256 } = await import('../js/cardparts.js');
const { createStore, WHOLE_RETRIES } = await import('../js/store.js');
const { questionCard } = await import('../js/views/cards.js');
const { createMock } = await import('../js/mock.js');
const { summarize, changes } = await import('../js/notify.js');

const ID = 'local:card:10e60000-0000-4000-8000-0000000010e6';
const base64 = (bytes) => Buffer.from(bytes).toString('base64');

// A node's parts of `card` (as `Requests.cardPart`), each reply through `tamper(part, index)` first.
async function node(card, { tamper = (part) => part, size = PART_BYTES } = {}) {
  const bytes = new TextEncoder().encode(JSON.stringify(card));
  const version = await sha256(bytes);
  const parts = Math.max(1, Math.ceil(bytes.length / size));
  const asked = [];
  const request = async (kind, args) => {
    asked.push({ kind, ...args });
    if (args.part > 0 && args.version !== version) return { ok: false, error: { code: 'changed', message: 'the card changed while it was being read' } };
    const part = { card: card.id, version, part: args.part, parts, bytes: bytes.length, data: base64(bytes.subarray(args.part * size, (args.part + 1) * size)) };
    return { ok: true, result: { part: tamper(part, args.part) } };
  };
  return { request, asked, bytes, version, parts };
}
const long = (size = 300_000, extra = {}) => ({ id: ID, kind: 'question', open: true, question: { text: 'Ünïcode “words” \\ '.repeat(size / 20), options: ['Yes', 'No'], version: 1 }, ...extra });

test('C7: the parts joined are the card whole: asked in order with the first’s version, each told as it comes', async () => {
  const card = long();
  const served = await node(card);
  assert.ok(served.parts > 2);
  const seen = [];
  const read = await readCardParts(served.request, ID, { progress: (got, of) => seen.push([got, of]) });
  assert.deepEqual(read.card, card);
  assert.equal(read.version, served.version);
  assert.deepEqual(served.asked.map((one) => [one.part, one.version ?? null]), [[0, null], ...Array.from({ length: served.parts - 1 }, (_, at) => [at + 1, served.version])]);
  assert.deepEqual(seen, Array.from({ length: served.parts }, (_, at) => [at + 1, served.parts]));
});

test('C7: parts that don’t fit together are never joined: another card, another version, a part out of turn, too large, too many, short, a hash that isn’t the version', async () => {
  const card = long();
  for (const [why, tamper] of [
    ['another card', (part, index) => (index === 1 ? { ...part, card: 'local:card:other' } : part)],
    ['another version', (part, index) => (index === 1 ? { ...part, version: 'f'.repeat(64) } : part)],
    ['out of turn', (part, index) => (index === 1 ? { ...part, part: 2 } : part)],
    ['a part past the bound', (part, index) => (index === 1 ? { ...part, data: base64(new Uint8Array(PART_BYTES + 1)) } : part)],
    ['more parts than the bound', (part) => ({ ...part, parts: MOST_PARTS + 1 })],
    ['a length that isn’t the parts’', (part) => ({ ...part, bytes: part.bytes + 1 })],
    ['not base64', (part, index) => (index === 1 ? { ...part, data: '%%%' } : part)],
  ]) {
    const served = await node(card, { tamper });
    const read = await readCardParts(served.request, ID);
    assert.equal(read.card, undefined, why);
    assert.equal(read.failed, 'odd', why);
  }
  const served = await node(card);
  const read = await readCardParts(served.request, ID, { digest: async () => '0'.repeat(64) });
  assert.equal(read.failed, 'odd', 'a hash that isn’t the version');
  const other = await node({ ...card, id: 'local:card:other' }, { tamper: (part) => ({ ...part, card: ID }) });
  assert.equal((await readCardParts(other.request, ID)).failed, 'odd', 'the JSON of another card');
});

test('C7: a card changed while it was read is `changed`; a node from before parts is `older`; a refusal is the node’s words', async () => {
  const card = long();
  const served = await node(card);
  let first = true;
  const changing = (kind, args) => {
    if (args.part === 1 && first) { first = false; return { ok: false, error: { code: 'changed', message: 'the card changed while it was being read' } }; }
    return served.request(kind, args);
  };
  assert.deepEqual(await readCardParts(changing, ID), { changed: true });
  assert.deepEqual(await readCardParts(async () => ({ ok: true, result: { cards: [card], more: 0 } }), ID), { older: true });
  const refused = await readCardParts(async () => ({ ok: false, error: { code: 'gone', message: 'no card' } }), ID);
  assert.equal(refused.failed, 'refused');
  assert.equal(refused.error.code, 'gone');
});

const until = async (holds, ms = 8000) => {
  const end = Date.now() + ms;
  while (!holds()) {
    if (Date.now() > end) throw new Error('waited too long');
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
};

// The store over the mock (`large`): the site lead's long question as its stub, then read whole.
async function mocked(options = {}) {
  const store = createStore();
  const mock = createMock(store, { still: true, large: 'yes', ...options });
  store.connect(mock);
  store.setKinds(mock.kinds, null, ['read', 'draft', 'watch', 'act']);
  mock.start();
  await until(() => store.state.cards.has(ID));
  return { store, mock, app: { store, ui: { state: { route: { name: 'home' } } } } };
}

test('C7: the long card shows a calm loading line, then the whole card in its place, answerable; nothing of it before', async () => {
  setLanguage('en');
  const { store, mock, app } = await mocked();
  const stub = store.state.cards.get(ID);
  assert.ok(stub?.tooLarge, 'the stream holds its stub');
  const view = questionCard(app, stub);
  const redraw = () => view.update(store.state.cards.get(ID));
  store.subscribe('cards', redraw);
  assert.match(view.el.shownText, /Loading this long card…/);
  assert.doesNotMatch(view.el.shownText, /vibeswitcher/, 'no command');
  assert.doesNotMatch(view.el.shownText, /maintenance window/, 'nothing of what it asks yet');
  assert.ok(find(view.el, (node) => node.attrs['aria-busy'] === 'true'), 'busy while it loads');
  await until(() => store.state.wholeCards.get(ID)?.status === 'loaded');
  assert.match(view.el.shownText, /Run all of them tonight, or only the first hundred/);
  assert.ok(find(view.el, button('Run all of them tonight')), 'its options to answer');
  assert.doesNotMatch(view.el.shownText, /Loading this long card/);
  mock.stop();
});

test('C7: a card that keeps changing while it is read is read again, then says so, with Read it again (Spanish)', async () => {
  setLanguage('es');
  const { store, mock, app } = await mocked({ large: 'changing' });
  const view = questionCard(app, store.state.cards.get(ID));
  store.subscribe('cards', () => view.update(store.state.cards.get(ID)));
  await until(() => store.state.wholeCards.get(ID)?.status === 'changing');
  assert.equal(store.state.wholeCards.get(ID).retries, WHOLE_RETRIES, 'read again before it says so');
  assert.match(view.el.shownText, /Esta tarjeta no deja de cambiar mientras se lee\./);
  const again = find(view.el, button('Volver a leerla'));
  assert.ok(again);
  again.click();
  assert.equal(store.state.wholeCards.get(ID).status, 'loading');
  assert.match(view.el.shownText, /Cargando esta tarjeta larga…/);
  setLanguage('en');
  mock.stop();
});

test('C7: an older node, which takes no parts, keeps the card in a terminal; a notification of a long card names no command', async () => {
  setLanguage('en');
  const { store, mock, app } = await mocked({ older: true });
  const view = questionCard(app, store.state.cards.get(ID));
  store.subscribe('cards', () => view.update(store.state.cards.get(ID)));
  await until(() => store.state.wholeCards.get(ID)?.status === 'older');
  assert.match(view.el.shownText, /This card is too large for the page: read it with vibeswitcher questions/);
  const state = (cards) => ({ sessions: new Map(), leads: new Map(), cards: new Map(cards.map((c) => [c.id, c])), cardKeys: new Map(), plugins: null });
  const told = changes(summarize(state([])), summarize(state([store.state.cards.get(ID)])));
  assert.equal(told.at(-1).body, 'A long card: open the page to read it whole.');
  assert.equal(findAll(view.el, (node) => node.tag === 'pre').length, 0);
  mock.stop();
});

test('C7: an answer on a long card the node refuses as changed reads it whole again (a change that kept its stub)', async () => {
  setLanguage('en');
  const { store, mock } = await mocked();
  const stub = store.state.cards.get(ID);
  store.wholeCard(stub);
  await until(() => store.state.wholeCards.get(ID)?.status === 'loaded');
  const first = store.state.wholeCards.get(ID);
  store.connect({ ...mock, request: (message) => (message.kind === 'answer'
    ? Promise.resolve({ ok: false, error: { code: 'changed', message: 'the card changed since you saw it' } }) : mock.request(message)) });
  await store.act(ID, 'answer', { text: 'Only the first hundred' });
  assert.notEqual(store.state.wholeCards.get(ID), first, 'read again');
  await until(() => store.state.wholeCards.get(ID)?.status === 'loaded');
  mock.stop();
});
