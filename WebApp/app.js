// VibeSwitcher's web client. This file puts the pieces together: the store (what the node says), the feed that fills
// it (the node's WebSocket, or with ?mock an invented node that needs no server), the window's own state, the views
// and the keyboard.

import { createStore } from './js/store.js';
import { createMock } from './js/mock.js';
import { connectSocket } from './js/socket.js';
import { validate } from './wire/validators.js';
import { createUI, arrange, teamOf, boardHref } from './js/ui.js';
import { h, setText } from './js/dom.js';
import { since, until, stateOf, lastPart, KEY, MAC } from './js/words.js';
import { sidebar } from './js/views/sidebar.js';
import { sessionView } from './js/views/session.js';
import { nodeView } from './js/views/node.js';
import { boardView } from './js/views/board.js';
import { startView } from './js/views/start.js';
import { palette } from './js/views/palette.js';
import { notifications } from './js/notify.js';

const params = new URLSearchParams(location.search);
const store = createStore();
const ui = createUI();
const mocked = params.has('mock') || params.has('still') || params.has('empty') || params.has('rows');
const feed = mocked
  ? createMock(store, { rows: Number(params.get('rows')) || 0, still: params.has('still'), empty: params.has('empty') })
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
  // The sessions from top to bottom, as the list shows them.
  order: () => list.order(),
  commands,
};
// The browser's notifications when something needs you, and the title bar's count (js/notify.js).
app.notifications = notifications(app);

const list = sidebar(app);
const session = sessionView(app);
const node = nodeView(app);
const board = boardView(app);
const start = startView(app);
const offline = h('div', { class: 'offline', role: 'status', hidden: true }, 'Reconnecting to the node…');
// The node doesn't know this page, or dropped it: said once, quietly, with the one thing that fixes it. The rows it
// had stay readable underneath.
const unpaired = h('div', { class: 'offline signed-out', role: 'status', hidden: true });
const main = h('main', { class: 'main' }, start.el, session.el, node.el, board.el);
const root = document.getElementById('app');
root.replaceChildren(list.el, main, palette(app).el, offline, unpaired, app.notifications.offer);

function route() {
  const name = ui.state.route.name;
  root.dataset.route = name;
  start.el.hidden = name !== 'home';
  session.el.hidden = name !== 'session';
  node.el.hidden = name !== 'node';
  board.el.hidden = name !== 'board';
  if (name === 'board') return; // the board names itself (views/board.js)
  const shown = store.state.sessions.get(ui.state.route.id);
  document.title = name === 'session' && shown ? `${shown.title || 'Session'} · VibeSwitcher` : name === 'node' ? 'This node · VibeSwitcher' : 'VibeSwitcher';
}
ui.subscribe((what) => { if (what === 'route') route(); });
store.subscribe('sessions', route);
route();

// Said only while it's true: nothing marks a working connection.
store.subscribe('connection', () => {
  const connection = store.state.connection;
  offline.hidden = connection !== 'reconnecting';
  // With no rows the start page says it already; the mark is for rows that stay readable but won't change.
  unpaired.hidden = (connection !== 'unpaired' && connection !== 'revoked') || store.state.sessions.size === 0;
  if (!unpaired.hidden) {
    unpaired.replaceChildren(connection === 'revoked' ? 'This page’s access was revoked. ' : 'This page isn’t paired with the node. ',
      'Run ', h('code', null, 'vibeswitcher web'), ' in a terminal and open the address it prints.');
  }
});

// ---- Commands (the palette's, and the keys') ----

function nextNeedingYou() {
  const order = arrange(store.state, { ...ui.state, filter: '', teams: new Set(store.state.sessions.keys()) }).order.filter((entry) => stateOf(entry) === 'needs-you');
  if (!order.length) return;
  const at = order.findIndex((entry) => entry.id === ui.state.route.id);
  ui.select(order[(at + 1) % order.length].id);
}

function step(by) {
  const order = list.order();
  if (!order.length) return;
  const at = order.findIndex((entry) => entry.id === ui.state.route.id);
  ui.select(order[at < 0 ? 0 : (at + by + order.length) % order.length].id);
}

