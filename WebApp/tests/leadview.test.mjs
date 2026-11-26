// The lead view and the roadmap at the bar (the design review of 2026-11-25, group E): one header height in Lead and
// Roadmap with the switch where nothing moves it (D11), one scroll for the centre at every width that keeps what is
// being read where it is (D10), a task and a goal opening and closing in place over the short motion (D22), and the
// roadmap's goals as rows with the rows' badges (D28). Drawn on tests/fakedom.test.mjs's stand-in DOM, with style.css
// read as tests/phone.test.mjs reads it; the pixels themselves are measured in Chrome (the task's report).
// Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { installDom, find, findAll, byClass, FakeNode } from './fakedom.test.mjs';

process.env.TZ = 'UTC';
installDom();
const { setLanguage } = await import('../js/i18n.js');
const kit = await import('../js/kit.js');
const { lineKey } = await import('../js/conversation.js');

// ---- style.css's rules, by media ('' outside any) ----
const here = dirname(fileURLToPath(import.meta.url));
const css = readFileSync(join(here, '..', 'style.css'), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');
function rules(source = css) {
  const found = [];
  const walk = (text, media) => {
    let at = 0;
    while (at < text.length) {
      const open = text.indexOf('{', at);
      if (open < 0) break;
      const head = text.slice(at, open).trim();
      let depth = 1; let end = open + 1;
      while (end < text.length && depth) { if (text[end] === '{') depth++; else if (text[end] === '}') depth--; end++; }
      const body = text.slice(open + 1, end - 1);
      if (head.startsWith('@media')) walk(body, head.slice(6).trim());
      else if (head.startsWith('@keyframes')) found.push({ media, selector: head, body });
      else if (!head.startsWith('@supports')) found.push({ media, selector: head, body });
      at = end;
    }
  };
  walk(source, '');
  return found;
}
const RULES = rules();
function declarations(body) {
  const out = {};
  for (const part of body.split(';')) {
    const colon = part.indexOf(':');
    if (colon < 0) continue;
    out[part.slice(0, colon).trim()] = part.slice(colon + 1).trim();
  }
  return out;
}
const listed = (rule) => rule.selector.split(/,(?![^(]*\))/).map((one) => one.trim());
function under(media, selector) {
  const out = {};
  for (const rule of RULES) if (rule.media === media && listed(rule).includes(selector)) Object.assign(out, declarations(rule.body));
  return out;
}
const PHONE = '(max-width: 760px)';

// A desktop: no media query matches (the phone's 760 px, reduced motion). Set before a view is made: it asks once.
const desktop = () => { globalThis.matchMedia = () => ({ matches: false, addEventListener() {} }); };
const reduced = () => { globalThis.matchMedia = (query) => ({ matches: query.includes('reduce'), addEventListener() {} }); };

// ---- A project, its lead, its board ----
const P = 'local:project:site';
const ROOT = '/home/dev/projects/example-site';
const at = (minutes) => new Date(Date.UTC(2026, 10, 26, 9, minutes)).toISOString();
const lead = { project: P, root: ROOT, session: 'local:lead', named: null, bound: 'local:lead', replaced: [], held: 0, reportsWaiting: 0, notice: null,
  starting: false, looks: 1, questions: { open: 0, blocking: 0 }, cards: [], told: [] };
const task = (slug, status, extra = {}) => ({ id: slug, slug, title: `Task ${slug}`, status, group: status === 'done' ? 'done' : 'running', state: status, line: '', after: [],
  checkpoints: [], startedAt: at(0), ...extra });
const results = Array.from({ length: 20 }, (_, n) => ({ id: `r${n}`, title: `Result ${n}`, body: '', at: at(10 + n * 2) }));
const board = (more = {}) => ({ project: P, root: ROOT, baseBranch: 'main', counts: { attention: 0, running: 1, waiting: 0, done: 0 }, more: 0, unreadable: null,
  tasks: [task('one', 'running')], answered: [], results, decisions: [], ...more });

function fakeApp({ route, boards = new Map([[P, board()]]), cards = [] }) {
  const listeners = [];
  const store = {
    state: { node: null, connection: 'live', phrase: null, pageWords: null, sessions: new Map(), leads: new Map([[P, lead]]), boards, cards: new Map(cards.map((card) => [card.id, card])),
      cardKeys: new Map(), acting: new Map(), draftRefused: new Map(), plugins: null },
    acts: () => true, can: () => true, follows: () => true, watches: () => true, subscribe() {}, read: () => Promise.resolve({ ok: false }),
    request: () => Promise.resolve({ ok: true, result: {} }), act() {}, cardKey: (id) => id, draftOf: () => null, sessionDraft() {}, chatOf: () => null,
  };
  const ui = { state: { route }, subscribe(fn) { listeners.push(fn); }, go() {}, setPalette() {}, pane: () => 'chat', setPane() {},
    inspectorShown: () => false, inspectorWide: () => true, toggleInspector() {} };
  return { store, ui, drawer() {} };
}
const sheet = { open() {}, close() {}, shown: () => false };
const leadRoute = (more = {}) => ({ name: 'project', id: P, view: 'lead', show: 'decisions', tab: 'team', task: null, open: [], ...more });
const roadRoute = (open = []) => ({ name: 'project', id: P, view: 'roadmap', show: 'decisions', tab: 'team', task: null, open });

// ---- D11: one header height, the switch where nothing moves it ----

test('D11: the header is one row at the columns’ header height in Lead and Roadmap, the switch first, the dial at its end', async () => {
  desktop();
  const { projectView } = await import('../js/views/project.js');
  const head = under('', '.project-view .centre-head');
  assert.equal(head.height, 'var(--head)', 'the left and right columns’ header height');
  assert.equal(head['flex-wrap'], 'nowrap', 'never a second row wider than a phone');
  assert.equal(under(PHONE, '.project-view .centre-head').height, 'auto', 'a phone’s header is its own two rows');
  for (const route of [leadRoute(), roadRoute()]) {
    const view = projectView(fakeApp({ route }), { sheet });
    view.render();
    const row = find(view.el, byClass('centre-head'));
    const shown = row.children.filter((node) => !node.classList.contains('phone-only'));
    assert.ok(shown[0].classList.contains('segmented') && !shown[0].classList.contains('dial'), `${route.view}: Lead | Roadmap first`);
    const kinds = row.children.map((node) => node.classList.contains('grow') ? 'grow' : node.classList.contains('dial') ? 'dial' : node.classList.contains('head-words') ? 'words' : '');
    assert.ok(kinds.indexOf('words') < kinds.indexOf('grow') && kinds.indexOf('grow') < kinds.indexOf('dial'), `${route.view}: the words, then the dial at the end`);
  }
});

test('D11: where the row can’t hold it, the dial folds behind its button, then the sentence gives way to its count; never a second row', async () => {
  desktop();
  const { projectView } = await import('../js/views/project.js');
  setLanguage('es');
  const view = projectView(fakeApp({ route: leadRoute() }), { sheet });
  const head = find(view.el, byClass('centre-head'));
  const name = find(head, byClass('pname'));
  let need = { open: 820, folded: 640, short: 420 };
  head.clientWidth = 600;
  Object.defineProperty(head, 'scrollWidth', { get: () => (head.classList.contains('words-short') ? need.short : head.classList.contains('dial-folded') ? need.folded : need.open) });
  name.clientWidth = 90; name.scrollWidth = 90;
  view.render();
  assert.ok(head.classList.contains('dial-folded') && head.classList.contains('words-short'), 'too narrow for the dial and the sentence');
  need = { open: 820, folded: 560, short: 420 };
  view.render();
  assert.ok(head.classList.contains('dial-folded') && !head.classList.contains('words-short'), 'the folded dial is enough');
  need = { open: 580, folded: 500, short: 420 };
  view.render();
  assert.ok(!head.classList.contains('dial-folded') && !head.classList.contains('words-short'), 'room for all of it');
  // The folded dial and the count are drawn at every width, not only a phone's.
  assert.equal(under('', '.project-view .centre-head.dial-folded > .dial-fold:not([hidden])').display, 'inline-flex');
  assert.equal(under('', '.project-view .centre-head.dial-folded > .dial').position, 'absolute');
  assert.equal(under('', '.project-view .centre-head.words-short .big').position, 'absolute', 'the sentence stays for a screen reader');
  assert.equal(under('', '.project-view .centre-head:not(.words-short) > .head-count').display, 'none');
  setLanguage('en');
});

// ---- D10: one scroll that keeps what is being read ----

test('D10: the centre is one scroll at every width: the conversation, then what waits, the box pinned under it; nothing scrolls inside', async () => {
  desktop();
  const { projectView } = await import('../js/views/project.js');
  const view = projectView(fakeApp({ route: leadRoute() }), { sheet });
  view.render();
  const scroll = find(view.el, byClass('centre-scroll'));
  assert.deepEqual(scroll.children.map((node) => node.attrs.class), ['talk', 'wait-box']);
  assert.equal(view.el.children.indexOf(find(view.el, byClass('composer-lead'))), view.el.children.indexOf(scroll) + 1, 'the box under the scroll, outside it');
  assert.equal(under('', '.project-view .centre-scroll')['overflow-y'], 'auto');
  assert.equal(under('', '.project-view .centre-scroll > .talk').overflow, 'visible');
  assert.equal(under('', '.project-view .centre-scroll > .wait-box').overflow, 'visible');
  assert.equal(under('', '.project-view .centre-scroll > .wait-box')['max-height'], 'none');
  // At “What waits on me” the conversation is gone, not an empty pane taking half of the scroll above the cards.
  const asks = RULES.filter((rule) => rule.media === '' && /\.talk\b/.test(rule.selector) && /display:/.test(rule.body));
  assert.equal(asks.at(-1).selector, '.project-view.show-asks .centre-scroll > .talk', 'the last word on the pane’s display');
  assert.equal(declarations(asks.at(-1).body).display, 'none');
  for (const selector of ['.talk', '.wait-box']) {
    for (const rule of RULES.filter((one) => one.media === '' && listed(one).includes(selector))) {
      assert.ok(!/overflow-y|max-height/.test(rule.body), `${selector} has no scroll of its own: ${rule.body}`);
    }
  }
});

// A layout for the stand-in DOM: the conversation's rows one under another (a day line 20 px, a line 30, an answer's
// pill 40, anything else 20), then the waiting block (300 px while shown), in a box 300 px tall at y 100.
function laidOut(view, { waitFirst = false } = {}) {
  const scroll = find(view.el, byClass('centre-scroll'));
  const col = find(view.el, byClass('col'));
  const wait = find(view.el, byClass('wait-box'));
  const cardsIn = () => findAll(wait, (node) => node.classList.contains('card') && !node.hidden).length;
  const height = (node) => (node === wait ? (wait.hidden ? 0 : 100 + 200 * cardsIn()) : node.classList.contains('line') ? 30 : node.classList.contains('mine') ? 40 : 20);
  scroll.clientHeight = 300;
  scroll.scrollTop = 0;
  scroll.scrollHeight = 3000;
  scroll.querySelectorAll = () => findAll(scroll, (node) => !!node.dataset?.anchor);
  const rect = (top, size) => ({ top, bottom: top + size, height: size, left: 0, right: 600, width: 600 });
  const base = FakeNode.prototype.getBoundingClientRect;
  FakeNode.prototype.getBoundingClientRect = function () {
    if (this === scroll) return rect(100, 300);
    let y = 0;
    for (const node of waitFirst ? [wait, ...col.children] : [...col.children, wait]) {
      if (node === this) return rect(100 + y - scroll.scrollTop, height(node));
      y += height(node);
    }
    return base.call(this);
  };
  return { scroll, done: () => { FakeNode.prototype.getBoundingClientRect = base; } };
}

test('D10: a card answered while you read higher up: its question joins the conversation above you, and what you read stays put', async () => {
  desktop();
  const { projectView } = await import('../js/views/project.js');
  const boards = new Map([[P, board()]]);
  const view = projectView(fakeApp({ route: leadRoute(), boards }), { sheet });
  view.render();
  const { scroll, done } = laidOut(view);
  try {
    const line = (key) => find(view.el, (node) => node.dataset?.anchor === key);
    const top = (key) => line(key).getBoundingClientRect().top - 100;
    // Reading Result 10 at the top of the box, not at the end.
    scroll.scrollTop = 0;
    scroll.scrollTop = top(lineKey('result', 'r10'));
    scroll.dispatch('scroll');
    assert.equal(top(lineKey('result', 'r10')), 0);
    // The question asked between Result 3 and Result 4 is answered: its line and its answer arrive above.
    boards.set(P, board({ answered: [{ id: 'q1', text: 'Ship it on Thursday?', answer: 'Thursday', state: 'answered', at: at(17) }] }));
    view.render();
    assert.ok(line(lineKey('ask', 'q1')), 'the answered question is in the conversation');
    assert.equal(top(lineKey('result', 'r10')), 0, 'Result 10 where it was');
  } finally { done(); }
});

const baseCard = (n) => ({ id: `local:card:base${n}`, kind: 'base', project: P, root: ROOT, open: true, closed: null, notice: null, at: at(n), blocking: true,
  base: { branch: 'main', from: 'aaaaaaa', fromIs: null, to: `bbbbbb${n}`, reason: 'moved', commits: [] } });

test('D10 on a phone: a card arriving above what you read (what waits comes first there) leaves what you read where it was', async () => {
  globalThis.matchMedia = (query) => ({ matches: query.includes('760'), addEventListener() {} });
  const { projectView } = await import('../js/views/project.js');
  const app = fakeApp({ route: leadRoute(), cards: [baseCard(1)] });
  const view = projectView(app, { sheet });
  const { scroll, done } = laidOut(view, { waitFirst: true });
  try {
    view.render();
    const line = (key) => find(view.el, (node) => node.dataset?.anchor === key);
    const top = (key) => line(key).getBoundingClientRect().top - 100;
    scroll.scrollTop = 0;
    scroll.scrollTop = top(lineKey('result', 'r10'));
    scroll.dispatch('scroll');
    assert.equal(top(lineKey('result', 'r10')), 0);
    // A second card arrives: the waiting block, above, grows by its height.
    app.store.state.cards.set(baseCard(2).id, baseCard(2));
    view.render();
    assert.equal(findAll(find(view.el, byClass('wait-box')), (node) => node.classList.contains('card') && !node.hidden).length, 2, 'the second card is drawn');
    assert.equal(top(lineKey('result', 'r10')), 0, 'Result 10 where it was');
  } finally { done(); desktop(); }
});

test('D10 on a desktop: a project opens on the conversation’s end with the top of what waits in sight, never at the bottom of its last card', async () => {
  desktop();
  const { projectView } = await import('../js/views/project.js');
  const app = fakeApp({ route: leadRoute(), cards: [baseCard(1), baseCard(2)] });
  const view = projectView(app, { sheet });
  const { scroll, done } = laidOut(view);
  try {
    view.render();
    const wait = find(view.el, byClass('wait-box'));
    // The waiting block (500 px) is taller than 60% of the 300 px view: its top 40% down the view.
    assert.equal(wait.getBoundingClientRect().top - 100, 120);
  } finally { done(); }
});

// ---- D22: opening and closing in place ----

test('D22: kit.unfold opens over the short motion once, folds away the same way, and does neither under reduced motion', () => {
  desktop();
  const opening = kit.unfold({ motion: 'opening' }, 'details');
  assert.ok(opening.classList.contains('unfold') && opening.classList.contains('opening'));
  opening.dispatch('animationend', { target: opening });
  assert.ok(!opening.classList.contains('opening'), 'once open, simply there');
  let closed = 0;
  const closing = kit.unfold({ motion: 'closing', onclosed: () => { closed += 1; } }, 'details');
  assert.ok(closing.classList.contains('closing'));
  assert.equal(closing.getAttribute('aria-hidden'), 'true', 'what folds away is gone for a screen reader at once');
  closing.dispatch('animationend', { target: closing });
  assert.equal(closed, 1, 'the caller draws again without it');
  assert.ok(!kit.unfold({}, 'details').classList.contains('opening'), 'drawn again open: no motion');
  // The motion: the short token, eased, from no height.
  assert.match(under('', '.unfold.opening').animation, /^unfold var\(--dur-2\) var\(--ease-out\)$/);
  assert.match(under('', '.unfold.closing').animation, /^unfold-away var\(--dur-2\) var\(--ease-in\)/);
  const frames = RULES.find((rule) => rule.selector === '@keyframes unfold');
  assert.match(frames.body, /from \{ grid-template-rows: 0fr;/);
  reduced();
  const still = kit.unfold({ motion: 'opening' }, 'details');
  assert.ok(!still.classList.contains('opening'), 'reduced motion: none');
  desktop();
});

test('D22: what folds away where it isn’t drawn (a hidden column) is gone all the same, by twice the motion’s time', async () => {
  desktop();
  let closed = 0;
  const el = kit.unfold({ motion: 'closing', onclosed: () => { closed += 1; } }, 'details');
  assert.ok(el.classList.contains('closing'));
  await new Promise((resolve) => setTimeout(resolve, 0)); // after the fold's own timer, made first
  assert.equal(closed, 1, 'no animationend came, and it closed');
  assert.ok(!el.classList.contains('closing'));
  el.dispatch('animationend', { target: el });
  assert.equal(closed, 1, 'once');
});

test('D22: reduced motion: what closes is gone at once', async () => {
  reduced();
  let closed = 0;
  const el = kit.unfold({ motion: 'closing', onclosed: () => { closed += 1; } }, 'details');
  assert.ok(!el.classList.contains('closing'));
  await Promise.resolve();
  assert.equal(closed, 1);
  desktop();
});

test('D22: a task opens in place once when the address opens it, not at every redraw, and folds away when closed', async () => {
  desktop();
  const { rightColumn } = await import('../js/views/right.js');
  const boards = new Map([[P, board({ tasks: [task('one', 'running'), task('two', 'running')] })]]);
  const app = fakeApp({ route: leadRoute(), boards });
  const right = rightColumn(app);
  right.render();
  assert.equal(findAll(right.el, byClass('unfold')).length, 0);
  app.ui.state.route = leadRoute({ task: 'one' });
  right.render();
  const opened = find(right.el, byClass('unfold'));
  assert.ok(opened && opened.classList.contains('opening'), 'opened by the address: it unfolds');
  boards.set(P, board({ tasks: [task('one', 'running', { line: 'moved on' }), task('two', 'running')] }));
  right.render();
  assert.ok(!find(right.el, byClass('unfold')).classList.contains('opening'), 'drawn again for a task that moved: just there');
  app.ui.state.route = leadRoute();
  right.render();
  const closing = find(right.el, byClass('unfold'));
  assert.ok(closing && closing.classList.contains('closing'), 'closed: it folds away');
  closing.dispatch('animationend', { target: closing });
  assert.equal(findAll(right.el, byClass('unfold')).length, 0, 'then it is gone');
});

// ---- D28 and D22: the roadmap's goals ----

const goals = [{ id: 'g1', title: 'The new landing page is live and every page loads fast on a phone over a slow connection', state: 'open', done: 'The hero is on main' },
  { id: 'g2', title: 'Uploads never lose work', state: 'open', done: null }];
const goalBoard = (more = {}) => board({ goals, tasks: [task('one', 'running', { goal: 'g1' }), task('two', 'done', { goal: 'g1', group: 'done', finishedAt: new Date().toISOString() }),
  task('three', 'planned', { goal: 'g2', group: 'waiting' })], ...more });

test('D28: a goal is a row: the whole row opens it, its counts are the rows’ badges, a long name keeps to two lines', async () => {
  desktop();
  const { projectView } = await import('../js/views/project.js');
  const view = projectView(fakeApp({ route: roadRoute(), boards: new Map([[P, goalBoard()]]) }), { sheet });
  view.render();
  const rows = findAll(view.el, byClass('goal-row'));
  assert.ok(rows.length >= 2);
  const first = find(rows[0], byClass('goal-title'));
  assert.equal(first.getAttribute('title'), goals[0].title, 'the whole name on hover');
  const badges = findAll(rows[0], byClass('badge'));
  assert.ok(badges.length >= 1, 'its counts as badges');
  assert.ok(badges.every((one) => !one.classList.contains('working') || /marcha|motion/i.test(one.textContent)), 'working only for what moves');
  assert.equal(under('', '.goal-title::after').inset, '0', 'the title’s button covers the row');
  assert.equal(under('', '.goal-row > .road-when')['z-index'], '1', 'the date over the cover: its basis on a tap');
  assert.equal(under('', '.goal-name b')['-webkit-line-clamp'], '2');
  const hover = RULES.find((rule) => rule.media === '(hover: hover)' && rule.selector.includes('.goal-row') && /background-color: var\(--fill\)/.test(rule.body));
  assert.ok(hover, 'the row fills under the pointer as the list rows do');
  assert.equal(under('', '.goal-row')['border-radius'], 'var(--r-2)');
});

test('D22: a goal opens in place once when the address opens it, folds away when closed; the roadmap keeps its scroll', async () => {
  desktop();
  const { projectView } = await import('../js/views/project.js');
  const boards = new Map([[P, goalBoard()]]);
  const app = fakeApp({ route: roadRoute(), boards });
  const view = projectView(app, { sheet });
  view.render();
  const scroll = find(view.el, byClass('centre-scroll'));
  scroll.scrollTop = 240;
  app.ui.state.route = roadRoute(['g1']);
  view.render();
  const opened = find(view.el, byClass('unfold'));
  assert.ok(opened && opened.classList.contains('opening'), 'opened: it unfolds');
  assert.equal(scroll.scrollTop, 240, 'where it was scrolled, not back at the top');
  boards.set(P, goalBoard({ tasks: [task('one', 'running', { goal: 'g1', line: 'moved on' }), task('three', 'planned', { goal: 'g2', group: 'waiting' })] }));
  view.render();
  assert.ok(!find(view.el, byClass('unfold')).classList.contains('opening'), 'drawn again: just there');
  app.ui.state.route = roadRoute();
  view.render();
  const closing = find(view.el, byClass('unfold'));
  assert.ok(closing && closing.classList.contains('closing'), 'closed: it folds away');
  closing.dispatch('animationend', { target: closing });
  assert.equal(findAll(view.el, byClass('unfold')).length, 0);
  // Another project's roadmap, or the roadmap opened again: from its top.
  app.ui.state.route = leadRoute();
  view.render();
  scroll.scrollTop = 300;
  app.ui.state.route = roadRoute();
  view.render();
  assert.equal(scroll.scrollTop, 0);
});
