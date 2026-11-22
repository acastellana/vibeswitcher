// A shell request's card on the page, as the shell plugin draws it (Sources/VibeNode/Plugins/Shell/ShellPlugin.swift,
// `card.plugin`; js/plugincard.js, views/cards.js's pluginCard): in the node's card shape, what would run whole (every
// line), its size as the command line says it, the two lines that settle it, the session's own cards only, and its
// notification. Run: node --test WebApp/tests/*.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { validate } from '../wire/validators.js';
import { pluginFacts, pluginCardsOf } from '../js/plugincard.js';
import { summarize, changes } from '../js/notify.js';

const COMMAND = 'npm run dev -- --port 5173\necho "ready ✓"';
const actions = [
  { word: 'run', label: 'Run', acts: true, short: 'runs it', does: 'runs the command above (2 lines, 43 bytes), exactly as shown, in a new shell session in /home/u/site, as you: it runs with everything your account can do', verb: "run an agent's command in your login shell", marks: 'starting' },
  { word: 'decline', label: 'Decline', acts: false, short: 'declines it', does: 'declines this shell request: nothing runs, and the asking session is told', verb: "decline an agent's shell request", marks: 'declined' },
];
const shell = (fields = {}) => ({
  plugin: 'shell', request: 'r1', session: 'local:3f6c2c1e-8a5b-4c1d-9e0f-2b7a6d5c4e3f', asker: 'Worker: fix-login',
  title: 'A shell asked for', noun: 'shell request', ask: 'asks for a new shell session',
  facts: [{ name: 'folder', label: 'in the folder', value: '/home/u/site', folder: true, decisive: true }],
  body: { name: 'command', label: 'running exactly this command', note: 'by your login shell, which stays open after it', lines: COMMAND.split('\n'), bytes: 43, size: '2 lines, 43 bytes' },
  context: { name: 'label', label: 'named', text: 'Shell: dev server' }, severity: 'important', expiresAt: '2026-11-21T10:30:00.000Z',
  actions, waiting: 'nothing runs until you answer run', state: 'waiting', outcome: null, ...fields,
});
const card = (fields = {}, plugin = {}) => ({
  id: 'local:card:0a1b2c3d-0000-4000-8000-00000000000a', kind: 'plugin', project: 'local:project:x', root: '/home/u/site', open: true,
  closed: null, notice: null, at: '2026-11-21T10:00:00.000Z', blocking: false, draft: null, plugin: shell(plugin), ...fields,
});

test('the card is the node’s shape, and says exactly what would run, whole, with the lines that settle it', () => {
  assert.equal(validate('card', card()), null);
  const said = pluginFacts(card());
  assert.deepEqual(said.body.lines, ['npm run dev -- --port 5173', 'echo "ready ✓"']);
  assert.equal(said.body.size, '2 lines, 43 bytes', 'bytes of UTF-8, as the command line counts them');
  assert.equal(said.asker, 'Worker: fix-login');
  assert.deepEqual(said.facts, [{ label: 'In the folder', value: '/home/u/site', folder: true }]);
  assert.deepEqual(said.actions.map((a) => a.line), ['vibeswitcher answer 0a1b2c3d run', 'vibeswitcher answer 0a1b2c3d decline']);
  assert.equal(said.outcome, null);
  assert.equal(pluginFacts(card({}, { state: 'started', outcome: 'Started: session “Shell: dev server”' })).outcome, 'Started: session “Shell: dev server”');
});

test('a session shows its own open shell cards only, oldest first', () => {
  const mine = card();
  const later = card({ id: 'local:card:0a1b2c3d-0000-4000-8000-00000000000b', at: '2026-11-21T10:05:00.000Z' });
  const other = card({ id: 'local:card:0a1b2c3d-0000-4000-8000-00000000000c' }, { session: 'local:other' });
  const closed = card({ id: 'local:card:0a1b2c3d-0000-4000-8000-00000000000d', open: false });
  const question = { ...card(), kind: 'question' };
  assert.deepEqual(pluginCardsOf([later, other, closed, question, mine], 'LOCAL:3F6C2C1E-8A5B-4C1D-9E0F-2B7A6D5C4E3F').map((c) => c.id), [mine.id, later.id]);
});

test('a new shell card is told as one, its asker and command’s first line', () => {
  const state = (cards) => ({ sessions: new Map(), leads: new Map(), cards: new Map(cards.map((c) => [c.id, c])), cardKeys: new Map() });
  const told = changes(summarize(state([])), summarize(state([card()])));
  assert.equal(told.length, 1);
  assert.ok(told[0].title.startsWith('A shell asked for'), told[0].title);
  assert.equal(told[0].body, 'Worker: fix-login: npm run dev -- --port 5173');
});

// The card drawn (views/cards.js's pluginCard) on a small stand-in DOM: the command as text, never markup; the only
// buttons copy a line; a settled card says what became of it and offers nothing to copy.
class FakeNode {
  constructor(tag, text) { this.tag = tag; this.text = text ?? null; this.children = []; this.attrs = {}; this.dataset = {}; this.handlers = {}; }
  append(...nodes) { this.children.push(...nodes); }
  setAttribute(name, value) { this.attrs[name] = value; }
  addEventListener(name, fn) { this.handlers[name] = fn; }
  get textContent() { return this.text ?? this.children.map((c) => c.textContent).join(''); }
  set textContent(value) { this.text = value; this.children = []; }
  all(tag) { return [...(this.tag === tag ? [this] : []), ...this.children.flatMap((c) => c.all(tag))]; }
}

test('the card shows the command whole as text, and its only buttons copy the lines', async () => {
  const before = { Node: globalThis.Node, document: globalThis.document };
  globalThis.Node = FakeNode;
  globalThis.document = { createElement: (tag) => new FakeNode(tag), createElementNS: (_, tag) => new FakeNode(tag), createTextNode: (text) => new FakeNode('#text', text) };
  try {
    const { pluginCard } = await import('../js/views/cards.js');
    const markup = card({}, { body: { ...shell().body, lines: ['<img src=x onerror=alert(1)>', 'rm -rf "$HOME/tmp"'] } });
    const el = pluginCard(markup);
    assert.equal(el.all('pre')[0].children.length, 1);
    assert.equal(el.all('pre')[0].children[0].tag, '#text', 'the command is one text node');
    assert.equal(el.all('pre')[0].textContent, '<img src=x onerror=alert(1)>\nrm -rf "$HOME/tmp"');
    assert.deepEqual(el.all('img'), []);
    const text = el.textContent;
    for (const said of ['Worker: fix-login', '/home/u/site', '2 lines', 'vibeswitcher answer 0a1b2c3d run', 'vibeswitcher answer 0a1b2c3d decline', 'Shell: dev server']) assert.ok(text.includes(said), said);
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
