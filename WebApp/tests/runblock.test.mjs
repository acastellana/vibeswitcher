// A reply's code block and its Run in the chat (P-s2): an untagged block whose only line reads as a command gets the
// same Run a tagged one does (left as the session's draft, nothing sent), a sentence in a bare fence gets none, and a
// Run pressed after the session stopped taking drafts here says so in words instead of doing nothing.
// Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { installDom, find, findAll, byClass, FakeNode } from './fakedom.test.mjs';

installDom();
FakeNode.prototype.isEqualNode ??= function isEqualNode(other) {
  return !!other && this.tag === other.tag && this.text === other.text && JSON.stringify(this.attrs) === JSON.stringify(other.attrs)
    && this.children.length === other.children.length && this.children.every((child, i) => child.isEqualNode(other.children[i]));
};
globalThis.matchMedia = () => ({ matches: false, addEventListener() {} });
globalThis.MutationObserver ??= class { observe() {} disconnect() {} };
globalThis.ResizeObserver ??= class { observe() {} unobserve() {} disconnect() {} };
const { chatView } = await import('../js/views/chat.js');
const { createStore } = await import('../js/store.js');
const { setLanguage, t } = await import('../js/i18n.js');

const SID = 'local:e91d05a3-4f6a-4c1e-9b7d-2e5a8c0d1f3b';
const AT = '2026-11-26T10:00:00.000Z';
const fence = '```';

function open(text) {
  const session = { id: SID, terminal: 'pts/7', agent: 'claude', cwd: '/home/dev/x', status: 'idle', hosted: true, sendWays: ['step', 'now'] };
  const requests = [];
  const store = createStore();
  store.connect({ request: (message) => { requests.push(message); return Promise.resolve({ ok: true, result: {} }); }, subscribeChat() {}, unsubscribeChat() {}, resync() {} });
  store.setKinds(['send', 'chat.page', 'session.draft'], null, ['read', 'draft', 'watch', 'act']);
  store.apply({ v: 1, kind: 'snapshot', epoch: 'e', seq: 0, state: { node: { home: '/home/dev', ended: [] }, sessions: [session], leads: [], cards: [], boards: [] } });
  const chat = chatView({ store, ui: { state: { route: { name: 'session', id: SID } }, subscribe() {}, go() {} }, later: () => () => {} });
  chat.show(SID);
  store.chatSnapshot(SID, { items: [{ id: 'r1', type: 'reply', at: AT, text }], after: null, more: false });
  chat.reveal();
  return { chat, store, requests };
}
const runs = (chat) => findAll(chat.el, byClass('code-run'));

test('P-s2: a bare fence holding one command line gets Run, which leaves `! command` as the session’s draft', () => {
  setLanguage('en');
  const { chat, store } = open(`Start the server:\n\n${fence}\ncd site && python3 -m http.server 8000\n${fence}\n`);
  const [run] = runs(chat);
  assert.ok(run, 'a Run on the untagged block');
  assert.equal(run.attrs.title, t('chRunTitle', { prompt: '! cd site && python3 -m http.server 8000' }));
  run.dispatch('click');
  assert.equal(store.sessionDraftOf(SID)?.text, '! cd site && python3 -m http.server 8000', 'drafted, not sent');
});

for (const language of ['', 'sh']) {
  test(`Run checks default-ignorable characters in a ${language || 'bare'} fence`, () => {
    const block = (filename) => open([fence + language, 'cat ' + filename, fence].join('\n'));
    assert.equal(runs(block('café.txt').chat).length, 1);
    assert.equal(runs(block('café\u180b.txt').chat).length, 0);
  });
}

test('P-s2: a bare fence holding a sentence or two lines gets no Run', () => {
  setLanguage('en');
  for (const body of ['Build succeeded.', 'npm install\nnpm run dev']) {
    const { chat } = open(`Here:\n\n${fence}\n${body}\n${fence}\n`);
    assert.equal(runs(chat).length, 0, body);
  }
});

test('P-s2: a Run pressed once the session no longer takes a draft here says so, and drafts nothing', () => {
  setLanguage('en');
  const { chat, store } = open(`${fence}\nnpm run dev\n${fence}\n`);
  const [run] = runs(chat);
  assert.ok(run);
  // The page lost the right to draft after Run was drawn.
  store.setKinds(['send', 'chat.page'], null, ['read', 'watch']);
  run.dispatch('click');
  assert.equal(store.sessionDraftOf(SID), null, 'nothing drafted');
  const notice = find(chat.el, byClass('composer-notice'));
  assert.ok(!notice.hidden, 'the notice shows');
  assert.equal(notice.children[0].textContent, t('chRunCant'));
  setLanguage('es');
  assert.notEqual(t('chRunCant'), 'chRunCant');
  assert.match(t('chRunCant'), /^No se ejecutó/);
  setLanguage('en');
});
