// VibeSwitcher's web client. This file puts the pieces together: the store (what the node says), the feed that fills
// it (the node's WebSocket, or with ?mock an invented node that needs no server), the window's own state, the views
// and the keyboard.

import { createStore } from './js/store.js';
import { connectSocket } from './js/socket.js';
import { validate } from './wire/validators.js';
import { createUI, teamOf, projectHref } from './js/ui.js';
import { h, setText } from './js/dom.js';
import { since, until, lastPart, tilde, KEY, MAC } from './js/words.js';
import { t } from './js/i18n.js';
import { projectsOf, firstProject } from './js/conversation.js';
import { leftColumn, ownSession } from './js/views/left.js';
import { projectView } from './js/views/project.js';
import { rightColumn } from './js/views/right.js';
import { sideSheet } from './js/views/sheet.js';
import { ownSessionsView, newProjectView } from './js/views/own.js';
import { sessionView } from './js/views/session.js';
import { nodeView } from './js/views/node.js';
import { settingsView, settingsHref } from './js/views/settings.js';
import { statsView, statsHref } from './js/views/stats.js';
import { mailView, mailHref } from './js/views/mail.js';
import { palette } from './js/views/palette.js';
import { notifications } from './js/notify.js';
import { recentFolders, newEntries, endable, leadFolders } from './js/actions.js';
import { briefFoot, speech, speak } from './js/brief.js';
const params = new URLSearchParams(location.search);
const store = createStore();
const ui = createUI();
const mocked = params.has('mock') || params.has('still') || params.has('empty') || params.has('rows');
// The mock is loaded only for ?mock and its kin: the node's embedded page leaves it out (scripts/webapp-embed.sh), so
// there it says so; WebApp/serve.sh and a scratch server's folder serve it.
const feed = mocked
  ? await import('./js/mock.js').then(
    ({ createMock }) => createMock(store, { rows: Number(params.get('rows')) || 0, still: params.has('still'), empty: params.has('empty') }),
    (error) => {
      document.body.textContent = 'The mock (?mock) couldn\u2019t be loaded: the node\u2019s own page leaves it out; WebApp/serve.sh serves it.';
      throw error;
    })
  : connectSocket(store, {
    url: `ws://${location.host}/ws`,
    WebSocket,
    storage: sessionStorage,
    validate,
    // The page's own build, which `hello.assets` is weighed against: a newer one on the node reloads the page.
    build: fetch('build.json', { cache: 'no-cache' }).then((reply) => (reply.ok ? reply.json() : null)).then((json) => json?.assets || null, () => null),
  });
store.connect(feed);

// ?theme=dark or ?theme=light shows the other look without changing the system's; with neither it follows the system.
if (['dark', 'light'].includes(params.get('theme'))) document.documentElement.dataset.theme = params.get('theme');

const app = {
  store,
  ui,
  // The feed itself, for what goes past the store: a session's terminal (binary frames).
  feed,
  // The sessions the palette lists: your own first, then the leads', workers' and verifiers'.
  order: () => [...store.state.sessions.values()].sort((a, b) => ownSession(b) - ownSession(a)),
  commands,
  // On a phone the left and right columns are drawers over the centre: `which` opens one, null closes both.
  drawer(which) {
    root.dataset.drawer = which || '';
  },
};
// The browser's notifications when something needs you, and the title bar's count (js/notify.js).
app.notifications = notifications(app);

// Brief me (the Mac's Briefing), from the left column's summary: what happened and what's asked of you, as the node
// writes it, in the side sheet; read aloud by the browser's own speech where it has one.
const voice = speech();
function brief() {
  if (!store.can?.('brief')) return;
  sheet.open({ title: t('briefTitle'), text: t('briefing') });
  store.request('brief', {}).then((reply) => {
    if (!sheet.shown()) return;
    const result = reply.ok ? reply.result : null;
    let speaking = false;
    const speakButton = h('button', { class: 'button quiet', type: 'button', onclick: () => {
      if (speaking) { voice.synth.cancel(); return; }
      speaking = true;
      speakButton.textContent = t('stopSpeaking');
      speak(voice, result.text, result.language || 'en', () => { speaking = false; speakButton.textContent = t('speak'); });
    } }, t('speak'));
    sheet.open({ title: t('briefTitle'), text: result ? result.text : (reply.error?.message || t('briefFailed')),
      more: result ? [h('p', { class: 'brief-foot' }, [briefFoot(result), result.notice || ''].filter(Boolean).join(' ')), voice ? speakButton : null].filter(Boolean) : [] },
    () => { if (speaking) voice.synth.cancel(); });
  });
}

