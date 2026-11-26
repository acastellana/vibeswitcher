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

// ---- D18: This node and the inspector in a person's words ----

const vectors = JSON.parse(readFileSync(new URL('../wire/vectors.json', import.meta.url), 'utf8'));
const nodeValue = () => ({ ...structuredClone(vectors['snapshot.node'].entries[0].value), home: '/home/dev',
  server: { pid: 48213, startedAt: '2026-11-23T09:00:00.000Z', commit: 'f62aef61c0ffee11' },
  builds: { installRoot: '/home/dev/.local/share/vibeswitcher', installed: ['f62aef61c0ffee11', '200e2c32', '5e563cf5'], rollback: { commit: '200e2c32', line: '200e2c32 v2 journal: an entry with no cgroup softens no mark' } },
  rule: { mode: 'systemd', says: 'a request is the user’s when its process is in a terminal’s scope of this login', scopes: [] },
  accepted: [{ kind: 'lead', action: 'b7e0', subject: '/home/dev/projects/example-site', at: '2026-11-23T10:00:00.000Z', pid: 51022, cgroup: '/init.scope', commandLine: ['vibeswitcher', 'lead', '/home/dev/projects/example-site'] }] });

async function nodeGroup(code, group) {
  setLanguage(code);
  const { nodeView } = await import('../js/views/node.js');
  const node = nodeValue();
  node.host.notes = { ...(node.host.notes || {}), build: node.server.commit };
  const app = fakeApp({ route: { name: 'node', group }, state: { node } });
  const view = nodeView(app);
  return { view, detail: view.columns.detail, list: view.columns.el };
}

test('D18: a build is a date and a name a person can say, its hash short and after them, whole on hover; who may act and what it took as yours in words', async () => {
  for (const code of ['en', 'es']) {
    const { detail, list } = await nodeGroup(code, 'build');
    const words = detail.textContent;
    assert.match(words, new RegExp(t('noBuildSince', { date: '' }).trim().slice(0, 10)), `${code}: since when it runs`);
    assert.match(words, /v2 journal: an entry with no cgroup softens no mark/, 'the rollback’s build by its name');
    const hashes = findAll(detail, byClass('node-hash'));
    assert.deepEqual(hashes.map((one) => one.textContent), ['f62aef6', '200e2c3', '5e563cf'], 'each 7 characters');
    assert.equal(hashes[0].attrs.title, 'f62aef61c0ffee11', 'whole on hover');
    assert.doesNotMatch(words, /f62aef61c0ffee11/);
    // The list's row says the day, not the hash.
    const row = find(list, (node) => node.dataset?.key === 'build');
    assert.doesNotMatch(row.textContent, /f62aef/);
    // Who may act: the mode in words.
    const rule = (await nodeGroup(code, 'rule'));
    assert.match(rule.detail.textContent, new RegExp(t('noRuleSystemd')));
    const ruleRow = find(rule.list, (node) => node.dataset?.key === 'rule').textContent;
    assert.doesNotMatch(ruleRow, /systemd/);
    assert.match(ruleRow, new RegExp(t('noRuleShortHere')), 'a word or two in the list');
    // What it took as yours: in words, the folder ~/…, no command line or cgroup.
    const accepted = (await nodeGroup(code, 'accepted')).detail.textContent;
    assert.match(accepted, new RegExp(t('noAccLead')));
    assert.match(accepted, /~\/projects\/example-site/);
    assert.doesNotMatch(accepted, /init\.scope|vibeswitcher lead/);
  }
  setLanguage('en');
});

test('D18: process ids, the node’s name and its state folder fold under Technical details, found by a search', async () => {
  const { detail } = await nodeGroup('en', 'server');
  const fold = find(detail, (node) => node.tag === 'details');
  assert.ok(fold && fold.classList.contains('node-technical'));
  assert.equal(find(fold, (node) => node.tag === 'summary').textContent, 'Technical details');
  assert.match(fold.textContent, /pid 48213/);
  const open = findAll(detail, (node) => node.classList.contains('fact') && !findAll(fold, (one) => one === node).length);
  assert.ok(open.every((one) => !/pid|State folder/.test(one.textContent)), 'nothing technical outside the fold');
  const host = (await nodeGroup('en', 'host')).detail;
  assert.match(find(host, (node) => node.tag === 'details').textContent, /pid/);
});

