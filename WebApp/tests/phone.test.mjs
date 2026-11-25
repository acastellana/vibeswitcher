// The phone (2026-11-25, the UX review's U2 and U13): the lead view's header one row with Lead | Roadmap and the dial
// folded under it, the team strip one line that opens, one scroll with what waits first, the message box one row; a
// session's header one row with no tab that leads nowhere; the keyboard (js/viewport.js). Drawn on
// tests/fakedom.test.mjs's stand-in DOM, and style.css read as in tests/uxa.test.mjs. The heights themselves are
// measured in Chrome (the task's report). Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { installDom, find, findAll, byClass, FakeNode } from './fakedom.test.mjs';

process.env.TZ = 'UTC';
installDom();
const { setLanguage, t } = await import('../js/i18n.js');

// ---- style.css, as tests/uxa.test.mjs reads it (here, not shared: a tests' folder holds Node tests alone) ----
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
      else if (!head.startsWith('@keyframes') && !head.startsWith('@supports')) found.push({ media, selector: head, body });
      at = end;
    }
  };
  walk(source, '');
  return found;
}
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
// What `selector` gets from the rules under `media` ('' outside any), the later winning.
function under(media, selector) {
  const out = {};
  for (const rule of rules()) if (rule.media === media && listed(rule).includes(selector)) Object.assign(out, declarations(rule.body));
  return out;
}
const PHONE = '(max-width: 760px)';

// ---- A project, its lead and a card waiting ----
const P = 'local:project:site';
const ROOT = '/home/dev/projects/example-site';
const at = new Date(Date.now() - 600_000).toISOString();
const lead = { project: P, root: ROOT, session: 'local:lead', named: null, bound: 'local:lead', replaced: [], held: 0, reportsWaiting: 0, notice: null,
  starting: false, looks: 1, questions: { open: 0, blocking: 0 }, cards: [], told: [] };
const tasks = ['running', 'review', 'blocked', 'planned', 'done'].map((status, n) => ({ id: `t${n}`, slug: `task-${n}`, title: `Task ${n}`, status,
  group: status === 'done' ? 'done' : 'running', state: status, line: '', after: [], checkpoints: [] }));
const board = { project: P, root: ROOT, baseBranch: 'main', counts: { attention: 0, running: 3, waiting: 1, done: 1 }, more: 0, unreadable: null, tasks, answered: [] };
const baseCard = { id: 'local:card:base', kind: 'base', project: P, root: ROOT, open: true, closed: null, notice: null, at, blocking: true,
  base: { branch: 'main', from: 'aaaaaaa', fromIs: null, to: 'bbbbbbb', reason: 'moved', commits: [] } };

function fakeApp({ route, cards = [], leads = new Map([[P, lead]]), sessions = new Map(), can = () => true, feed = null }) {
  const calls = [];
  const store = {
    state: { node: null, connection: 'live', phrase: null, pageWords: null, sessions, leads, boards: new Map([[P, board]]), cards: new Map(cards.map((card) => [card.id, card])),
      cardKeys: new Map(), acting: new Map(), draftRefused: new Map(), plugins: null },
    acts: () => true, can, follows: () => true, watches: () => true, subscribe() {}, read: () => Promise.resolve({ ok: false }),
    request: () => Promise.resolve({ ok: true, result: {} }), act() {}, cardKey: (id) => id, draftOf: () => null, sessionDraft() {}, chatOf: () => null,
  };
  const listeners = [];
  const panes = new Map();
  const ui = { state: { route }, subscribe(fn) { listeners.push(fn); }, go() {}, setPalette() {}, pane: (id) => panes.get(id) || 'chat',
    setPane: (id, pane) => { panes.set(id, pane); calls.push(['pane', pane]); listeners.forEach((fn) => fn('pane')); },
    inspectorShown: () => false, inspectorWide: () => true, toggleInspector() {} };
  return { store, ui, calls, feed, drawer: (which) => calls.push(['drawer', which]) };
}
const sheet = { open() {}, close() {}, shown: () => false };

