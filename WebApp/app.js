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
import { register as registerPasskey } from './js/passkey.js';
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
// The build this page's files came from: their address names it (`/_/<build>/app.js`); by a plain path, /build.json.
function fetchBuild() {
  return fetch('build.json', { cache: 'no-cache' }).then((reply) => (reply.ok ? reply.json() : null)).then((json) => json?.assets || null, () => null);
}
function ownBuild() {
  const named = /\/_\/([^/]+)\//.exec(import.meta.url)?.[1];
  return named ? Promise.resolve(decodeURIComponent(named)) : fetchBuild();
}
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
    // The page's own build, which `hello.assets` is weighed against: the one its files were loaded from (`/_/<build>/`,
    // in this module's own address), else /build.json, asked again at a hello while it isn't known.
    build: ownBuild(),
    rebuild: fetchBuild,
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
  // A quiet project's "give it a goal": New project's lead form with its folder.
  startLead(folder) {
    ui.go('#/new');
    newProject.lead(folder);
  },
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
app.sheet = sheet;
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
const offline = h('div', { class: 'offline', role: 'status', hidden: true }, t('apReconnectingToTheNode'));
// The node doesn't know this page, or dropped it: said once, quietly, with the one thing that fixes it. The rows it
// had stay readable underneath.
const unpaired = h('div', { class: 'offline signed-out', role: 'status', hidden: true });
// A page that just redeemed a pairing code: the words to check against what `vibeswitcher web` shows, until the user
// confirms it there.
const confirming = h('div', { class: 'offline confirm-pairing', role: 'status', hidden: true });
// This tab acted for the user and no longer does, or the node serves a newer page than this acting tab runs: said at
// the top of the centre, on every screen, with why and the one thing that fixes it.
const tabBanner = h('div', { class: 'tab-banner', role: 'alert', hidden: true });
function drawTabBanner() {
  const state = store.state;
  const lost = state.actsLost && !store.acts();
  tabBanner.hidden = !lost && !state.newerBuild;
  if (tabBanner.hidden) return;
  if (!lost) {
    tabBanner.replaceChildren(h('span', null, h('strong', null, t('tbOlderBuild')), ' ', store.acts() ? t('tbOlderActing') : t('tbOlderReads')),
      h('button', { class: 'button small', type: 'button', onclick: () => store.reloadNow() }, t('tbReload')));
    return;
  }
  const level = state.node?.web?.acts?.level ?? (state.node?.web?.acts?.on ? 'trust' : 'off');
  const unconfirmed = state.actsLost === 'unconfirmed';
  const why = unconfirmed ? 'tbUnconfirmed' : state.actsLost === 'reloaded' ? 'tbReloaded' : level === 'off' ? 'tbTurnedOff' : 'tbEnded';
  // With acting off on the node, pairing again needs it on first: said too when the reason was another.
  const off = level === 'off' && !unconfirmed;
  tabBanner.replaceChildren(h('span', null, h('strong', null, t(unconfirmed ? 'tbNotPaired' : 'tbNoLonger')), ' ', t(why), ' ',
    off ? (why !== 'tbTurnedOff' ? t('tbOffToo') + ' ' : '') : unconfirmed ? '' : t('tbPairIt') + ' '),
    off ? h('code', null, 'vibeswitcher set web_acts trust') : null,
    off ? h('span', null, t('tbThen')) : null,
    h('code', null, 'vibeswitcher web'),
    h('button', { class: 'icon-button tab-banner-close', type: 'button', 'aria-label': t('close'), title: t('close'), onclick: () => store.forgetActsLost() }, '×'));
}
store.subscribe('connection', drawTabBanner);

// At `confirm`: while the browser asks for the passkey, what it approves, large; after, the vault's line for it.
const passkeyPill = h('div', { class: 'offline confirm-pairing passkey-pill', role: 'status', hidden: true });
let recordedTimer = null;
function drawPasskeyPill() {
  const { confirming, recorded } = store.state;
  passkeyPill.hidden = !confirming && !recorded;
  if (confirming) {
    passkeyPill.replaceChildren(h('span', null, t('pkConfirming')), h('strong', { class: 'phrase passkey-line' }, confirming.line), h('span', { class: 'sub' }, t('pkBrowserAsks')));
  } else if (recorded) {
    passkeyPill.replaceChildren(h('span', null, t('pkRecorded')), h('span', { class: 'passkey-line' }, recorded.line));
    clearTimeout(recordedTimer);
    recordedTimer = setTimeout(() => store.clearRecorded(), 8000);
  }
}
store.subscribe('connection', drawPasskeyPill);

