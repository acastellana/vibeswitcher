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
import { hasDates, dated, timeAxis, axisPoints, landingWords, basisWords } from '../forecast.js';
import { leadLines, shownLines, dialCounts, waitingCards, waitingCount, cut, shortHashes, dayOf, teamCounts, standing, taskTone, taskStep, waitsOn, goalRows, lineKey } from '../conversation.js';
import { projectHref, routeHref } from '../ui.js';
import { questionStack, pluginCard, copyLine, cardSheet } from './cards.js';
import { tellLine, shellWord, leadLine } from '../actions.js';
import { actsFor, doButton, cardArgs, refusalWords } from '../acting.js';
import { waysFor, sendArgs, sentWords } from '../sendways.js';
import { sendMenu } from './sendmenu.js';

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
  // What waits on the user, at the bottom above the message box: never more than about 60% of the centre's height
  // (it scrolls inside itself beyond that), so the conversation stays in sight above it.
  const waitBox = h('section', { class: 'wait-box', hidden: true, 'aria-label': t('cQuestionsForYou') });
  const toWho = h('span', { class: 'to' });
  const input = h('input', { class: 'say', type: 'text', placeholder: t('messageLead'), 'aria-label': t('messageLead'), autocomplete: 'off', maxlength: 4000 });
  // With the `act` right, one Send and a menu of the ways the lead's agent takes a message (js/sendways.js): at its
  // next step (Enter: `tell`, as the lead's mail), now (Ctrl+Enter), after this turn where it has one, or interrupt,
  // then send (the others `send` to the lead's session with `when`).
  const sender = sendMenu({ className: 'lead-send', send: (way) => note({ way }) });
  input.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' && (event.ctrlKey || event.metaKey) && !sender.el.hidden && waysNow().includes('now')) { event.preventDefault(); note({ way: 'now' }); }
  });
  const composer = h('form', { class: 'composer-lead', onsubmit: (event) => { event.preventDefault(); note(); } }, toWho, input, sender.el);
  // While an answer is being changed here: its line's key, and what the node said if it refused.
  const changing = new Map();
  // A project whose lead isn't running: how to start it again, plainly (the line, and New project's lead form).
  const quietWords = h('p', { class: 'quiet-words' });
  const quietLines = h('div', { class: 'quiet-lines' });
  const quietForm = h('a', { class: 'link', href: '#/new' }, t('quietForm'));
  const quiet = h('section', { class: 'quiet-block', hidden: true, 'aria-label': t('quietProject') },
    h('h2', { class: 'quiet-title' }, t('quietProject')), quietWords, quietLines, h('p', { class: 'confirm-note' }, t('quietNote'), ' ', quietForm));
  let quietDrawn = '';
  const gone = h('div', { class: 'empty-state', hidden: true }, h('h2', null, t('goneProject')), h('p', null, t('goneProjectSub')));
  const el = h('section', { class: 'centre project-view', 'aria-label': t('lead') }, head, strip, quiet, talk, waitBox, composer, gone);
  // The project's name beside "N things need you" shrinks to an ellipsis; squeezed to a mark, it goes (the right
  // column's head names the project).
  const fitName = () => {
    name.classList.remove('squeezed');
    if (name.textContent && name.clientWidth < 56 && name.scrollWidth > name.clientWidth) name.classList.add('squeezed');
  };
  if (typeof ResizeObserver === 'function') new ResizeObserver(fitName).observe(head);

  // The waiting block's cards, one stack a project (it keeps what was typed in a card across updates).
  const stacks = new Map();
  const stackOf = (project) => {
    if (!stacks.has(project)) stacks.set(project, questionStack(app, project, { onChange: () => { drawn = ''; render(); } }));
    return stacks.get(project);
  };
  // Notes drafted for a lead, this page's only: the line that tells it from a terminal.
  const notes = new Map();
  let drawn = '';
  let lastProject = null;
  let lastLevel = null;
  let sheetShown = null;
  let waitShown = false;

  // The ways past the next step reach the lead's own session (`send`): that kind and a live lead session.
  const sendsTo = (lead) => actsFor(app, 'send') && !!lead?.session && store.state.sessions.has(lead.session);
  const waysNow = () => {
    const lead = store.state.leads.get(ui.state.route.id);
    return sendsTo(lead) ? waysFor(store.state.sessions.get(lead.session)) : ['step'];
  };
  // A message told at the lead's next step (`tell`): what the node says of it (`leads[…].told`, by its action): read
  // by the lead, or not yet (then it can be taken back). Nothing when the node doesn't say.
  const toldOf = (lead, entry) => (Array.isArray(lead?.told) ? lead.told.find((one) => one.action === entry.action) || null : undefined);
  function noteState(lead, entry) {
    if (entry.state === 'sending') return [t('acSending')];
    if (entry.state === 'retracted') return [t('swTakenBack')];
    if (entry.state !== 'sent') return [entry.why];
    if (entry.way !== 'step') return [sentWords(entry.way, entry.result)];
    const told = toldOf(lead, entry);
    if (told?.delivered) return [t('swReadByLead')];
    const back = told && actsFor(app, 'tell.retract')
      ? h('button', { class: 'link take-back', type: 'button', onclick: () => takeBack(entry) }, t('swTakeBack')) : null;
    return [entry.said || t('acToldLead'), back ? ' ' : null, back, entry.backWhy ? h('span', { class: 'refused' }, ' ', entry.backWhy) : null];
  }
  // Takes back a message the lead hasn't read (`tell.retract`); the node refuses once it has (`delivered`).
  function takeBack(entry) {
    store.request('tell.retract', { action: entry.action }).then((reply) => {
      if (reply.ok) entry.state = 'retracted';
      else entry.backWhy = reply.error?.code === 'delivered' ? t('swAlreadyRead') : refusalWords(reply.error);
      drawn = '';
      render();
    });
  }

  // A note for the lead: with the `act` right it is sent (`tell`), and said as sent or refused under it; else drafted,
  // with the line that sends it from a terminal.
  function note({ way = 'step' } = {}) {
    const route = ui.state.route;
    const text = input.value.trim();
    const lead = store.state.leads.get(route.id);
    if (!text || !lead?.root) return;
    const sends = way !== 'step' && sendsTo(lead) && waysNow().includes(way);
    const chosen = sends ? way : 'step';
    const action = crypto.randomUUID();
    const entry = { text, way: chosen, action, state: actsFor(app, 'tell') || sends ? 'sending' : 'draft', why: '' };
    notes.set(route.id, [...(notes.get(route.id) || []), entry]);
    input.value = '';
    if (entry.state === 'sending') {
      input.disabled = true;
      const asked = sends ? store.request('send', sendArgs(store.state.sessions.get(lead.session), text, chosen), action) : store.request('tell', { folder: lead.root, text }, action);
      asked.then((reply) => {
        input.disabled = false;
        entry.state = reply.ok ? 'sent' : 'refused';
        entry.why = reply.ok ? '' : refusalWords(reply.error);
        // What became of it, in the node's words where it gives them.
        entry.result = reply.ok ? reply.result || {} : null;
        entry.said = reply.ok ? reply.result?.said || null : null;
        if (!reply.ok) input.value = text;
        drawn = '';
        render();
      });
    }
    drawn = '';
    render();
    talk.scrollTop = talk.scrollHeight;
  }

  // An answer's state under its pill, as the node says it (`delivered`): read by the lead, or not yet, when it can be
  // changed (`answer.replace`, by its card and version); nothing when the node doesn't say.
  function answerState(line) {
    if (line.state !== 'answered' || line.delivered === undefined) return [];
    // Read: and if a Change was open here meanwhile, it says the change can't be made (the node's refusal, or the mark).
    if (line.delivered) {
      return [h('p', { class: 'answer-state' }, t('swReadByLead')),
        changing.has(line.key) ? h('p', { class: 'card-notice answer-state', role: 'alert' }, changing.get(line.key) || t('swAlreadyReadAnswer')) : null].filter(Boolean);
    }
    // Change only where the node says it would take it (`replaceable`), by the card it names.
    const card = line.card ? store.state.cards.get(line.card) : null;
    const cardId = line.card;
    if (!cardId || !line.replaceable || !actsFor(app, 'answer.replace')) return [h('p', { class: 'answer-state' }, t('swNotReadYet'))];
    const open = changing.has(line.key);
    const why = changing.get(line.key) || '';
    if (!open) {
      return [h('p', { class: 'answer-state' }, t('swNotReadYet'), ' ',
        h('button', { class: 'link', type: 'button', onclick: () => { changing.set(line.key, ''); drawn = ''; render(); } }, t('swChange')))];
    }
    const replace = (text) => {
      if (!text.trim()) return;
      store.request('answer.replace', { card: cardId, seen: card?.seen ?? null, version: line.version ?? card?.question?.version ?? null, text: text.trim() }).then((reply) => {
        if (reply.ok) changing.delete(line.key);
        else changing.set(line.key, reply.error?.code === 'delivered' ? t('swAlreadyReadAnswer') : refusalWords(reply.error));
        drawn = '';
        render();
      });
    };
    const options = (card?.question?.options || []).filter((option) => option !== line.answer);
    const own = h('input', { class: 'answer-input', type: 'text', placeholder: t('cOwnWords'), 'aria-label': t('yourAnswer'), autocomplete: 'off', maxlength: 4000 });
    return [h('div', { class: 'answer-change' },
      h('p', { class: 'answer-state' }, t('swChangeTo')),
      options.length ? h('div', { class: 'options' }, options.map((option) => h('button', { class: 'option', type: 'button', onclick: () => replace(option) }, h('span', { class: 'option-text' }, option)))) : null,
      h('form', { class: 'answer', onsubmit: (event) => { event.preventDefault(); replace(own.value); } }, own, h('button', { class: 'button', type: 'submit' }, t('cAnswer')),
        h('button', { class: 'button quiet', type: 'button', onclick: () => { changing.delete(line.key); drawn = ''; render(); } }, t('swKeep'))),
      why ? h('p', { class: 'card-notice', role: 'alert' }, why) : null)];
  }

  function lineEl(line, route) {
    const answered = line.kind === 'ask';
    const button = h('a', { class: `line kind-${line.kind}${answered ? ' answered' : ''}`, href: routeHref(route, { sheet: line.key }) },
      lineMark(line.kind), h('span', { class: 'line-text' }, cut(shortHashes(line.head), 140)), h('time', null, clock(line.at)));
    if (!answered || !line.answer) return [button];
    const said = line.state === 'autoDecided' ? t('wentAhead', { x: cut(line.answer, 60) }) : cut(shortHashes(line.answer), 140);
    const pill = h('p', { class: 'mine' + (line.state === 'autoDecided' ? ' auto' : '') }, said);
    return [button, pill, ...answerState(line)];
  }

  // A held config change or a base move, as a card: what it holds and the lines that settle it.
  // What a held config or a base move holds, whole, from the node (never the lead's words): shown before a click acts.
  function heldFacts(card) {
    const fact = (name, ...value) => [h('dt', null, name), h('dd', null, value)];
    if (card.kind === 'config' && card.config) {
      const items = card.config.items || [];
      const rails = card.config.guarded || [];
      return h('div', { class: 'facts' }, h('div', { class: 'facts-head' }, t('cFacts')), h('dl', null,
        items.map((item) => fact(item.name, [item.change || '', item.files?.length ? h('ul', { class: 'files' }, item.files.map((file) => h('li', null, h('code', null, file)))) : null])),
        rails.map((rail) => fact(rail.key, h('code', null, rail.value), rail.sinceAccept ? ` (${rail.sinceAccept})` : ''))));
    }
    if (card.kind === 'base' && card.base) {
      const base = card.base;
      return h('div', { class: 'facts' }, h('div', { class: 'facts-head' }, t('cFacts')), h('dl', null,
        fact(t('acBranch'), h('code', null, base.branch)),
        fact(t('acMove'), h('code', null, `${base.from || '?'} → ${base.to}`), base.fromIs && base.fromIs !== 'recorded' ? ` (${base.fromIs})` : ''),
        base.reason ? fact(t('acWhy'), base.reason) : null,
        (base.commits || []).length ? fact(t('cCommits'), h('ul', { class: 'files' }, base.commits.map((commit) => h('li', null, h('code', null, [String(commit.sha || '').slice(0, 8), commit.subject || ''].filter(Boolean).join(' ')))))) : null));
    }
    return null;
  }

  function otherCard(card) {
    if (card.kind === 'plugin') return pluginCard(card, app);
    const root = card.root || '';
    const config = card.kind === 'config';
    // With the `act` right: accept the held config, or accept or keep the base, from here (the card and its seen).
    const acts = config ? actsFor(app, 'config.accept') : actsFor(app, 'base.accept');
    return h('article', { class: 'card' },
      h('header', { class: 'card-head' }, h('span', { class: 'priority blocking' }, t('blocking')), h('time', { class: 'asked' }, t('askedAt', { who: t('vibeswitcher'), time: clock(card.at) }))),
      h('h3', { class: 'card-question' }, t(config ? 'heldConfig' : 'baseMove')),
      h('p', { class: 'card-why' }, t(config ? 'heldConfigWhy' : 'baseMoveWhy')),
      heldFacts(card),
      acts ? h('div', { class: 'card-acts' },
        doButton(app, { label: t(config ? 'acAccept' : 'acAcceptMove'), kind: config ? 'config.accept' : 'base.accept', args: () => cardArgs(card) }).el,
        !config && actsFor(app, 'base.keep') ? doButton(app, { label: t('acKeepBase'), kind: 'base.keep', quiet: true, args: () => cardArgs(card) }).el : null) : null,
      // The terminal's lines: beside the buttons when this tab acts; else one click away, never the pile of them.
      acts ? h('div', { class: 'card-command' }, h('span', { class: 'card-command-label' }, t('acSeeFirst')),
        config ? copyLine(`vibeswitcher config held ${shellWord(root)}`, 'the command that shows it') : copyLine(`vibeswitcher base show ${shellWord(root)}`, 'the command that shows it'))
        : h('details', { class: 'card-terminal' }, h('summary', null, t('cUseTerminal')),
          h('div', { class: 'card-command' }, h('span', { class: 'card-command-label' }, t('settleInTerminal')),
            config ? copyLine(`vibeswitcher config held ${shellWord(root)}`, 'the command that shows it') : copyLine(`vibeswitcher base show ${shellWord(root)}`, 'the command that shows it'),
            config ? copyLine('vibeswitcher approve', 'the command that accepts it') : null)));
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
    const key = JSON.stringify([route.id, route.show, lines.map((line) => [line.key, line.answer, line.state, line.delivered, line.replaceable]), extra.map((card) => [card.id, card.seen]), mine, waiting, lang(), store.acts(),
      lead?.told || null, [...changing]]);
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
    const waits = [];
    if (waiting) {
      const push = lead?.push ? 1 : 0;
      waits.push(h('h2', { class: 'asked-title' }, push && waiting === 1 ? t('pushWaits') : t('questionsForYou', { n: waiting - push }) + (push ? t('andAPush') : '')));
    }
    waits.push(stack.el, ...extra.map(otherCard));
    const inner = h('div', { class: 'wait-col' }, waits);
    waitBox.replaceChildren(inner);
    waitShown = !!waiting || !stack.el.hidden || extra.length > 0;
    waitBox.hidden = !waitShown;
    for (const entry of mine) {
      if (entry.state === 'draft') {
        children.push(h('div', { class: 'note' }, h('p', { class: 'mine' }, entry.text), copyLine(tellLine(lead.root, entry.text), 'the command that tells the lead'), h('p', { class: 'confirm-note' }, t('tellNote'))));
      } else {
        children.push(h('div', { class: 'note' }, h('p', { class: 'mine' + (entry.state === 'refused' ? ' refused' : '') }, entry.text),
          h('p', { class: 'confirm-note' + (entry.state === 'refused' ? ' refused' : '') }, noteState(lead, entry))));
      }
    }
    col.replaceChildren(...children);
    const changedView = lastProject !== route.id || lastLevel !== route.show;
    lastProject = route.id;
    lastLevel = route.show;
    if (changedView || atEnd) requestAnimationFrame(() => { talk.scrollTop = talk.scrollHeight; });
  }

  // The date column: the landing as the node says it, its range under it, and where it comes from on hover and focus
  // (every date an estimate). Empty, it takes no room (the estimates aren't there yet).
  function whenEl(landing, basis, context = {}) {
    const said = landingWords(landing, Date.now(), context);
    if (!said.date) return h('span', { class: 'road-when' });
    return h('span', { class: 'road-when' + (said.late ? ' late' : '') + (landing.basis === 'blocked' ? ' nodate' : ''), tabindex: basis ? 0 : null, data: basis ? { basis } : null, 'aria-label': [said.date, said.range, said.note, basis].filter(Boolean).join('. ') },
      h('b', null, said.date), said.range || said.note ? h('small', null, [said.range, said.note].filter(Boolean).join(' · ')) : null);
  }

  // A row's track on the axis: the grid (each tick, each midnight, now), a bar from its start to its likely landing,
  // the likely–worst range as a band, a dot where it lands, a mark per task landing (a goal's), a diamond at now for
  // what is blocked, and a bar to now in the late colour for what runs past its worst case.
  function trackEl(axis, { start = null, landing = null, tone = 'working', marks = [], blocked = false }) {
    const at = (node, from, to = null) => {
      node.style.setProperty('left', `${axis.x(from)}%`);
      if (to !== null) node.style.setProperty('width', `${Math.max(axis.x(to) - axis.x(from), 0.6)}%`);
      return node;
    };
    const parts = [h('i', { class: 'track-base' }), ...axis.ticks.map((tick) => at(h('i', { class: 'track-tick' + (tick.day ? ' day' : '') }), tick.at)), at(h('i', { class: 'track-now' }), axis.now)];
    const likely = dated(landing) ? Date.parse(landing.likely) : null;
    const worst = dated(landing) && Date.parse(landing.worst || '') ? Date.parse(landing.worst) : null;
    if (likely !== null) {
      if (worst !== null && worst > likely) parts.push(at(h('i', { class: `track-band tone-${tone}` }), likely, worst));
      const from = start !== null ? Math.max(start, axis.from) : Math.min(axis.now, likely);
      parts.push(at(h('i', { class: `track-bar tone-${tone}` }), from, likely), at(h('i', { class: `track-dot tone-${tone}` }), likely));
    } else if (landing?.basis === 'overdue' && start !== null) {
      parts.push(at(h('i', { class: 'track-bar late' }), Math.max(start, axis.from), axis.now));
    }
    for (const mark of marks) parts.push(at(h('i', { class: `track-mark tone-${mark.tone}` + (mark.blocked ? ' blocked' : '') }), mark.at));
    if (blocked) parts.push(at(h('i', { class: 'track-mark tone-blocked blocked now' }), axis.now));
    return h('span', { class: 'track', 'aria-hidden': 'true' }, parts);
  }

  // The axis's labels over the rows: now, the hours, each midnight.
  function axisHead(axis) {
    const label = (tick) => { const el = h('span', { class: 'axis-tick' + (tick.day ? ' day' : '') }, tick.label); el.style.setProperty('left', `${axis.x(tick.at)}%`); return el; };
    const now = h('span', { class: 'axis-tick now' }, t('now'));
    now.style.setProperty('left', `${axis.x(axis.now)}%`);
    return h('div', { class: 'axis-row' }, h('span'), h('span', { class: 'axis' }, ...axis.ticks.filter((tick) => Math.abs(axis.x(tick.at) - axis.x(axis.now)) > 4).map(label), now), h('span'), h('span'));
  }

  // A task's line: its title and state (its note under them when dated), its five steps or its bar, its date.
  function taskLine2(task, note, { axis, score, cls, board = null }) {
    if (!axis) return h('div', { class: cls }, h('span', { class: 'road-title' }, task.title, h('small', null, nodeWords(task.state))), stepBar(task), h('span', { class: 'road-note' }, ...note), h('span', { class: 'road-when' }));
    const start = Date.parse(task.startedAt || '') || null;
    return h('div', { class: cls },
      h('span', { class: 'road-title' }, task.title, h('small', null, [nodeWords(task.state), ...note.map((one) => (typeof one === 'string' ? one : one.textContent))].filter(Boolean).join(' · '))),
      trackEl(axis, { start, landing: task.forecast, tone: taskTone(task), blocked: task.forecast?.basis === 'blocked' || (!task.forecast && taskTone(task) === 'blocked') }),
      whenEl(task.forecast, basisWords(task.forecast, { estimate: task.estimate, score }), { task, board }));
  }

  function taskRow(task, extra = [], dates = {}) {
    return taskLine2(task, extra, { ...dates, cls: 'road-row' + (dates.axis ? ' dated' : '') });
  }

  // Whom a blocked task waits on, in words (you, other tasks, the lead), or nothing when the board doesn't say.
  function waitsWords(task, board, cards) {
    const who = waitsOn(task, board, cards);
    const words = who.who === 'you' ? t('waitsOnYou') : who.who === 'tasks' ? t('waitsOnTasks', { list: listed(who.titles) }) : who.who === 'lead' ? t('waitsOnLead') : '';
    return h('span', { class: who.who === 'you' ? 'tone-text-asked' : '' }, words);
  }

  // A task's note on the roadmap: what it does now, whom it waits on, or what it comes after.
  function roadNote(task, board, cards, where) {
    if (where === 'blocked') return [waitsWords(task, board, cards)];
    if (where === 'queued') return task.after?.length ? [t('after', { list: listed(task.after.map((slug) => board.tasks.find((one) => one.slug === slug)?.title || slug)) })] : [];
    return [cut(shortHashes(nodeWords(taskLine(task))), 120)];
  }

  // The address with `id` opened or closed among the roadmap's open rows.
  const toggled = (route, id) => projectHref(route.id, { view: 'roadmap', open: route.open.includes(id) ? route.open.filter((one) => one !== id) : [...route.open, id] });

  // With goals: one row per goal (its tasks' marks and counts; with estimates its bar to its landing, the likely–worst
  // band, a mark per task landing, and its date), opening in place to its tasks joined to it by branch lines; Unsorted
  // last of the open ones; the done goals folded at the end.
  function drawGoals(route, board, cards, axis) {
    const rows = goalRows(board);
    const team = standing(board);
    const score = board.score || null;
    const whereOf = (task) => (team.motion.includes(task) ? 'motion' : team.blocked.includes(task) ? 'blocked' : team.queued.includes(task) ? 'queued' : 'merged');
    const goalRow = (row) => {
      const id = row.goal ? row.goal.id : 'unsorted';
      const open = route.open.includes(id);
      const counts = [['motion', 'roadCountMotion'], ['blocked', 'roadCountBlocked'], ['queued', 'roadCountQueued'], ['merged', 'roadCountMerged']]
        .filter(([where]) => row.counts[where]).map(([where, key]) => t(key, { n: row.counts[where] }));
      const marks = axis
        ? trackEl(axis, {
          start: Math.min(...row.tasks.map((task) => Date.parse(task.startedAt || '') || Infinity)), landing: row.goal?.forecast, tone: 'goal',
          marks: row.tasks.filter((task) => dated(task.forecast)).map((task) => ({ at: Date.parse(task.forecast.likely), tone: taskTone(task) })),
          blocked: row.tasks.some((task) => whereOf(task) === 'blocked'),
        })
        : h('span', { class: 'goal-marks', 'aria-hidden': 'true' }, row.tasks.map((task) => h('i', { class: `goal-mark tone-${taskTone(task)}${whereOf(task) === 'blocked' ? ' blocked' : ''}`, title: task.title })));
      // A group, not a button: the title side opens and closes the goal; the track and the date (which takes focus for
      // where it comes from) do nothing.
      const head = h('div', { class: 'goal-row' + (row.goal ? '' : ' unsorted') + (row.goal?.state === 'done' ? ' done' : ''), role: 'group', 'aria-label': row.goal ? row.goal.title : t('roadUnsorted') },
        h('button', { class: 'goal-title', type: 'button', 'aria-expanded': String(open), onclick: () => ui.go(toggled(route, id)) },
          h('b', null, row.goal ? row.goal.title : t('roadUnsorted'), h('span', { class: 'goal-toggle' }, icon('chevron', 10))),
          h('small', null, [counts.join(', ') || t('roadNoTasks'), row.goal?.done ? `${t('roadDoneMeans')} ${row.goal.done}` : null].filter(Boolean).join(' · '))),
        marks, axis ? whenEl(row.goal?.forecast, basisWords(row.goal?.forecast, { score, goal: true }), { board }) : h('span', { class: 'road-when' }));
      if (!open) return [head];
      const tasks = row.tasks.map((task, index) => taskLine2(task, roadNote(task, board, cards, whereOf(task)), { axis, score, board, cls: 'goal-task' + (index === row.tasks.length - 1 ? ' last' : '') }));
      return [head, h('div', { class: 'goal-tasks' }, tasks.length ? tasks : [h('p', { class: 'road-note goal-empty' }, t('roadNoTasks'))])];
    };
    const children = [h('p', { class: 'road-intro' }, axis ? [t('roadGoalsDated'), score?.line ? ' ' + score.line : ''].join('') : t('roadGoalsIntro'))];
    if (axis) children.push(axisHead(axis));
    for (const row of rows.open) children.push(...goalRow(row));
    if (rows.unsorted) children.push(...goalRow(rows.unsorted));
    if (rows.done.length) {
      const open = route.open.includes('done');
      children.push(h('button', { class: 'road-band', type: 'button', 'aria-expanded': String(open), onclick: () => ui.go(toggled(route, 'done')) },
        h('span', null, t('roadDoneGoals', { n: rows.done.length })), h('span', { class: 'road-band-toggle' }, open ? t('roadQueueClose') : t('roadQueueOpen'), icon('chevron', 10))));
      if (open) for (const row of rows.done) children.push(...goalRow(row));
    }
    col.replaceChildren(...children);
    setClass(col, 'dated', !!axis);
    talk.scrollTop = 0;
  }

  function drawRoadmap(route, board) {
    const team = standing(board);
    const cards = [...store.state.cards.values()];
    const key = JSON.stringify([route, board?.tasks, board?.goals, board?.score, cards.map((card) => [card.id, card.open]), lang(), Math.floor(Date.now() / 60000)]);
    if (key === drawn) return;
    drawn = key;
    // With estimates, the time axis; without, what the roadmap drew before them.
    const axis = hasDates(board) ? timeAxis(axisPoints(board)) : null;
    if (board?.goals?.length) { drawGoals(route, board, cards, axis); return; }
    const dates = { axis, score: board?.score || null, board };
    const open = route.open.includes('queue');
    const titles = (slugs) => slugs.map((slug) => board.tasks.find((task) => task.slug === slug)?.title || slug);
    const children = [h('p', { class: 'road-intro' }, axis ? [t('roadDated'), board.score?.line ? ' ' + board.score.line : ''].join('') : t('roadIntro'))];
    if (axis) children.push(axisHead(axis));
    if (team.motion.length) children.push(h('h2', { class: 'road-head' }, t('roadMotion')), ...team.motion.map((task) => taskRow(task, [cut(shortHashes(nodeWords(taskLine(task))), 120)], dates)));
    if (team.blocked.length) children.push(h('h2', { class: 'road-head' }, t('roadBlocked')), ...team.blocked.map((task) => taskRow(task, [waitsWords(task, board, cards)], dates)));
    if (team.queued.length) {
      // A plain open and close of the row (the address keeps it, so back closes it again).
      const band = h('button', { class: 'road-band', type: 'button', 'aria-expanded': String(open), onclick: () => ui.go(toggled(route, 'queue')) },
        h('span', { class: 'road-band-bar' }), h('span', null, t('roadQueue', { n: team.queued.length })),
        axis ? whenEl(lastLanding(team.queued), '') : null,
        h('span', { class: 'road-band-toggle' }, open ? t('roadQueueClose') : t('roadQueueOpen'), icon('chevron', 10)));
      children.push(h('h2', { class: 'road-head' }, t('roadQueued')), band);
      if (open) children.push(h('div', { class: 'road-queue' }, team.queued.map((task) => taskRow(task, task.after?.length ? [t('after', { list: listed(titles(task.after)) })] : [], dates))));
    }
    if (!team.motion.length && !team.blocked.length && !team.queued.length) children.push(h('p', { class: 'empty-line' }, t('roadNothing')));
    col.replaceChildren(...children);
    setClass(col, 'dated', !!axis);
    talk.scrollTop = 0;
  }

  // The queue's band says when its last dated task lands ("all by …").
  function lastLanding(tasks) {
    const last = tasks.filter((task) => dated(task.forecast)).sort((a, b) => Date.parse(b.forecast.likely) - Date.parse(a.forecast.likely))[0];
    return last ? { ...last.forecast, basis: tasks.every((task) => dated(task.forecast)) ? last.forecast.basis : 'partial', undated: tasks.filter((task) => !dated(task.forecast)).length } : null;
  }

  // The sheet the address names, opened over this project's lines; closing it takes `sheet=` off the address.
  function drawSheet(route, board) {
    if (route.view !== 'lead' || !route.sheet) {
      if (sheetShown && sheet.shown()) { sheetShown = null; sheet.close(); }
      sheetShown = null;
      return;
    }
    if (sheetShown === route.sheet && sheet.shown()) return;
    const close = () => {
      if (sheetShown !== route.sheet) return;
      sheetShown = null;
      const now = ui.state.route;
      if (now.name === 'project' && now.sheet) ui.go(routeHref(now, { sheet: null }));
    };
    // A waiting card's whole text ("Read it all"): its key is the card's first id's.
    const card = [...store.state.cards.values()].find((one) => one.project === route.id && one.question && lineKey('card', store.cardKey(one.id)) === route.sheet);
    if (card) {
      sheetShown = route.sheet;
      sheet.open(cardSheet(card), close);
      return;
    }
    const line = leadLines(board).find((one) => one.key === route.sheet);
    if (!line) return;
    sheetShown = route.sheet;
    const more = [];
    if (line.kind === 'ask' && line.answer) more.push(h('h3', { class: 'sheet-sub' }, line.state === 'autoDecided' ? t('wentAhead', { x: '' }).replace(/\s*$/, '') : t('yourAnswer')), h('p', { class: 'mine' }, line.answer));
    if (line.kind === 'ask' && line.state === 'withdrawn') more.push(h('p', { class: 'sheet-sub' }, t('withdrawn') + (line.why ? `: ${line.why}` : '')));
    if (line.kind === 'update' && line.why) more.push(h('h3', { class: 'sheet-sub' }, t('why')), h('p', null, line.why));
    const kicker = { ask: 'question', result: 'result', update: 'decision' }[line.kind];
    sheet.open({ kicker: t(kicker), title: line.kind === 'result' ? line.title : line.head, at: line.at, text: line.full, more }, close);
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
    if (!known && !connecting) waitBox.hidden = true;
    gone.hidden = known || connecting;
    if (!known) return;
    const root = lead?.root || board?.root || '';
    const waiting = waitingCount(state, route.id);
    setText(big, waiting ? t('thingsNeedYou', { n: waiting }) : t('nothingNeedsYou'));
    setClass(big, 'asked', waiting > 0);
    setText(name, lastPart(root));
    fitName();
    name.title = tilde(root, state.node?.home);
    leadLink.setAttribute('href', projectHref(route.id));
    roadLink.setAttribute('href', projectHref(route.id, { view: 'roadmap' }));
    if (route.view === 'roadmap') { roadLink.setAttribute('aria-current', 'page'); leadLink.removeAttribute('aria-current'); } else { leadLink.setAttribute('aria-current', 'page'); roadLink.removeAttribute('aria-current'); }
    dial.hidden = route.view !== 'lead';
    composer.hidden = route.view !== 'lead';
    waitBox.hidden = route.view !== 'lead' || !waitShown;
    strip.replaceChildren(h('b', null, t('team')), ...stripCounts(board));
    const live = !!lead?.session && state.sessions.has(lead.session);
    setText(toWho, lead?.root ? t('toLead', { p: lastPart(root) }) : t('noLeadToTell'));
    input.disabled = !lead?.root;
    // The buttons only where the page sends: next step with `tell`; now with `send` to a live lead session.
    sender.el.hidden = !lead?.root || (!actsFor(app, 'tell') && !sendsTo(lead));
    sender.update(waysNow());
    setClass(el, 'quiet', !live);
    quiet.hidden = live || route.view !== 'lead' || !root;
    const quietKey = JSON.stringify([root, live, lang(), store.acts()]);
    if (!quiet.hidden && quietKey !== quietDrawn) {
      quietDrawn = quietKey;
      setText(quietWords, t('quietWords'));
      // With the `act` right, the two starts are buttons (`lead`, back in its conversation or fresh), the lines beside.
      const acts = actsFor(app, 'lead');
      quietLines.replaceChildren(...[acts ? h('div', { class: 'card-acts' },
        doButton(app, { label: t('acResumeLead'), kind: 'lead', args: () => ({ folder: root, resume: true }) }).el,
        doButton(app, { label: t('acFreshLead'), kind: 'lead', quiet: true, args: () => ({ folder: root }) }).el) : null,
      copyLine(`${leadLine(root)} --resume`, 'the command that starts its lead again in its conversation'),
      copyLine(leadLine(root), 'the command that starts a new lead there')].filter(Boolean));
      quietForm.onclick = (event) => { event.preventDefault(); app.startLead?.(root); };
    }
    if (route.view === 'roadmap') { lastProject = null; drawRoadmap(route, board); } else drawLead(route, board, lead);
    drawSheet(route, board);
  }

  const schedule = framed(render);
  for (const topic of ['boards', 'leads', 'cards', 'sessions', 'connection', 'node']) store.subscribe(topic, schedule);
  return { el, render };
}
