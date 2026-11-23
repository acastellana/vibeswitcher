// The centre column on a project (the redesign's "Centre"): a header saying what needs the user, Lead | Roadmap, the
// noise dial, the team strip, and then either the lead conversation or the roadmap.
//
// - Lead: only what passes between the lead and the user, one line each, oldest first: the questions it asked with the
//   user's answers under them (muted once answered), its results, and with the dial at Everything its decisions, which
//   are its status updates. A line's whole text opens in the side sheet (`sheet=` in the address). What waits on the
//   user sits at the bottom, above the message box: the cards (views/cards.js: a pick leaves a draft and shows the line
//   that confirms it in a terminal, as before), the lead's push, held config and a base move.
// - Roadmap, without goals (the node keeps none yet): the tasks in motion, the blocked ones with whom they wait on when
//   the board says, and the queue as one band that opens. No dates: they come with the workers' estimates.
//
// Every line is the sessions' writing, drawn as text.

import { h, s, setText, setClass, framed } from '../dom.js';
import { icon } from '../marks.js';
import { clock, moment, tilde, lastPart, taskLine } from '../words.js';
import { t, listed, lang, nodeWords } from '../i18n.js';
import { leadLines, shownLines, dialCounts, waitingCards, waitingCount, cut, shortHashes, dayOf, teamCounts, standing, taskTone, taskStep, waitsOn } from '../conversation.js';
import { projectHref, routeHref } from '../ui.js';
import { questionStack, pluginCard, copyLine } from './cards.js';
import { tellLine, shellWord, leadLine } from '../actions.js';

// The line marks: a diamond for a question (filled while open, an outline once answered), a check for a result, a
// small dot for a status update.
function lineMark(kind) {
  const svg = (...children) => s('svg', { class: `line-mark mark-${kind}`, width: 16, height: 16, viewBox: '0 0 18 18', 'aria-hidden': 'true' }, ...children);
  if (kind === 'ask') return svg(s('path', { d: 'M9 2 16 9 9 16 2 9z' }));
  if (kind === 'result') return svg(s('circle', { cx: 9, cy: 9, r: 7.5 }), s('path', { class: 'tick', d: 'M5.4 9.3 8 11.8l4.6-5.3' }));
  return svg(s('circle', { cx: 9, cy: 9, r: 3 }));
}

// The five steps (queued, working, audit, ready to merge, merged) as a bar in the task's colour.
export function stepBar(task) {
  const step = taskStep(task);
  return h('span', { class: `steps tone-${taskTone(task)}`, title: t('steps'), 'aria-hidden': 'true' },
    [1, 2, 3, 4, 5].map((n) => h('i', { class: n <= step ? 'on' : '' })));
}

// The team strip's counts, each with its colour.
export function stripCounts(board) {
  const counts = teamCounts(board);
  const parts = ['working', 'review', 'ready', 'blocked', 'queued', 'merged'].filter((tone) => counts[tone])
    .map((tone) => h('span', { class: 'strip-part' }, h('i', { class: `dot tone-${tone}` }), t(tone, { n: counts[tone] })));
  return parts.length ? parts : [h('span', { class: 'strip-part' }, t('noTasks'))];
}

const dayWords = (iso) => {
  const day = dayOf(iso, Date.now(), lang());
  return day === 'today' ? t('today') : day === 'yesterday' ? t('yesterday') : day;
};

