// The join's four page-side leftovers (the spacing task, 2026-11-26): the team strip one row in Lead and Roadmap alike
// at any width, a phone's loading header the real header's height, the composer's + round, and the card's answer box
// whose words fit a phone. Drawn on tests/fakedom.test.mjs's stand-in DOM, style.css read as tests/phone.test.mjs reads
// it; the heights are resolved from the tokens here, and measured in Chrome in the task's report.
// Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { installDom, find, byClass } from './fakedom.test.mjs';

process.env.TZ = 'UTC';
installDom();
const { setLanguage, t } = await import('../js/i18n.js');

// ---- style.css as rules, and a length resolved from the tokens (env() is 0: no notch) ----
const here = dirname(fileURLToPath(import.meta.url));
const css = readFileSync(join(here, '..', 'style.css'), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');
function rules() {
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
  walk(css, '');
  return found;
}
function declarations(body) {
  const out = {};
  for (const part of body.split(';')) {
    const colon = part.indexOf(':');
    if (colon >= 0) out[part.slice(0, colon).trim()] = part.slice(colon + 1).trim();
  }
  return out;
}
const listed = (rule) => rule.selector.split(/,(?![^(]*\))/).map((one) => one.trim());
function under(media, selector) {
  const out = {};
  for (const rule of rules()) if (rule.media === media && listed(rule).includes(selector)) Object.assign(out, declarations(rule.body));
  return out;
}
// What a selector gets on a phone: the rules outside any @media, then the phone's (a later shorthand replaces the
// longhands before it).
function onPhone(selector) {
  const out = under('', selector);
  for (const [property, value] of Object.entries(under(PHONE, selector))) {
    for (const longhand of Object.keys(out)) if (longhand.startsWith(`${property}-`)) delete out[longhand];
    out[property] = value;
  }
  return out;
}
const PHONE = '(max-width: 760px)';
const TOUCH = '(hover: none) and (pointer: coarse)';
const ROOT = under('', ':root');
// A length in px: tokens substituted, env() as 0, calc's arithmetic done.
function px(value) {
  let text = String(value);
  for (let n = 0; n < 10 && /var\(/.test(text); n++) text = text.replace(/var\((--[\w-]+)\)/g, (_, name) => `(${ROOT[name]})`);
  text = text.replace(/env\([^)]*\)/g, '0px').replace(/calc/g, '').replace(/(-?\d*\.?\d+)px/g, '$1');
  assert.match(text, /^[\d.\s()+\-*/]+$/, `a length: ${value}`);
  return Function(`return (${text})`)();
}
// A shorthand's four sides.
function sides(value) {
  const parts = []; let depth = 0; let word = '';
  for (const ch of value) {
    if (ch === '(') depth++;
    if (ch === ')') depth--;
    if (ch === ' ' && !depth) { if (word) parts.push(word); word = ''; } else word += ch;
  }
  if (word) parts.push(word);
  const [top, right = top, bottom = top, left = right] = parts;
  return { top: px(top), right: px(right), bottom: px(bottom), left: px(left) };
}
const padding = (rule) => {
  const all = sides(rule.padding || '0');
  for (const side of ['top', 'right', 'bottom', 'left']) if (rule[`padding-${side}`]) all[side] = px(rule[`padding-${side}`]);
  return all;
};
const gap = (rule) => px((rule['row-gap'] || rule.gap || '0').split(' ')[0]);

// ---- A project, as tests/phone.test.mjs makes one ----
const P = 'local:project:site';
const ROOT_DIR = '/home/dev/projects/example-site';
const lead = { project: P, root: ROOT_DIR, session: 'local:lead', named: null, bound: 'local:lead', replaced: [], held: 0, reportsWaiting: 0, notice: null,
  starting: false, looks: 1, questions: { open: 0, blocking: 0 }, cards: [], told: [] };
const tasks = ['running', 'review', 'blocked', 'planned', 'done'].map((status, n) => ({ id: `t${n}`, slug: `task-${n}`, title: `Task ${n}`, status,
  group: status === 'done' ? 'done' : 'running', state: status, line: '', after: [], checkpoints: [] }));
const board = { project: P, root: ROOT_DIR, baseBranch: 'main', counts: { attention: 0, running: 3, waiting: 1, done: 1 }, more: 0, unreadable: null, tasks, answered: [] };
function fakeApp(route) {
  const store = {
    state: { node: null, connection: 'live', phrase: null, pageWords: null, sessions: new Map(), leads: new Map([[P, lead]]), boards: new Map([[P, board]]), cards: new Map(),
      cardKeys: new Map(), acting: new Map(), draftRefused: new Map(), plugins: null },
    acts: () => true, can: () => true, follows: () => true, watches: () => true, subscribe() {}, read: () => Promise.resolve({ ok: false }),
    request: () => Promise.resolve({ ok: true, result: {} }), act() {}, cardKey: (id) => id, draftOf: () => null, sessionDraft() {}, chatOf: () => null,
  };
  const ui = { state: { route }, subscribe() {}, go() {}, setPalette() {}, pane: () => 'chat', setPane() {}, inspectorShown: () => false, inspectorWide: () => true, toggleInspector() {} };
  return { store, ui, calls: [], feed: null, drawer() {} };
}
const sheet = { open() {}, close() {}, shown: () => false };

test('leftover 1: the team strip is one row at any width, in Lead and Roadmap alike; what doesn’t fit folds behind its chevron', async () => {
  // The strip's row: its parts a small control's height, its padding, its hairline. Wrapped (1024 px with the right
  // column, Lead was 54 px and Roadmap 34), the rest is hidden under the row, never cut, with the fold that shows it.
  const strip = under('', '.team-strip');
  const part = under('', '.team-strip > :not(.strip-fold)');
  const pad = padding(strip);
  assert.equal(strip.overflow, 'hidden');
  assert.equal(strip['flex-wrap'], 'wrap', 'a count that doesn’t fit goes whole to the hidden row');
  assert.equal(px(part.height), px('var(--ctl-s)'));
  assert.equal(px(strip['max-height']), px(part.height) + pad.top + pad.bottom + 1, 'one row and its hairline');
  assert.equal(under('', '.team-strip.open')['max-height'], 'none');
  assert.ok(pad.right >= px('var(--ctl-s)'), 'room for the fold at the row’s end');
  const fold = under('', '.strip-fold:not([hidden])');
  assert.equal(fold.position, 'absolute');
  assert.equal(px(fold.height), px('var(--ctl-s)'));
  // The same strip element heads both views (project.js builds one): measured wide, the fold shows where a count
  // wrapped, and a click opens the strip.
  const saved = globalThis.matchMedia;
  globalThis.matchMedia = () => ({ matches: false, addEventListener() {} });
  try {
    const { projectView } = await import('../js/views/project.js');
    for (const view of ['lead', 'roadmap']) {
      const shown = projectView(fakeApp({ name: 'project', id: P, view, show: 'decisions', open: [] }), { sheet });
      const el = find(shown.el, byClass('team-strip'));
      el.clientHeight = 33;
      el.scrollHeight = 61;
      shown.render();
      const chevron = find(el, byClass('strip-fold'));
      assert.ok(!chevron.hidden, `${view}: a count past the row, the fold`);
      el.click();
      assert.ok(el.classList.contains('open'), `${view}: the fold opens the strip`);
      el.click();
      el.scrollHeight = 33;
      shown.render();
      assert.ok(chevron.hidden, `${view}: everything on the row, no fold`);
    }
  } finally {
    globalThis.matchMedia = saved;
  }
});

test('leftover 2: a phone’s loading header is the real header’s height (109 px at 390: two rows, 44 and 48)', () => {
  const real = onPhone('.project-view .centre-head');
  const switcher = onPhone('.project-view .centre-head > .segmented:not(.dial)');
  const rows = [px('var(--ctl-touch)'), px('var(--ctl-touch)') + padding(switcher).top + padding(switcher).bottom];
  assert.equal(under(TOUCH, '.segment')['min-height'], 'var(--ctl-touch)', 'a segment is a fingertip on a touch screen');
  const realHeight = padding(real).top + rows[0] + gap(real) + rows[1] + padding(real).bottom + 1;
  assert.equal(realHeight, 109);
  const skeleton = onPhone('.skeleton-head');
  const skeletonRows = skeleton['grid-template-rows'] ? sides(skeleton['grid-template-rows']) : null;
  const row = px(onPhone('.skeleton-head > .skeleton-row')['min-height'] || under('', '.skeleton-row')['min-height']);
  const [first, second] = skeletonRows ? [skeletonRows.top, skeletonRows.right] : [row, row];
  assert.equal(padding(skeleton).top + first + gap(skeleton) + second + padding(skeleton).bottom + 1, realHeight, 'nothing moves as the content comes');
  assert.ok(row <= Math.min(first, second), 'each row holds its bones');
});

test('leftover 3: the composer’s + is round again, 36 px (44 on a touch screen), as before the join', () => {
  // The kit's round icon button (the Components section's disc, later than .icon-button's corners), sized by its place.
  assert.equal(under('', '.icon-button.round')['border-radius'], 'var(--r-pill)');
  const order = rules().map((rule) => listed(rule));
  assert.ok(order.findIndex((names) => names.includes('.icon-button.round')) > order.findIndex((names) => names.includes('.icon-button')));
  const attach = under('', '.composer-attach');
  assert.equal(attach.width, 'var(--ctl-l)');
  assert.equal(attach.height, 'var(--ctl-l)');
  assert.equal(under(TOUCH, '.composer-attach').width, 'var(--ctl-touch)');
  const source = readFileSync(join(here, '..', 'js', 'views', 'chat.js'), 'utf8');
  assert.match(source, /kit\.iconButton\(\{ class: 'composer-attach', round: true,/, 'the + is the kit’s round icon button');
});

test('leftover 4: the answer box’s words fit a phone’s field at 360 px, in both languages', () => {
  // Measured in Chrome at 16 px (a touch screen's text box): 164 px of room in the field at 360 px; "O responde con tus
  // palabras" took 209. Twenty characters of these words is at most about 155 px.
  for (const lang of ['en', 'es']) {
    setLanguage(lang);
    const words = t('cOwnWords');
    assert.ok(words.length <= 20, `${lang}: "${words}" (${words.length} characters) fits 164 px`);
  }
  setLanguage('en');
});
