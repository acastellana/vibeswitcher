// Reading the chat (the design review's group C): a session's question waits for the rows so it never jumps as they
// arrive (D14); one failure in a run of tools is its count in red, not the whole line (D13); your words and the agent's
// drawn with the same marks, links opening apart; a reply's time; on a touch screen a message's actions on a tap
// (D15); an empty chat says what to do.
// Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { installDom, find, findAll, byClass, FakeNode } from './fakedom.test.mjs';

const dom = installDom();
// A growing reply keeps the blocks that read the same (chat.js's patchChildren): the browser's isEqualNode, by structure.
FakeNode.prototype.isEqualNode ??= function isEqualNode(other) {
  return !!other && this.tag === other.tag && this.text === other.text && JSON.stringify(this.attrs) === JSON.stringify(other.attrs)
    && this.children.length === other.children.length && this.children.every((child, i) => child.isEqualNode(other.children[i]));
};
let touch = false;
globalThis.matchMedia = (query) => ({ matches: query.includes('hover: none') ? touch : false, addEventListener() {} });
globalThis.MutationObserver ??= class { observe() {} disconnect() {} };
globalThis.ResizeObserver ??= class { observe() {} unobserve() {} disconnect() {} };
const { chatView } = await import('../js/views/chat.js');
const { createStore } = await import('../js/store.js');
const { setLanguage, t } = await import('../js/i18n.js');

const SID = 'local:e91d05a3-4f6a-4c1e-9b7d-2e5a8c0d1f3b';
const AT = '2026-11-26T10:00:00.000Z';
function open(fields = {}) {
  const session = { id: SID, terminal: 'pts/7', agent: 'claude', cwd: '/home/dev/x', status: 'needs-you', hosted: true, sendWays: ['step', 'now'], ...fields };
  const store = createStore();
  store.connect({ request: () => Promise.resolve({ ok: true, result: {} }), subscribeChat() {}, unsubscribeChat() {}, resync() {} });
  store.setKinds(['send', 'chat.page'], null, ['read', 'draft', 'watch', 'act']);
  store.apply({ v: 1, kind: 'snapshot', epoch: 'e', seq: 0, state: { node: { home: '/home/dev', ended: [] }, sessions: [session], leads: [], cards: [], boards: [] } });
  const chat = chatView({ store, ui: { state: { route: { name: 'session', id: SID } }, subscribe() {}, go() {} } });
  chat.show(SID);
  return { chat, store };
}
const ITEMS = [
  { id: 'p1', type: 'prompt', at: AT, text: 'Is **this** right?\nSee https://example.com/a', steered: false, fromLead: false, images: [] },
  { id: 'tools:t1', type: 'tools', at: AT, summary: 'Ran 2 commands', tools: [
    { id: 't1', name: 'Bash', title: 'npm test', at: AT, detail: { type: 'command', command: 'npm test' }, result: { output: 'ok', failed: false, at: AT, images: [] } },
    { id: 't2', name: 'Bash', title: 'npm run lint', at: AT, detail: { type: 'command', command: 'npm run lint' }, result: { output: 'error', failed: true, at: AT, images: [] } }] },
  { id: 'r1', type: 'reply', at: AT, text: 'It is *mostly* right: see [the docs](https://example.com/docs).' },
];

test('D14: a session’s question is held back until the chat’s rows are drawn, then shown once, where it stays', () => {
  setLanguage('en');
  const { chat, store } = open({ prompt: { question: 'Proceed?', options: ['Yes', 'No'], text: [] } });
  const card = find(chat.el, byClass('session-prompt'));
  assert.ok(card.classList.contains('waiting-rows'), 'not drawn above rows that are still coming');
  store.chatSnapshot(SID, { items: ITEMS, after: null, more: false });
  chat.reveal();
  assert.ok(!card.classList.contains('waiting-rows'));
  assert.ok(!card.hidden);
});

