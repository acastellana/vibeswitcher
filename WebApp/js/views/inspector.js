// The inspector (the Mac's InspectorView): beside the selected session, its Team (a lead's own, or the one a worker or
// a verifier is in), an Overview of facts about it, and its Activity (the files it changed and the commands it ran).
// A column where the window has room, a sheet over the chat where it doesn't (ui.js says which).
//
// Every value is one the node sent. A fact the node doesn't send has no row, and a tab it sends nothing for says so in
// one line. Rows are written in place (`setText`), and a fact that comes and goes while you watch keeps its row, so
// nothing under it moves. Nothing is drawn while the inspector is closed.

import { h, keyed, setText, setClass, framed } from '../dom.js';
import { statusMark, setMark, icon } from '../marks.js';
import { STATES, AGENTS, ROLES, stateOf, since, short, moment, tilde, plural } from '../words.js';
import { sessionHref, inspectorTab, teamOf, projectOf } from '../ui.js';
import { ledger, fileWords, usageWords, costWords } from '../activity.js';
import { teamTasks } from './lead.js';
import { boardRecords } from './records.js';

const TABS = [{ id: 'team', label: 'Team' }, { id: 'overview', label: 'Overview' }, { id: 'activity', label: 'Activity' }];
// How close to the end of the Activity counts as being at its end.
const NEAR = 48;
// How often the Overview asks for a session's tokens and cost again while it shows.
const USAGE_EVERY = 15_000;


// A fact: its name, dim, and its value, plain.
function fact(name, ...content) {
  const dt = h('dt', null, name);
  const dd = h('dd', null, content);
  const el = h('div', { class: 'inspect-row' }, dt, dd);
  return {
    el, dt, dd,
    // Its value as text. With nothing to say the row is left out.
    say(text, whole = null) {
      el.hidden = !text;
      setText(dd, text || '');
      if (whole) dd.title = whole; else dd.removeAttribute('title');
    },
    // The same for a fact that comes and goes while you watch: a dash holds its place.
    hold(text) {
      setText(dd, text || '—');
      setClass(dd, 'none', !text);
      if (text) dd.title = text; else dd.removeAttribute('title');
    },
  };
}

// A titled group of facts, left out while none of them has anything to say.
function group(title, ...facts) {
  const el = h('section', { class: 'inspect-group' }, h('h2', { class: 'group-head' }, title), h('dl', null, facts.map((entry) => entry.el)));
  return { el, settle() { el.hidden = facts.every((entry) => entry.el.hidden); } };
}

// The lead session of `project`, as a link's text and address (nothing while the node lists no such session).
function leadOf(store, project) {
  for (const session of store.state.sessions.values()) {
    if (session.role === 'lead' && session.lead === project) return session;
  }
  return null;
}
function pointAt(link, session) {
  setText(link, session ? session.title || projectOf(session) : '');
  if (session) link.setAttribute('href', sessionHref(session.id)); else link.removeAttribute('href');
}