test('D18: the inspector folds the agent’s ids, process, command and size under Technical details; its folder is ~/… elided; its links are the shared quiet button', async () => {
  setLanguage('es');
  const { inspector } = await import('../js/views/inspector.js');
  const P = 'local:project:site';
  const lead = { id: 'local:lead', role: 'lead', lead: P, hosted: true, cwd: '/home/dev/projects/example-site', status: 'working', title: 'example-site' };
  const worker = { id: 'local:w1', hosted: true, cwd: '/home/dev/projects/example-site/.vibeswitcher/worktrees/fix-footer/packages/web', agent: 'claude', status: 'working',
    since: '2026-11-23T09:00:00.000Z', startedAt: '2026-11-23T08:00:00.000Z', agentSession: '01a9c3d7-aaaa', pid: 51022, terminal: 'pts/3', command: 'claude', size: { cols: 132, rows: 38 },
    role: 'worker', lead: P };
  const app = fakeApp({ state: { node: { home: '/home/dev' }, sessions: new Map([[lead.id, lead], [worker.id, worker]]) } });
  app.ui.state.inspector.tab = 'overview';
  const pane = inspector(app);
  pane.update(worker);
  const fold = find(pane.el, byClass('inspect-technical'));
  assert.ok(fold && fold.tag === 'details' && !fold.hidden);
  assert.equal(find(fold, (node) => node.tag === 'summary').textContent, 'Detalles técnicos');
  for (const words of ['01a9c3d7', '51022 en pts/3', 'claude', '132 × 38']) assert.match(fold.textContent, new RegExp(words));
  const folder = findAll(pane.el, byClass('inspect-row')).find((row) => row.children[0].textContent === t('inFolder'));
  assert.equal(folder.children[1].textContent, '~/projects/…/fix-footer/packages/web');
  assert.equal(folder.children[1].attrs.title, worker.cwd, 'whole on hover');
  // The worker's lead, in its Team rows.
  const link = find(pane.el, (node) => node.classList.contains('inspect-link') && node.textContent === 'example-site');
  assert.ok(link, 'the lead’s link');
  assert.deepEqual(link.attrs.class.split(' ').sort(), ['button', 'inspect-link', 'quiet', 'small']);
  // No look of its own: the quiet button's, which a touch screen makes a fingertip.
  assert.doesNotMatch(bareCss, /\.inspect-link \{[^}]*color/);
  assert.match(bareCss, /\.button, \.button\.small, \.button\.quiet,/);
  setLanguage('en');
});

// ---- D12: New session and New project ----

const shown = (el) => findAll(el, (node) => node.tag === 'button' && !node.hidden && !findAncestorHidden(node));
function findAncestorHidden(node) { for (let at = node.parentNode; at; at = at.parentNode) if (at.hidden) return true; return false; }
const primaries = (el) => shown(el).filter((node) => /(^| )button( |$)/.test(node.attrs.class || '') && !/plain|quiet/.test(node.attrs.class));

test('D12: New session is one short form: what (the presets, the default chosen, in words), the folder with the recent ones, the model, and one button that says what it starts', async () => {
  const { newSessionForm } = await import('../js/views/drive.js');
  for (const code of ['en', 'es']) {
    setLanguage(code);
    let read;
    const asked = new Promise((resolve) => { read = resolve; });
    const app = fakeApp({ route: { name: 'sessions' }, kinds: ['session.new', 'session.presets'], state: { node: { home: '/home/dev' } } });
    app.store.read = (kind, args) => { read(args); return Promise.resolve({ ok: true, result: { problems: [], presets: [
      { name: 'Opus', kind: 'claude', command: 'claude --model opus', env: ['MAX_THINKING_TOKENS'], keepShell: false, project: true, default: true, digest: 'd-opus', refused: null },
      { name: 'Claude', kind: 'claude', command: 'claude', env: [], keepShell: false, project: false, default: false, digest: 'd-claude', refused: null }] } }); };
    const form = newSessionForm(app, { folder: () => '/home/dev/projects/example-site', recent: () => ['/home/dev/projects/example-site', '/home/dev/projects/notes'] });
    form.update();
    // The node's presets for the folder: asked a moment after it is offered, drawn once they come.
    await asked;
    await flush();
    const labels = findAll(form.el, byClass('start-label')).filter((one) => !findAncestorHidden(one)).map((one) => one.textContent);
    assert.deepEqual(labels, [t('drWhat'), t('drWhereFolder')], `${code}: what and where (the preset sets its own model)`);
    const chosen = find(form.el, (node) => node.classList.contains('segment') && node.attrs['aria-pressed'] === 'true');
    assert.equal(chosen.textContent, 'Opus', 'the folder’s default chosen');
    const about = find(form.el, byClass('preset-about'));
    assert.equal(about.textContent, [t('drPwModel', { agent: 'Claude', model: 'Opus' }), t('drPwSettings', { n: 1 }), t('drFolderDefault')].join(' · '));
    assert.match(about.title, /claude --model opus/, 'the command on hover only');
    const field = find(form.el, (node) => node.tag === 'input' && node.attrs['aria-label'] === t('drFolder'));
    assert.equal(field.value, '~/projects/example-site', 'shown as ~/…');
    const one = primaries(form.el);
    assert.equal(one.length, 1, 'one primary action');
    assert.equal(one[0].textContent, t('drStartIn', { what: 'Opus', name: 'example-site' }));
    assert.doesNotMatch(form.el.shownText, /vibeswitcher|--model|MAX_THINKING/, 'no command where a person reads');
    // A recent folder, pressed, is the folder.
    find(find(form.el, byClass('start-recent')), (node) => node.tag === 'button' && node.textContent === 'notes').click();
    assert.equal(field.value, '~/projects/notes');
    one[0].click();
    assert.deepEqual(app.sent.at(-1), { kind: 'session.new', args: { folder: '/home/dev/projects/example-site', preset: 'Opus', digest: 'd-opus' } }, 'the button drawn for example-site');
  }
  setLanguage('en');
});

