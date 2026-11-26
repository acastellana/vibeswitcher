// Two screens of the centre, from the left column's links (the redesign's "Other screens"):
// - Your own sessions (#/sessions): the sessions outside every project's team, each opening the session view the page
//   had (chat, terminal, inspector); starting one (views/drive.js's short form: what, where, the model, one Start); and
//   the ones that ended lately, with Resume.
// - New project (#/new): a lead in a folder you have (the page starts it) or a brand-new project (its folder made by
//   the line a terminal runs: no page makes one yet), as one short form.
// Where the page doesn't act, each form ends in the line to run in a terminal and why.

import * as kit from '../kit.js';
import { h, setClass, setText, framed } from '../dom.js';
import { sessionMark, icon } from '../marks.js';
import { STATES, stateOf, since, tilde, lastPart, AGENTS } from '../words.js';
import { twoColumns, queryWords, holdsAll } from './twocol.js';
import { t } from '../i18n.js';
import { actsFor } from '../acting.js';
import { sessionHref, leadMarks } from '../ui.js';
import { ownSession } from './left.js';
import { newSessionForm, newLeadForm, newProjectForm, resumeOrLine } from './drive.js';
import { recentProjects, recentFolders } from '../actions.js';
import { reopenCard } from './offers.js';

const ENDED_SHOWN = 5;

function screenHead(app, title, sub) {
  return h('header', { class: 'centre-head screen-head' },
    kit.iconButton({ class: 'phone-only', 'aria-label': t('menu'), onclick: () => app.drawer('left') }, icon('menu', 16)),
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
  // The recent folders offered beside the form's folder field: your sessions' and those that ended lately.
  const recent = () => recentFolders(store.state.sessions.values(), store.state.node?.ended || [], 4);
  const starting = newSessionForm(app, { folder, recent });
  const endedList = h('div', { class: 'ended-list' });
  const endedNote = h('p', { class: 'confirm-note' }, t('owRunTheLineInA'));
  const ended = h('section', { class: 'ended', hidden: true }, h('h2', { class: 'new-title' }, t('owEndedLately')), endedList, endedNote);
  // The list's head: a new session (its form beside the list) and a new project.
  const newSession = kit.iconButton({ tag: 'a', class: 'tc-new', href: '#/sessions/new', 'aria-label': t('owNewSession'), title: t('owNewSession') }, icon('plus', 16));
  const newProject = kit.iconButton({ tag: 'a', href: '#/new', 'aria-label': t('newProject'), title: t('newProject') }, icon('team', 16));
  const columns = twoColumns(app, { label: t('ownSessions'), title: t('ownSessions'), searchLabel: t('owSearch'), placeholder: t('owSearchShort'), listHref: '#/sessions', head: [newSession, newProject] });
  columns.onSearch(() => render());
  // The restart's reopen offer (`node.reopenOffer`): the sessions of yours a host restart ended, first.
  const reopen = reopenCard(app);
  const startPage = h('div', { class: 'screen-col tc-start' }, h('p', { class: 'tc-lede' }, t('ownSub')), reopen.el, starting.el, ended);
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
    reopen.update(state.node?.reopenOffer);
    starting.update();
    const endedNow = (state.node?.ended || []).slice(0, ENDED_SHOWN);
    const key = JSON.stringify([endedNow, state.node?.home, store.acts(), store.can('session.resume')]);
    if (key !== endedDrawn) {
      endedDrawn = key;
      ended.hidden = endedNow.length === 0;
      setText(endedNote, actsFor(app, 'session.resume') ? t('owEndedActs') : t('owRunTheLineInA'));
      endedList.replaceChildren(...endedNow.map((entry) => h('div', { class: 'ended-row' },
        h('div', { class: 'ended-name' }, h('span', null, entry.name || t('owASession')), h('span', { class: 'ended-folder' }, tilde(entry.folder, state.node?.home))),
        ...(entry.conversation ? resumeOrLine(app, entry, { plain: true }) : [h('p', { class: 'confirm-note' }, t('owItsConversationIdWasnT'))]))));
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
  // What to start: a lead in a folder that exists (the default: the page starts it), or a brand-new project (its
  // folder made by the terminal's line). One form shows at a time.
  let mode = 'folder';
  const modes = [['folder', t('owModeFolder')], ['new', t('owModeNew')]].map(([key, label]) => kit.segment({ 'aria-pressed': String(key === mode), onclick: () => choose(key) }, label));
  const switcher = h('div', { class: 'start-row' }, h('span', { class: 'start-label' }, t('owModeWhat')),
    h('div', { class: 'start-control' }, kit.segmented({ role: 'group', 'aria-label': t('owModeWhat') }, modes)));
  function choose(key) {
    mode = key;
    modes.forEach((button, index) => button.setAttribute('aria-pressed', String(['folder', 'new'][index] === key)));
    leading.el.hidden = key !== 'folder';
    project.el.hidden = key !== 'new';
  }
  choose(mode);
  const el = h('section', { class: 'centre screen new', 'aria-label': t('newProject') },
    screenHead(app, t('newProject')), h('div', { class: 'screen-body' }, h('div', { class: 'screen-col' },
      h('p', { class: 'tc-lede' }, t('owProjectLede')), h('div', { class: 'start-card' }, switcher, leading.el, project.el))));
  let known = null;
  let asked = false;

  function render() {
    const state = store.state;
    if (!asked && state.connection === 'live' && store.can?.('recent')) {
      asked = true;
      store.request('recent', {}).then((reply) => { if (reply.ok) { known = reply.result.projects; render(); } else asked = false; });
    }
    // The recent folders, offered beside the folder field: your sessions', those ended lately, the node's recent projects.
    leading.update(recentProjects(known, state.sessions.values(), state.node?.ended || [], state.leads.values(), 5).map((one) => one.folder));
  }

  const schedule = framed(render);
  for (const topic of ['sessions', 'node', 'connection', 'leads']) store.subscribe(topic, schedule);
  return { el, render, lead: (folder) => { choose('folder'); leading.choose(folder); } };
}