export function projectView(app, { sheet }) {
  const { store, ui } = app;
  const big = h('h1', { class: 'big' });
  const name = h('span', { class: 'pname' });
  const leadLink = h('a', { class: 'switch-link' }, t('lead'));
  const roadLink = h('a', { class: 'switch-link' }, t('roadmap'));
  const switcher = h('nav', { class: 'switch', 'aria-label': t('lead') + ' / ' + t('roadmap') }, leadLink, roadLink);
  const dialLinks = ['asks', 'decisions', 'all'].map((level) => {
    const count = h('small');
    return { level, count, el: h('a', { class: 'switch-link' }, t({ asks: 'dialAsks', decisions: 'dialDecisions', all: 'dialAll' }[level]), count) };
  });
  const dial = h('nav', { class: 'switch dial', 'aria-label': t('dialLabel') }, dialLinks.map((link) => link.el));
  const menuButton = h('button', { class: 'icon-button phone-only', type: 'button', 'aria-label': t('menu'), onclick: () => app.drawer('left') }, icon('menu', 16));
  const teamButton = h('button', { class: 'icon-button phone-only team-button', type: 'button', 'aria-label': t('showTeam'), onclick: () => app.drawer('right') }, icon('team', 16));
  const head = h('header', { class: 'centre-head' }, menuButton, h('div', { class: 'head-words' }, big, name), switcher, h('span', { class: 'grow' }), dial, teamButton);
  const strip = h('div', { class: 'team-strip' });
  const col = h('div', { class: 'col' });
  const talk = h('div', { class: 'talk' }, col);
  const toWho = h('span', { class: 'to' });
  const input = h('input', { class: 'say', type: 'text', placeholder: t('messageLead'), 'aria-label': t('messageLead'), autocomplete: 'off', maxlength: 4000 });
  const composer = h('form', { class: 'composer-lead', onsubmit: (event) => { event.preventDefault(); note(); } }, toWho, input);
  // A project whose lead isn't running: how to start it again, plainly (the line, and New project's lead form).
  const quietWords = h('p', { class: 'quiet-words' });
  const quietLines = h('div', { class: 'quiet-lines' });
  const quietForm = h('a', { class: 'link', href: '#/new' }, t('quietForm'));
  const quiet = h('section', { class: 'quiet-block', hidden: true, 'aria-label': t('quietProject') },
    h('h2', { class: 'quiet-title' }, t('quietProject')), quietWords, quietLines, h('p', { class: 'confirm-note' }, t('quietNote'), ' ', quietForm));
  let quietDrawn = '';
  const gone = h('div', { class: 'empty-state', hidden: true }, h('h2', null, t('goneProject')), h('p', null, t('goneProjectSub')));
  const el = h('section', { class: 'centre project-view', 'aria-label': t('lead') }, head, strip, quiet, talk, composer, gone);

  // The waiting block's cards, one stack a project (it keeps what was typed in a card across updates).
  const stacks = new Map();
  const stackOf = (project) => {
    if (!stacks.has(project)) stacks.set(project, questionStack(app, project));
    return stacks.get(project);
  };
  // Notes drafted for a lead, this page's only: the line that tells it from a terminal.
  const notes = new Map();
  let drawn = '';
  let lastProject = null;
  let lastLevel = null;
  let sheetShown = null;

  function note() {
    const route = ui.state.route;
    const text = input.value.trim();
    const lead = store.state.leads.get(route.id);
    if (!text || !lead?.root) return;
    notes.set(route.id, [...(notes.get(route.id) || []), text]);
    input.value = '';
    drawn = '';
    render();
    talk.scrollTop = talk.scrollHeight;
  }

  function lineEl(line, route) {
    const answered = line.kind === 'ask';
    const button = h('a', { class: `line kind-${line.kind}${answered ? ' answered' : ''}`, href: routeHref(route, { sheet: line.key }) },
      lineMark(line.kind), h('span', { class: 'line-text' }, cut(shortHashes(line.head), 140)), h('time', null, clock(line.at)));
    if (!answered || !line.answer) return [button];
    const said = line.state === 'autoDecided' ? t('wentAhead', { x: cut(line.answer, 60) }) : cut(shortHashes(line.answer), 140);
    return [button, h('p', { class: 'mine' + (line.state === 'autoDecided' ? ' auto' : '') }, said)];
  }

  // A held config change or a base move, as a card: what it holds and the lines that settle it.
  function otherCard(card) {
    if (card.kind === 'plugin') return pluginCard(card);
    const root = card.root || '';
    const config = card.kind === 'config';
    return h('article', { class: 'card' },
      h('header', { class: 'card-head' }, h('span', { class: 'priority blocking' }, t('blocking')), h('time', { class: 'asked' }, t('askedAt', { who: t('vibeswitcher'), time: clock(card.at) }))),
      h('h3', { class: 'card-question' }, t(config ? 'heldConfig' : 'baseMove')),
      h('p', { class: 'card-why' }, t(config ? 'heldConfigWhy' : 'baseMoveWhy')),
      h('div', { class: 'card-command' }, h('span', { class: 'card-command-label' }, t('settleInTerminal')),
        config ? copyLine(`vibeswitcher config held ${shellWord(root)}`, 'the command that shows it') : copyLine(`vibeswitcher base show ${shellWord(root)}`, 'the command that shows it'),
        config ? copyLine('vibeswitcher approve', 'the command that accepts it') : null));
  }

  function drawLead(route, board, lead) {
    const lines = leadLines(board);
    const cards = waitingCards(store.state.cards.values(), route.id);
    const waiting = waitingCount(store.state, route.id);
    const counts = dialCounts(lines, waiting);
    for (const link of dialLinks) {
      link.el.setAttribute('href', routeHref(route, { show: link.level, sheet: null }));
      if (link.level === route.show) link.el.setAttribute('aria-current', 'true'); else link.el.removeAttribute('aria-current');
      setText(link.count, String(counts[link.level]));
    }
    const stack = stackOf(route.id);
    stack.update();
    const extra = cards.filter((card) => !['question', 'approval'].includes(card.kind));
    const mine = notes.get(route.id) || [];
    const key = JSON.stringify([route.id, route.show, lines.map((line) => [line.key, line.answer, line.state]), extra.map((card) => card.id), mine, waiting, lang()]);
    if (key === drawn) return;
    const atEnd = talk.scrollHeight - talk.scrollTop - talk.clientHeight < 40;
    drawn = key;
    const shown = shownLines(lines, route.show);
    const children = [];
    let day = null;
    for (const line of shown) {
      const words = dayWords(line.at);
      if (words !== day) { day = words; children.push(h('p', { class: 'day' }, words)); }
      children.push(...lineEl(line, route));
    }
    // A short conversation leaves the centre bare: the lead's latest statement at its top, quietly, opening its sheet.
    const latest = lines.filter((line) => line.kind === 'update').at(-1);
    if (shown.length < 3 && latest && !shown.includes(latest)) {
      children.unshift(h('a', { class: 'latest-said', href: routeHref(route, { sheet: latest.key }) }, h('small', null, t('leadSaid', { time: moment(latest.at) })), cut(shortHashes(latest.head), 220)),
        h('span', { class: 'col-gap' }));
    }
    if (!shown.length && route.show !== 'asks') children.push(h('p', { class: 'empty-line' }, t('emptyTalk')));
    if (route.show === 'asks' && !waiting) children.push(h('p', { class: 'empty-line' }, t('emptyAsks')));
    if (waiting) {
      const push = lead?.push ? 1 : 0;
      children.push(h('h2', { class: 'asked-title' }, push && waiting === 1 ? t('pushWaits') : t('questionsForYou', { n: waiting - push }) + (push ? t('andAPush') : '')));
    }
    children.push(stack.el, ...extra.map(otherCard));
    for (const text of mine) {
      children.push(h('div', { class: 'note' }, h('p', { class: 'mine' }, text), copyLine(tellLine(lead.root, text), 'the command that tells the lead'), h('p', { class: 'confirm-note' }, t('tellNote'))));
    }
    col.replaceChildren(...children);
    const changedView = lastProject !== route.id || lastLevel !== route.show;
    lastProject = route.id;
    lastLevel = route.show;
    if (changedView || atEnd) requestAnimationFrame(() => { talk.scrollTop = talk.scrollHeight; });
  }

  function taskRow(task, extra = []) {
    return h('div', { class: 'road-row' },
      h('span', { class: 'road-title' }, task.title, h('small', null, nodeWords(task.state))),
      stepBar(task), h('span', { class: 'road-note' }, ...extra));
  }

  function drawRoadmap(route, board) {
    const team = standing(board);
    const cards = [...store.state.cards.values()];
    const key = JSON.stringify([route, board?.tasks, cards.map((card) => [card.id, card.open]), lang()]);
    if (key === drawn) return;
    drawn = key;
    const open = route.open.includes('queue');
    const titles = (slugs) => slugs.map((slug) => board.tasks.find((task) => task.slug === slug)?.title || slug);
    const children = [h('p', { class: 'road-intro' }, t('roadIntro'))];
    if (team.motion.length) children.push(h('h2', { class: 'road-head' }, t('roadMotion')), ...team.motion.map((task) => taskRow(task, [cut(shortHashes(nodeWords(taskLine(task))), 120)])));
    if (team.blocked.length) {
      children.push(h('h2', { class: 'road-head' }, t('roadBlocked')), ...team.blocked.map((task) => {
        const who = waitsOn(task, board, cards);
        const words = who.who === 'you' ? t('waitsOnYou') : who.who === 'tasks' ? t('waitsOnTasks', { list: listed(who.titles) }) : who.who === 'lead' ? t('waitsOnLead') : '';
        return taskRow(task, [h('span', { class: who.who === 'you' ? 'tone-text-asked' : '' }, words)]);
      }));
    }
    if (team.queued.length) {
      // A plain open and close of the row (the address keeps it, so back closes it again).
      const to = projectHref(route.id, { view: 'roadmap', open: open ? route.open.filter((one) => one !== 'queue') : [...route.open, 'queue'] });
      const band = h('button', { class: 'road-band', type: 'button', 'aria-expanded': String(open), onclick: () => ui.go(to) },
        h('span', { class: 'road-band-bar' }), h('span', null, t('roadQueue', { n: team.queued.length })),
        h('span', { class: 'road-band-toggle' }, open ? t('roadQueueClose') : t('roadQueueOpen'), icon('chevron', 10)));
      children.push(h('h2', { class: 'road-head' }, t('roadQueued')), band);
      if (open) children.push(h('div', { class: 'road-queue' }, team.queued.map((task) => taskRow(task, task.after?.length ? [t('after', { list: listed(titles(task.after)) })] : []))));
    }
    if (!team.motion.length && !team.blocked.length && !team.queued.length) children.push(h('p', { class: 'empty-line' }, t('roadNothing')));
    col.replaceChildren(...children);
    talk.scrollTop = 0;
  }

  // The sheet the address names, opened over this project's lines; closing it takes `sheet=` off the address.
  function drawSheet(route, board) {
    if (route.view !== 'lead' || !route.sheet) {
      if (sheetShown && sheet.shown()) { sheetShown = null; sheet.close(); }
      sheetShown = null;
      return;
    }
    if (sheetShown === route.sheet && sheet.shown()) return;
    const line = leadLines(board).find((one) => one.key === route.sheet);
    if (!line) return;
    sheetShown = route.sheet;
    const more = [];
    if (line.kind === 'ask' && line.answer) more.push(h('h3', { class: 'sheet-sub' }, line.state === 'autoDecided' ? t('wentAhead', { x: '' }).replace(/\s*$/, '') : t('yourAnswer')), h('p', { class: 'mine' }, line.answer));
    if (line.kind === 'ask' && line.state === 'withdrawn') more.push(h('p', { class: 'sheet-sub' }, t('withdrawn') + (line.why ? `: ${line.why}` : '')));
    if (line.kind === 'update' && line.why) more.push(h('h3', { class: 'sheet-sub' }, t('why')), h('p', null, line.why));
    const kicker = { ask: 'question', result: 'result', update: 'decision' }[line.kind];
    sheet.open({ kicker: t(kicker), title: line.kind === 'result' ? line.title : line.head, at: line.at, text: line.full, more }, () => {
      if (sheetShown !== route.sheet) return;
      sheetShown = null;
      const now = ui.state.route;
      if (now.name === 'project' && now.sheet) ui.go(routeHref(now, { sheet: null }));
    });
  }

  function render() {
    const route = ui.state.route;
    if (route.name !== 'project') return;
    const state = store.state;
    const lead = state.leads.get(route.id) || null;
    const board = state.boards.get(route.id) || null;
    const known = !!lead || !!board;
    const connecting = state.connection === 'connecting';
    for (const part of [head, strip, talk, composer]) part.hidden = !known && !connecting;
    gone.hidden = known || connecting;
    if (!known) return;
    const root = lead?.root || board?.root || '';
    const waiting = waitingCount(state, route.id);
    setText(big, waiting ? t('thingsNeedYou', { n: waiting }) : t('nothingNeedsYou'));
    setClass(big, 'asked', waiting > 0);
    setText(name, lastPart(root));
    name.title = tilde(root, state.node?.home);
    leadLink.setAttribute('href', projectHref(route.id));
    roadLink.setAttribute('href', projectHref(route.id, { view: 'roadmap' }));
    if (route.view === 'roadmap') { roadLink.setAttribute('aria-current', 'page'); leadLink.removeAttribute('aria-current'); } else { leadLink.setAttribute('aria-current', 'page'); roadLink.removeAttribute('aria-current'); }
    dial.hidden = route.view !== 'lead';
    composer.hidden = route.view !== 'lead';
    strip.replaceChildren(h('b', null, t('team')), ...stripCounts(board));
    const live = !!lead?.session && state.sessions.has(lead.session);
    setText(toWho, lead?.root ? t('toLead', { p: lastPart(root) }) : t('noLeadToTell'));
    input.disabled = !lead?.root;
    setClass(el, 'quiet', !live);
    quiet.hidden = live || route.view !== 'lead' || !root;
    const quietKey = JSON.stringify([root, live, lang()]);
    if (!quiet.hidden && quietKey !== quietDrawn) {
      quietDrawn = quietKey;
      setText(quietWords, t('quietWords'));
      quietLines.replaceChildren(copyLine(`${leadLine(root)} --resume`, 'the command that starts its lead again in its conversation'),
        copyLine(leadLine(root), 'the command that starts a new lead there'));
      quietForm.onclick = (event) => { event.preventDefault(); app.startLead?.(root); };
    }
    if (route.view === 'roadmap') { lastProject = null; drawRoadmap(route, board); } else drawLead(route, board, lead);
    drawSheet(route, board);
  }

  const schedule = framed(render);
  for (const topic of ['boards', 'leads', 'cards', 'sessions', 'connection', 'node']) store.subscribe(topic, schedule);
  return { el, render };
}