test('U2 phone: the lead view’s header is one row: the menu, the project’s name, what needs you as a count, the team', async () => {
  const { projectView } = await import('../js/views/project.js');
  setLanguage('es');
  const view = projectView(fakeApp({ route: { name: 'project', id: P, view: 'lead', show: 'decisions' }, cards: [baseCard] }), { sheet });
  view.render();
  const head = find(view.el, byClass('centre-head'));
  const count = find(head, byClass('head-count'));
  assert.ok(count && !count.hidden, 'the count shows while something waits');
  assert.equal(count.textContent, '1');
  // The whole sentence stays for a screen reader (clipped on a phone, not removed); the count is its short form.
  assert.equal(find(head, byClass('big')).textContent, '1 cosa de este proyecto te necesita');
  assert.equal(count.getAttribute('aria-hidden'), 'true');
  const big = under(PHONE, '.project-view .centre-head .big');
  assert.equal(big.position, 'absolute');
  assert.equal(big['clip-path'], 'inset(50%)');
  const grid = under(PHONE, '.project-view .centre-head');
  assert.equal(grid.display, 'grid');
  // Row 1 holds the menu, the name, the count and the team; row 2 Lead | Roadmap and the dial's fold.
  assert.equal(under(PHONE, '.project-view .centre-head > :first-child')['grid-row'], '1');
  assert.equal(under(PHONE, '.project-view .centre-head .pname')['grid-row'], '1');
  assert.equal(under(PHONE, '.project-view .head-count:not([hidden])')['grid-row'], '1');
  assert.equal(under(PHONE, '.project-view .centre-head .team-button')['grid-row'], '1');
  assert.equal(under(PHONE, '.project-view .centre-head > .switch:not(.dial)')['grid-row'], '2');
  assert.equal(under(PHONE, '.project-view .dial-fold:not([hidden])')['grid-row'], '2');
  // Wider, the phone's parts never show.
  assert.equal(under('', '.head-count').display, 'none');
  assert.equal(under('', '.dial-fold').display, 'none');
  assert.equal(under('', '.strip-fold').display, 'none');
  // Nothing waiting: no count.
  const quiet = projectView(fakeApp({ route: { name: 'project', id: P, view: 'lead', show: 'decisions' } }), { sheet });
  quiet.render();
  assert.ok(find(quiet.el, byClass('head-count')).hidden);
  setLanguage('en');
});

test('U2 phone: the dial folds behind one button saying the level shown and its count, opening the same three links', async () => {
  const { projectView } = await import('../js/views/project.js');
  for (const [code, words] of [['es', 'Decisiones'], ['en', 'Decisions']]) {
    setLanguage(code);
    const view = projectView(fakeApp({ route: { name: 'project', id: P, view: 'lead', show: 'decisions' }, cards: [baseCard] }), { sheet });
    view.render();
    const fold = find(view.el, byClass('dial-fold'));
    const dial = find(view.el, byClass('dial'));
    assert.ok(fold && fold.tag === 'button');
    assert.equal(fold.children[0].textContent, words, 'the short name of the level shown');
    assert.match(fold.getAttribute('aria-label'), new RegExp(t('dialDecisions')));
    assert.equal(findAll(dial, (node) => node.tag === 'a').length, 3, 'the same three links, in the dial');
    assert.equal(fold.getAttribute('aria-expanded'), 'false');
    fold.click();
    assert.ok(dial.classList.contains('open'));
    assert.equal(fold.getAttribute('aria-expanded'), 'true');
    // A link chosen closes it.
    const link = find(dial, (node) => node.tag === 'a');
    dial.dispatch('click', { target: { closest: () => link } });
    assert.ok(!dial.classList.contains('open'));
    // Esc closes it too.
    fold.click();
    dial.dispatch('keydown', { key: 'Escape' });
    assert.ok(!dial.classList.contains('open'));
    // The menu on a phone: over the page under its button, shown only while open.
    assert.equal(under(PHONE, '.project-view .centre-head > .dial').position, 'absolute');
    assert.equal(under(PHONE, '.project-view .centre-head > .dial').display, 'none');
    assert.equal(under(PHONE, '.project-view .centre-head > .dial.open:not([hidden])').display, 'flex');
  }
  setLanguage('en');
});

