// Two screens of the centre, from the left column's links (the redesign's "Other screens"):
// - Your own sessions (#/sessions): the sessions outside every project's team, each opening the session view the page
//   had (chat, terminal, inspector); starting one (the line that starts it in a terminal, views/drive.js); and the
//   ones that ended lately, with the line that resumes each.
// - New project (#/new): the lines that make a project and start its lead, and the recent folders with theirs.
// Nothing here starts anything: each line is copied and run in a terminal, where the code is typed.

import { h, setText, framed } from '../dom.js';
import { sessionMark, icon } from '../marks.js';
import { STATES, stateOf, since, tilde, lastPart, AGENTS } from '../words.js';
import { t } from '../i18n.js';
import { actsFor, doButton } from '../acting.js';
import { sessionHref, projectHref, leadMarks } from '../ui.js';
import { ownSession } from './left.js';
import { newSessionForm, newLeadForm, newProjectForm } from './drive.js';
import { copyLine } from './cards.js';
import { resumeLine, recentProjects, projectLines } from '../actions.js';

const ENDED_SHOWN = 5;

function screenHead(app, title, sub) {
  return h('header', { class: 'centre-head screen-head' },
    h('button', { class: 'icon-button phone-only', type: 'button', 'aria-label': t('menu'), onclick: () => app.drawer('left') }, icon('menu', 16)),
    h('div', { class: 'head-words' }, h('h1', { class: 'big' }, title), sub ? h('span', { class: 'pname' }, sub) : null));
}

export function ownSessionsView(app) {
  const { store } = app;
  const list = h('div', { class: 'own-list' });
  const none = h('p', { class: 'empty-line', hidden: true }, t('ownNone'));
  const folder = () => {
    const hosted = [...store.state.sessions.values()].filter((session) => session.hosted && session.cwd);
    hosted.sort((a, b) => String(b.startedAt || '').localeCompare(String(a.startedAt || '')));
    return hosted[0]?.cwd || store.state.node?.home || '';
  };
  const starting = newSessionForm(app, { folder });
  const endedList = h('div', { class: 'ended-list' });
  const ended = h('section', { class: 'ended', hidden: true }, h('h2', { class: 'new-title' }, t('owEndedLately')), endedList,
    h('p', { class: 'confirm-note' }, t('owRunTheLineInA')));
  const el = h('section', { class: 'centre screen own', 'aria-label': t('ownSessions') },
    screenHead(app, t('ownSessions'), t('ownSub')),
    h('div', { class: 'screen-body' }, h('div', { class: 'screen-col' }, list, none, starting.el, ended)));
  const rows = new Map();
  let endedDrawn = '';

  function row(session) {
    const mark = sessionMark(20);
    const title = h('span', { class: 'own-title' });
    const where = h('span', { class: 'own-where' });
    const state = h('span', { class: 'own-state' });
    const time = h('time');
    const tag = h('span', { class: 'lead-tag replaced', hidden: true }, t('owReplaced'));
    const el = h('a', { class: 'own-row row', href: sessionHref(session.id) }, mark.el, h('span', { class: 'own-words' }, h('span', { class: 'own-line' }, title, tag), where), h('span', { class: 'own-when' }, state, time));
    return {
      el,
      update(next) {
        const word = stateOf(next);
        mark.update(word, next.agent);
        setText(title, next.title || lastPart(next.cwd) || t('owASession'));
        setText(where, [tilde(next.cwd, store.state.node?.home) || t('owNoFolder'), AGENTS[next.agent], next.hosted ? null : t('owOtherTerminal', { terminal: next.terminal })].filter(Boolean).join(' · '));
        setText(state, STATES[word].label);
        state.className = `own-state tone-text-${word}`;
        if (next.since) time.dataset.since = next.since; else delete time.dataset.since;
        setText(time, since(next.since));
        const marks = leadMarks(store.state, next);
        tag.hidden = !marks.replaced;
        el.title = marks.replaced ? t('owALeadSessionItsProject') : '';
      },
    };
  }

  function render() {
    const state = store.state;
    const mine = [...state.sessions.values()].filter(ownSession);
    const next = new Map();
    let cursor = list.firstChild;
    for (const session of mine) {
      const r = rows.get(session.id) || row(session);
      r.update(session);
      next.set(session.id, r);
      if (r.el === cursor) cursor = cursor.nextSibling; else list.insertBefore(r.el, cursor);
    }
    for (const [id, r] of rows) if (!next.has(id)) r.el.remove();
    rows.clear();
    for (const [id, r] of next) rows.set(id, r);
    none.hidden = mine.length > 0 || state.connection === 'connecting';
    starting.el.hidden = state.connection === 'unpaired' || state.connection === 'revoked';
    starting.update();
    const endedNow = (state.node?.ended || []).slice(0, ENDED_SHOWN);
    const key = JSON.stringify([endedNow, state.node?.home, store.acts()]);
    if (key !== endedDrawn) {
      endedDrawn = key;
      ended.hidden = endedNow.length === 0;
      endedList.replaceChildren(...endedNow.map((entry) => h('div', { class: 'ended-row' },
        h('div', { class: 'ended-name' }, h('span', null, entry.name || t('owASession')), h('span', { class: 'ended-folder' }, tilde(entry.folder, state.node?.home))),
        entry.conversation && actsFor(app, 'session.resume') ? doButton(app, { label: t('acResume'), kind: 'session.resume', quiet: true, args: () => ({ session: entry.session }) }).el : null,
        entry.conversation ? copyLine(resumeLine(entry), t('owTheCommandThatResumesIt')) : h('p', { class: 'confirm-note' }, t('owItsConversationIdWasnT')))));
    }
  }

  const schedule = framed(render);
  for (const topic of ['sessions', 'node', 'connection', 'leads']) store.subscribe(topic, schedule);
  return { el, render, choose: (where, preset) => starting.choose(where, preset) };
}

export function newProjectView(app) {
  const { store } = app;
  const project = newProjectForm(app);
  const leading = newLeadForm(app);
  const recentList = h('div', { class: 'ended-list' });
  const recent = h('section', { class: 'ended recent', hidden: true }, h('h2', { class: 'new-title' }, t('owRecentFolders')), recentList,
    h('p', { class: 'confirm-note' }, t('owRunALineInA')));
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
    const key = JSON.stringify([rows, state.node?.home]);
    if (key === drawn) return;
    drawn = key;
    recent.hidden = rows.length === 0;
    recentList.replaceChildren(...rows.map((one) => {
      const lines = projectLines(one);
      return h('div', { class: 'ended-row' },
        h('div', { class: 'ended-name' }, h('span', null, lastPart(one.folder) || one.folder), h('span', { class: 'ended-folder' }, tilde(one.folder, state.node?.home))),
        copyLine(lines.session, t('owStartsIn', { name: lastPart(one.folder) })),
        lines.lead ? copyLine(lines.lead, t('owTheCommandThatStartsIts')) : h('a', { class: 'link', href: projectHref(one.lead) }, t('owItsLeadRunsOpenIt')));
    }));
  }

  const schedule = framed(render);
  for (const topic of ['sessions', 'node', 'connection', 'leads']) store.subscribe(topic, schedule);
  return { el, render, lead: (folder) => leading.choose(folder) };
}
