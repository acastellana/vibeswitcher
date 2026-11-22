// A feature plugin's card on the page (js/plugincard.js, views/cards.js's pluginCard): in the node's card shape, what
// it asks whole (every line) with its size, the node's facts, the agent's words, the lines that settle it, a session's
// own cards only and only of the plugins the node has on, and its notification. Run: node --test WebApp/tests/*.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { validate } from '../wire/validators.js';
import { pluginFacts, pluginCardsOf, pluginsOn, pluginOn } from '../js/plugincard.js';
import { summarize, changes } from '../js/notify.js';

const action = (word, short, acts) => ({ word, label: word[0].toUpperCase() + word.slice(1), acts, short, does: `${short}, as you`, verb: word, marks: acts ? 'starting' : 'declined' });
const card = (fields = {}, plugin = {}) => ({
  id: 'local:card:0a1b2c3d-0000-4000-8000-00000000000a', kind: 'plugin', project: 'local:project:x', root: '/home/u/site', open: true,
  closed: null, notice: null, at: '2026-11-22T10:00:00.000Z', blocking: false, draft: null,
  plugin: {
    plugin: 'probe', request: 'r1', session: 'local:3f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f', asker: 'Worker: fix-login',
    title: 'A probe asked for', noun: 'probe request', ask: 'asks for a probe',
    facts: [{ name: 'folder', label: 'in the folder', value: '/home/u/site', folder: true, decisive: true }],
    body: { name: 'command', label: 'running exactly this', note: 'as you', lines: ['probe --deep', 'echo "done ✓"'], bytes: 28, size: '2 lines, 28 bytes' },
    context: { name: 'label', label: 'named', text: 'deep probe' }, severity: 'important', expiresAt: '2026-11-22T10:30:00.000Z',
    actions: [action('run', 'runs it', true), action('decline', 'declines it', false)], waiting: 'nothing runs until you answer run',
    state: 'waiting', outcome: null, ...plugin,
  },
  ...fields,
});

test('the card is the node’s shape, and says what it asks whole, with the lines that settle it', () => {
  assert.equal(validate('card', card()), null);
  const said = pluginFacts(card());
  assert.deepEqual(said.body.lines, ['probe --deep', 'echo "done ✓"']);
  assert.equal(said.body.size, '2 lines, 28 bytes');
  assert.equal(said.body.name, 'Command');
  assert.deepEqual(said.facts, [{ label: 'In the folder', value: '/home/u/site', folder: true }]);
  assert.deepEqual(said.context, { label: 'Named (the agent’s words)', text: '“deep probe”' }, 'the agent’s words marked as its own');
  assert.deepEqual(said.actions.map((a) => a.line), ['vibeswitcher answer 0a1b2c3d run', 'vibeswitcher answer 0a1b2c3d decline']);
  assert.deepEqual(said.actions.map((a) => a.says), ['the command that runs it', 'the command that declines it']);
  assert.equal(said.outcome, null);
  assert.equal(pluginFacts(card({}, { state: 'withdrawn', outcome: 'Withdrawn: you turned Probes off' })).outcome, 'Withdrawn: you turned Probes off');
});

test('a session shows its own open plugin cards only, oldest first, and none of a plugin the node has off', () => {
  const mine = card();
  const later = card({ id: 'local:card:0a1b2c3d-0000-4000-8000-00000000000b', at: '2026-11-22T10:05:00.000Z' });
  const other = card({ id: 'local:card:0a1b2c3d-0000-4000-8000-00000000000c' }, { session: 'local:other' });
  const closed = card({ id: 'local:card:0a1b2c3d-0000-4000-8000-00000000000d', open: false });
  const question = { ...card(), kind: 'question' };
  const all = [later, other, closed, question, mine];
  const session = 'LOCAL:3F6C2C1E-8A5B-4C1D-9E0F-2B7A6D5C4E3F';
  assert.deepEqual(pluginCardsOf(all, session).map((c) => c.id), [mine.id, later.id], 'a node before plugins: every card');
  assert.deepEqual(pluginCardsOf(all, session, [{ id: 'probe', title: 'Probes' }]).map((c) => c.id), [mine.id, later.id]);
  assert.deepEqual(pluginCardsOf(all, session, [{ id: 'shell', title: 'Shell requests' }]), [], 'its plugin off: nothing drawn');
  assert.deepEqual(pluginCardsOf(all, session, []), []);
  // The node's status (live) wins over its hello.
  assert.deepEqual(pluginsOn({ plugins: [{ id: 'probe' }], node: { plugins: [] } }), []);
  assert.deepEqual(pluginsOn({ plugins: [{ id: 'probe' }], node: {} }), [{ id: 'probe' }]);
  assert.equal(pluginsOn({ plugins: null, node: null }), null);
  assert.equal(pluginOn(null, 'probe'), true);
});

