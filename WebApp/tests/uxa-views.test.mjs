// The UX review's small states (2026-11-25), drawn on tests/fakedom.test.mjs's stand-in DOM: U19 a project that is gone,
// U22 a question the lead withdrew, U23 Brief me and the palette from a phone's drawer (their stylesheet's part, and
// U18's and U21's, in tests/uxa.test.mjs). Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { installDom, find, findAll, byClass } from './fakedom.test.mjs';

process.env.TZ = 'UTC';
installDom();
const { setLanguage } = await import('../js/i18n.js');

const P = 'local:project:site';
function fakeApp({ route, boards = new Map(), leads = new Map() }) {
  const calls = [];
  const store = {
    state: { node: null, connection: 'live', phrase: null, pageWords: null, sessions: new Map(), leads, boards, cards: new Map(),
      cardKeys: new Map(), acting: new Map(), draftRefused: new Map(), plugins: null },
    acts: () => true, can: () => true, subscribe() {}, read: () => Promise.resolve({ ok: false }), request: () => Promise.resolve({ ok: true, result: {} }),
    act() {}, cardKey: (id) => id, draftOf: () => null,
  };
  const ui = { state: { route }, subscribe() {}, go() {}, setPalette: (open) => calls.push(['palette', open]) };
  return { store, ui, calls, drawer: (which) => calls.push(['drawer', which]) };
}

test('U19: a project that is gone says so and offers the start page', async () => {
  const { projectView } = await import('../js/views/project.js');
  for (const [code, words] of [['en', 'Start Page'], ['es', 'Página de inicio']]) {
    setLanguage(code);
    const view = projectView(fakeApp({ route: { name: 'project', id: 'local:project:gone', view: 'lead' } }), { sheet: { open() {}, close() {}, shown: () => false } });
    view.render();
    const gone = find(view.el, (node) => node.classList.contains('empty-state') && !node.hidden);
    assert.ok(gone, 'the gone page shows');
    const way = find(gone, (node) => node.tag === 'a' && node.attrs.href === '#/');
    assert.ok(way, 'a way out');
    assert.equal(way.textContent, words);
  }
  setLanguage('en');
});

test('U22: a question the lead withdrew has a muted line under it, with the lead’s reason, never an empty answer', async () => {
  const { projectView } = await import('../js/views/project.js');
  const at = new Date(Date.now() - 3600_000).toISOString();
  const lead = { project: P, root: '/home/dev/projects/example-site', session: 'local:lead', named: null, bound: 'local:lead', replaced: [], held: 0, reportsWaiting: 0,
    notice: null, starting: false, looks: 1, questions: { open: 0, blocking: 0 }, cards: [], told: [] };
  const board = { project: P, root: lead.root, baseBranch: 'main', counts: { attention: 0, running: 0, waiting: 0, done: 0 }, more: 0, unreadable: null, tasks: [],
    answered: [
      { id: 'q-footer', state: 'withdrawn', text: 'Should the footer link to the old blog?', answer: null, proposal: null, why: 'The blog moved; the link goes to the new one.', at },
      { id: 'q-cache', state: 'answered', text: 'Cache for a day or a year?', answer: 'A year', proposal: null, why: null, at },
    ] };
  for (const [code, words] of [['en', 'Withdrawn by the lead: The blog moved; the link goes to the new one.'], ['es', 'Retirada por el líder: The blog moved; the link goes to the new one.']]) {
    setLanguage(code);
    const app = fakeApp({ route: { name: 'project', id: P, view: 'lead', show: 'all' }, boards: new Map([[P, board]]), leads: new Map([[P, lead]]) });
    const view = projectView(app, { sheet: { open() {}, close() {}, shown: () => false } });
    view.render();
    const lines = findAll(view.el, byClass('line'));
    const asked = lines.find((line) => line.textContent.includes('old blog'));
    assert.ok(asked, 'the withdrawn question’s line');
    const siblings = asked.parentNode.children;
    const next = siblings[siblings.indexOf(asked) + 1];
    assert.ok(next?.classList.contains('withdrawn-note'), `under it: ${next?.attrs.class}`);
    assert.equal(next.textContent, words);
    // Only the withdrawn one: an answered question keeps its answer, no such line.
    assert.equal(findAll(view.el, byClass('withdrawn-note')).length, 1);
  }
  setLanguage('en');
});

test('U23: Brief me is a button with its mark; the drawer’s head opens the palette, which a phone has no ⌘K for', async () => {
  const { leftColumn } = await import('../js/views/left.js');
  const app = fakeApp({ route: { name: 'home' } });
  const left = leftColumn(app, { brief() {} });
  left.render();
  const brief = find(left.el, byClass('summary-brief'));
  assert.ok(find(brief, (node) => node.tag === 'svg'), 'Brief me has its mark');
  const open = find(find(left.el, byClass('colhead')), byClass('palette-open'));
  assert.ok(open && open.tag === 'button', 'a button in the drawer’s head');
  assert.ok(open.classList.contains('phone-only'), 'where there is no ⌘K: a phone or a narrow window');
  open.click();
  assert.deepEqual(app.calls, [['drawer', null], ['palette', true]]);
});
