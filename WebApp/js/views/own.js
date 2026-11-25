// Two screens of the centre, from the left column's links (the redesign's "Other screens"):
// - Your own sessions (#/sessions): the sessions outside every project's team, each opening the session view the page
//   had (chat, terminal, inspector); starting one (the line that starts it in a terminal, views/drive.js); and the
//   ones that ended lately, with the line that resumes each.
// - New project (#/new): the lines that make a project and start its lead, and the recent folders with theirs.
// Nothing here starts anything: each line is copied and run in a terminal, where the code is typed.

import { h, setClass, setText, framed } from '../dom.js';
import { sessionMark, icon } from '../marks.js';
import { STATES, stateOf, since, tilde, lastPart, AGENTS } from '../words.js';
import { twoColumns, queryWords, holdsAll } from './twocol.js';
import { t } from '../i18n.js';
import { actsFor } from '../acting.js';
import { sessionHref, projectHref, leadMarks } from '../ui.js';
import { ownSession } from './left.js';
import { newSessionForm, newLeadForm, newProjectForm, startOrLine, resumeOrLine, leadStartOrLine } from './drive.js';
import { recentProjects, projectLines } from '../actions.js';

const ENDED_SHOWN = 5;

function screenHead(app, title, sub) {
  return h('header', { class: 'centre-head screen-head' },
    h('button', { class: 'icon-button phone-only', type: 'button', 'aria-label': t('menu'), onclick: () => app.drawer('left') }, icon('menu', 16)),
    h('div', { class: 'head-words' }, h('h1', { class: 'big' }, title), sub ? h('span', { class: 'pname' }, sub) : null));
}

// The list's three bands, in the order the page shows them: what needs you, what works, the rest (idle, finished,
// paused, ended). A session's band by its state word.
const BANDS = [['needs-you', ['needs-you']], ['working', ['working', 'background']], ['rest', ['done', 'idle', 'paused', 'ended', 'unknown']]];
export const bandOf = (word) => BANDS.find(([, words]) => words.includes(word))[0];

// Your own sessions as the list's rows: in their bands, each with its name, its state and its folder's name, and when
// its state last moved; with a search, only those whose name, folder or state holds every word.
export function ownItems(sessions, query, home = null, replaced = () => false) {
  const words = queryWords(query);
  const title = { 'needs-you': t('owBandNeedsYou'), working: t('owBandWorking'), rest: t('owBandRest') };
  const rows = sessions.map((session) => {
    const word = stateOf(session);
    const name = session.title || lastPart(session.cwd) || t('owASession');
    const folder = tilde(session.cwd, home) || t('owNoFolder');
    return { session, word, name, folder, band: bandOf(word) };
  }).filter((one) => !words.length || holdsAll([one.name, one.folder, STATES[one.word].label, AGENTS[one.session.agent] || ''].join(' '), words));
  const items = [];
  for (const [band] of BANDS) {
    // Within a band, the one that moved last first.
    const mine = rows.filter((one) => one.band === band).sort((a, b) => String(b.session.since || '').localeCompare(String(a.session.since || '')));
    for (const one of mine) {
      items.push({ key: one.session.id, href: sessionHref(one.session.id), group: title[band], title: one.name,
        sub: [STATES[one.word].label, replaced(one.session) ? t('owReplaced') : null, lastPart(one.session.cwd) || one.folder].filter(Boolean).join(' · '), subTone: one.word,
        meta: since(one.session.since), since: one.session.since || null, tone: one.word === 'needs-you' ? 'asked' : '',
        about: [one.folder, AGENTS[one.session.agent], one.session.hosted ? null : t('owOtherTerminal', { terminal: one.session.terminal })].filter(Boolean).join(' · '),
        markKey: `${one.word}:${one.session.agent}`, mark: () => { const mark = sessionMark(20); mark.update(one.word, one.session.agent); return mark.el; } });
    }
  }
  return items;
}