const sheet = sideSheet();
const left = leftColumn(app, { brief });
const project = projectView(app, { sheet });
const right = rightColumn(app);
const session = sessionView(app);
const own = ownSessionsView(app);
const newProject = newProjectView(app);
const node = nodeView(app);
const settings = settingsView(app);
const stats = statsView(app);
const mail = mailView(app);
const offline = h('div', { class: 'offline', role: 'status', hidden: true }, 'Reconnecting to the node…');
// The node doesn't know this page, or dropped it: said once, quietly, with the one thing that fixes it. The rows it
// had stay readable underneath.
const unpaired = h('div', { class: 'offline signed-out', role: 'status', hidden: true });
// What the centre says before there is anything to show: connecting, or not paired.
const waitingWords = h('h1', { class: 'big' });
const waitingSub = h('p');
const waiting = h('section', { class: 'centre screen status-screen', hidden: true }, h('div', { class: 'empty-state' }, waitingWords, waitingSub));
const centre = h('main', { class: 'centre-wrap' }, project.el, own.el, newProject.el, session.el, node.el, settings.el, stats.el, mail.el, waiting);
const root = document.getElementById('app');
const commandPalette = palette(app);
const scrim = h('div', { class: 'drawer-scrim', onclick: () => app.drawer(null) });
root.replaceChildren(left.el, centre, right.el, scrim, sheet.scrim, sheet.el, commandPalette.el, offline, unpaired, app.notifications.offer);

// `#/` opens the project with the most waiting on you, else the most active one, else Your own sessions; it takes
// the address's place (no history entry), so back doesn't land on it again.
function settleHome() {
  if (ui.state.route.name !== 'home') return false;
  const connection = store.state.connection;
  if (connection === 'connecting' || connection === 'unpaired' || connection === 'revoked') return false;
  const first = firstProject(projectsOf(store.state));
  location.replace(location.pathname + location.search + (first ? projectHref(first) : '#/sessions'));
  return true;
}

// A phone or a narrow window: the left and right columns are drawers (style.css).
const narrow = typeof matchMedia === 'function' ? matchMedia('(max-width: 900px)') : { matches: false };

function route() {
  if (settleHome()) return;
  const r = ui.state.route;
  const name = r.name;
  root.dataset.route = name;
  const connection = store.state.connection;
  const blank = name === 'home';
  const shown = { project: project.el, sessions: own.el, new: newProject.el, session: session.el, node: node.el, settings: settings.el, stats: stats.el, mail: mail.el };
  for (const [key, el] of Object.entries(shown)) el.hidden = key !== name;
  waiting.hidden = !blank;
  if (blank) {
    const off = connection === 'unpaired' || connection === 'revoked';
    setText(waitingWords, off ? t('unpaired') : t('connecting'));
    setText(waitingSub, off ? t('unpairedSub') : '');
  }
  // The right column: a project's lead conversation's; a session's inspector takes its place in the session view.
  const known = name === 'project' && (store.state.leads.has(r.id) || store.state.boards.has(r.id));
  root.classList.toggle('with-right', known && r.view === 'lead');
  // On a phone a task opens where it is drawn: in the right column, a drawer there.
  app.drawer(narrow.matches && known && r.view === 'lead' && r.task ? 'right' : null);
  // The side sheet belongs to the screen it opened on: a project's line stays open only while the address names it.
  if (!(name === 'project' && r.sheet)) sheet.close();
  left.render();
  if (name === 'project') { project.render(); right.render(); }
  if (name === 'sessions') own.render();
  if (name === 'new') newProject.render();
  const lead = name === 'project' ? store.state.leads.get(r.id) || store.state.boards.get(r.id) : null;
  const one = store.state.sessions.get(r.id);
  document.title = name === 'project' && lead ? `${lastPart(lead.root) || t('lead')} · VibeSwitcher` : name === 'session' && one ? `${one.title || 'Session'} · VibeSwitcher`
    : name === 'node' ? `${t('thisNode')} · VibeSwitcher` : name === 'settings' ? `${t('settings')} · VibeSwitcher` : name === 'stats' ? `${t('stats')} · VibeSwitcher`
      : name === 'mail' ? `${t('mail')} · VibeSwitcher` : name === 'sessions' ? `${t('ownSessions')} · VibeSwitcher` : name === 'new' ? `${t('newProject')} · VibeSwitcher` : 'VibeSwitcher';
  app.notifications.refresh?.();
}
ui.subscribe((what) => { if (what === 'route') route(); });
for (const topic of ['sessions', 'leads', 'boards', 'cards', 'connection', 'node']) store.subscribe(topic, () => { if (ui.state.route.name === 'home' || (ui.state.route.name === 'project' && !root.classList.contains('with-right') && ui.state.route.view === 'lead')) route(); else left.render(); });
store.subscribe('sessions', () => { if (ui.state.route.name === 'session') route(); });
route();