function commands() {
  const selected = ui.state.route.name === 'session' ? store.state.sessions.get(ui.state.route.id) : null;
  const pane = (id, title, key) => ({ title, keys: `${KEY.mod}${KEY.alt}${key}`, icon: id, run: () => ui.setPane(selected.id, id) });
  return [
    { title: 'Next Session Needing You', keys: `${KEY.mod}J`, icon: 'question', run: nextNeedingYou },
    ...(selected ? [pane('chat', 'Chat', '2'), pane('terminal', 'Terminal', '1')] : []),
    // The inspector's, for a session: the Mac's View › Toggle Inspector, and its Team tab for a lead or its team.
    ...(selected && teamOf(store.state, selected) ? [{ title: 'Team', about: 'The team’s tasks, in the inspector', keys: `${KEY.mod}${KEY.alt}3`, icon: 'team', run: () => ui.showInspector('team') }] : []),
    ...(selected ? [{ title: 'Toggle Inspector', about: 'Team, Overview and Activity', keys: `${KEY.mod}${KEY.alt}0`, icon: 'inspector', run: () => ui.toggleInspector() }] : []),
    // Each lead's board: its team's tasks, grouped (views/board.js).
    ...[...store.state.boards.values()].map((board) => ({ title: `Board: ${lastPart(board.root) || 'a project'}`, about: 'Its lead’s tasks, as they move', icon: 'team', run: () => ui.go(boardHref(board.project)) })),
    { title: 'Start Page', icon: 'home', run: () => ui.go('#/') },
    { title: 'This Node', about: 'Host, server, build and notices', icon: 'node', run: () => ui.go('#/node') },
    { title: app.notifications.enabled() ? 'Turn Notifications Off' : 'Turn Notifications On', about: 'When something needs you, while this page is open', icon: 'question', run: () => app.notifications.turn(!app.notifications.enabled()) },
    { title: 'Group by Attention', icon: 'filter', run: () => ui.setGrouping('attention') },
    { title: 'Group by Project', icon: 'filter', run: () => ui.setGrouping('projects') },
    { title: 'Filter Sessions', keys: `${KEY.alt}F`, icon: 'search', run: () => list.focusFilter() },
    // The mock's own: what a server restart looks like from here.
    ...(feed.restart ? [{ title: 'Restart the Mock Server', about: 'Shows the reconnect: nothing is lost, nothing reloads', icon: 'node', run: () => feed.restart() }] : []),
  ];
}

// ---- Keys ----
// The Mac app's where a browser lets a page have them. ⌘1–9 belongs to the browser's tabs (it reaches the page only
// in an installed window), so ⌥1–9 does the same everywhere. ⌥⌘0 is the inspector's, as on the Mac.

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
  } else if ((mod || event.altKey) && !(mod && event.altKey) && !event.shiftKey && digit) {
    const target = list.order()[digit - 1];
    if (target) { event.preventDefault(); ui.select(target.id); }
  } else if ((mod || event.altKey) && !event.shiftKey && event.code === 'KeyJ') {
    event.preventDefault();
    nextNeedingYou();
  } else if (event.altKey && !mod && (event.key === 'ArrowDown' || event.key === 'ArrowUp')) {
    event.preventDefault();
    step(event.key === 'ArrowDown' ? 1 : -1);
  } else if (event.altKey && !mod && event.code === 'KeyF') {
    event.preventDefault();
    list.focusFilter();
  }
});

// ---- The clock ----
// One timer keeps every duration on the page current ("39s", "asked 15m ago", "in 8 min"). It writes only what
// changed, and rests while the page is hidden.

function tick() {
  if (document.hidden) return;
  const now = Date.now();
  for (const el of document.querySelectorAll('[data-since]')) setText(el, since(el.dataset.since, now));
  for (const el of document.querySelectorAll('[data-ago]')) setText(el, `asked ${since(el.dataset.ago, now)} ago`);
  for (const el of document.querySelectorAll('[data-until]')) setText(el, until(el.dataset.until, now));
}
setInterval(tick, 1000);
document.addEventListener('visibilitychange', tick);

feed.start();