// The terminal's offer to add a passkey (`vibeswitcher web --passkey`): at the top of the centre, one button.
const passkeyOffer = h('div', { class: 'tab-banner passkey-offer', role: 'status', hidden: true });
function drawPasskeyOffer() {
  const { passkeyOffer: offer, passkeyAdding: adding } = store.state;
  // Shown while the offer holds (`expires`) and this connection may answer it.
  const expired = offer?.expires && Date.parse(offer.expires) <= Date.now();
  passkeyOffer.hidden = !offer || expired || !store.can('passkey.registered');
  if (passkeyOffer.hidden) return;
  if (offer.expires) setTimeout(drawPasskeyOffer, Math.max(0, Date.parse(offer.expires) - Date.now()) + 50);
  const add = h('button', { class: 'button small', type: 'button', disabled: adding?.state === 'adding' || adding?.state === 'added', onclick: () => store.addPasskey(registerPasskey) }, t('pkAdd'));
  const named = store.state.pageWords ? h('span', { class: 'page-words' }, t('pkThisPage'), ' ', h('strong', null, store.state.pageWords)) : null;
  const said = !adding ? t('pkOffer') : adding.state === 'adding' ? t('pkAdding') : adding.state === 'added' ? t('pkAdded', { id: adding.id })
    : adding.state === 'cancelled' ? t('pkCancelled') : adding.state === 'unsupported' ? t('pkUnsupported') : t('pkRefused', { why: adding.why });
  passkeyOffer.replaceChildren(h('span', null, said), named, adding?.state === 'added' ? null : add);
}
store.subscribe('connection', drawPasskeyOffer);
store.subscribe('node', drawTabBanner);
// The page never sits scrolled sideways (a focus or a scroll into view past an edge could move it): put back at once.
const unscroll = () => {
  if (scrollX) scrollTo(0, scrollY);
  for (const el of [document.documentElement, document.body, root]) if (el && el.scrollLeft) el.scrollLeft = 0;
};
addEventListener('scroll', unscroll, { passive: true });
addEventListener('resize', unscroll);
document.addEventListener('focusin', () => requestAnimationFrame(unscroll));
// What the centre says before there is anything to show: connecting, or not paired.
const waitingWords = h('h1', { class: 'big' });
const waitingSub = h('p');
const waiting = h('section', { class: 'centre screen status-screen', hidden: true }, h('div', { class: 'empty-state' }, waitingWords, waitingSub));
const centre = h('main', { class: 'centre-wrap' }, tabBanner, passkeyOffer, project.el, own.el, newProject.el, session.el, node.el, settings.el, stats.el, mail.el, waiting);
const root = document.getElementById('app');
const commandPalette = palette(app);
const scrim = h('div', { class: 'drawer-scrim', onclick: () => app.drawer(null) });
root.replaceChildren(left.el, centre, right.el, scrim, sheet.scrim, sheet.el, commandPalette.el, offline, unpaired, confirming, passkeyPill, app.notifications.offer);

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
  document.title = name === 'project' && lead ? `${lastPart(lead.root) || t('lead')} · VibeSwitcher` : name === 'session' && one ? `${one.title || t('apSession')} · VibeSwitcher`
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
  const phrase = store.state.phrase;
  confirming.hidden = !phrase || connection === 'unpaired' || connection === 'revoked';
  if (!confirming.hidden) confirming.replaceChildren(h('span', null, t('apConfirmInTerminal')), h('strong', { class: 'phrase' }, phrase), h('span', { class: 'sub' }, t('apConfirmSub')));
  if (!unpaired.hidden) {
    unpaired.replaceChildren(connection === 'revoked' ? t('apThisPageSAccessWas') : t('apThisPageIsnTPaired'),
      t('apRun'), h('code', null, 'vibeswitcher web'), t('apInATerminalAndOpen'));
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
    title: t('apNewIn', { preset: preset.name, folder: lastPart(folder) || folder }),
    about: `${tilde(folder, home)} · ${t('apLineStarts')}`,
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
    title: t('apStartLeadIn', { folder: lastPart(folder) || folder }),
    about: `${tilde(folder, home)} · ${t('apLeadAbout')}`,
    icon: 'team',
    run: () => { ui.go('#/new'); newProject.lead(folder); },
  }));
}

// The Mac's row menu for the session shown: each opens the line that does it, under its header.
function sessionCommands(selected) {
  if (!selected || selected.ended) return [];
  const act = (tab) => () => session.act(tab);
  return [
    { title: t('apRenameSession'), about: t('apYourNameForItKept'), icon: 'pencil', run: act('rename') },
    selected.paused ? { title: t('apResumeNotifications'), about: t('apItSRemindedAndNotified'), icon: 'pause', run: act('pause') }
      : { title: t('apPauseSession'), about: t('apGreyedOutNeverRemindedOr'), icon: 'pause', run: act('pause') },
    ...(endable(selected) ? [{ title: t('apEndSession'), about: t('apItsAgentStopsWithEverything'), icon: 'close', run: act('end') }] : []),
    ...(selected.hosted && selected.cwd ? [{ title: t('apCloseFinishedShells'), about: t('apShellsIn', { folder: lastPart(selected.cwd) }), icon: 'terminal', run: act('shells') }] : []),
  ];
}