// On a phone, a screen's back arrow opens the left column, where every place is.
root.addEventListener('click', (event) => {
  if (narrow.matches && event.target.closest?.('.head .back')) { event.preventDefault(); app.drawer('left'); }
});

// Said only while it's true: nothing marks a working connection.
store.subscribe('connection', () => {
  const connection = store.state.connection;
  offline.hidden = connection !== 'reconnecting';
  unpaired.hidden = (connection !== 'unpaired' && connection !== 'revoked') || store.state.sessions.size === 0;
  if (!unpaired.hidden) {
    unpaired.replaceChildren(connection === 'revoked' ? 'This page’s access was revoked. ' : 'This page isn’t paired with the node. ',
      'Run ', h('code', null, 'vibeswitcher web'), ' in a terminal and open the address it prints.');
  }
});

// ---- Commands (the palette's, and the keys') ----

// ⌘J: the next project with something waiting on you, after the one shown.
function nextNeedingYou() {
  const waiting = projectsOf(store.state).filter((one) => one.waiting > 0);
  if (!waiting.length) return;
  const at = waiting.findIndex((one) => ui.state.route.name === 'project' && one.project === ui.state.route.id);
  ui.go(projectHref(waiting[(at + 1) % waiting.length].project));
}

// The palette's "New … in …" (the Mac's palette): each recent folder's presets as the node lists them, asked once a
// minute at most while the palette is open (Claude and Shell until the node answers). Running one shows the start
// page's form with that folder and preset, and the line that starts it.
const BUILT_INS = [{ name: 'Claude', kind: 'claude', builtIn: true }, { name: 'Shell', kind: 'shell', builtIn: true }];
const presetsByFolder = new Map();
function presetsOf(folder) {
  const known = presetsByFolder.get(folder);
  if ((!known || Date.now() - known.at > 60_000) && !known?.asking && store.can('session.presets')) {
    presetsByFolder.set(folder, { presets: known?.presets || BUILT_INS, at: known?.at || 0, asking: true });
    store.read('session.presets', { folder }).then((reply) => {
      const presets = reply?.ok && reply.result.presets.length ? reply.result.presets : presetsByFolder.get(folder)?.presets || BUILT_INS;
      presetsByFolder.set(folder, { presets, at: Date.now(), asking: false });
      commandPalette.refresh();
    }, () => presetsByFolder.set(folder, { presets: known?.presets || BUILT_INS, at: Date.now(), asking: false }));
  }
  return presetsByFolder.get(folder)?.presets || BUILT_INS;
}

function newCommands() {
  if (store.state.connection === 'unpaired' || store.state.connection === 'revoked') return [];
  const home = store.state.node?.home;
  const folders = recentFolders(store.state.sessions.values(), store.state.node?.ended);
  return newEntries(folders, presetsOf).map(({ folder, preset }) => ({
    title: `New ${preset.name} in ${lastPart(folder) || folder}`,
    about: `${tilde(folder, home)} · the line that starts it`,
    icon: 'plus',
    run: () => { ui.go('#/sessions'); own.choose(folder, preset.name); },
  }));
}