test('D12: where the page can’t act New session is the same form, ending in the line to copy and one sentence why', async () => {
  const { newSessionForm } = await import('../js/views/drive.js');
  const app = fakeApp({ route: { name: 'sessions' }, acts: false, kinds: ['session.new'], state: { node: { home: '/home/dev' } } });
  const form = newSessionForm(app, { folder: () => '/home/dev/projects/example-site', recent: () => [] });
  form.update();
  assert.deepEqual(findAll(form.el, byClass('start-label')).filter((one) => !findAncestorHidden(one)).map((one) => one.textContent), ['What to start', 'Folder', 'Model (optional)']);
  assert.equal(primaries(form.el).length, 0);
  assert.ok(find(form.el, byClass('copy-line')));
  assert.equal(findAll(form.el, byClass('start-why')).length, 1);
  assert.match(form.el.textContent, /doesn’t act for you here/);
  assert.equal(find(form.el, byClass('start-recent')).hidden, true, 'none recent: nothing offered');
});

test('D12: New project, for someone with no projects yet: a folder you have (the default) or a new one; no recent row; Start the lead waits for a folder; a new folder says plainly the page can’t make it, and offers the line, no button', async () => {
  const { newProjectView } = await import('../js/views/own.js');
  for (const code of ['en', 'es']) {
    setLanguage(code);
    const app = fakeApp({ route: { name: 'new' }, kinds: ['lead', 'recent'], state: { node: { home: '/home/dev', ended: [] } },
      reply: (kind) => (kind === 'recent' ? { ok: true, result: { projects: [] } } : { ok: true, result: {} }) });
    const view = newProjectView(app);
    view.render();
    await flush();
    view.render();
    assert.match(view.el.textContent, new RegExp(t('owProjectLede').slice(0, 30)), 'one sentence on what a project is');
    const modes = findAll(view.el, byClass('segment'));
    assert.deepEqual(modes.map((one) => [one.textContent, one.attrs['aria-pressed']]), [[t('owModeFolder'), 'true'], [t('owModeNew'), 'false']]);
    assert.equal(find(view.el, byClass('start-recent')).hidden, true);
    let start = primaries(view.el);
    assert.equal(start.length, 1);
    assert.equal(start[0].disabled, true, 'nothing to start until a folder is given');
    const folder = find(view.el, (node) => node.tag === 'input' && node.attrs['aria-label'] === t('drProjectFolder'));
    folder.value = '~/projects/shop';
    folder.dispatch('input');
    start = primaries(view.el);
    assert.equal(start[0].textContent, t('drStartLeadIn', { name: 'shop' }));
    start[0].click();
    assert.deepEqual(app.sent.at(-1), { kind: 'lead', args: { folder: '/home/dev/projects/shop' } });
    // A new folder: the form says so plainly, offers the line, no button.
    modes[1].click();
    const fresh = find(view.el, byClass('new-project'));
    assert.equal(fresh.hidden, false);
    assert.equal(find(view.el, byClass('new-lead')).hidden, true);
    const name = find(fresh, (node) => node.tag === 'input' && node.attrs['aria-label'] === t('drProjectName'));
    name.value = 'Shop';
    name.dispatch('input');
    assert.equal(primaries(fresh).length, 0, 'no button the node can’t serve');
    assert.match(fresh.textContent, new RegExp(t('drProjectTerminalOnly').slice(0, 30)));
    assert.match(find(fresh, byClass('copy-line')).textContent, /vibeswitcher new-project Shop/);
  }
  setLanguage('en');
});