test('a new plugin card is told as its own title, its asker and its first line; not while its plugin is off', () => {
  const state = (cards, plugins = null) => ({ sessions: new Map(), leads: new Map(), cards: new Map(cards.map((c) => [c.id, c])), cardKeys: new Map(), plugins });
  const told = changes(summarize(state([])), summarize(state([card()])));
  assert.equal(told.length, 1);
  assert.ok(told[0].title.startsWith('A probe asked for'), told[0].title);
  assert.equal(told[0].body, 'Worker: fix-login: probe --deep');
  assert.equal(changes(summarize(state([], [])), summarize(state([card()], []))).length, 0, 'off: not told');
});

// The card drawn on a small stand-in DOM: the body as text, never markup; the only buttons copy a line; a settled card
// says what became of it and offers nothing to copy.
class FakeNode {
  constructor(tag, text) { this.tag = tag; this.text = text ?? null; this.children = []; this.attrs = {}; this.dataset = {}; this.handlers = {}; }
  append(...nodes) { this.children.push(...nodes); }
  setAttribute(name, value) { this.attrs[name] = value; }
  addEventListener(name, fn) { this.handlers[name] = fn; }
  get textContent() { return this.text ?? this.children.map((c) => c.textContent).join(''); }
  set textContent(value) { this.text = value; this.children = []; }
  all(tag) { return [...(this.tag === tag ? [this] : []), ...this.children.flatMap((c) => c.all(tag))]; }
}

test('the card shows the body whole as text, and its only buttons copy the lines', async () => {
  const before = { Node: globalThis.Node, document: globalThis.document };
  globalThis.Node = FakeNode;
  globalThis.document = { createElement: (tag) => new FakeNode(tag), createElementNS: (_, tag) => new FakeNode(tag), createTextNode: (text) => new FakeNode('#text', text) };
  try {
    const { pluginCard } = await import('../js/views/cards.js');
    const el = pluginCard(card({}, { body: { name: 'command', label: 'x', note: null, lines: ['<img src=x onerror=alert(1)>', 'rm -rf "$HOME/tmp"'], bytes: 47, size: '2 lines, 47 bytes' } }));
    assert.equal(el.all('pre')[0].children.length, 1);
    assert.equal(el.all('pre')[0].children[0].tag, '#text', 'the body is one text node');
    assert.equal(el.all('pre')[0].textContent, '<img src=x onerror=alert(1)>\nrm -rf "$HOME/tmp"');
    assert.deepEqual(el.all('img'), []);
    const text = el.textContent;
    for (const said of ['A probe asked for', 'Worker: fix-login', '/home/u/site', '2 lines', 'vibeswitcher answer 0a1b2c3d run', 'vibeswitcher answer 0a1b2c3d decline', 'deep probe']) assert.ok(text.includes(said), said);
    const buttons = el.all('button');
    assert.equal(buttons.length, 2);
    assert.ok(buttons.every((b) => b.attrs.class === 'copy-button'));
    const settled = pluginCard(card({ open: false }, { state: 'declined', outcome: 'Declined' }));
    assert.deepEqual(settled.all('button'), []);
    assert.ok(settled.textContent.includes('Declined'));
  } finally {
    Object.assign(globalThis, before);
  }
});
