// This node's Logs (the no-terminal inventory's C8): the node's `logs` read, what `vibeswitcher logs` shows, masked by
// the node: read when the group is first shown and at Refresh, the lines drawn as text (never markup), Copy taking
// exactly the lines shown, and each read saying what happened, in English and Spanish; the mock answers `logs` as the
// node does. Drawn on tests/fakedom.test.mjs's stand-in DOM. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { installDom, find, findAll, byClass, button } from './fakedom.test.mjs';

installDom();
const { setLanguage } = await import('../js/i18n.js');
const { logsGroup, nodeView } = await import('../js/views/node.js');
const { createMock } = await import('../js/mock.js');

const settle = () => new Promise((resolve) => setImmediate(resolve));
const LINES = ['2026-11-26T09:00:00Z session e91d05a3 started for the user (pts/7)', '2026-11-26T09:00:01Z exported TOKEN=••• before the run',
  '2026-11-26T09:00:02Z <b>not markup</b> & <img src=x onerror=alert(1)>'];

function rig(reply = (args) => ({ ok: true, result: { log: args.sessions ? 'sessions' : 'node', lines: LINES, cut: 0, why: null } })) {
  const asked = [];
  const app = { store: { read: (kind, args) => { asked.push({ kind, args }); return Promise.resolve(reply(args)); } } };
  return { app, asked, group: logsGroup(app) };
}
const lines = (el) => find(el, byClass('log-lines'));
const status = (el) => find(el, byClass('logs-status'));

test('C8: Logs reads the node’s log when first shown, never before, and draws its lines as text, newest last', async () => {
  setLanguage('en');
  const r = rig();
  assert.equal(r.asked.length, 0, 'nothing read until the group is shown');
  r.group.refresh(true);
  assert.match(status(r.group.el).textContent, /Reading the log…/);
  await settle();
  assert.deepEqual(r.asked, [{ kind: 'logs', args: {} }]);
  assert.equal(lines(r.group.el).textContent, LINES.join('\n'));
  assert.equal(findAll(lines(r.group.el), (node) => node.tag !== '#text' && node !== lines(r.group.el)).length, 0, 'text only: no element from a line');
  assert.match(status(r.group.el).textContent, /^The last 3 lines, read at \d\d:\d\d\. Secrets in them are masked\.$/);
  r.group.refresh(true);
  await settle();
  assert.equal(r.asked.length, 1, 'shown again: not read again on its own');
});

test('C8: Refresh reads again and says when; Sessions asks for the session log; the oldest left out are counted', async () => {
  setLanguage('en');
  let cut = 0;
  const r = rig((args) => ({ ok: true, result: { log: args.sessions ? 'sessions' : 'node', lines: LINES.slice(0, 2), cut, why: null } }));
  r.group.refresh(true);
  await settle();
  cut = 120;
  find(r.group.el, button('Refresh')).click();
  assert.equal(find(r.group.el, button('Refresh')).getAttribute('aria-busy'), 'true', 'busy while it reads');
  await settle();
  assert.equal(find(r.group.el, button('Refresh')).getAttribute('aria-busy'), null);
  assert.match(status(r.group.el).textContent, /The last 2 lines, read at \d\d:\d\d\. Secrets in them are masked\. 120 older ones are left out to keep this short\./);
  const sessions = find(r.group.el, (node) => node.tag === 'button' && node.textContent === 'Sessions');
  sessions.click();
  assert.equal(sessions.getAttribute('aria-pressed'), 'true');
  await settle();
  assert.deepEqual(r.asked.map((one) => one.args), [{}, {}, { sessions: true }]);
});