function commands() {
  const selected = ui.state.route.name === 'session' ? store.state.sessions.get(ui.state.route.id) : null;
  const pane = (id, title, key) => ({ title, keys: `${KEY.mod}${KEY.alt}${key}`, icon: id, run: () => ui.setPane(selected.id, id) });
  return [
    { title: t('apNextProjectNeedingYou'), keys: `${KEY.mod}J`, icon: 'question', run: nextNeedingYou },
    ...(selected ? [pane('chat', t('apChat'), '2'), pane('terminal', t('apTerminal'), '1')] : []),
    // The inspector's, for a session: the Mac's View › Toggle Inspector, and its Team tab for a lead or its team.
    ...(selected && teamOf(store.state, selected) ? [{ title: t('apTeam'), about: t('apTheTeamSTasksIn'), keys: `${KEY.mod}${KEY.alt}3`, icon: 'team', run: () => ui.showInspector('team') }] : []),
    ...(selected ? [{ title: t('apToggleInspector'), about: t('apTeamOverviewAndActivity'), keys: `${KEY.mod}${KEY.alt}0`, icon: 'inspector', run: () => ui.toggleInspector() }] : []),
    // Each lead's board: its team's tasks, grouped (views/board.js).
    ...projectsOf(store.state).flatMap((one) => [
      { title: t('apLeadOf', { name: one.name }), about: t('apYouAndItsLead'), icon: 'chat', run: () => ui.go(projectHref(one.project)) },
      { title: t('apRoadmapOf', { name: one.name }), about: t('apItsTasksAsTheyMove'), icon: 'team', run: () => ui.go(projectHref(one.project, { view: 'roadmap' })) },
    ]),
    ...sessionCommands(selected),
    // The chat's own (the Mac's Find, Copy as Markdown and Export Chat): of what the page holds of it.
    ...(selected && store.can('chat.page') ? [
      { title: t('apFindInChat'), about: t('apEveryMessageOfItThis'), keys: `${KEY.mod}F`, icon: 'search', run: () => session.chat('find') },
      { title: t('apCopyChatAsMarkdown'), about: t('apTheConversationToTheClipboard'), icon: 'copy', run: () => session.chat('copyMarkdown') },
      { title: t('apExportChat'), about: t('apTheConversationAsAMarkdown'), icon: 'file', run: () => session.chat('exportChat') },
    ] : []),
    { title: t('ownSessions'), about: t('apSessionsOutsideAProject'), icon: 'chat', run: () => ui.go('#/sessions') },
    { title: t('newProject'), about: t('apMakeAProjectOrStart'), icon: 'plus', run: () => ui.go('#/new') },
    { title: t('apThisNode'), about: t('apHostServerBuildAndNotices'), icon: 'node', run: () => ui.go('#/node') },
    // The node's settings, and each lead's project's (views/settings.js).
    { title: t('apSettings'), about: t('apLimitsBoostTheWorkingPolicy'), icon: 'settings', run: () => ui.go(settingsHref(null)) },
    // This browser's terminal look (Settings › Terminal, views/termlook.js): the Mac's Appearance.
    { title: t('apTerminalLook'), about: t('apThemeFontSizeCursorAnd'), icon: 'terminal', run: () => ui.go(settingsHref(null)) },
    // The Mac's Statistics window (views/stats.js).
    ...(store.can('stats') ? [{ title: t('apStatistics'), about: t('apLoadUsageMergesQualityAnd'), icon: 'node', run: () => ui.go(statsHref('week')) }] : []),
    // What the projects' leads told each other (views/mail.js).
    { title: t('apBetweenLeads'), about: t('apTheLeadsMessagesToEach'), icon: 'chat', run: () => ui.go(mailHref) },
    ...[...store.state.leads.values()].filter((lead) => lead.root).map((lead) => ({ title: t('apSettingsOf', { name: lastPart(lead.root) }), about: t('apItsModelsMaxWorkersAnd'), icon: 'settings', run: () => ui.go(settingsHref(lead.project)) })),
    { title: app.notifications.enabled() ? t('apTurnNotificationsOff') : t('apTurnNotificationsOn'), about: t('apWhenSomethingNeedsYouWhile'), icon: 'question', run: () => app.notifications.turn(!app.notifications.enabled()) },
    ...leadCommands(selected),
    ...newCommands(),
    // The mock's own: what a server restart looks like from here.
    ...(feed.restart ? [{ title: t('apRestartTheMockServer'), about: t('apShowsTheReconnectNothingIs'), icon: 'node', run: () => feed.restart() }] : []),
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
