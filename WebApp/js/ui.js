// What this window shows, as opposed to what the node knows (store.js): the route, the list's grouping and filter,
// which pane a session shows, which teams are unfolded, the inspector. The route lives in the address
// (#/s/<session id>, #/p/<project id>, #/node), so the browser's back button works and a session can be linked to.

import { ATTENTION, stateOf, lastPart, taskCount } from './words.js';

function remembered(key, fallback) {
  try { return localStorage.getItem(key) ?? fallback; } catch { return fallback; }
}
function remember(key, value) {
  try { localStorage.setItem(key, value); } catch { /* private window: the choice lasts for this page */ }
}

export function parseRoute(hash) {
  const session = hash.match(/^#\/s\/(.+)$/);
  if (session) {
    try { return { name: 'session', id: decodeURIComponent(session[1]) }; } catch { return { name: 'home' }; }
  }
  const board = hash.match(/^#\/p\/(.+)$/);
  if (board) {
    try { return { name: 'board', id: decodeURIComponent(board[1]) }; } catch { return { name: 'home' }; }
  }
  return hash === '#/node' ? { name: 'node' } : { name: 'home' };
}

export const sessionHref = (id) => '#/s/' + encodeURIComponent(id);
// A project's board: its lead's tasks (views/board.js).
export const boardHref = (project) => '#/p/' + encodeURIComponent(project);

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
    grouping: remembered('vs.grouping', 'attention') === 'projects' ? 'projects' : 'attention',
    filter: '',
    // By session id: chat (the default), terminal or team.
    panes: new Map(),
    // The leads whose team is unfolded in the list.
    teams: new Set(),
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
    setGrouping(grouping) {
      if (state.grouping === grouping) return;
      state.grouping = grouping;
      remember('vs.grouping', grouping);
      changed('list');
    },
    setFilter(filter) { state.filter = filter; changed('list'); },
    toggleTeam(id) {
      if (!state.teams.delete(id)) state.teams.add(id);
      changed('list');
    },
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

// A lead's team in a few words, from its board: "team: 1 working · 1 in review · 1 blocked · 1 queued".
export function teamSummary(board) {
  if (!board) return null;
  const parts = ['running', 'review', 'blocked', 'failed', 'planned']
    .map((status) => [status, board.tasks.filter((task) => task.status === status).length])
    .filter(([, count]) => count > 0)
    .map(([status, count]) => taskCount(status, count));
  return 'team: ' + (parts.length ? parts.join(' · ') : 'none running');
}

// The list as it's shown: sections of rows, a lead's workers and verifiers folded under it (the Mac's sidebar).
// Attention: Needs you (longest waiting first), Working, Done (latest first), Idle. Projects: by folder, in the
// node's order. Returns { sections: [{ id, title, rows: [{ session, nested, team }] }], order: [session] }, `order`
// being the rows from top to bottom, which is what ⌘1–9 counts.
export function arrange(store, ui) {
  const all = [...store.sessions.values()];
  const leadOf = new Map();
  for (const session of all) if (session.role === 'lead' && session.lead) leadOf.set(session.lead, session);
  const teams = new Map();
  const top = [];
  for (const session of all) {
    const lead = session.role !== 'lead' && session.lead ? leadOf.get(session.lead) : null;
    if (lead) {
      if (!teams.has(lead.id)) teams.set(lead.id, []);
      teams.get(lead.id).push(session);
    } else top.push(session);
  }
  const needle = ui.filter.trim().toLowerCase();
  const matches = (session) => !needle || `${session.title || ''} ${projectOf(session)} ${session.detail || ''}`.toLowerCase().includes(needle);
  const shown = top.filter((session) => matches(session) || (teams.get(session.id) || []).some(matches));

  let groups;
  if (ui.grouping === 'projects') {
    const byProject = new Map();
    for (const session of shown) {
      const project = projectOf(session);
      if (!byProject.has(project)) byProject.set(project, []);
      byProject.get(project).push(session);
    }
    groups = [...byProject].map(([project, rows]) => ({ id: 'project:' + project, title: project, rows }));
  } else {
    const time = (session) => Date.parse(session.since) || 0;
    groups = ATTENTION.map((group) => {
      const rows = shown.filter((session) => group.has(stateOf(session)));
      if (group.id === 'needs-you') rows.sort((a, b) => time(a) - time(b));
      if (group.id === 'done') rows.sort((a, b) => time(b) - time(a));
      return { id: group.id, title: group.title, rows };
    }).filter((group) => group.rows.length);
  }

  const order = [];
  const sections = groups.map((group) => ({
    id: group.id,
    title: group.title,
    rows: group.rows.flatMap((session) => {
      const team = teams.get(session.id) || [];
      const open = ui.teams.has(session.id) || (needle && team.some(matches));
      const rows = [{ session, nested: false, team, open }];
      if (open) for (const member of team) rows.push({ session: member, nested: true, team: [], open: false });
      for (const row of rows) order.push(row.session);
      return rows;
    }),
  }));
  return { sections, order, total: all.length };
}

// "2 need you · 3 working": the list's foot (WindowGroups.summary), counting the rows the list shows at its top
// level: a lead's workers and verifiers are in its own team line. Empty when nothing needs you and nothing works.
export function summary(store) {
  const leads = new Set([...store.sessions.values()].filter((session) => session.role === 'lead').map((session) => session.lead));
  let needs = 0;
  let working = 0;
  for (const session of store.sessions.values()) {
    if (session.role !== 'lead' && leads.has(session.lead)) continue;
    const state = stateOf(session);
    if (state === 'needs-you') needs++;
    else if (state === 'working' || state === 'background') working++;
  }
  const parts = [];
  if (needs) parts.push(needs === 1 ? '1 needs you' : `${needs} need you`);
  if (working) parts.push(`${working} working`);
  return parts.join(' · ');
}
