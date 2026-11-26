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

import * as kit from '../kit.js';
import { h, s, setText, setClass, framed } from '../dom.js';
import { icon } from '../marks.js';
import { clock, moment, tilde, lastPart, taskLine } from '../words.js';
import { t, listed, lang, nodeWords } from '../i18n.js';
import { hasDates, dated, timeAxis, axisPoints, landingWords, basisWords } from '../forecast.js';
import { leadLines, shownLines, dialCounts, waitingCards, waitingCount, withPushLines, cut, shortHashes, dayOf, teamCounts, standing, taskTone, taskStep, waitsOn, goalRows, lineKey } from '../conversation.js';
import { projectHref, routeHref } from '../ui.js';
import { questionStack, pluginCard, copyLine, cardSheet, optionWords } from './cards.js';
import { heldParts, sinceWord } from './sheet.js';
import { leadStartOrLine, baseMoveOf } from './drive.js';
import { tellLine, shellWord, leadLine } from '../actions.js';
import { pushReceipt } from '../push.js';
import { pluginFacts } from '../plugincard.js';
import { actsFor, doButton, cardArgs, refusalWords } from '../acting.js';
import { waysFor, sendArgs, sentWords } from '../sendways.js';
import { sendMenu } from './sendmenu.js';
import { composer as messageBox } from './composer.js';

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
  const leadLink = kit.segment({ tag: 'a' }, t('lead'));
  const roadLink = kit.segment({ tag: 'a' }, t('roadmap'));
  const switcher = kit.segmented({ tag: 'nav', 'aria-label': t('lead') + ' / ' + t('roadmap') }, leadLink, roadLink);
  const dialLinks = ['asks', 'decisions', 'all'].map((level) => {
    const count = h('small');
    return { level, count, el: kit.segment({ tag: 'a' }, t({ asks: 'dialAsks', decisions: 'dialDecisions', all: 'dialAll' }[level]), count) };
  });
  const dial = kit.segmented({ tag: 'nav', class: 'dial', 'aria-label': t('dialLabel') }, dialLinks.map((link) => link.el));
  // On a phone (style.css's 760 px) the header is one row (the menu, the project's name, what needs you as a count, the
  // team), with Lead | Roadmap under it and the dial folded behind one button there: the level shown and its count,
  // opening the same three links as a menu. Wider, neither the count nor the fold shows and the dial stays as it is.
  const phoneQuery = globalThis.matchMedia?.('(max-width: 760px)');
  const phone = () => !!phoneQuery?.matches;
  const count = h('span', { class: 'head-count', hidden: true, 'aria-hidden': 'true' });
  const foldWords = h('span');
  const foldCount = h('small');
  const dialFold = h('button', { class: 'dial-fold', type: 'button', 'aria-haspopup': 'true', 'aria-expanded': 'false', onclick: () => foldDial(!dialOpen) },
    foldWords, foldCount, icon('chevron', 12));
  let dialOpen = false;
  function foldDial(open) {
    dialOpen = open;
    setClass(dial, 'open', open);
    dialFold.setAttribute('aria-expanded', String(open));
  }
  // A link chosen, Esc, or a touch outside it closes it.
  dial.addEventListener('click', (event) => { if (dialOpen && event.target.closest?.('a')) foldDial(false); });
  dial.addEventListener('keydown', (event) => { if (dialOpen && event.key === 'Escape') { event.stopPropagation(); foldDial(false); dialFold.focus(); } });
  globalThis.document?.addEventListener?.('click', (event) => { if (dialOpen && !dial.contains(event.target) && !dialFold.contains(event.target)) foldDial(false); });
  const menuButton = kit.iconButton({ class: 'phone-only', 'aria-label': t('menu'), onclick: () => app.drawer('left') }, icon('menu', 16));
  const teamButton = kit.iconButton({ class: 'phone-only team-button', 'aria-label': t('showTeam'), onclick: () => app.drawer('right') }, icon('team', 16));
  const head = h('header', { class: 'centre-head' }, menuButton, h('div', { class: 'head-words' }, big, name), count, switcher, h('span', { class: 'grow' }), dialFold, dial, teamButton);
  const strip = h('div', { class: 'team-strip' });
  // On a phone the team strip is one line, whole counts only, that opens to all of them at a touch.
  const stripFold = h('button', { class: 'strip-fold', type: 'button', 'aria-expanded': 'false', 'aria-label': t('stripAll') }, icon('chevron', 12));
  let stripOpen = false;
  strip.addEventListener('click', () => {
    if (!phone() || stripFold.hidden) return;
    stripOpen = !stripOpen;
    setClass(strip, 'open', stripOpen);
    stripFold.setAttribute('aria-expanded', String(stripOpen));
  });
  const col = h('div', { class: 'col' });
  const talk = h('div', { class: 'talk' }, col);
  // What waits on the user, at the bottom above the message box: never more than about 60% of the centre's height
  // (it scrolls inside itself beyond that), so the conversation stays in sight above it. At "What waits on me"
  // (`show=asks`, the class `show-asks`) there is no conversation: it takes the centre, the one thing that scrolls.
  const waitBox = h('section', { class: 'wait-box', hidden: true, 'aria-label': t('cQuestionsForYou') });
  const toWho = h('span', { class: 'to' });
  // The one message box (views/composer.js), as a session's: Enter sends to the lead at its next step (`tell`, as the
  // lead's mail), ⌘↩ / Ctrl+↩ now and ⌥↩ after this turn where its agent takes them; Shift+Enter a new line. With the
  // `act` right the arrow beside Send opens every way the lead's agent takes a message (js/sendways.js): the others
  // `send` to the lead's session with `when`. Where the page doesn't act, Enter drafts the note and its line.
  const sender = sendMenu({ className: 'lead-send', send: (way) => note({ way }), main: false });
  const box = messageBox({
    className: 'composer lead-box', label: t('messageLead'), placeholder: t('messageLead'), maxLength: 4000, menu: sender.el,
    onSend: (way) => note({ way: way === 'send' ? 'step' : way }),
  });
  const input = box.input;
  const composer = h('div', { class: 'composer-lead' }, box.notice, toWho, box.el);
  // While an answer is being changed here: its line's key, and what the node said if it refused.
  const changing = new Map();
  // A project whose lead isn't running: how to start it again, plainly (the line, and New project's lead form).
  const quietWords = h('p', { class: 'quiet-words' });
  const quietLines = h('div', { class: 'quiet-lines' });
  const quietForm = h('a', { class: 'link', href: '#/new' }, t('quietForm'));
  const quiet = h('section', { class: 'quiet-block', hidden: true, 'aria-label': t('quietProject') },
    h('h2', { class: 'quiet-title' }, t('quietProject')), quietWords, quietLines, h('p', { class: 'confirm-note' }, t('quietNote'), ' ', quietForm));
  let quietDrawn = '';
  const gone = kit.empty({ size: 'page', class: 'empty-state', hidden: true }, h('h2', null, t('goneProject')), h('p', null, t('goneProjectSub')), kit.button('plain', { tag: 'a', href: '#/' }, t('seStartPage')));
  // The conversation and what waits on the user: two panes wide (the waiting block under the conversation, scrolling
  // in itself), one scroll on a phone (what waits first, the conversation under it): style.css's `.centre-scroll`.
  const scroller = h('div', { class: 'centre-scroll' }, talk, waitBox);
  const scrollBox = () => (phone() ? scroller : talk);
  const el = h('section', { class: 'centre project-view', 'aria-label': t('lead') }, head, strip, quiet, scroller, composer, gone);
  // The project's name beside "N things need you" shrinks to an ellipsis; squeezed to a mark, it goes (the right
  // column's head names the project).
  const fitName = () => {
    name.classList.remove('squeezed');
    if (name.textContent && name.clientWidth < 56 && name.scrollWidth > name.clientWidth) name.classList.add('squeezed');
  };
  if (typeof ResizeObserver === 'function') new ResizeObserver(fitName).observe(head);
  // The strip's fold only where a count is past its first line (or it is open): measured while the strip has a
  // layout (not while the keyboard hides it, nor before the view is placed), and again as its width changes.
  function fitStrip() {
    if (stripOpen) { stripFold.hidden = false; return; }
    if (!phone()) { stripFold.hidden = true; return; }
    if (!strip.clientHeight) return;
    stripFold.hidden = !(strip.scrollHeight > strip.clientHeight + 1);
  }
  if (typeof ResizeObserver === 'function') new ResizeObserver(() => fitStrip()).observe(strip);

  // The waiting block's cards, one stack a project (it keeps what was typed in a card across updates).
  const stacks = new Map();
  const stackOf = (project) => {
    if (!stacks.has(project)) stacks.set(project, questionStack(app, project, { onChange: () => { drawn = ''; render(); }, others: () => othersOf(project) }));
    return stacks.get(project);
  };
  // The project's other cards (held config, a base move, a plugin's request) for the stack to place by priority: each
  // drawn again only when it or what the page may do changed, so a button's refusal under it stays.
  const others = new Map();
  const othersOf = (project) => {
    const cards = waitingCards(store.state.cards.values(), project).filter((card) => !['question', 'approval'].includes(card.kind));
    for (const id of others.keys()) if (!cards.some((card) => card.id === id)) others.delete(id);
    return cards.map((card) => {
      const shape = JSON.stringify([card, store.acts(), lang()]);
      if (others.get(card.id)?.shape !== shape) others.set(card.id, { shape, el: otherCard(card) });
      return { key: card.id, at: card.at, priority: card.kind === 'plugin' ? pluginFacts(card).severity : 'blocking', el: others.get(card.id).el };
    });
  };
  // Notes drafted for a lead, this page's only: the line that tells it from a terminal.
  const notes = new Map();
  let drawn = '';
  let lastProject = null;
  let lastLevel = null;
  let sheetShown = null;
  let waitShown = false;
  let lastWaiting = 0;

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
      ? kit.button('quiet', { size: 's', class: 'take-back', onclick: () => takeBack(entry) }, t('swTakeBack')) : null;
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
    const text = box.value.trim();
    const lead = store.state.leads.get(route.id);
    if (!text || !lead?.root) return;
    const sends = way !== 'step' && sendsTo(lead) && waysNow().includes(way);
    const chosen = sends ? way : 'step';
    const action = crypto.randomUUID();
    const entry = { text, way: chosen, action, state: actsFor(app, 'tell') || sends ? 'sending' : 'draft', why: '' };
    notes.set(route.id, [...(notes.get(route.id) || []), entry]);
    box.clear();
    if (entry.state === 'sending') {
      const asked = sends ? store.request('send', sendArgs(store.state.sessions.get(lead.session), text, chosen), action) : store.request('tell', { folder: lead.root, text }, action);
      asked.then((reply) => {
        entry.state = reply.ok ? 'sent' : 'refused';
        entry.why = reply.ok ? '' : refusalWords(reply.error);
        // What became of it, in the node's words where it gives them.
        entry.result = reply.ok ? reply.result || {} : null;
        entry.said = reply.ok ? reply.result?.said || null : null;
        // Refused: why, beside the box, with Try again; the words back in it.
        if (!reply.ok) box.refused(t('cmRefused', { why: entry.why }), text, () => note({ way: chosen }));
        drawn = '';
        render();
      });
    }
    drawn = '';
    render();
    const scrolling = scrollBox();
    scrolling.scrollTop = scrolling.scrollHeight;
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
        kit.button('quiet', { size: 's', onclick: () => { changing.set(line.key, ''); drawn = ''; render(); } }, t('swChange')))];
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
    const own = kit.field({ class: 'answer-input', type: 'text', placeholder: t('cOwnWords'), 'aria-label': t('yourAnswer'), autocomplete: 'off', maxlength: 4000 });
    return [h('div', { class: 'answer-change' },
      h('p', { class: 'answer-state' }, t('swChangeTo')),
      options.length ? h('div', { class: 'options' }, options.map((option) => h('button', { class: 'option', type: 'button', onclick: () => replace(option) }, h('span', { class: 'option-text' }, option)))) : null,
      h('form', { class: 'answer', onsubmit: (event) => { event.preventDefault(); replace(own.value); } }, own, kit.button('primary', { type: 'submit' }, t('cAnswer')),
        kit.button('plain', { onclick: () => { changing.delete(line.key); drawn = ''; render(); } }, t('swKeep'))),
      why ? h('p', { class: 'card-notice', role: 'alert' }, why) : null)];
  }

  function lineEl(line, route) {
    // A push settled from this page: what came of it, one quiet line (the lead hears it from the node).
    if (line.kind === 'push') return [h('p', { class: `line kind-push ${line.outcome}` }, icon(line.outcome === 'declined' ? 'close' : 'check', 13), h('span', { class: 'line-text' }, line.head), h('time', null, clock(line.at)))];
    const answered = line.kind === 'ask';
    const button = h('a', { class: `line kind-${line.kind}${answered ? ' answered' : ''}`, href: routeHref(route, { sheet: line.key }) },
      lineMark(line.kind), h('span', { class: 'line-text' }, cut(shortHashes(line.head), 140)), h('time', null, clock(line.at)));
    // A question the lead withdrew: nobody answers it now, and the line under it says so, with the lead's reason.
    if (answered && line.state === 'withdrawn') return [button, h('p', { class: 'withdrawn-note' }, t('withdrawn') + (line.why ? `: ${cut(shortHashes(line.why), 160)}` : ''))];
    if (!answered || !line.answer) return [button];
    // An approval's answer as its button said it (Approve merging 4e1c9a7b into landing-base, Not yet), by its card;
    // with the card gone, an answer that names a whole commit to approve still says it in words.
    const answerCard = (line.card ? store.state.cards.get(line.card) : null)
      || (/^Approve ([0-9a-f]{40}|[0-9a-f]{64})$/i.test(String(line.answer || '').trim()) ? { kind: 'approval' } : null);
    const answer = optionWords(answerCard, line.answer);
    const said = line.state === 'autoDecided' ? t('wentAhead', { x: cut(answer, 60) }) : cut(shortHashes(answer), 140);
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
        // A held folder's files as the node sends them ({ path, change }; a name alone from an older one).
        items.map((item) => fact(item.name, [item.change || '', item.files?.length ? h('ul', { class: 'files' }, item.files.map((file) => h('li', null, h('code', null, typeof file === 'string' ? file : file?.path || ''),
          typeof file === 'object' && file?.change ? ` · ${t({ added: 'shAdded', changed: 'shChanged', removed: 'shRemoved' }[file.change] || 'shChanged')}` : ''))) : null])),
        rails.map((rail) => fact(rail.key, h('code', null, rail.value), rail.sinceAccept ? ` (${sinceWord(rail.sinceAccept)})` : ''))));
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

  // Show it whole: the node asked for the card as it is now (`config.held` or `base.show`, the project's folder), and the
  // side sheet opens with it whole; Reading… meanwhile, the node's refusal beside the button.
  function showWhole(card) {
    const config = card.kind === 'config';
    const kind = config ? 'config.held' : 'base.show';
    const said = h('span', { class: 'act-said', role: 'status' });
    const button = kit.button('plain', { onclick: () => {
      button.disabled = true;
      button.setAttribute('aria-busy', 'true');
      button.textContent = t('shReading');
      said.classList.remove('refused');
      setText(said, '');
      store.read(kind, { folder: card.root }).then((reply) => {
        button.disabled = false;
        button.removeAttribute('aria-busy');
        button.textContent = t('shShowWhole');
        const result = reply?.ok ? reply.result : null;
        if (result?.card) { sheet.open(heldParts(result.card, { root: card.root, kicker: lastPart(card.root), read: store.read, kind })); return; }
        // The base hasn't moved since (`unmoved`), or an answer without its card: said, nothing opened.
        setText(said, result?.unmoved ? t('shUnmoved', { branch: result.branch || '' }) : refusalWords(reply?.error, t('shShowWhole')));
        if (!result?.unmoved) said.classList.add('refused');
      });
    } }, t('shShowWhole'));
    return h('div', { class: 'card-acts show-whole' }, h('span', { class: 'act' }, button, said));
  }

  function otherCard(card) {
    if (card.kind === 'plugin') return pluginCard(card, app);
    const root = card.root || '';
    const config = card.kind === 'config';
    // With the `act` right: accept the held config, or accept or keep the base, from here (the card and its seen).
    const acts = config ? actsFor(app, 'config.accept') : actsFor(app, 'base.accept');
    const whole = actsFor(app, config ? 'config.held' : 'base.show');
    return h('article', { class: 'card' },
      h('header', { class: 'card-head' }, h('span', { class: 'priority blocking' }, t('blocking')), h('time', { class: 'asked' }, t('askedAt', { who: t('vibeswitcher'), time: clock(card.at) }))),
      h('h3', { class: 'card-question' }, t(config ? 'heldConfig' : 'baseMove')),
      h('p', { class: 'card-why' }, t(config ? 'heldConfigWhy' : 'baseMoveWhy')),
      heldFacts(card),
      // To see it whole first: Show it whole where the node lists the read (`config.held`, `base.show`), in the side
      // sheet; else the terminal's line beside the buttons when this tab acts, or one click away, never the pile of them.
      whole ? showWhole(card) : null,
      acts ? h('div', { class: 'card-acts' },
        doButton(app, { label: t(config ? 'acAccept' : 'acAcceptMove'), kind: config ? 'config.accept' : 'base.accept', args: () => cardArgs(card) }).el,
        !config && actsFor(app, 'base.keep') ? doButton(app, { label: t('acKeepBase'), kind: 'base.keep', plain: true, args: () => cardArgs(card) }).el : null) : null,
      acts && whole ? null
      : acts ? h('div', { class: 'card-command' }, h('span', { class: 'card-command-label' }, t('acSeeFirst')),
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
    setText(foldWords, t({ asks: 'dialAsks', decisions: 'dialDecisionsShort', all: 'dialAll' }[route.show] || 'dialDecisionsShort'));
    setText(foldCount, String(counts[route.show] ?? ''));
    dialFold.setAttribute('aria-label', `${t('dialLabel')}: ${t({ asks: 'dialAsks', decisions: 'dialDecisions', all: 'dialAll' }[route.show] || 'dialDecisions')}`);
    const stack = stackOf(route.id);
    stack.update();
    const extra = cards.filter((card) => !['question', 'approval'].includes(card.kind));
    const mine = notes.get(route.id) || [];
    const pushes = stack.receipts();
    const key = JSON.stringify([route.id, route.show, lines.map((line) => [line.key, line.answer, line.state, line.delivered, line.replaceable]), extra.map((card) => [card.id, card.seen]), mine, waiting, lang(), store.acts(),
      lead?.told || null, [...changing], pushes, stack.el.hidden]);
    if (key === drawn) return;
    const box = scrollBox();
    const atEnd = box.scrollHeight - box.scrollTop - box.clientHeight < 40;
    drawn = key;
    const asks = route.show === 'asks';
    setClass(el, 'show-asks', asks);
    const shown = withPushLines(shownLines(lines, route.show), asks ? [] : pushes, pushReceipt);
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
    if (!shown.length && !asks) children.push(kit.empty({ tag: 'p', size: 'page', class: 'empty-line' }, t('emptyTalk')));
    const waits = [];
    if (asks && !waiting) waits.push(kit.empty({ tag: 'p', size: 'page', class: 'empty-line' }, t('emptyAsks')));
    if (waiting) {
      const push = lead?.push ? 1 : 0;
      waits.push(h('h2', { class: 'asked-title' }, push && waiting === 1 ? t('pushWaits') : t('questionsForYou', { n: waiting - push }) + (push ? t('andAPush') : '')));
    }
    waits.push(stack.el);
    const inner = h('div', { class: 'wait-col' }, waits);
    waitBox.replaceChildren(inner);
    waitShown = asks || !!waiting || !stack.el.hidden;
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
    // Opened on a phone with something waiting: its top, where the waiting comes first; else the conversation's end.
    // The last thing waiting answered there: the conversation's end, the lead's latest words, not its oldest lines.
    const top = changedView && phone() && waitShown && !asks;
    const settled = !changedView && phone() && !asks && lastWaiting > 0 && !waiting;
    lastWaiting = waiting;
    if (changedView || atEnd || settled) requestAnimationFrame(() => { box.scrollTop = top ? 0 : box.scrollHeight; });
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
    scroller.scrollTop = 0;
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
    if (!team.motion.length && !team.blocked.length && !team.queued.length) children.push(kit.empty({ tag: 'p', size: 'page', class: 'empty-line' }, t('roadNothing')));
    col.replaceChildren(...children);
    setClass(col, 'dated', !!axis);
    talk.scrollTop = 0;
    scroller.scrollTop = 0;
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
    setText(big, waiting ? t('thingsHereNeedYou', { n: waiting }) : t('nothingHereNeedsYou'));
    setClass(big, 'asked', waiting > 0);
    setText(count, String(waiting));
    count.hidden = !waiting;
    setText(name, lastPart(root));
    fitName();
    name.title = tilde(root, state.node?.home);
    leadLink.setAttribute('href', projectHref(route.id));
    roadLink.setAttribute('href', projectHref(route.id, { view: 'roadmap' }));
    if (route.view === 'roadmap') { roadLink.setAttribute('aria-current', 'page'); leadLink.removeAttribute('aria-current'); } else { leadLink.setAttribute('aria-current', 'page'); roadLink.removeAttribute('aria-current'); }
    dial.hidden = route.view !== 'lead';
    dialFold.hidden = dial.hidden;
    if (dial.hidden && dialOpen) foldDial(false);
    composer.hidden = route.view !== 'lead';
    waitBox.hidden = route.view !== 'lead' || !waitShown;
    strip.replaceChildren(h('b', null, t('team')), ...stripCounts(board), stripFold);
    // Its fold only where a count is past the first line (or it is open).
    fitStrip();
    const live = !!lead?.session && state.sessions.has(lead.session);
    setText(toWho, lead?.root ? t('toLead', { p: lastPart(root) }) : t('noLeadToTell'));
    // On a phone the header names the project: the line over the box shows only when there is no lead to tell.
    setClass(toWho, 'no-lead', !lead?.root);
    input.disabled = !lead?.root;
    // What was typed for this lead and not sent comes back with it.
    box.setKey('lead:' + route.id);
    const tells = actsFor(app, 'tell') || sendsTo(lead);
    box.setMode({ word: tells ? t('swSend') : t('cmDraft'), title: tells ? t('cmLeadSendTitle') : t('cmLeadDraftTitle'), way: 'step', disabled: !lead?.root });
    // The buttons only where the page sends: next step with `tell`; now with `send` to a live lead session.
    sender.el.hidden = !lead?.root || (!actsFor(app, 'tell') && !sendsTo(lead));
    sender.update(waysNow());
    setClass(el, 'quiet', !live);
    quiet.hidden = live || route.view !== 'lead' || !root;
    const quietKey = JSON.stringify([root, live, lang(), store.acts(), store.can('lead'), baseMoveOf(app, root)?.id ?? null]);
    if (!quiet.hidden && quietKey !== quietDrawn) {
      quietDrawn = quietKey;
      setText(quietWords, t('quietWords'));
      // With the `act` right, the two starts are buttons (`lead`, back in its conversation or fresh), and where its base
      // moved, Take the base as it is with what it does (views/drive.js); the lines where the page doesn't start it.
      const acts = actsFor(app, 'lead');
      quietLines.replaceChildren(...(acts ? [h('div', { class: 'card-acts quiet-starts' },
        ...leadStartOrLine(app, { folder: root, extra: () => ({ resume: true }), label: t('acResumeLead') }),
        ...leadStartOrLine(app, { folder: root, label: t('acFreshLead'), plain: true, baseChoice: false }))]
        : [copyLine(`${leadLine(root)} --resume`, 'the command that starts its lead again in its conversation'),
          copyLine(leadLine(root), 'the command that starts a new lead there')]));
      quietForm.onclick = (event) => { event.preventDefault(); app.startLead?.(root); };
    }
    if (route.view === 'roadmap') { lastProject = null; setClass(el, 'show-asks', false); drawRoadmap(route, board); } else drawLead(route, board, lead);
    drawSheet(route, board);
  }

  const schedule = framed(render);
  for (const topic of ['boards', 'leads', 'cards', 'sessions', 'connection', 'node']) store.subscribe(topic, schedule);
  return { el, render };
}
