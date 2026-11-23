// What this window shows, as opposed to what the node knows (store.js): the route, which pane a session shows, the
// inspector. The route lives in the address
// (parseRoute below), so the browser's back button works and anything on screen can be linked to.

import { lastPart } from './words.js';

function remembered(key, fallback) {
  try { return localStorage.getItem(key) ?? fallback; } catch { return fallback; }
}
function remember(key, value) {
  try { localStorage.setItem(key, value); } catch { /* private window: the choice lasts for this page */ }
}

// The address says what is on screen (the redesign's "Deep links"), and back and forward walk it:
//   #/p/<project>/lead?show=asks|all&tab=stats|files&task=<slug>&sheet=<line>   a project's lead conversation
//   #/p/<project>/roadmap?open=<band>,…                                          its roadmap
//   #/sessions, #/s/<session>, #/node, #/settings[/<project>], #/stats[/<range>], #/mail, #/new
// The old addresses still work: #/p/<project> (the board page) is its lead conversation, #/s/<session> a session.
const decode = (text) => { try { return decodeURIComponent(text); } catch { return null; } };
const SHOWS = ['asks', 'all'];
const TABS_RIGHT = ['stats', 'files'];

export function parseRoute(hash) {
  const at = hash.indexOf('?');
  const path = at < 0 ? hash : hash.slice(0, at);
  const query = new URLSearchParams(at < 0 ? '' : hash.slice(at + 1));
  const session = path.match(/^#\/s\/(.+)$/);
  if (session) {
    const id = decode(session[1]);
    return id === null ? { name: 'home' } : { name: 'session', id };
  }
  const project = path.match(/^#\/p\/([^/]+)(?:\/(lead|roadmap))?\/?$/);
  if (project) {
    const id = decode(project[1]);
    if (id === null) return { name: 'home' };
    if (project[2] === 'roadmap') return { name: 'project', id, view: 'roadmap', open: (query.get('open') || '').split(',').filter(Boolean) };
    return {
      name: 'project', id, view: 'lead',
      show: SHOWS.includes(query.get('show')) ? query.get('show') : 'decisions',
      tab: TABS_RIGHT.includes(query.get('tab')) ? query.get('tab') : 'team',
      task: query.get('task') || null,
      sheet: query.get('sheet') || null,
    };
  }
  // Settings: the node's, and a project's with its id (views/settings.js).
  const settings = path.match(/^#\/settings(?:\/(.+))?$/);
  if (settings) return { name: 'settings', id: settings[1] ? decode(settings[1]) : null };
  // Statistics, for a range (views/stats.js).
  const stats = path.match(/^#\/stats(?:\/([a-z]+))?$/);
  if (stats) return { name: 'stats', id: stats[1] || null };
  const named = { '#/mail': 'mail', '#/node': 'node', '#/sessions': 'sessions', '#/new': 'new' }[path];
  return named ? { name: named } : { name: 'home' };
}

export const sessionHref = (id) => '#/s/' + encodeURIComponent(id);

// A project's address: its lead conversation (with the dial, the right column's tab, the task open and the sheet
// open, each only when not the default), or its roadmap with its bands open.
export function projectHref(project, { view = 'lead', show = 'decisions', tab = 'team', task = null, sheet = null, open = [] } = {}) {
  const query = new URLSearchParams();
  if (view === 'roadmap') {
    if (open.length) query.set('open', open.join(','));
  } else {
    if (SHOWS.includes(show)) query.set('show', show);
    if (TABS_RIGHT.includes(tab)) query.set('tab', tab);
    if (task) query.set('task', task);
    if (sheet) query.set('sheet', sheet);
  }
  const said = query.toString().replaceAll('%2C', ',');
  return `#/p/${encodeURIComponent(project)}/${view === 'roadmap' ? 'roadmap' : 'lead'}${said ? '?' + said : ''}`;
}
// The board page's address before the redesign: the project's lead conversation now.
export const boardHref = (project) => projectHref(project);

// The route `route` with some of its parts changed, as an address.
export function routeHref(route, changes) {
  const next = { ...route, ...changes };
  return projectHref(next.id, next);
}

// The inspector is a column beside the chat from this width up; under it the chat would get cramped, so it is a sheet
// over the chat, opened when asked and closed again by itself.
const WIDE = '(min-width: 1180px)';
const TABS = ['team', 'overview', 'activity'];

// The inspector's tab for the one remembered (the Mac's `InspectorView.effectiveTab`): Team on a session with no team
// is Overview there, and Team again back on a lead, so the remembered one stays.
export function inspectorTab(stored, team) {
  if (stored === 'team') return team ? 'team' : 'overview';
  return stored === 'activity' ? 'activity' : 'overview';
}

// The project whose team a session is in (a lead's own; a worker's or a verifier's lead's), when the node has said
// which and knows that lead or its board. Null: no Team to show.
export function teamOf(store, session) {
  const project = session?.role ? session.lead : null;
  return project && (store.leads.has(project) || store.boards.has(project)) ? project : null;
}

export function createUI() {
  const state = {
    route: parseRoute(location.hash),
    // By session id: chat (the default), terminal or team.
    panes: new Map(),
    palette: false,
    // The inspector: `open` is the column's (remembered in this browser), `sheet` the sheet's (never remembered: it
    // covers the chat), `tab` the one remembered (Team, Overview or Activity).
    inspector: {
      open: remembered('vs.inspector', 'open') !== 'closed',
      sheet: false,
      tab: TABS.includes(remembered('vs.inspector.tab', '')) ? remembered('vs.inspector.tab', '') : 'overview',
    },
  };
  const listeners = new Set();
  const changed = (what) => { for (const fn of listeners) fn(what); };
  const wide = typeof matchMedia === 'function' ? matchMedia(WIDE) : { matches: true, addEventListener() {} };

  addEventListener('hashchange', () => {
    state.route = parseRoute(location.hash);
    // A sheet belongs to the session it was opened over.
    if (state.route.name !== 'session') state.inspector.sheet = false;
    changed('route');
  });
  // The window crossed the width: a sheet doesn't become a column (the column has its own remembered state).
  wide.addEventListener('change', () => {
    state.inspector.sheet = false;
    changed('inspector');
  });

  return {
    state,
    subscribe(fn) { listeners.add(fn); return () => listeners.delete(fn); },
    go(hash) { if (location.hash !== hash) location.hash = hash; },
    select(id) { this.go(sessionHref(id)); },
    pane(id) { return state.panes.get(id) || 'chat'; },
    setPane(id, pane) {
      if (this.pane(id) === pane) return;
      state.panes.set(id, pane);
      changed('pane');
    },
    setPalette(open) {
      if (state.palette === open) return;
      state.palette = open;
      changed('palette');
    },
    // Whether the window has room for the inspector as a column; else it's a sheet.
    inspectorWide: () => wide.matches,
    inspectorShown: () => (wide.matches ? state.inspector.open : state.inspector.sheet),
    setInspector(shown) {
      if (this.inspectorShown() === shown) return;
      if (wide.matches) {
        state.inspector.open = shown;
        remember('vs.inspector', shown ? 'open' : 'closed');
      } else state.inspector.sheet = shown;
      changed('inspector');
    },
    toggleInspector() { this.setInspector(!this.inspectorShown()); },
    setInspectorTab(tab) {
      if (!TABS.includes(tab) || state.inspector.tab === tab) return;
      state.inspector.tab = tab;
      remember('vs.inspector.tab', tab);
      changed('inspector');
    },
    // The inspector on `tab`, opened if it wasn't (the Team strip's button, ⌥⌘3).
    showInspector(tab) {
      this.setInspectorTab(tab);
      this.setInspector(true);
    },
  };
}

export const projectOf = (session) => lastPart(session.cwd) || 'No folder';

// A lead's row marks (the Mac's `WindowRowView`): `replaced` when another session of its project replaced it (the
// lead's record lists it), `allDone` while its board's all-done mark is unseen (never on a replaced one).
export function leadMarks(state, session) {
  if (session?.role !== 'lead') return { replaced: false, allDone: false };
  // A replaced one leads nothing (`lead` null): its project is `replacedFrom` (wire.js).
  const replaced = !!session.replacedFrom || !!state.leads.get(session.lead)?.replaced?.includes(session.id);
  const done = state.boards.get(session.lead)?.allDone;
  return { replaced, allDone: !replaced && !!done && !done.seen };
}
