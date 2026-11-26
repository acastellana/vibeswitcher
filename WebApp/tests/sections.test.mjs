// The sections the design review graded lowest (2026-11-25, its group F): New session and New project (D12), This node
// and the inspector (D18), Settings' on/off values (D16) and the icons (D25). Drawn on tests/fakedom.test.mjs's
// stand-in DOM, in English and Spanish; style.css and the views' source read as text where the rule is the source's.
// Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { installDom, find, findAll, byClass } from './fakedom.test.mjs';

process.env.TZ = 'UTC';
installDom();
const { setLanguage, t } = await import('../js/i18n.js');

const here = dirname(fileURLToPath(import.meta.url));
const css = readFileSync(join(here, '..', 'style.css'), 'utf8');
const bareCss = css.replace(/\/\*[\s\S]*?\*\//g, '');
const sources = () => {
  const files = ['app.js', ...readdirSync(join(here, '..', 'js')).filter((f) => f.endsWith('.js')).map((f) => 'js/' + f),
    ...readdirSync(join(here, '..', 'js', 'views')).map((f) => 'js/views/' + f)];
  return files.map((file) => ({ file, text: readFileSync(join(here, '..', file), 'utf8') }));
};

const flush = () => new Promise((resolve) => setImmediate(resolve));

// An app as the views read it (as buttons.test.mjs's): a store over `state`, the kinds this connection may send,
// whether it acts, and every request sent, each answered by `reply(kind, args)`.
function fakeApp({ route = { name: 'node' }, state = {}, kinds = null, acts = true, reply = () => ({ ok: true, result: {} }) } = {}) {
  const sent = [];
  const answer = (kind, args) => { sent.push({ kind, args }); return Promise.resolve(reply(kind, args)); };
  const listeners = new Map();
  const store = {
    state: { node: null, connection: 'live', phrase: null, pageWords: null, sessions: new Map(), leads: new Map(), boards: new Map(), cards: new Map(),
      chats: new Map(), cardKeys: new Map(), acting: new Map(), draftRefused: new Map(), sessionDraftRefused: new Map(), plugins: null, ...state },
    acts: () => acts,
    can: (kind) => kinds === null || kinds.includes(kind),
    follows: () => true,
    subscribe(topic, fn) { (listeners.get(topic) || listeners.set(topic, []).get(topic)).push(fn); return () => {}; },
    notify(topic) { for (const fn of listeners.get(topic) || []) fn(); },
    read: answer,
    request: answer,
    cardKey: (id) => id,
    draftOf: () => null,
    sessionDraftOf: () => null,
  };
  const went = [];
  const routeListeners = [];
  const ui = { state: { route, inspector: { open: true, tab: 'overview', sheet: false } }, subscribe(fn) { routeListeners.push(fn); }, go(hash) { went.push(hash); },
    inspectorShown: () => true, setInspector() {}, setInspectorTab() {} };
  return { store, sent, ui, went };
}

// ---- D25: the icons ----

test('D25: every icon is one family on one grid (12, 16, 24) with one 1.5 px line, whatever size a view asks for', async () => {
  const { icon, iconSize, ICON_GRID } = await import('../js/marks.js');
  assert.deepEqual(ICON_GRID, [12, 16, 24]);
  for (const [asked, drawn] of [[10, 12], [11, 12], [12, 12], [13, 12], [14, 16], [15, 16], [16, 16], [22, 24]]) {
    assert.equal(iconSize(asked), drawn, `${asked} → ${drawn}`);
    const svg = icon('close', asked);
    assert.equal(svg.attrs.width, String(drawn));
    assert.equal(svg.attrs.height, String(drawn));
    assert.equal(svg.attrs.viewBox, '0 0 16 16', 'every icon drawn on the same 16-unit square');
  }
  assert.throws(() => icon('nothing'), /no icon nothing/);
  // Every size a view asks for lands on the grid (the calls as written: icon('name', N)).
  for (const { file, text } of sources()) {
    for (const match of text.matchAll(/\bicon\('[a-z]+', (\d+)\)/g)) assert.ok(ICON_GRID.includes(iconSize(Number(match[1]))), `${file}: icon size ${match[1]}`);
  }
  // One weight: the path's own stroke, 1.5 px on the screen at any size, which an svg's stroke-width elsewhere can't reach.
  assert.match(bareCss, /\.icon > path \{ vector-effect: non-scaling-stroke; stroke-width: 1\.5px; \}/);
  const pathRules = [...bareCss.matchAll(/([^{}]*\.icon[^{}]*>\s*path[^{}]*)\{([^}]*)\}/g)].filter((m) => /stroke-width/.test(m[2]));
  assert.equal(pathRules.length, 1, 'no other rule sets an icon path’s weight');
});

test('D25: every icon-only button has a name for screen readers and a tooltip', async () => {
  const kit = await import('../js/kit.js');
  const { icon } = await import('../js/marks.js');
  const named = kit.iconButton({ 'aria-label': 'Close' }, icon('close', 16));
  assert.equal(named.attrs.title, 'Close', 'the tooltip is its name when it has no other');
  assert.equal(kit.iconButton({ 'aria-label': 'Close', title: 'Close (Esc)' }).attrs.title, 'Close (Esc)');
  // In the source: each icon-only button names itself where it is made, or the line that draws it later sets both.
  const missing = [];
  for (const { file, text } of sources()) {
    if (file === 'js/kit.js') continue;
    for (const match of text.matchAll(/kit\.iconButton\(\{|h\('button', \{ class: '[^']*icon-button/g)) {
      const call = text.slice(match.index, text.indexOf('\n', text.indexOf('}', match.index + 14)));
      const props = call.slice(0, call.indexOf('}') + 1);
      const name = props.match(/const (\w+) = kit\.iconButton/) || text.slice(Math.max(0, match.index - 40), match.index).match(/const (\w+) = $/);
      const later = name && new RegExp(`${name[1]}\\.setAttribute\\('aria-label'`).test(text) && new RegExp(`${name[1]}\\.title = `).test(text);
      const hasName = /'aria-label'/.test(props) || later;
      const hasTip = /\btitle:/.test(props) || /'aria-label'/.test(props) && /kit\.iconButton/.test(match[0]) || later;
      if (!hasName || !hasTip) missing.push(`${file}: ${props.slice(0, 90)}`);
    }
  }
  assert.deepEqual(missing, []);
});