export function ownSessionsView(app, { session = null } = {}) {
  const { store, ui } = app;
  const folder = () => {
    const hosted = [...store.state.sessions.values()].filter((one) => one.hosted && one.cwd);
    hosted.sort((a, b) => String(b.startedAt || '').localeCompare(String(a.startedAt || '')));
    return hosted[0]?.cwd || store.state.node?.home || '';
  };
  const starting = newSessionForm(app, { folder });
  const endedList = h('div', { class: 'ended-list' });
  const endedNote = h('p', { class: 'confirm-note' }, t('owRunTheLineInA'));
  const ended = h('section', { class: 'ended', hidden: true }, h('h2', { class: 'new-title' }, t('owEndedLately')), endedList, endedNote);
  // The list's head: a new session (its form beside the list) and a new project.
  const newSession = h('a', { class: 'icon-button tc-new', href: '#/sessions/new', 'aria-label': t('owNewSession'), title: t('owNewSession') }, icon('plus', 16));
  const newProject = h('a', { class: 'icon-button', href: '#/new', 'aria-label': t('newProject'), title: t('newProject') }, icon('team', 16));
  const columns = twoColumns(app, { label: t('ownSessions'), title: t('ownSessions'), searchLabel: t('owSearch'), placeholder: t('owSearchShort'), listHref: '#/sessions', head: [newSession, newProject] });
  columns.onSearch(() => render());
  const startPage = h('div', { class: 'screen-col tc-start' }, h('p', { class: 'tc-lede' }, t('ownSub')), starting.el, ended);
  const el = columns.el;
  let endedDrawn = '';

  function render() {
    const state = store.state;
    const route = ui.state.route;
    const here = route.name === 'sessions' || route.name === 'session';
    if (!here) return;
    const mine = [...state.sessions.values()].filter(ownSession);
    const shown = route.name === 'session' ? state.sessions.get(route.id) : null;
    // A team's session (a lead's, a worker's, a verifier's) shows alone, as before: the list is yours only.
    const alone = !!shown && !ownSession(shown);
    setClass(el, 'alone', alone);
    columns.fold(route.name === 'session' || !!route.start);
    const query = columns.query();
    const items = ownItems(mine, query, state.node?.home, (one) => leadMarks(state, one).replaced);
    const connecting = state.connection === 'connecting';
    columns.setItems(items, route.name === 'session' ? route.id : null, {
      empty: connecting ? '' : query.trim() ? t('owNoMatch', { query: query.trim() }) : t('owNoneYet') });
    if (route.name === 'sessions') newSession.setAttribute('aria-current', 'page'); else newSession.removeAttribute('aria-current');
    if (route.name === 'session' && session) { columns.own(session.el); return; }
    starting.el.hidden = state.connection === 'unpaired' || state.connection === 'revoked';
    starting.update();
    const endedNow = (state.node?.ended || []).slice(0, ENDED_SHOWN);
    const key = JSON.stringify([endedNow, state.node?.home, store.acts(), store.can('session.resume')]);
    if (key !== endedDrawn) {
      endedDrawn = key;
      ended.hidden = endedNow.length === 0;
      setText(endedNote, actsFor(app, 'session.resume') ? t('owEndedActs') : t('owRunTheLineInA'));
      endedList.replaceChildren(...endedNow.map((entry) => h('div', { class: 'ended-row' },
        h('div', { class: 'ended-name' }, h('span', null, entry.name || t('owASession')), h('span', { class: 'ended-folder' }, tilde(entry.folder, state.node?.home))),
        ...(entry.conversation ? resumeOrLine(app, entry, { quiet: true }) : [h('p', { class: 'confirm-note' }, t('owItsConversationIdWasnT'))]))));
    }
    columns.show({ title: t('owNewSession'), sub: mine.length ? t('owCount', { n: mine.length }) : '', body: [startPage] });
  }

  const schedule = framed(render);
  for (const topic of ['sessions', 'node', 'connection', 'leads']) store.subscribe(topic, schedule);
  ui.subscribe((what) => { if (what === 'route') render(); });
  return { el, render, focusSearch: () => columns.focusSearch(), columns, alone: () => el.classList.contains('alone'), choose: (where, preset) => starting.choose(where, preset) };
}

export function newProjectView(app) {
  const { store } = app;
  const project = newProjectForm(app);
  const leading = newLeadForm(app);
  const recentList = h('div', { class: 'ended-list' });
  const recentNote = h('p', { class: 'confirm-note' }, t('owRunALineInA'));
  const recent = h('section', { class: 'ended recent', hidden: true }, h('h2', { class: 'new-title' }, t('owRecentFolders')), recentList, recentNote);
  const el = h('section', { class: 'centre screen new', 'aria-label': t('newProject') },
    screenHead(app, t('newProject')), h('div', { class: 'screen-body' }, h('div', { class: 'screen-col' }, project.el, leading.el, recent)));
  let known = null;
  let asked = false;
  let drawn = '';

  function render() {
    const state = store.state;
    if (!asked && state.connection === 'live' && store.can?.('recent')) {
      asked = true;
      store.request('recent', {}).then((reply) => { if (reply.ok) { known = reply.result.projects; render(); } else asked = false; });
    }
    const rows = recentProjects(known, state.sessions.values(), state.node?.ended || [], state.leads.values());
    const key = JSON.stringify([rows, state.node?.home, store.acts(), store.can('session.new'), store.can('lead')]);
    if (key === drawn) return;
    drawn = key;
    recent.hidden = rows.length === 0;
    // Where the page acts and the node lists `session.new` and `lead`, New session and Start lead start them from here
    // (views/drive.js, the page goes to what started); elsewhere each line and why.
    const startsHere = actsFor(app, 'session.new') || actsFor(app, 'lead');
    setText(recentNote, startsHere ? t('owRecentActs') : t('owRunALineInA'));
    recentList.replaceChildren(...rows.map((one) => {
      const lines = projectLines(one);
      const name = lastPart(one.folder) || one.folder;
      return h('div', { class: 'ended-row recent-row' },
        h('div', { class: 'ended-name' }, h('span', null, name), h('span', { class: 'ended-folder' }, tilde(one.folder, state.node?.home))),
        h('div', { class: 'recent-acts' },
          ...startOrLine(app, { kind: 'session.new', label: t('owNewSessionHere'), quiet: true, orLine: false, args: () => ({ folder: one.folder, agent: 'claude' }),
            line: lines.session, lineLabel: t('owStartsIn', { name }), terminalOnly: 'drStartTerminalOnly',
            target: (result) => ({ session: typeof result.session === 'string' ? result.session : null }) }),
          ...(lines.lead ? leadStartOrLine(app, { folder: one.folder, label: t('acStartLead'), quiet: true, line: lines.lead, lineLabel: t('owTheCommandThatStartsIts') })
            : [h('a', { class: 'link', href: projectHref(one.lead) }, t('owItsLeadRunsOpenIt'))])));
    }));
  }

  const schedule = framed(render);
  for (const topic of ['sessions', 'node', 'connection', 'leads']) store.subscribe(topic, schedule);
  return { el, render, lead: (folder) => leading.choose(folder) };
}