// Overview: Status, Place, Time, Agent (the Mac's sections and names), and Team for a session with a role.
function overview(app) {
  const { store } = app;
  const mark = statusMark('unknown', 10);
  const word = h('span');
  const time = h('time');
  const shown = h('span', { class: 'inspect-state' }, mark, word, time);
  const state = fact('State', shown);
  const began = fact('Since');
  const running = fact('Running');
  const says = h('p', { class: 'inspect-says' });
  const status = h('section', { class: 'inspect-group' }, h('h2', { class: 'group-head' }, 'Status'), h('dl', null, state.el, began.el, running.el), says);

  const folder = fact('Folder');
  folder.el.classList.add('wraps');
  const branch = fact('Branch');
  const runsIn = fact('Runs in');
  const place = group('Place', folder, branch, runsIn);

  const started = fact('Started');
  const lasted = h('time');
  const runningFor = fact('Running for', lasted);
  const times = group('Time', started, runningFor);

  const agent = fact('Agent');
  const agentSession = fact('Session');
  const process = fact('Process');
  const command = fact('Command');
  const size = fact('Size');
  const agents = group('Agent', agent, agentSession, process, command, size);

  // Tokens and cost (the Mac's ActivityFeed): asked of the node (`session.usage`) as the tab shows, and again while it
  // shows, at most every `USAGE_EVERY` ms.
  const tokens = fact('Tokens');
  tokens.el.classList.add('wraps');
  const cost = fact('Cost');
  const turns = fact('Turns');
  const usage = group('Usage', tokens, cost, turns);
  let usageFor = null;
  let usageAt = 0;
  let usageAsking = false;

  const role = fact('Role');
  const leadLink = h('a', { class: 'inspect-link' });
  const lead = fact('Lead', leadLink);
  const task = fact('Task');
  const team = group('Team', role, lead, task);

  const el = h('div', { class: 'inspect-pane' }, status, place.el, times.el, agents.el, usage.el, team.el);

  function drawUsage(result) {
    tokens.say(usageWords(result));
    cost.say(costWords(result));
    turns.say(result && result.count ? `${plural(result.count, 'turn')}${result.partial ? ', the transcript’s last part' : ''}` : null);
    usage.settle();
  }
  function askUsage(session) {
    if (!store.can('session.usage') || !session.hasTranscript) {
      usageFor = session.id;
      drawUsage(null);
      return;
    }
    if (usageFor !== session.id) {
      usageFor = session.id;
      usageAt = 0;
      drawUsage(null);
    }
    if (usageAsking || Date.now() - usageAt < USAGE_EVERY) return;
    usageAsking = true;
    usageAt = Date.now();
    const id = session.id;
    store.read('session.usage', { session: id }).then((reply) => {
      usageAsking = false;
      if (usageFor === id) drawUsage(reply?.ok ? reply.result : null);
    });
  }

  return {
    el,
    update(session) {
      const home = store.state.node?.home;
      const now = stateOf(session);
      setMark(mark, now);
      shown.className = `inspect-state tone-text-${now}`;
      setText(word, STATES[now].label);
      // No duration and no moment where the node knows none for the status (the clock skips an element without one).
      if (session.since) time.dataset.since = session.since; else delete time.dataset.since;
      setText(time, since(session.since));
      time.hidden = !session.since;
      began.say(session.since ? moment(session.since) : null);
      running.hold(session.activity || null);
      // What it says of itself, when that isn't the tool call above. One line, always there, the rest in its tooltip.
      const said = session.detail && session.detail !== session.activity ? session.detail : '';
      setText(says, said);
      if (said) says.title = said; else says.removeAttribute('title');

      folder.say(tilde(session.cwd, home), session.cwd);
      branch.say(session.branch);
      runsIn.say(session.hosted ? 'The session host' : 'Another terminal');
      place.settle();

      started.say(session.startedAt ? moment(session.startedAt) : null);
      runningFor.el.hidden = !session.startedAt;
      if (session.startedAt) lasted.dataset.since = session.startedAt; else delete lasted.dataset.since;
      setText(lasted, since(session.startedAt));
      times.settle();

      agent.say(AGENTS[session.agent] || session.agent);
      agentSession.say(session.agentSession ? `${session.agentSession.slice(0, 8)}…` : null, session.agentSession);
      // "4242 on pts/3" where the node says the process; else the terminal alone, under its own name.
      setText(process.dt, session.pid ? 'Process' : 'Terminal');
      process.say(session.pid ? `${session.pid} on ${session.terminal}` : session.terminal);
      command.say(session.command);
      size.say(session.size ? `${session.size.cols} × ${session.size.rows}` : null);
      agents.settle();
      askUsage(session);

      role.say(ROLES[session.role]);
      const leader = session.role && session.role !== 'lead' && session.lead ? leadOf(store, session.lead) : null;
      lead.el.hidden = !leader;
      pointAt(leadLink, leader);
      // The task by its title on the board; a session's own `task` may be other words, so nothing without the board.
      const onBoard = session.role && session.role !== 'lead' && session.boardTask
        ? store.state.boards.get(session.lead)?.tasks.find((entry) => entry.slug === session.boardTask) : null;
      task.say(onBoard ? onBoard.title : null);
      team.settle();
    },
  };
}