test('U2 phone: the team strip is one line of whole counts, with a fold that opens it to all of them', async () => {
  const { projectView } = await import('../js/views/project.js');
  const view = projectView(fakeApp({ route: { name: 'project', id: P, view: 'lead', show: 'decisions' } }), { sheet });
  view.render();
  const strip = find(view.el, byClass('team-strip'));
  const fold = find(strip, byClass('strip-fold'));
  assert.ok(fold && fold.tag === 'button', 'the fold is in the strip');
  const line = under(PHONE, '.project-view .team-strip');
  assert.equal(line['max-height'], '44px', 'one line');
  assert.equal(line.overflow, 'hidden');
  assert.equal(line['flex-wrap'], 'wrap', 'a count that doesn’t fit goes whole to the hidden line, never cut');
  assert.equal(under(PHONE, '.project-view .team-strip.open')['max-height'], 'none');
});

test('U2 phone: one scroll, what waits first and the conversation under it; no box scrolls inside it', async () => {
  const { projectView } = await import('../js/views/project.js');
  const view = projectView(fakeApp({ route: { name: 'project', id: P, view: 'lead', show: 'decisions' }, cards: [baseCard] }), { sheet });
  view.render();
  const scroll = find(view.el, byClass('centre-scroll'));
  assert.ok(scroll, 'the conversation and the waiting block share one box');
  assert.deepEqual(scroll.children.map((node) => node.attrs.class), ['talk', 'wait-box'], 'in the order the wide page draws them');
  assert.ok(!find(scroll, byClass('wait-box')).hidden, 'the card waits in it');
  // Wide, the shared box is no box: each pane as before.
  assert.equal(under('', '.centre-scroll').display, 'contents');
  // A phone: the shared box scrolls; the panes in it don't; what waits comes first.
  assert.equal(under(PHONE, '.project-view .centre-scroll')['overflow-y'], 'auto');
  assert.equal(under(PHONE, '.project-view .centre-scroll > .talk').overflow, 'visible');
  const waits = under(PHONE, '.project-view .centre-scroll > .wait-box');
  assert.equal(waits.order, '-1');
  assert.equal(waits['max-height'], 'none');
  assert.equal(waits.overflow, 'visible');
});

test('U2 phone: the message box is one row, its "To the lead of…" only when there is no lead to tell', async () => {
  const { projectView } = await import('../js/views/project.js');
  const view = projectView(fakeApp({ route: { name: 'project', id: P, view: 'lead', show: 'decisions' } }), { sheet });
  view.render();
  const to = find(view.el, byClass('to'));
  assert.ok(!to.classList.contains('no-lead'));
  assert.equal(under(PHONE, '.project-view .composer-lead > .to:not(.no-lead)').display, 'none');
  assert.equal(under(PHONE, '.project-view .composer-lead')['flex-wrap'], 'nowrap');
  const none = projectView(fakeApp({ route: { name: 'project', id: P, view: 'lead', show: 'decisions' }, leads: new Map([[P, { ...lead, root: null }]]) }), { sheet });
  none.render();
  assert.ok(find(none.el, byClass('to')).classList.contains('no-lead'));
  // The notifications' offer is one row on a phone.
  assert.equal(under(PHONE, '.centre-wrap > .offline.offer')['flex-wrap'], 'nowrap');
  assert.equal(under(PHONE, '.centre-wrap > .offline.offer > span')['-webkit-line-clamp'], '2');
});

