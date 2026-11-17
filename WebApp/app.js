// VibeSwitcher's web client. This file puts the pieces together: the store (what the node says), the feed that fills
// it (a mock until the WebSocket exists), the window's own state, the views and the keyboard.

import { createStore } from './js/store.js';
import { createMock } from './js/mock.js';
import { createUI, arrange } from './js/ui.js';
import { h, setText } from './js/dom.js';
import { since, until, stateOf, KEY, MAC } from './js/words.js';
import { sidebar } from './js/views/sidebar.js';
import { sessionView } from './js/views/session.js';
import { nodeView } from './js/views/node.js';
import { startView } from './js/views/start.js';
import { palette } from './js/views/palette.js';

const params = new URLSearchParams(location.search);
const store = createStore();
const ui = createUI();
const feed = createMock(store, { rows: Number(params.get('rows')) || 0, still: params.has('still'), empty: params.has('empty') });
store.connect(feed);

// ?theme=dark or ?theme=light shows the other look without changing the system's; with neither it follows the system.
if (['dark', 'light'].includes(params.get('theme'))) document.documentElement.dataset.theme = params.get('theme');

const app = {
  store,
  ui,
  // The sessions from top to bottom, as the list shows them.
  order: () => list.order(),
  commands,
};

const list = sidebar(app);
const session = sessionView(app);
const node = nodeView(app);
const start = startView(app);
const offline = h('div', { class: 'offline', role: 'status', hidden: true }, 'Reconnecting to the node…');
const main = h('main', { class: 'main' }, start.el, session.el, node.el);
const root = document.getElementById('app');
root.replaceChildren(list.el, main, palette(app).el, offline);

function route() {
  const name = ui.state.route.name;
  root.dataset.route = name;
  start.el.hidden = name !== 'home';
  session.el.hidden = name !== 'session';
  node.el.hidden = name !== 'node';
  const shown = store.state.sessions.get(ui.state.route.id);
  document.title = name === 'session' && shown ? `${shown.title || 'Session'} · VibeSwitcher` : name === 'node' ? 'This node · VibeSwitcher' : 'VibeSwitcher';
}
ui.subscribe((what) => { if (what === 'route') route(); });
store.subscribe('sessions', route);
route();

// Said only while it's true: nothing marks a working connection.
store.subscribe('connection', () => { offline.hidden = store.state.connection !== 'reconnecting'; });

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
  const pane = (id, title, key) => ({ title, keys: `${KEY.mod}${KEY.alt}${key}`, icon: id === 'team' ? 'team' : id, run: () => ui.setPane(selected.id, id) });
  return [
    { title: 'Next Session Needing You', keys: `${KEY.mod}J`, icon: 'question', run: nextNeedingYou },
    ...(selected ? [pane('chat', 'Chat', '2'), pane('terminal', 'Terminal', '1')] : []),
    ...(selected?.role === 'lead' ? [pane('team', 'Team', '3')] : []),
    { title: 'Start Page', icon: 'home', run: () => ui.go('#/') },
    { title: 'This Node', about: 'Host, server, build and notices', icon: 'node', run: () => ui.go('#/node') },
    { title: 'Group by Attention', icon: 'filter', run: () => ui.setGrouping('attention') },
    { title: 'Group by Project', icon: 'filter', run: () => ui.setGrouping('projects') },
    { title: 'Filter Sessions', keys: `${KEY.alt}F`, icon: 'search', run: () => list.focusFilter() },
    // The mock's own: what a server restart looks like from here.
    ...(feed.restart ? [{ title: 'Restart the Mock Server', about: 'Shows the reconnect: nothing is lost, nothing reloads', icon: 'node', run: () => feed.restart() }] : []),
  ];
}

// ---- Keys ----
// The Mac app's where a browser lets a page have them. ⌘1–9 belongs to the browser's tabs (it reaches the page only
// in an installed window), so ⌥1–9 does the same everywhere.

addEventListener('keydown', (event) => {
  const mod = MAC ? event.metaKey : event.ctrlKey;
  const digit = /^Digit[1-9]$/.test(event.code) ? Number(event.code.slice(5)) : 0;
  if (mod && !event.altKey && event.code === 'KeyK') {
    event.preventDefault();
    ui.setPalette(!ui.state.palette);
  } else if (ui.state.palette) {
    return;
  } else if (mod && event.altKey && digit >= 1 && digit <= 3 && ui.state.route.name === 'session') {
    event.preventDefault();
    ui.setPane(ui.state.route.id, ['terminal', 'chat', 'team'][digit - 1]);
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
