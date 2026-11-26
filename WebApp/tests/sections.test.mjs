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
  // Leaving the page: its route listeners told (a view that reads again on a timer stops it).
  const leave = () => { ui.state.route = { name: 'home' }; for (const fn of routeListeners) fn('route'); };
  return { store, sent, ui, went, leave };
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

// ---- D16: Settings' on/off values ----

const NODE_SETTINGS = [
  { key: 'ignore_usage_limits', title: 'Ignore usage limits', about: 'Leads keep starting work at any share of a Claude limit.', section: 'Usage limits', scope: 'node', form: 'flag',
    home: 'limits', choices: [], limits: 'on or off', value: 'off', default: 'off', isDefault: true, where: '/home/u/.vibeswitcher/mac-limits.json', guardRail: false, note: null },
  { key: 'lead_mail', title: 'Let project leads message each other', about: 'Lets one project’s lead send messages to another’s.', section: 'Usage limits', scope: 'node', form: 'flag',
    home: 'preferences', choices: [], limits: 'on or off', value: 'on', default: 'on', isDefault: true, where: '/home/u/.vibeswitcher/settings.plist', guardRail: false, note: null },
  { key: 'node_heavy_slots', title: 'Test and build slots at once', about: 'How many builds may run at once.', section: 'Usage limits', scope: 'node', form: 'count',
    home: 'limits', choices: [], limits: '1 to 12', value: '3', default: '2', isDefault: false, where: '/home/u/.vibeswitcher/mac-limits.json', guardRail: false, note: null },
  { key: 'boost', title: 'Boost', about: 'Raises the limits.', section: 'Usage limits', scope: 'node', form: 'choice',
    home: 'preferences', choices: ['off', 'on', 'automatic'], limits: 'off, on, automatic', value: 'off', default: 'off', isDefault: true, where: '/home/u/.vibeswitcher/settings.plist', guardRail: false, note: null },
];

async function settingsPage(code, { acts = true, reply = null } = {}) {
  setLanguage(code);
  const { settingsView } = await import('../js/views/settings.js');
  const answers = [];
  const app = fakeApp({ route: { name: 'settings', id: null }, acts, kinds: ['set', 'settings'], state: { node: { home: '/home/u' } },
    reply: (kind, args) => (kind === 'settings' ? { ok: true, result: { node: { root: '/home/u/.vibeswitcher', settings: NODE_SETTINGS }, project: null, leftOut: [], usage: null } }
      : reply ? reply(kind, args, answers) : { ok: true, result: { key: args.key, value: args.value } }) });
  const view = settingsView(app);
  await flush();
  const row = (key) => find(view.columns.detail, (node) => node.classList.contains('setting') && node.dataset.key === key);
  return { app, view, row };
}

test('D16: an on/off setting the page may set is a switch, one press sends what Set sends, busy until the node answers, what happened said beside it', async () => {
  for (const code of ['en', 'es']) {
    let answer;
    const { app, row } = await settingsPage(code, { reply: () => new Promise((resolve) => { answer = resolve; }) });
    const ignore = row('ignore_usage_limits');
    const box = find(ignore, (node) => node.tag === 'input');
    assert.ok(box, `${code}: a switch in the row`);
    assert.equal(box.attrs.type, 'checkbox', 'a native checkbox underneath');
    assert.equal(box.attrs.role, 'switch');
    assert.equal(box.attrs['aria-label'], 'Ignore usage limits');
    assert.ok(box.classList.contains('toggle'));
    assert.equal(box.checked, false);
    assert.equal(find(ignore, (node) => node.tag === 'button' && /Change|Cambiar/.test(node.textContent)), null, 'no Change: the switch is the control');
    box.checked = true;
    box.dispatch('change');
    assert.deepEqual(app.sent.at(-1), { kind: 'set', args: { key: 'ignore_usage_limits', value: 'on' } }, 'what Set sends');
    assert.equal(box.disabled, true);
    assert.equal(box.attrs['aria-busy'], 'true');
    answer({ ok: true, result: { key: 'ignore_usage_limits', value: 'on' } });
    await flush();
    assert.equal(box.disabled, false);
    assert.equal(box.attrs['aria-busy'], undefined);
    assert.match(ignore.textContent, new RegExp(t('svSwitchedOn').slice(0, 12)));
    // The node refuses: said beside it, the switch put back.
    box.checked = false;
    box.dispatch('change');
    assert.deepEqual(app.sent.at(-1).args, { key: 'ignore_usage_limits', value: 'off' });
    answer({ ok: false, error: { code: 'refused', message: 'the node is stopping' } });
    await flush();
    assert.equal(box.checked, true, 'put back');
    assert.match(ignore.textContent, /the node is stopping/);
    app.leave();
  }
  setLanguage('en');
});

test('D16: a setting the node keeps to a terminal shows no control but Change and its reason; a page that reads gets no switch; choices are the shared select; numbers say their range; no file name in the row', async () => {
  for (const code of ['en', 'es']) {
    const { row, app } = await settingsPage(code);
    // lead_mail: a terminal's. Its value in words, Change, and (opened) the line and why.
    const mail = row('lead_mail');
    assert.equal(find(mail, (node) => node.tag === 'input'), null, 'no switch for what a page may not set');
    assert.match(find(mail, byClass('setting-value')).textContent, new RegExp(t('noOn')));
    find(mail, (node) => node.tag === 'button' && node.textContent === t('svChange')).click();
    const opened = row('lead_mail');
    assert.match(opened.textContent, /vibeswitcher set lead_mail/);
    assert.match(opened.textContent, new RegExp(t('svTerminalKeeps').slice(0, 20)));
    // A few named values: the shared select.
    find(row('boost'), (node) => node.tag === 'button' && node.textContent === t('svChange')).click();
    const select = find(row('boost'), (node) => node.tag === 'select');
    assert.ok(select?.parentNode.classList.contains('select'), 'kit’s select');
    // A number keeps its field, its range said beside it.
    find(row('node_heavy_slots'), (node) => node.tag === 'button' && node.textContent === t('svChange')).click();
    const slots = row('node_heavy_slots');
    assert.ok(find(slots, (node) => node.tag === 'input' && node.classList.contains('field')));
    assert.equal(find(slots, byClass('setting-range')).textContent, t('svRange', { low: 1, high: 12 }));
    // Where it is kept: behind its words, shortened, whole on hover; never in the row's own line.
    const file = find(slots, byClass('setting-file'));
    assert.equal(file.attrs.title, '~/.vibeswitcher/mac-limits.json');
    assert.doesNotMatch(find(slots, byClass('setting-about')).textContent, /mac-limits/);
    app.leave();
  }
  // A page that only reads: no switch anywhere; the flag's Change and line.
  const reading = await settingsPage('en', { acts: false });
  assert.equal(find(reading.row('ignore_usage_limits'), (node) => node.tag === 'input'), null);
  assert.ok(find(reading.row('ignore_usage_limits'), (node) => node.tag === 'button' && node.textContent === 'Change'));
  reading.app.leave();
  const { elided } = await import('../js/views/settings.js');
  assert.equal(elided('~/projects/site/.vibeswitcher/workflow.md'), '~/projects/…/.vibeswitcher/workflow.md');
  assert.equal(elided('~/.vibeswitcher/policy.md'), '~/.vibeswitcher/policy.md');
});