test('C8: Copy takes exactly the lines shown; no lines, no Copy', async () => {
  setLanguage('en');
  let copied = null;
  const before = globalThis.navigator;
  Object.defineProperty(globalThis, 'navigator', { value: { platform: 'MacIntel', clipboard: { writeText: async (text) => { copied = text; } } }, configurable: true });
  try {
    const r = rig();
    const copy = find(r.group.el, byClass('copy-button'));
    assert.equal(copy.hidden, true, 'nothing to copy before a read');
    r.group.refresh(true);
    await settle();
    assert.equal(copy.hidden, false);
    copy.click();
    await settle();
    assert.equal(copied, LINES.join('\n'));
    assert.match(copy.textContent, /Copied/, 'it says it copied');
  } finally {
    Object.defineProperty(globalThis, 'navigator', { value: before, configurable: true });
  }
});

test('C8: no lines says why in the page’s words (no tool’s name); a refusal says the node’s reason; in Spanish too', async () => {
  for (const [why, words] of [['not there yet', /it hasn’t been written yet/], ['scratch node: no journal, no manager', /this node keeps no system journal/],
    ["journalctl --user didn't answer", /the system’s journal didn’t answer/]]) {
    setLanguage('en');
    const r = rig(() => ({ ok: true, result: { log: 'node', lines: [], cut: 0, why } }));
    r.group.refresh(true);
    await settle();
    assert.match(status(r.group.el).textContent, words);
    assert.doesNotMatch(status(r.group.el).textContent, /journalctl/);
    assert.equal(lines(r.group.el).hidden, true);
  }
  const refused = rig(() => ({ ok: false, error: { code: 'voice', message: 'this page’s token doesn’t read' } }));
  refused.group.refresh(true);
  await settle();
  assert.match(status(refused.group.el).textContent, /The node didn’t give its logs: this page’s token doesn’t read/);
  setLanguage('es');
  const es = rig();
  assert.ok(find(es.group.el, button('Actualizar')) && find(es.group.el, (node) => node.tag === 'button' && node.textContent === 'Sesiones'));
  es.group.refresh(true);
  await settle();
  assert.match(status(es.group.el).textContent, /Las últimas 3 líneas, leídas a las \d\d:\d\d\. Los secretos que contienen van ocultos\./);
  setLanguage('en');
});

test('C8: This node lists Logs only where the node takes it', () => {
  setLanguage('en');
  const node = { host: { state: 'connected', notes: {} }, server: {}, builds: {}, notices: [] };
  for (const [kinds, listed] of [[['logs'], true], [[], false]]) {
    const store = { state: { node, connection: 'live', phrase: null, pageWords: null, cards: new Map(), sessions: new Map(), leads: new Map(), boards: new Map(), cardKeys: new Map(), acting: new Map(), draftRefused: new Map() }, acts: () => false, can: (kind) => kinds.includes(kind),
      subscribe() {}, read: () => Promise.resolve({ ok: false }) };
    const view = nodeView({ store, ui: { state: { route: { name: 'node', group: 'host' } }, subscribe() {} } });
    const keys = findAll(view.columns.rows, byClass('tc-row')).map((row) => row.dataset.key);
    assert.equal(keys.includes('logs'), listed, `${kinds}: ${keys}`);
  }
});

test('C8: the mock answers logs as the node does: the node’s or the session log, at most lines, a bad count refused', async () => {
  const store = { apply() {}, setConnection() {}, setKinds() {}, setPhrase() {}, setPageWords() {} };
  const mock = createMock(store, { still: true });
  assert.ok(mock.kinds.includes('logs'));
  const node = await mock.request({ kind: 'logs', args: {} });
  assert.equal(node.result.log, 'node');
  assert.ok(node.result.lines.length > 0 && node.result.lines.every((line) => typeof line === 'string'));
  const sessions = await mock.request({ kind: 'logs', args: { sessions: true, lines: 2 } });
  assert.equal(sessions.result.log, 'sessions');
  assert.equal(sessions.result.lines.length, 2);
  assert.equal((await mock.request({ kind: 'logs', args: { lines: 0 } })).error.code, 'bad-args');
  mock.stop();
});