// ---- The keyboard ----
function keyboardPage() {
  const listeners = {};
  const frames = [];
  const vv = { width: 390, height: 844, offsetTop: 0, addEventListener(name, fn) { (listeners[name] ||= []).push(fn); } };
  const win = { visualViewport: vv, requestAnimationFrame: (fn) => frames.push(fn) };
  const docListeners = {};
  const doc = { activeElement: null, addEventListener(name, fn) { (docListeners[name] ||= []).push(fn); } };
  const root = new FakeNode('div');
  const props = {};
  root.style = { setProperty: (name, value) => { props[name] = value; }, removeProperty: (name) => { delete props[name]; } };
  const fire = (name) => (listeners[name] || []).forEach((fn) => fn());
  const focus = (el) => { doc.activeElement = el; (docListeners.focusin || []).forEach((fn) => fn()); };
  const run = () => frames.splice(0).forEach((fn) => fn());
  return { vv, win, doc, root, props, fire, focus, run };
}
const box = (classes, { inLead = false } = {}) => {
  const el = new FakeNode('input');
  el.matches = (selector) => selector.startsWith('input');
  el.scrolledIntoView = 0;
  el.scrollIntoView = () => { el.scrolledIntoView++; };
  const scroll = { scrollTop: 0, scrollHeight: 1200 };
  el.closest = (selector) => (inLead && selector === '.composer-lead' ? { parentNode: { querySelector: (s) => (s === '.centre-scroll' ? scroll : null) } } : null);
  el.attrs.class = classes;
  return { el, scroll };
};

test('the keyboard: with a box focused and the visible part well short of its tallest, the page keeps to the visible part', async () => {
  const { followKeyboard } = await import('../js/viewport.js');
  const page = keyboardPage();
  followKeyboard({ root: page.root, win: page.win, doc: page.doc, phone: () => true });
  assert.ok(!page.root.classList.contains('keyboard'));
  // The lead's box focused, the keyboard comes up.
  const { el: say, scroll } = box('say', { inLead: true });
  page.focus(say);
  page.vv.height = 500;
  page.fire('resize');
  assert.ok(page.root.classList.contains('keyboard'));
  assert.equal(page.props['--vv-height'], '500px');
  assert.equal(page.props['--vv-top'], '0px');
  page.run();
  assert.equal(scroll.scrollTop, 1200, 'the conversation’s end just above the box');
  // Safari pans the visible part: the page follows it.
  page.vv.offsetTop = 120;
  page.fire('scroll');
  assert.equal(page.props['--vv-top'], '120px');
  // The keyboard goes down: as before.
  page.vv.height = 844;
  page.vv.offsetTop = 0;
  page.fire('resize');
  assert.ok(!page.root.classList.contains('keyboard'));
  assert.equal(page.props['--vv-height'], undefined);
  // A card's answer box: brought into sight where it is.
  const { el: answer } = box('answer-input');
  page.focus(answer);
  page.vv.height = 480;
  page.fire('resize');
  page.run();
  assert.equal(answer.scrolledIntoView, 1);
  // A toolbar hiding (a little shorter) is no keyboard; nor is anything on a wide window.
  const calm = keyboardPage();
  followKeyboard({ root: calm.root, win: calm.win, doc: calm.doc, phone: () => true });
  calm.focus(box('say').el);
  calm.vv.height = 790;
  calm.fire('resize');
  assert.ok(!calm.root.classList.contains('keyboard'));
  const wide = keyboardPage();
  followKeyboard({ root: wide.root, win: wide.win, doc: wide.doc, phone: () => false });
  wide.focus(box('say').el);
  wide.vv.height = 400;
  wide.fire('resize');
  assert.ok(!wide.root.classList.contains('keyboard'));
});

test('the keyboard on a phone: the page is the visible part’s height and place; only the header, the scroll and the box stay', () => {
  const app = under(PHONE, '.app.keyboard');
  assert.equal(app.height, 'var(--vv-height, 100dvh)');
  assert.equal(app.transform, 'translateY(var(--vv-top, 0px))');
  const hidden = rules().find((rule) => rule.media === PHONE && listed(rule).includes('.app.keyboard .project-view :is(.team-strip, .dial-fold, .centre-head > .switch)'));
  assert.ok(hidden && declarations(hidden.body).display === 'none');
  // The page's own wiring: app.js follows the keyboard on a phone's width.
  const source = readFileSync(join(here, '..', 'app.js'), 'utf8');
  assert.match(source, /followKeyboard\(\{ root, phone: \(\) => phoneWidth\.matches \}\)/);
  assert.match(source, /matchMedia\('\(max-width: 760px\)'\)/);
});