// Team: the board's tasks (lead.js), and what the node says of the lead itself.
function teamPane(app) {
  const { store } = app;
  const tasks = teamTasks(app);
  // Under the tasks, as the Mac's Team tab: the scorecard, decisions, answered questions, files.
  const records = boardRecords(app);
  const later = h('p', { class: 'inspect-note' }, 'The board’s tasks come to this page in a later build.');
  const leadLink = h('a', { class: 'inspect-link' });
  const leader = fact('Session', leadLink);
  const questions = fact('Questions');
  const held = fact('Held');
  const reports = fact('Reports');
  const about = group('Lead', leader, questions, held, reports);
  const noticeText = h('span');
  const notice = h('p', { class: 'inspect-notice', hidden: true }, icon('warning', 13), noticeText);
  const el = h('div', { class: 'inspect-pane' }, tasks.el, about.el, notice, records.el, later);

  return {
    el,
    update(session) {
      const board = store.state.boards.get(session.lead);
      const lead = store.state.leads.get(session.lead);
      tasks.el.hidden = !board;
      if (board) tasks.update(session);
      records.update(board);
      // Said only where the node sends no board at all, not where a board is still on its way.
      later.hidden = !!board || store.follows('boards');

      const other = session.role !== 'lead' ? leadOf(store, session.lead) : null;
      leader.el.hidden = !other;
      pointAt(leadLink, other);
      const asks = lead?.questions;
      questions.say(!asks ? null : asks.open > 0
        ? `${asks.open} for you` + (asks.blocking > 0 ? ` · ${asks.blocking} blocking` : '') : 'None open');
      held.say(lead?.held > 0 ? `${plural(lead.held, 'message')} waiting for the lead` : null);
      reports.say(lead?.reportsWaiting > 0 ? `${lead.reportsWaiting} waiting too long` : null);
      about.settle();
      notice.hidden = !lead?.notice;
      setText(noticeText, lead?.notice || '');
    },
  };
}

function ledgerRow(first) {
  const dim = h('span', { class: 'ledger-dim' });
  if (first.kind === 'file') {
    const folder = h('span', { class: 'ledger-folder' });
    const name = h('span', { class: 'ledger-name' });
    const plus = h('span', { class: 'plus' });
    const minus = h('span', { class: 'minus' });
    const el = h('li', { class: 'ledger-row' }, icon('pencil', 13), h('div', { class: 'ledger-text' },
      h('div', { class: 'ledger-line' }, h('span', { class: 'ledger-path' }, folder, name), h('span', { class: 'counts' }, plus, minus)), dim));
    return {
      el,
      update(row) {
        setText(folder, row.folder);
        setText(name, row.name);
        el.title = row.path;
        setText(plus, `+${row.added}`);
        // A written file has no lines removed to count; an edited one says so even at none.
        minus.hidden = !(row.removed > 0 || row.replaced);
        setText(minus, `−${row.removed}`);
        setText(dim, fileWords(row));
      },
    };
  }
  const title = h('span', { class: 'ledger-title' });
  const trail = h('span', { class: 'ledger-trail' });
  const running = h('span', { class: 'running', role: 'status', 'aria-label': 'Running', hidden: true });
  const el = h('li', { class: 'ledger-row' }, icon('terminal', 13), h('div', { class: 'ledger-text' },
    h('div', { class: 'ledger-line' }, title, running, trail), dim));
  return {
    el,
    update(row) {
      setText(title, row.title);
      setClass(title, 'mono', !row.line);
      el.title = row.line || row.title;
      setText(dim, row.line || '');
      dim.hidden = !row.line;
      setClass(dim, 'mono', true);
      running.hidden = !row.running;
      setClass(el, 'failed', row.failed);
      const took = row.took === null ? '' : row.took < 1 ? '<1s' : short(row.took);
      setText(trail, [row.failed ? 'failed' : '', took].filter(Boolean).join(' · '));
    },
  };
}