test('D13: one failure in a run of tools is its count in the failure’s colour; the summary stays quiet', () => {
  setLanguage('es');
  const { chat, store } = open();
  store.chatSnapshot(SID, { items: ITEMS, after: null, more: false });
  chat.reveal();
  const fold = find(chat.el, byClass('fold'));
  assert.equal(find(fold, byClass('fold-text')).textContent, 'Ran 2 commands');
  assert.equal(find(fold, byClass('fold-failed')).textContent, t('chFailed', { n: 1 }));
  assert.ok(fold.classList.contains('failed'));
});

test('your words and the agent’s: the same marks, your lines kept, links opening apart; a reply’s time', () => {
  setLanguage('en');
  const { chat, store } = open();
  store.chatSnapshot(SID, { items: ITEMS, after: null, more: false });
  chat.reveal();
  const bubble = find(chat.el, byClass('bubble'));
  assert.ok(find(bubble, (node) => node.tag === 'strong' && node.textContent === 'this'));
  assert.ok(find(bubble, (node) => node.tag === 'br'), 'a new line you typed stays one');
  const links = findAll(chat.el, (node) => node.tag === 'a');
  assert.deepEqual(links.map((one) => [one.attrs.href, one.attrs.target, one.attrs.rel]),
    [['https://example.com/a', '_blank', 'noopener noreferrer'], ['https://example.com/docs', '_blank', 'noopener noreferrer']]);
  const reply = find(chat.el, (node) => node.classList.contains('chat-row') && node.classList.contains('reply'));
  assert.ok(find(reply, (node) => node.tag === 'em' && node.textContent === 'mostly'));
  assert.equal(find(reply, byClass('reply-time')).attrs.datetime, AT);
});

test('a reply that stops streaming is drawn again whole, its markers settled', () => {
  setLanguage('en');
  const { chat, store } = open();
  store.chatSnapshot(SID, { items: [{ id: 'r2', type: 'reply', at: AT, text: 'Done: **bold*', streaming: true }], after: null, more: false });
  chat.reveal();
  const prose = () => find(chat.el, (node) => node.classList.contains('prose') && !node.classList.contains('bubble'));
  assert.equal(findAll(prose(), (node) => node.tag === 'em' || node.tag === 'strong').length, 0, 'still arriving: the half marker waits');
  store.chatSnapshot(SID, { items: [{ id: 'r2', type: 'reply', at: AT, text: 'Done: **bold*' }], after: null, more: false });
  chat.reveal();
  assert.ok(find(prose(), (node) => node.tag === 'em'), 'whole: what it says stands');
});

test('D15: on a touch screen a message’s actions show on a tap on it, and go with a tap on another', () => {
  setLanguage('en');
  touch = true;
  const { chat, store } = open();
  store.chatSnapshot(SID, { items: ITEMS, after: null, more: false });
  chat.reveal();
  const rows = find(chat.el, byClass('chat-rows'));
  const [prompt, reply] = findAll(rows, (node) => node.classList.contains('prompt') || node.classList.contains('reply')).filter((node) => node.classList.contains('chat-row'));
  const tap = (row) => { const target = row.children.at(-1); target.closest = (selector) => (selector.includes('.chat-row') ? row : null); rows.dispatch('click', { target }); };
  tap(prompt);
  assert.ok(prompt.classList.contains('touched'));
  tap(reply);
  assert.ok(!prompt.classList.contains('touched'));
  assert.ok(reply.classList.contains('touched'));
  tap(reply);
  assert.ok(!reply.classList.contains('touched'), 'a second tap puts them away');
  touch = false;
});

test('an empty chat says what to do', () => {
  setLanguage('es');
  const { chat, store } = open({ status: 'idle' });
  store.chatSnapshot(SID, { items: [], after: null, more: false });
  chat.reveal();
  const empty = find(chat.el, (node) => node.classList.contains('pane-empty') && node.textContent.includes(t('chNoConversationForThisSession')));
  assert.ok(empty && !empty.hidden);
  assert.match(empty.textContent, new RegExp(t('cmEmptyWhat').slice(0, 20)));
});

test.after(() => dom.restore());
