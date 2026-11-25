// The UX review's small states (2026-11-25), drawn on tests/fakedom.mjs's stand-in DOM: U19 a project that is gone,
// U22 a question the lead withdrew, U23 Brief me and the palette from a phone's drawer; and the stylesheet's U18 and
// U21. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { installDom, find, findAll, byClass } from './fakedom.mjs';
import { rules, declarations } from './cssread.mjs';

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

// The cascade's result for `selector` among the rules outside any @media: the last declaration wins.
const computed = (selector) => Object.assign({}, ...rules().filter((rule) => rule.media === '' && rule.selector === selector).map((rule) => declarations(rule.body)));

test('U21: the team strip wraps to a second line where it doesn’t fit, each count whole; never scrolled out of sight', () => {
  const strip = computed('.team-strip');
  assert.equal(strip['flex-wrap'], 'wrap');
  assert.notEqual(strip['overflow-x'], 'auto');
  assert.equal(computed('.team-strip > *')['white-space'], 'nowrap');
});

test('U18: “Now” sits on a line of its own above the hours, the axis tall enough for both', () => {
  const now = parseFloat(computed('.axis-tick.now').top);
  const hour = parseFloat(computed('.axis-tick').top);
  // A line of the small size on a phone (12.5 px at 1.4): the hours start under it.
  assert.ok(hour - now >= 12.5 * 1.4, `now at ${now}px, the hours at ${hour}px`);
  assert.ok(parseFloat(computed('.axis').height) >= hour + 12.5 * 1.4, 'the axis holds both lines');
});
