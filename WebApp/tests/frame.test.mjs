// The frame's calm (the design review of 2026-11-25, group D: D5, D6, D17, D21, D24, D29): nothing in the frame moves
// that the user didn't move, and the first second says nothing false. Drawn on tests/fakedom.test.mjs's stand-in DOM,
// with the mock's own snapshot held back and then given. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { installDom, find, findAll, byClass } from './fakedom.test.mjs';

installDom();
const { setLanguage, TABLES } = await import('../js/i18n.js');
const { createStore } = await import('../js/store.js');
const { createMock } = await import('../js/mock.js');
const { leftColumn, framePhase, frameShape, keepShape } = await import('../js/views/left.js');
const { framePageKind, framePage, PAGE_KINDS, centreSkeleton } = await import('../js/views/frame.js');
const { notifications } = await import('../js/notify.js');

const read = (path) => readFileSync(new URL(path, import.meta.url), 'utf8');
const APP = read('../app.js');
const CSS = read('../style.css').replace(/\/\*[\s\S]*?\*\//g, '');
// The top-level rules (outside any @media or @keyframes): [selector list, body].
const TOP = (() => {
  const found = [];
  let at = 0;
  while (at < CSS.length) {
    const open = CSS.indexOf('{', at);
    if (open < 0) break;
    const head = CSS.slice(at, open).trim();
    let depth = 1;
    let close = open + 1;
    while (depth && close < CSS.length) { if (CSS[close] === '{') depth += 1; else if (CSS[close] === '}') depth -= 1; close += 1; }
    if (!head.startsWith('@')) found.push([head, CSS.slice(open + 1, close - 1)]);
    at = close;
  }
  return found;
})();
// The body of the top-level rule whose selector list is exactly `selector`.
const rule = (selector) => TOP.find(([head]) => head === selector)?.[1] ?? null;

// A storage of its own, for a test's remembered shape and choices.
function memory() {
  const kept = new Map();
  return { getItem: (key) => kept.get(key) ?? null, setItem: (key, value) => kept.set(key, String(value)), removeItem: (key) => kept.delete(key) };
}

// The mock's snapshot as a node would send it, taken from a mock of its own.
function snapshot() {
  return new Promise((resolve) => {
    const mock = createMock({ apply: resolve, setKinds() {}, setConnection() {}, chatSnapshot() {}, chatOps() {} }, { still: true });
    mock.start();
  });
}

// The page's app as the left column reads it, over a real store.
function appOver(store, route = { name: 'project', id: 'local:project:Zx3kQ0aVtLmN', view: 'lead' }) {
  return { store, ui: { state: { route }, subscribe() {}, go() {} } };
}

test('D6: until the first snapshot the left column says nothing it doesn’t know: skeleton rows, bars in the foot; then the truth, in the same places', async () => {
  for (const code of ['en', 'es']) {
    setLanguage(code);
    const store = createStore();
    const left = leftColumn(appOver(store), { brief() {} });
    left.render();
    assert.equal(framePhase(store.state), 'loading');
    const said = left.el.shownText;
    // Neither "Nothing needs you" nor any count nor the acting line before the node has said a thing.
    for (const word of ['nothingNeedsYou', 'frNothingMoving', 'frOwnNone', 'frActs', 'briefMe']) assert.ok(!said.includes(TABLES[code][word]), `${code}: “${TABLES[code][word]}” before the snapshot`);
    assert.ok(left.el.classList.contains('loading'));
    assert.equal(find(left.el, byClass('projects-skeleton')).hidden, false);
    assert.ok(findAll(left.el, byClass('skeleton-row')).length >= 1, 'a row a project, as the last load had');
    for (const bone of ['summary-bone', 'place-bone']) assert.ok(findAll(left.el, byClass(bone)).some((one) => !one.hidden), bone);
    // The snapshot: the words take the bars' places, the skeleton goes.
    store.apply(await snapshot());
    left.render();
    assert.equal(framePhase(store.state), 'known');
    assert.ok(!left.el.classList.contains('loading'));
    assert.equal(find(left.el, byClass('projects-skeleton')).hidden, true);
    assert.equal(left.el.shownText.includes(TABLES[code].nothingNeedsYou), false, 'the mock needs you: never said otherwise, before or after');
    const skeleton = find(left.el, byClass('projects-skeleton'));
    assert.deepEqual(findAll(left.el, byClass('bone')).filter((one) => !one.hidden && !findAll(skeleton, (node) => node === one).length), [], 'no bar left showing');
    assert.match(find(left.el, byClass('summary-count')).textContent, code === 'en' ? /need you in all/ : /te necesitan en total/);
  }
  setLanguage('en');
});

test('D6: the skeleton takes the shape the last load had (how many projects, Brief me, the acting row, where home went), kept in this browser', async () => {
  const storage = memory();
  // A node's own defaults: acting is off until turned on (`web_acts`), so a first load's foot keeps its rows.
  assert.deepEqual(frameShape(storage), { projects: 1, brief: true, acts: false, home: 'project' }, 'the defaults, before any load');
  keepShape({ projects: 3, brief: false, acts: true, home: 'sessions' }, storage);
  assert.deepEqual(frameShape(storage), { projects: 3, brief: false, acts: true, home: 'sessions' });
  keepShape({ projects: 40 }, storage);
  assert.equal(frameShape(storage).projects, 6, 'never more than a column’s worth');
  assert.deepEqual(frameShape({ getItem() { throw new Error('refused'); } }), { projects: 1, brief: true, acts: false, home: 'project' }, 'storage refused: the defaults');
});

test('D6: a held snapshot shows skeletons in the centre for a project and home; the frame’s pages for not paired, out of reach and an empty node', () => {
  const kind = (phase, connection, name, sessions = 0) => framePageKind({ phase, connection, route: { name }, sessions });
  assert.equal(kind('loading', 'connecting', 'project'), 'loading');
  assert.equal(kind('loading', 'connecting', 'home'), 'loading');
  assert.equal(kind('loading', 'connecting', 'session'), null, 'a session draws its own skeleton');
  assert.equal(kind('down', 'connecting', 'session'), 'down', 'out of reach, whatever the address');
  assert.equal(kind('off', 'unpaired', 'project'), 'unpaired');
  assert.equal(kind('off', 'revoked', 'home', 3), 'revoked');
  assert.equal(kind('off', 'revoked', 'project', 3), null, 'unpaired with rows shown: they stay readable, the row above says so');
  assert.equal(kind('known', 'live', 'home'), 'empty', 'home stays only on a node with nothing on it (app.js settleHome)');
  assert.equal(kind('known', 'live', 'project'), null);
  assert.equal(framePhase({ connection: 'connecting' }, true), 'down');
  assert.equal(framePhase({ connection: 'reconnecting' }, true), 'known', 'a dropped connection keeps what it knew');
  const { el } = centreSkeleton();
  assert.equal(el.getAttribute('aria-busy'), 'true');
  assert.equal(el.shownText, '', 'a skeleton says no words');
  // The loop, never a literal time; reduced motion stops it (style.css's one rule for every animation).
  assert.match(rule('.bone'), /animation: pulse var\(--loop\)/);
  assert.match(rule('.skeleton-mark'), /animation: pulse var\(--loop\)/);
});

test('D21: not paired, out of reach and an empty node each say what this is, what to do and what happens then, in English and Spanish, with their one action', () => {
  for (const code of ['en', 'es']) {
    setLanguage(code);
    for (const kind of PAGE_KINDS) {
      const page = framePage(kind, { retry() {} });
      const paragraphs = findAll(page, (node) => node.tag === 'p');
      assert.ok(find(page, (node) => node.tag === 'h1')?.textContent, `${code} ${kind}: a title`);
      assert.equal(paragraphs.length, 3, `${code} ${kind}: what this is, what to do, what happens then`);
      for (const p of paragraphs) assert.ok(p.textContent.length > 20, `${code} ${kind}: ${p.textContent}`);
      // No command, hash, path or file name where a person reads; the one terminal line is its own copyable line.
      for (const p of [...paragraphs, find(page, (node) => node.tag === 'h1')]) {
        assert.doesNotMatch(p.textContent, /`|\$ |\bvibeswitcher [a-z]|~\/|\/[a-z]+\/|\.(json|md|plist|sh)\b|\b[0-9a-f]{7,}\b|--[a-z]/, `${code} ${kind}: ${p.textContent}`);
      }
    }
    const unpaired = framePage('unpaired');
    assert.equal(find(unpaired, byClass('copy-text')).textContent, 'vibeswitcher web', 'pairing still starts in a terminal: the line to copy');
    assert.ok(find(unpaired, byClass('copy-button')), 'with its copy button');
    let tried = 0;
    const waits = [];
    const down = framePage('down', { retry: () => { tried += 1; }, later: (fn) => waits.push(fn) });
    const retry = find(down, (node) => node.tag === 'button' && node.classList.contains('frame-action'));
    assert.equal(retry.textContent, TABLES[code].frDownRetry);
    retry.click();
    assert.equal(tried, 1, 'the button tries again now');
    assert.equal(retry.textContent, TABLES[code].frDownTrying, 'and says so');
    assert.equal(retry.disabled, true);
    waits.splice(0).forEach((fn) => fn());
    assert.equal(retry.textContent, TABLES[code].frDownRetry);
    // No way to try now (a feed without one): no button that would do nothing, and never a reload.
    assert.equal(find(framePage('down'), (node) => node.tag === 'button'), null);
    assert.doesNotMatch(read('../js/views/frame.js') + APP, /location\??\.reload\(\)/);
    const empty = framePage('empty');
    const links = findAll(empty, (node) => node.tag === 'a').map((node) => node.getAttribute('href'));
    assert.deepEqual(links, ['#/sessions/new', '#/new'], 'start a session; or a new project');
    assert.ok(find(empty, (node) => node.tag === 'a' && node.getAttribute('href') === '#/sessions/new').classList.contains('button'));
  }
  setLanguage('en');
});

test('D21: the frame’s words: tú in Spanish, no retired word, none of the old terminal sentences', () => {
  const keys = Object.keys(TABLES.en).filter((key) => key.startsWith('fr'));
  assert.ok(keys.length >= 25, keys.join(' '));
  for (const key of keys) {
    assert.ok(TABLES.es[key], `${key} in Spanish`);
    const es = TABLES.es[key];
    assert.doesNotMatch(es, /\busted(es)?\b|\bsu nodo\b|\bsus proyectos\b|\bejecute\b|\babra\b|\bcompruebe\b/i, `${key}: tú, never usted: ${es}`);
    assert.doesNotMatch(es, /\btableros?\b|\bcifras\b|\ben reposo\b/i, `${key}: a retired word: ${es}`);
    assert.doesNotMatch(TABLES.en[key], /\bboards?\b|\bStats\b/, key);
    // This browser's notifications are Notificaciones, never avisos (the node's notices).
    if (/notif/i.test(TABLES.en[key])) assert.doesNotMatch(es, /\bavis(o|os)\b/i, key);
  }
  // The page not paired no longer says the old sentence with a command in it.
  assert.doesNotMatch(APP, /t\('unpairedSub'\)|t\('apRun'\)/);
});

test('D5: the reconnecting line and the notifications’ offer sit in the left column’s gap, between what grows and the places: never in the centre, never over the page', () => {
  setLanguage('en');
  const store = createStore();
  const left = leftColumn(appOver(store), { brief() {} });
  const body = find(left.el, byClass('colbody'));
  const order = body.children.map((node) => node.classList.contains('left-gap') ? 'gap' : node.classList.contains('left-notes') ? 'notes' : node.dataset?.place || '');
  assert.ok(order.indexOf('gap') >= 0 && order.indexOf('notes') === order.indexOf('gap') + 1 && order.indexOf('ownSessions') === order.indexOf('notes') + 1, order.join(' '));
  // app.js puts both there, and nowhere else.
  assert.match(APP, /left\.notes\.append\(offline, app\.notifications\.offer\)/);
  const centre = APP.match(/const centre = h\('main', \{[^}]*\}, ([^;]+)\);/)?.[1] || '';
  for (const part of ['offline', 'notifications.offer']) assert.ok(!centre.includes(part), `${part} not in the centre`);
  const root = APP.match(/root\.replaceChildren\(([^;]+)\);/)?.[1] || '';
  for (const part of ['offline', 'notifications.offer']) assert.ok(!root.includes(part), `${part} not laid over the page`);
  // A note is a card in the column's flow: nothing positions it over anything.
  assert.doesNotMatch(rule('.note'), /position:/);
  assert.match(rule('.left-gap'), /flex: 1/, 'the gap gives the room a note takes, so the places under it stay put');
  // On a phone the column is a drawer: a dot on the button that opens it says a note waits there, the offer's as the
  // reconnecting line's.
  assert.match(CSS, /\.app\.has-note :is\(\.centre-head, \.tc-head, \.head\) > :is\(\.phone-only, \.back\):first-child::after/);
  assert.match(APP, /function noteDot\(\) \{ root\.classList\.toggle\('has-note', !offline\.hidden \|\| !app\.notifications\.offer\.hidden\); \}/);
  // Out of reach only before the node's hello: a node that answered is never called asleep while its state streams.
  assert.match(APP, /if \(store\.state\.connection !== 'connecting' \|\| store\.state\.kinds !== null\) return;/);
});

test('D5: the offer is asked once, after the first thing that needs you; answered, it says what happened and goes; “Not now” is remembered', async () => {
  setLanguage('en');
  const later = [];
  const storage = memory();
  const Notification = function Notification() {};
  Notification.permission = 'default';
  Notification.requestPermission = () => Promise.resolve('granted');
  const card = (id) => ({ id, kind: 'question', project: 'p', root: '/home/dev/site', open: true, question: { text: 'Ship it?' } });
  const state = { connection: 'live', node: null, sessions: new Map(), leads: new Map(), cards: new Map(), boards: new Map() };
  const app = { store: { state, subscribe() {} }, ui: { state: { route: { name: 'home' } }, go() {} } };
  const doc = { title: 'VibeSwitcher', visibilityState: 'hidden', hasFocus: () => false };
  let dots = 0;
  app.noteChanged = () => { dots += 1; };
  const notes = notifications(app, { Notification, storage, document: doc, later: (fn) => later.push(fn), AudioContext: undefined });
  assert.equal(notes.offer.hidden, true, 'nothing asked at load');
  assert.ok(notes.offer.classList.contains('note') && !notes.offer.classList.contains('offline'), 'a note of the left column, not a row of the centre');
  state.cards.set('c1', card('c1'));
  notes.look();
  assert.equal(notes.offer.hidden, false, 'the first thing that needs you: asked');
  assert.equal(dots, 1, 'the frame told, for the dot on a phone’s menu');
  find(notes.offer, byClass('offer-no')).click();
  assert.equal(storage.getItem('vibeswitcher.notifications'), 'off');
  assert.equal(notes.offer.hidden, false, 'it says what happened first');
  assert.equal(notes.offer.shownText, TABLES.en.frOfferOff);
  later.splice(0).forEach((fn) => fn());
  assert.equal(notes.offer.hidden, true, 'then goes');
  state.cards.set('c2', card('c2'));
  notes.look();
  assert.equal(notes.offer.hidden, true, '“Not now” is remembered: never asked again');
  // Turned on: the browser asks, and the note says so.
  const storage2 = memory();
  const state2 = { ...state, cards: new Map() };
  const on = notifications({ ...app, store: { state: state2, subscribe() {} } }, { Notification, storage: storage2, document: doc, later: () => {}, AudioContext: undefined });
  state2.cards.set('c1', card('c1'));
  on.look();
  find(on.offer, byClass('offer-yes')).click();
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(storage2.getItem('vibeswitcher.notifications'), 'on');
  assert.equal(on.offer.shownText, TABLES.en.frOfferOn);
});

test('D24: the foot is one calm block of fixed rows: what needs you, what moves, Brief me, and “Acts for you” with Turn off', async () => {
  for (const code of ['en', 'es']) {
    setLanguage(code);
    const store = createStore();
    store.apply(await snapshot());
    store.acts = () => true;
    const left = leftColumn(appOver(store), { brief() {} });
    left.render();
    const foot = find(left.el, byClass('left-summary'));
    const lines = findAll(foot, byClass('summary-line'));
    assert.equal(lines.length, 2, 'two lines, each its own height whatever it says');
    assert.ok(!lines[1].shownText.startsWith(' · '), 'what moves on its own line, not run on after the count');
    const acts = find(foot, byClass('acts-row'));
    assert.ok(acts, 'the acting row');
    assert.equal(find(acts, byClass('acts-words')).textContent, TABLES[code].frActs);
    assert.equal(find(acts, (node) => node.tag === 'button').textContent, TABLES[code].acTurnOff);
    assert.match(acts.getAttribute('title'), code === 'en' ? /acts for you since/ : /actúa por ti desde/, 'since when, in its title');
    // Your own sessions: its count under its name, as a project's line.
    const own = find(left.el, (node) => node.dataset?.place === 'ownSessions');
    assert.ok(own.classList.contains('two-line'));
  }
  setLanguage('en');
  assert.match(rule('.place.two-line'), /grid-template-columns/);
  assert.match(rule('.summary-line'), /white-space: nowrap/);
});

test('D17: orange means working, and only that: the acting line, the reconnecting mark, a card’s Push and Important labels and the notices are quiet ink', () => {
  for (const selector of ['.acts-line.compact', '.acts-row', '.priority.important', '.card-notice', '.inspect-notice .icon', '.notices .icon', '.setting-note', '.offline::before', '.note.reconnecting::before']) {
    const body = rule(selector);
    assert.ok(body !== null, selector);
    assert.doesNotMatch(body, /var\(--working\)/, selector);
  }
  // Where it stays: something working (a status, a running tool, a to-do in progress, a draft sent now, the ring).
  const working = TOP.filter(([head, body]) => /var\(--working\)/.test(body) && !head.startsWith(':root')).map(([head]) => head);
  assert.deepEqual(working.sort(), ['.badge.working', '.composer-draft.now', '.composer-draft.now .confirm-label', '.running', '.todo.active::before', '.tone-working'].sort());
  // A refusal said in a card is the danger colour, not quiet ink.
  assert.match(rule('.card-notice[role="alert"]'), /var\(--danger\)/);
  // Boost keeps its own token.
  assert.match(rule('.boost-mark > .icon'), /var\(--boost\)/);
});

test('D29: a skip link to the content is the keyboard’s first stop, hidden until it has the focus', () => {
  const root = APP.match(/root\.replaceChildren\(([^;]+)\);/)?.[1] || '';
  assert.equal(root.split(',')[0].trim(), 'skip', 'first in the page');
  assert.match(APP, /const skip = kit\.button\('plain', \{ tag: 'a', class: 'skip-link', href: '#content'/);
  assert.match(APP, /h\('main', \{ class: 'centre-wrap', id: 'content', tabindex: '-1' \}/);
  assert.match(rule('.skip-link'), /transform: translateY\(-200%\)/);
  assert.match(rule('.skip-link:focus'), /transform: none/);
  assert.ok(TABLES.es.frSkip === 'Saltar al contenido');
});

test('the mock: ?delay holds its first snapshot that long; ?delay=never never sends one (the node out of reach)', async () => {
  const at = (delay) => new Promise((resolve) => {
    const started = Date.now();
    createMock({ apply: () => resolve(Date.now() - started), setKinds() {}, setConnection() {}, chatSnapshot() {}, chatOps() {} }, { delay, still: true }).start();
  });
  let never = false;
  createMock({ apply: () => { never = true; }, setKinds() {}, setConnection() {}, chatSnapshot() {}, chatOps() {} }, { delay: 'never', still: true }).start();
  // A held snapshot arrives no sooner than asked (the event itself is waited on, never a sleep).
  assert.ok(await at('120') >= 100);
  assert.equal(never, false, 'never: nothing sent while another mock’s later snapshot came');
});