// The palette's "Start Project Lead in …" (the Mac's): the shown session's folder and the recent ones. Running one shows
// the start page's lead form with that folder, the goal to write, and the line that starts the lead.
function leadCommands(selected) {
  if (store.state.connection === 'unpaired' || store.state.connection === 'revoked') return [];
  const home = store.state.node?.home;
  return leadFolders(selected, store.state.sessions.values(), store.state.node?.ended).map((folder) => ({
    title: `Start Project Lead in ${lastPart(folder) || folder}`,
    about: `${tilde(folder, home)} · a lead that runs workers, has their work verified, and merges`,
    icon: 'team',
    run: () => { ui.go('#/new'); newProject.lead(folder); },
  }));
}

// The Mac's row menu for the session shown: each opens the line that does it, under its header.
function sessionCommands(selected) {
  if (!selected || selected.ended) return [];
  const act = (tab) => () => session.act(tab);
  return [
    { title: 'Rename Session…', about: 'Your name for it, kept across a resume', icon: 'pencil', run: act('rename') },
    selected.paused ? { title: 'Resume Notifications', about: 'It’s reminded and notified of again', icon: 'pause', run: act('pause') }
      : { title: 'Pause Session…', about: 'Greyed out, never reminded or notified of', icon: 'pause', run: act('pause') },
    ...(endable(selected) ? [{ title: 'End Session…', about: 'Its agent stops, with everything in its terminal', icon: 'close', run: act('end') }] : []),
    ...(selected.hosted && selected.cwd ? [{ title: 'Close Finished Shells…', about: `In ${lastPart(selected.cwd)}: the shells back at their prompt`, icon: 'terminal', run: act('shells') }] : []),
  ];
}

function commands() {
  const selected = ui.state.route.name === 'session' ? store.state.sessions.get(ui.state.route.id) : null;
  const pane = (id, title, key) => ({ title, keys: `${KEY.mod}${KEY.alt}${key}`, icon: id, run: () => ui.setPane(selected.id, id) });
  return [
    { title: 'Next Project Needing You', keys: `${KEY.mod}J`, icon: 'question', run: nextNeedingYou },
    ...(selected ? [pane('chat', 'Chat', '2'), pane('terminal', 'Terminal', '1')] : []),
    // The inspector's, for a session: the Mac's View › Toggle Inspector, and its Team tab for a lead or its team.
    ...(selected && teamOf(store.state, selected) ? [{ title: 'Team', about: 'The team’s tasks, in the inspector', keys: `${KEY.mod}${KEY.alt}3`, icon: 'team', run: () => ui.showInspector('team') }] : []),
    ...(selected ? [{ title: 'Toggle Inspector', about: 'Team, Overview and Activity', keys: `${KEY.mod}${KEY.alt}0`, icon: 'inspector', run: () => ui.toggleInspector() }] : []),
    // Each lead's board: its team's tasks, grouped (views/board.js).
    ...projectsOf(store.state).flatMap((one) => [
      { title: `Lead: ${one.name}`, about: 'You and its lead', icon: 'chat', run: () => ui.go(projectHref(one.project)) },
      { title: `Roadmap: ${one.name}`, about: 'Its tasks as they move', icon: 'team', run: () => ui.go(projectHref(one.project, { view: 'roadmap' })) },
    ]),
    ...sessionCommands(selected),
    // The chat's own (the Mac's Find, Copy as Markdown and Export Chat): of what the page holds of it.
    ...(selected && store.can('chat.page') ? [
      { title: 'Find in Chat', about: 'Every message of it this page holds', keys: `${KEY.mod}F`, icon: 'search', run: () => session.chat('find') },
      { title: 'Copy Chat as Markdown', about: 'The conversation, to the clipboard', icon: 'copy', run: () => session.chat('copyMarkdown') },
      { title: 'Export Chat…', about: 'The conversation as a Markdown file', icon: 'file', run: () => session.chat('exportChat') },
    ] : []),
    { title: t('ownSessions'), about: 'Sessions outside a project', icon: 'chat', run: () => ui.go('#/sessions') },
    { title: t('newProject'), about: 'Make a project, or start a lead in a folder', icon: 'plus', run: () => ui.go('#/new') },
    { title: 'This Node', about: 'Host, server, build and notices', icon: 'node', run: () => ui.go('#/node') },
    // The node's settings, and each lead's project's (views/settings.js).
    { title: 'Settings', about: 'Limits, Boost, the working policy', icon: 'settings', run: () => ui.go(settingsHref(null)) },
    // This browser's terminal look (Settings › Terminal, views/termlook.js): the Mac's Appearance.
    { title: 'Terminal Look', about: 'Theme, font, size, cursor and colours, in this browser', icon: 'terminal', run: () => ui.go(settingsHref(null)) },
    // The Mac's Statistics window (views/stats.js).
    ...(store.can('stats') ? [{ title: 'Statistics', about: 'Load, usage, merges, quality and cost, by project', icon: 'node', run: () => ui.go(statsHref('week')) }] : []),
    // What the projects' leads told each other (views/mail.js).
    { title: 'Between leads', about: 'The leads’ messages to each other', icon: 'chat', run: () => ui.go(mailHref) },
    ...[...store.state.leads.values()].filter((lead) => lead.root).map((lead) => ({ title: `Settings: ${lastPart(lead.root)}`, about: 'Its models, max_workers and review floor', icon: 'settings', run: () => ui.go(settingsHref(lead.project)) })),
    { title: app.notifications.enabled() ? 'Turn Notifications Off' : 'Turn Notifications On', about: 'When something needs you, while this page is open', icon: 'question', run: () => app.notifications.turn(!app.notifications.enabled()) },
    ...leadCommands(selected),
    ...newCommands(),
    // The mock's own: what a server restart looks like from here.
    ...(feed.restart ? [{ title: 'Restart the Mock Server', about: 'Shows the reconnect: nothing is lost, nothing reloads', icon: 'node', run: () => feed.restart() }] : []),
  ];
}

