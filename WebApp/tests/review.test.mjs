// What the lead's review of the mock found (2026-11-25), each held here: drawn on tests/fakedom.mjs's stand-in DOM
// with the node's own shapes (wire/vectors.json), in English and in Spanish. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { installDom, find, findAll, byClass, button } from './fakedom.mjs';

process.env.TZ = 'UTC';
const here = dirname(fileURLToPath(import.meta.url));
const vectors = JSON.parse(readFileSync(join(here, '..', 'wire', 'vectors.json'), 'utf8'));
const nodeValue = () => structuredClone(vectors['snapshot.node'].entries[0].value);

const dom = installDom();
const { setLanguage } = await import('../js/i18n.js');

// An app as the views read it: a store over `state`, the kinds this connection may send, whether it acts, and the
// requests sent (each answered by `reply`).
function fakeApp({ route = { name: 'node' }, state = {}, kinds = null, acts = true, reply = () => ({ ok: true, result: {} }) } = {}) {
  const sent = [];
  const store = {
    state: { node: null, connection: 'live', phrase: null, pageWords: null, sessions: new Map(), leads: new Map(), boards: new Map(), cards: new Map(),
      cardKeys: new Map(), acting: new Map(), draftRefused: new Map(), plugins: null, ...state },
    acts: () => acts,
    can: (kind) => kinds === null || kinds.includes(kind),
    subscribe() {},
    read: () => Promise.resolve({ ok: false, error: { code: 'unknown-kind' } }),
    request: (kind, args) => { sent.push({ kind, args }); return Promise.resolve(reply(kind, args)); },
    act: (card, kind, args) => sent.push({ kind, args: { card, ...args } }),
    cardKey: (id) => id,
    draftOf: () => null,
  };
  return { store, sent, ui: { state: { route }, subscribe() {}, go() {} } };
}

test('This node: a request it took as yours says how long ago as the other rows do, never an element’s name', async () => {
  setLanguage('en');
  const { nodeView } = await import('../js/views/node.js');
  const node = nodeValue();
  node.accepted = [{ kind: 'lead', action: 'b7e0c2d4-5a61-4f38-9c0b-1e2d3f4a5b6c', at: new Date(Date.now() - 90 * 60000).toISOString(), pid: 51022, cgroup: '/init.scope',
    commandLine: ['vibeswitcher', 'lead', '/home/dev/projects/example-site'] }];
  const app = fakeApp({ state: { node } });
  const text = nodeView(app).el.textContent;
  assert.doesNotMatch(text, /\[object /);
  assert.match(text, /vibeswitcher lead \/home\/dev\/projects\/example-site · 1h 30m ago · \/init\.scope/);
});
