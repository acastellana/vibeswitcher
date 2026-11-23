// The right column on a project's lead conversation (the redesign's "Right", about 320 px, tabs):
// - Team: the lead's latest statement and its time; the tasks in motion and the blocked ones, each with its five steps
//   in its colour; the queued count. A task opens in place, under itself (`task=` in the address): its latest note, its
//   audit, why it is blocked and on whom it waits, since when, and a link to its worker's chat.
// - Stats: the project's scorecard (the board's).
// - Files: the lead's files and the project's place.
// Read-only; every line is the sessions' writing, drawn as text.

import { h, setText } from '../dom.js';
import { clock, moment, tilde, lastPart, taskLine } from '../words.js';
import { t, listed, lang } from '../i18n.js';
import { standing, waitsOn, cut, shortHashes } from '../conversation.js';
import { routeHref, sessionHref } from '../ui.js';
import { settingsHref } from './settings.js';
import { stepBar } from './project.js';
import { filesLine } from './records.js';

// The session to open for a task: its verifier while it's in review, else its worker.
const sessionOf = (task) => (task.status === 'review' && task.verifier) || task.worker || null;

export function rightColumn(app) {
  const { store, ui } = app;
  const name = h('span', { class: 'colhead-name' });
  const tabs = ['team', 'stats', 'files'].map((tab) => h('a', { class: 'switch-link', role: 'tab', data: { tab } }, t({ team: 'tabTeam', stats: 'tabStats', files: 'tabFiles' }[tab])));
  const body = h('div', { class: 'colbody right-body' });
  const el = h('aside', { class: 'right', 'aria-label': t('team') },
    h('div', { class: 'colhead' }, name), h('div', { class: 'right-tabs' }, h('nav', { class: 'switch tabs', role: 'tablist' }, tabs)), body);
  let drawn = '';

  function taskDetails(task, board, route) {
    const parts = [];
    const fact = (label, ...value) => h('div', { class: 'tdet-fact' }, h('small', null, label), h('span', null, ...value));
    const note = task.checkpoint || task.checkpoints?.[task.checkpoints.length - 1];
    if (note?.text) parts.push(fact(t('latestNote', { time: clock(note.at) }), cut(shortHashes(note.text), 400)));
    else if (taskLine(task)) parts.push(fact(t('now'), cut(shortHashes(taskLine(task)), 400)));
    if (task.audit) parts.push(fact(t('audit'), t('auditWords', { r: task.audit.rounds ?? 0, verdict: task.audit.verdict || '…', f: task.audit.findings ?? 0, o: task.audit.open ?? 0 })));
    if (task.blocker) parts.push(fact(t('blockedBecause'), cut(shortHashes(task.blocker), 400)));
    if (task.group === 'attention' || task.status === 'blocked') {
      const who = waitsOn(task, board, store.state.cards.values());
      if (who.who === 'you') parts.push(fact(t('waitsOnYou'), h('a', { class: 'link', href: routeHref(route, { show: 'asks', task: null }) }, cut(who.card.question.text, 120))));
      else if (who.who === 'tasks') parts.push(fact(t('waitsOnTasks', { list: '' }).trim(), listed(who.titles)));
      else if (who.who === 'lead') parts.push(fact(t('waitsOnLead'), ''));
    }
    parts.push(fact(t('since'), task.startedAt ? `${moment(task.startedAt)} · ${t('attempt', { n: task.attempts || 1 })}` : t('notStarted')));
    const target = sessionOf(task);
    parts.push(target && store.state.sessions.has(target)
      ? h('a', { class: 'link tdet-chat', href: sessionHref(target) }, t(target === task.verifier && task.status === 'review' ? 'openVerifierChat' : 'openChat'))
      : h('p', { class: 'tdet-none' }, t('noChat')));
    return h('div', { class: 'tdet' }, parts);
  }

  function taskRow(task, board, route) {
    const open = route.task === task.slug;
    const row = h('a', { class: 'task-row2' + (open ? ' open' : ''), href: routeHref(route, { task: open ? null : task.slug, sheet: null }), 'aria-expanded': String(open) },
      stepBar(task), h('span', { class: 'task-words' }, h('span', { class: 'task-name' }, task.title), h('span', { class: `task-state tone-text-${task.status === 'blocked' || task.group === 'attention' ? 'blocked' : ''}` }, task.state || '')));
    return open ? [row, taskDetails(task, board, route)] : [row];
  }

  function team(route, board, lead) {
    const said = [...(board?.decisions || [])].sort((a, b) => Date.parse(b.at) - Date.parse(a.at))[0];
    const team = standing(board);
    const parts = [];
    if (said) parts.push(h('p', { class: 'now' }, h('small', null, t('leadSaid', { time: moment(said.at) })), cut(shortHashes(said.summary || said.text), 220)));
    parts.push(h('h3', { class: 'col-title' }, t('inMotionTitle', { n: team.motion.length })));
    parts.push(...(team.motion.length ? team.motion.flatMap((task) => taskRow(task, board, route)) : [h('p', { class: 'col-note' }, t('nothingMoving'))]));
    if (team.blocked.length) parts.push(h('h3', { class: 'col-title' }, t('blockedTitle', { n: team.blocked.length })), ...team.blocked.flatMap((task) => taskRow(task, board, route)));
    const foot = [team.queued.length ? t('queuedLine', { n: team.queued.length }) : null, team.merged.length ? t('mergedLine', { n: team.merged.length }) : null].filter(Boolean);
    if (foot.length) parts.push(h('p', { class: 'col-foot' }, foot.join(' · ')));
    if (!lead?.session || !store.state.sessions.has(lead.session)) parts.push(h('p', { class: 'col-note' }, t('noLeadRunning')));
    return parts;
  }

  function stats(board) {
    const card = board?.scorecard;
    if (!card || !card.merged) return [h('p', { class: 'col-note' }, t('scoreNone'))];
    return [
      h('div', { class: 'tiles' }, h('div', { class: 'tile' }, h('b', null, String(card.merged)), h('span', null, t('merged', { n: '' }).trim())),
        (card.tiles || []).map((tile) => h('div', { class: 'tile', title: tile.help || '' }, h('b', null, tile.value), h('span', null, tile.label), tile.note ? h('small', null, tile.note) : null))),
      card.footnote ? h('p', { class: 'col-note' }, card.footnote) : null,
      card.receipts ? h('p', { class: 'col-note' }, card.receipts) : null,
    ];
  }

  function files(board, lead) {
    const home = store.state.node?.home;
    const root = lead?.root || board?.root || '';
    const rows = (board?.files || []).map((file) => h('div', { class: 'file-row' + (file.present ? '' : ' missing') },
      h('span', null, file.name), h('small', null, file.present ? file.path : t('notWritten'))));
    const kv = (label, ...value) => [h('span', null, label), h('span', null, ...value)];
    const live = lead?.session && store.state.sessions.has(lead.session);
    return [
      h('h3', { class: 'col-title' }, t('files')), ...rows,
      board ? h('p', { class: 'col-note' }, filesLine(board, home)) : null,
      h('h3', { class: 'col-title' }, t('place')),
      h('div', { class: 'kv' }, kv(t('folder'), tilde(root, home)), board?.baseBranch ? kv(t('baseBranch'), board.baseBranch) : null,
        kv(t('leadSession'), live ? h('a', { class: 'link', href: sessionHref(lead.session) }, t('leadChat')) : t('noLeadRunning')),
        kv(t('settings'), h('a', { class: 'link', href: settingsHref(lead?.project || board?.project) }, lastPart(root)))),
    ];
  }

  function render() {
    const route = ui.state.route;
    if (route.name !== 'project' || route.view !== 'lead') return;
    const lead = store.state.leads.get(route.id) || null;
    const board = store.state.boards.get(route.id) || null;
    const key = JSON.stringify([route, board, lead, store.state.node?.home, [...store.state.cards.keys()], store.state.sessions.has(lead?.session), lang()]);
    if (key === drawn) return;
    drawn = key;
    setText(name, lastPart(lead?.root || board?.root || ''));
    for (const tab of tabs) {
      tab.setAttribute('href', routeHref(route, { tab: tab.dataset.tab, task: null, sheet: null }));
      tab.setAttribute('aria-selected', String(tab.dataset.tab === route.tab));
    }
    body.replaceChildren(...(route.tab === 'stats' ? stats(board) : route.tab === 'files' ? files(board, lead) : team(route, board, lead)).filter(Boolean));
  }

  for (const topic of ['boards', 'leads', 'cards', 'sessions', 'node']) store.subscribe(topic, () => { if (ui.state.route.name === 'project') render(); });
  return { el, render };
}