// ---- Keys ----
// The Mac app's where a browser lets a page have them: ⌘K the palette, ⌘J the next project waiting on you, and in a
// session ⌥⌘0 the inspector and ⌥⌘1 2 3 Terminal, Chat and Team, as on the Mac.

addEventListener('keydown', (event) => {
  // In a session's terminal the keyboard is the program's: Ctrl+K, Ctrl+J, Alt+F and the rest are its keys. A Mac's ⌘
  // keys stay the page's (the terminal sends none), and so do Ctrl+Alt+1 2 (Terminal, Chat) elsewhere.
  if (event.target?.closest?.('.terminal-pane:not(.is-watching) .terminal-screen') && !(MAC && event.metaKey)
    && !(!MAC && event.ctrlKey && event.altKey && /^Digit[12]$/.test(event.code))) return;
  const mod = MAC ? event.metaKey : event.ctrlKey;
  const digit = /^Digit[1-9]$/.test(event.code) ? Number(event.code.slice(5)) : 0;
  if (mod && !event.altKey && event.code === 'KeyK') {
    event.preventDefault();
    ui.setPalette(!ui.state.palette);
  } else if (ui.state.palette) {
    return;
  } else if (event.code === 'Digit0' && event.altKey && !event.shiftKey && ui.state.route.name === 'session') {
    // The Mac's ⌥⌘0 (Ctrl+Alt+0 elsewhere), and ⌥0 / Alt+0 where the browser or the system keeps that one. Never
    // AltGr+0, which types a character on some keyboards.
    if (event.getModifierState?.('AltGraph')) return;
    event.preventDefault();
    ui.toggleInspector();
  } else if (mod && event.altKey && digit >= 1 && digit <= 3 && ui.state.route.name === 'session') {
    event.preventDefault();
    if (digit < 3) ui.setPane(ui.state.route.id, digit === 1 ? 'terminal' : 'chat');
    else if (teamOf(store.state, store.state.sessions.get(ui.state.route.id))) ui.showInspector('team');
  } else if ((mod || event.altKey) && !event.shiftKey && event.code === 'KeyJ') {
    event.preventDefault();
    nextNeedingYou();
  } else if (event.key === 'Escape' && root.dataset.drawer) {
    app.drawer(null);
  }
});

// ---- The clock ----
// One timer keeps every duration on the page current ("39s", "asked 15m ago", "in 8 min"). It writes only what
// changed, and rests while the page is hidden.

function tick() {
  if (document.hidden) return;
  const now = Date.now();
  for (const el of document.querySelectorAll('[data-since]')) setText(el, since(el.dataset.since, now));
  for (const el of document.querySelectorAll('[data-ago]')) setText(el, t('askedAgo', { d: since(el.dataset.ago, now) }));
  for (const el of document.querySelectorAll('[data-until]')) setText(el, until(el.dataset.until, now));
}
setInterval(tick, 1000);
document.addEventListener('visibilitychange', tick);

feed.start();
