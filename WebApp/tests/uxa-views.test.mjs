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

// The cascade's result for `selector` among the rules outside any @media: the last declaration wins.
const computed = (selector) => Object.assign({}, ...rules().filter((rule) => rule.media === '' && rule.selector === selector).map((rule) => declarations(rule.body)));

test('U21: the team strip wraps to a second line where it doesn’t fit, each count whole; never scrolled out of sight', () => {
  const strip = computed('.team-strip');
  assert.equal(strip['flex-wrap'], 'wrap');
  assert.notEqual(strip['overflow-x'], 'auto');
  assert.equal(computed('.team-strip > *')['white-space'], 'nowrap');
});