// Activity: the ledger of the session's chat, kept at its end while you are there.
function activityPane(app, scroller, again) {
  const { store } = app;
  const list = h('ul', { class: 'ledger' });
  const note = h('p', { class: 'inspect-note', hidden: true });
  const skeleton = h('div', { class: 'inspect-skeleton', 'aria-hidden': 'true', hidden: true }, h('span', { class: 'bone wide' }), h('span', { class: 'bone' }), h('span', { class: 'bone short' }));
  const el = h('div', { class: 'inspect-pane' }, skeleton, note, list);
  const rows = new Map();
  let counts = new Map();
  let followed = null;
  let unsubscribe = null;
  let stale = true;
  let drawn = '';

  // Text growing in a reply changes nothing here; a row put, replaced or gone may.
  function onChat(changes) {
    if (!changes.some((change) => change.type !== 'text')) return;
    stale = true;
    again();
  }

  return {
    el,
    // `fresh`: the tab was just shown, so it starts at its end.
    update(session, fresh) {
      if (followed !== session.id) {
        unsubscribe?.();
        followed = session.id;
        counts = new Map();
        rows.clear();
        list.replaceChildren();
        unsubscribe = store.subscribe('chat:' + session.id, onChat);
        stale = true;
        fresh = true;
      }
      const chat = store.state.chats.get(session.id);
      const following = store.can('chat.page');
      const loaded = !!chat?.loaded;
      const home = store.state.node?.home || null;
      const now = [session.cwd, home, following, loaded].join('|');
      if (!stale && now === drawn && !fresh) return;
      const pinned = fresh || scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < NEAR;
      stale = false;
      drawn = now;
      const entries = following && loaded ? ledger(chat.items, { cwd: session.cwd, home, counts }) : [];
      keyed(list, rows, entries, (row) => row.key, ledgerRow);
      skeleton.hidden = !following || loaded;
      const said = !following ? 'The files this session changes and the commands it runs come to this page with its conversation, in a later build.'
        : loaded && entries.length === 0 ? 'No files changed or commands run in this conversation yet.' : '';
      note.hidden = !said;
      setText(note, said);
      if (pinned) scroller.scrollTop = scroller.scrollHeight;
    },
  };
}

export function inspector(app) {
  const { store, ui } = app;
  const tabs = TABS.map((tab) => h('button', { type: 'button', onclick: () => ui.setInspectorTab(tab.id) }, tab.label));
  const close = h('button', { class: 'icon-button inspect-close', type: 'button', 'aria-label': 'Close the inspector', onclick: () => ui.setInspector(false) }, icon('close', 14));
  const scroller = h('div', { class: 'inspect-scroll' });
  let current = null;
  const again = framed(() => {
    const session = store.state.sessions.get(current);
    if (session) update(session);
  });
  const panes = { team: teamPane(app), overview: overview(app), activity: activityPane(app, scroller, again) };
  scroller.append(panes.team.el, panes.overview.el, panes.activity.el);
  const el = h('aside', { class: 'inspector', id: 'inspector', 'aria-label': 'Inspector' },
    h('div', { class: 'inspect-top' }, h('div', { class: 'segmented', role: 'group', 'aria-label': 'Inspector' }, tabs), close), scroller);
  // Under a sheet: a touch beside it closes it.
  const scrim = h('div', { class: 'inspect-scrim', onclick: () => ui.setInspector(false) });
  let shownTab = null;

  function update(session) {
    current = session.id;
    const shown = ui.inspectorShown();
    setClass(el, 'shown', shown);
    if (!shown) {
      shownTab = null;
      return;
    }
    const team = !!teamOf(store.state, session);
    const tab = inspectorTab(ui.state.inspector.tab, team);
    tabs.forEach((button, index) => {
      button.hidden = TABS[index].id === 'team' && !team;
      button.setAttribute('aria-pressed', String(TABS[index].id === tab));
    });
    for (const [name, pane] of Object.entries(panes)) pane.el.hidden = name !== tab;
    // Another tab, or another session: from its top (the Activity from its end, which is its newest).
    const fresh = shownTab !== tab + session.id;
    shownTab = tab + session.id;
    if (fresh) scroller.scrollTop = 0;
    panes[tab].update(session, fresh);
  }

  // Esc closes a sheet, as it closes anything laid over the page; the column stays.
  document.addEventListener('keydown', (event) => {
    if (event.key !== 'Escape' || !ui.state.inspector.sheet || ui.state.palette) return;
    event.preventDefault();
    ui.setInspector(false);
  });

  return {
    el,
    scrim,
    update,
    // Into the sheet when it opens: its tabs take the focus.
    focus() { tabs.find((button) => button.getAttribute('aria-pressed') === 'true')?.focus(); },
  };
}
