// What the user answers: a lead's question, a merge to approve, and an agent's own prompt in its chat. The wording is
// the Mac's question card (LeadViews.swift). An answer shows at once and is taken back, saying why, if the node
// refuses it (the design's "Actions").
//
// On the node's page no click is the user's voice (the plan's LW-D6): a pick leaves a draft on the card, shown at
// once, and the card shows the one line that confirms it in a terminal, `vibeswitcher answer <card>`, a click to copy.
// The card closes when the node's delta says it was answered.
//
// Keys, with the focus anywhere in a card: 1–9 answer with that option, ↑ ↓ move, ↩ answers with the focused one,
// H holds the timer. ↑ from an empty message box steps into the last card.

import * as kit from '../kit.js';
import { h, setText, setClass } from '../dom.js';
import { icon } from '../marks.js';
import { since, until, clock } from '../words.js';
import { pushLines } from '../push.js';
import { talkButton } from '../dictate.js';
import { pluginFacts } from '../plugincard.js';
import { t, lang } from '../i18n.js';
import { actsFor, refusalWords, doButton, answerArgs } from '../acting.js';
import { questionHead, shortHashes, lineKey, contextOf } from '../conversation.js';
import { routeHref } from '../ui.js';
import { composer as messageBox } from './composer.js';

// A card's answer box: the one message box (views/composer.js) with the card's own button: Enter answers, Shift+Enter
// a new line, an input method's Enter never; what was typed kept across the card's redraws by its caller.
function answerBox({ value, placeholder, button, onSend, onInput, maxLength = null }) {
  const box = messageBox({ className: 'answer', field: 'answer-input', label: t('yourAnswer'), placeholder, maxLength, button, onSend, onInput, storage: null });
  box.input.value = value;
  box.grow();
  const talk = talkButton(box.input);
  if (talk) box.el.insertBefore(talk, button);
  return box;
}

const PRIORITY = { blocking: t('cBlocking'), important: t('cImportant'), whenever: t('cWhenever') };

// An option as its button says it. An approval's names its whole commit (the node checks the answer against it,
// `LeadWorkflow.approval(of:)`): the button says what it approves in words with the commit's first 8 characters; the
// whole option, which is what is sent, on hover, and the whole commit in the Commit row above. Anything else as it is.
export function optionWords(card, option) {
  const text = String(option ?? '');
  if (card?.kind !== 'approval') return text;
  const approve = /^Approve ([0-9a-f]{40}|[0-9a-f]{64})$/i.exec(text.trim());
  if (approve) return t(card.approval?.base ? 'ccApproveInto' : 'ccApprove', { short: approve[1].slice(0, 8), base: card.approval?.base || '' });
  return text.trim() === 'Not yet' ? t('ccNotYet') : text;
}

// The options as buttons, the proposed one marked, and the keys that work across them. `words`: what a button says
// for its option (the option itself is what `choose` gets).
function optionList(options, { proposed = null, numbered = false, choose, words = (option) => option }) {
  const buttons = options.map((option, index) => h('button', { class: 'option', type: 'button', title: words(option) !== option ? option : null, onclick: () => choose(option) },
    numbered ? h('span', { class: 'option-key', 'aria-hidden': 'true' }, String(index + 1)) : null,
    h('span', { class: 'option-text' }, words(option)),
    option === proposed ? h('span', { class: 'option-note' }, t('cProposed')) : null));
  buttons.forEach((button, index) => { if (options[index] === proposed) button.classList.add('proposed'); });
  return { el: h('div', { class: 'options' }, buttons), buttons, values: options };
}

// The keys every card shares, attached once; `now()` gives the card's buttons and actions as it's drawn at the
// moment (`hold` is null where there's no timer).
function cardKeys(el, now) {
  el.addEventListener('keydown', (event) => {
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    const { buttons, values = [], choose, hold } = now();
    const stops = [...el.querySelectorAll('.option, .answer-input')].filter((node) => !node.disabled);
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      const to = stops[stops.indexOf(document.activeElement) + (event.key === 'ArrowDown' ? 1 : -1)];
      if (to) { to.focus(); event.preventDefault(); }
      return;
    }
    if (event.target.matches('input, textarea')) return;
    if (/^[1-9]$/.test(event.key) && buttons[Number(event.key) - 1]) {
      event.preventDefault();
      choose(values[Number(event.key) - 1] ?? buttons[Number(event.key) - 1].querySelector('.option-text').textContent);
    } else if ((event.key === 'h' || event.key === 'H') && hold) {
      event.preventDefault();
      hold();
    }
  });
}

// The card as the command line names it: the first 8 characters of its UUID (`vibeswitcher answer` takes any prefix
// of 4 or more that only one card has; `vibeswitcher questions` lists them).
export const cardShort = (id) => id.replace(/^.*:card:/, '').slice(0, 8);

// An option as an example on the command line, only when it needs no shell quoting beyond the double quotes around
// it: a lead's words never become a command that does something else when pasted.
const sample = (option) => (option && /^[^"$`\\!\n]*$/.test(option) ? option : 'your answer');

// The line a terminal confirms the draft with, and a button that copies it: one click, then "Copied" for a moment.
// Where the clipboard is refused, the line is selected instead, for the keyboard's copy.
export function copyLine(text, label) {
  const code = h('code', { class: 'copy-text' }, text);
  const word = h('span', { class: 'copy-word' }, t('cCopy'));
  let timer = null;
  const said = (what, done) => {
    word.textContent = what;
    button.classList.toggle('done', done);
    clearTimeout(timer);
    timer = setTimeout(() => { word.textContent = t('cCopy'); button.classList.remove('done'); }, 1600);
  };
  const select = () => getSelection()?.selectAllChildren(code);
  const button = h('button', { class: 'copy-button', type: 'button', title: `${t('cCopy')}: ${text}`, 'aria-label': `${t('cCopy')} ${label}`, onclick: () => {
    const done = () => said(t('cCopied'), true);
    const refused = () => { select(); said(KEY_COPY, false); };
    if (navigator.clipboard?.writeText) navigator.clipboard.writeText(text).then(done, refused); else refused();
  } }, icon('copy', 13), word);
  return h('div', { class: 'copy-line' }, h('span', { class: 'copy-prompt', 'aria-hidden': 'true' }, '$'), code, button);
}

const KEY_COPY = /Mac|iPhone|iPad/.test(globalThis.navigator?.platform || '') ? '⌘C' : 'Ctrl+C';

// What a page that drafts shows under the question once a draft is on the card: the answer as it will be sent, the
// line that sends it, and a way to take it back. `sending` while the node hasn't acked it yet.
function confirmBox(card, drafted, clear) {
  const short = cardShort(card.id);
  return h('div', { class: 'confirm' + (drafted.sending ? ' sending' : ''), role: 'group', 'aria-label': t('cConfirmLabel') },
    h('div', { class: 'confirm-head' },
      h('span', { class: 'confirm-label' }, drafted.sending ? t('cSaving') : t('yourAnswer')),
      kit.button('quiet', { size: 's', title: t('cTakeOff'), onclick: clear }, t('clear'))),
    h('p', { class: 'confirm-text' }, drafted.text),
    copyLine(`vibeswitcher answer ${short}`, 'the command that sends it'),
    h('p', { class: 'confirm-note' }, t('cConfirmNote')));
}

// A page that may only read (`answer` isn't in what this connection may send: no browser action is the user's voice
// yet): the options as text, and the line that answers it in a terminal, where the user's own hands type its code.
function readOnlyAnswer(card, counting) {
  const short = cardShort(card.id);
  const options = card.question.options;
  return [
    options.length ? h('ol', { class: 'options read-only' }, options.map((option) => h('li', { class: 'option' },
      h('span', { class: 'option-text' }, option), option === card.question.proposal ? h('span', { class: 'option-note' }, t('cProposed')) : null))) : null,
    h('div', { class: 'card-command' },
      h('span', { class: 'card-command-label' }, t('cAnswerInTerminal')),
      // The node's own line for it (`settle`), as is; else the answer line with the first option.
      h('code', null, card.settle || `vibeswitcher answer ${short} "${sample(options[0])}"`),
      counting ? h('code', null, `vibeswitcher hold ${short}`) : null),
  ];
}

// What git and the vault say about a merge, apart from anything the lead wrote (the design's security rule 2: the
// person approves facts, not prose). Nothing here is shortened: these fields are what an approval covers.
export function approvalFacts(approval) {
  const fact = (name, ...value) => [h('dt', null, name), h('dd', null, value)];
  return h('div', { class: 'facts' },
    h('div', { class: 'facts-head' }, t('cFacts')),
    h('dl', null,
      fact(t('cCommit'), h('code', null, approval.commit)),
      fact(t('cSubject'), approval.subject || t('ccNoSubject')),
      fact(t('cInto'), approval.base || 'the base'),
      fact(t('cChanges'), approval.diffstat, h('ul', { class: 'files' }, approval.files.map((file) => h('li', null, h('code', null, file))))),
      Object.entries(approval.verdicts || {}).map(([task, verdict]) => fact(t('cVerdict'), `${task}: ${verdict}`)),
      approval.sensitive ? fact(t('cSensitive'), approval.sensitive.length ? approval.sensitive.join(', ') : 'none touched') : fact(t('cSensitive'), 'couldn’t be checked'),
      (approval.problems || []).map((problem) => fact(t('cNote'), problem))));
}

// The approval's key rows on the card (commit, base, how much changes, the verdicts, whether it touches a sensitive
// path, the problems), with the files and the sensitive paths one click away in place: every fact stays on the card.
function keyFacts(approval) {
  const fact = (name, ...value) => [h('dt', null, name), h('dd', null, value)];
  const sensitive = approval.sensitive;
  const files = approval.files || [];
  return h('div', { class: 'facts key-facts' },
    h('dl', null,
      fact(t('cCommit'), h('code', null, approval.commit)),
      fact(t('cInto'), approval.base || 'the base'),
      fact(t('cChanges'), approval.diffstat || t('ccFiles', { n: files.length })),
      Object.entries(approval.verdicts || {}).map(([task, verdict]) => fact(t('cVerdict'), `${task}: ${verdict}`)),
      // The sensitive paths themselves (what the user approves on), five at most and how many more.
      fact(t('cSensitive'), !sensitive ? t('ccSensitiveUnknown') : sensitive.length ? h('span', { class: 'sensitive-yes' },
        sensitive.slice(0, 5).flatMap((path, index) => [index ? ', ' : null, h('code', null, path)]).filter(Boolean), sensitive.length > 5 ? ` +${sensitive.length - 5}` : null) : t('ccSensitiveNone')),
      (approval.problems || []).map((problem) => fact(t('cNote'), problem))),
    files.length ? h('details', { class: 'facts-files' }, h('summary', null, t('ccTheFiles', { n: files.length })),
      h('ul', { class: 'files' }, files.map((file) => h('li', { class: sensitive?.includes(file) ? 'sensitive' : null }, h('code', null, file), sensitive?.includes(file) ? h('small', null, ' ' + t('ccSensitiveMark')) : null)))) : null);
}

// A card the node withheld from the page whole, too large for a snapshot's part (`tooLarge`): what it asks is never cut,
// so it is read whole in a terminal. Its place and title only; nothing of what it asks.
export function tooLargeCard(card) {
  const command = card.tooLarge?.command || 'vibeswitcher questions';
  return h('article', { class: 'card too-large' + (card.open ? '' : ' closed') },
    h('header', { class: 'card-head' }, h('span', { class: 'priority important' }, card.plugin?.title || (card.kind === 'approval' ? t('cMergeToApprove') : t('cAQuestion')))),
    h('p', { class: 'card-notice' }, t('cTooLarge'), h('code', null, command), '.'),
    copyLine(command, 'the command that shows it whole'));
}

// How long a Blocking card's answer waits to be taken back before it goes.
export const UNDO_MS = 5000;

// A lead's question or approval. Returns { el, update(card) }; `el` keeps its text field and its focus across updates.
export function questionCard(app, first, { expand = null } = {}) {
  const el = h('article', { class: 'card', tabindex: -1 });
  let card = first;
  // One of several open questions, not the one shown whole: its question line only, which opens it.
  let collapsed = false;
  let shape = '';
  let input = null;
  let keys = { buttons: [], hold: null };

  // With the `act` right the click is the answer: the card, the `seen` it was drawn with, the words and the version.
  // What was clicked on: the version and `seen` the card had then, so a question reworded since is refused as changed.
  const drawnAs = () => ({ ...(card.question?.version != null ? { version: card.question.version } : {}), seen: card.seen ?? null });
  const send = (text, drawn = drawnAs()) => app.store.act(card.id, 'answer', { text, ...drawn });
  // A Blocking card's answer waits a few seconds first, "Sending … · Undo" on the card, so a slip of one click can be
  // taken back; then it goes as it would have. `app.later(fn, ms)` (the tests' clock) returns what cancels it.
  let sending = null;
  const later = app.later || ((fn, ms) => { const timer = setTimeout(fn, ms); return () => clearTimeout(timer); });
  const choose = (answer) => {
    const text = answer.trim();
    if (!text || sending) return;
    if (card.question?.priority !== 'blocking') { send(text); return; }
    sending = { text, drawn: drawnAs(), cancel: later(() => { const going = sending; sending = null; shape = ''; send(going.text, going.drawn); build(); }, UNDO_MS) };
    shape = '';
    build();
  };
  const undo = () => { sending?.cancel(); sending = null; shape = ''; build(); el.focus?.(); };
  const hold = () => app.store.act(card.id, 'hold', { seen: card.seen ?? null });

  function closedLine(mark, ...text) {
    // What it asked, as its line (the sentence that asks, no markdown marks), never its whole text.
    return h('div', { class: 'card-closed' }, mark, h('div', null, h('p', null, text), h('p', { class: 'card-about' }, shortHashes(questionHead(card.question.text)))));
  }

  function build() {
    if (card.tooLarge) {
      el.replaceChildren(...tooLargeCard(card).childNodes);
      el.className = 'card too-large' + (card.open ? '' : ' closed');
      keys = { buttons: [], hold: null };
      return;
    }
    const question = card.question;
    const acting = app.store.state.acting.get(card.id) || {};
    const pendingAnswer = acting.kind === 'answer' ? (acting.text ?? acting.answer) : null;
    el.replaceChildren();
    el.className = 'card';

    // Answered elsewhere, or the question changed, while one waited to go: it doesn't go, and the card shows again.
    if (sending && (!card.open || JSON.stringify(drawnAs()) !== JSON.stringify(sending.drawn))) { sending.cancel(); sending = null; }
    if (sending) {
      el.classList.add('closed', 'sending');
      el.append(h('div', { class: 'card-closed', role: 'status' }, icon('send', 13), h('div', null,
        h('p', null, t('cSending', { x: optionWords(card, sending.text) }), ' · ', kit.button('quiet', { size: 's', class: 'card-undo', onclick: undo }, t('cUndo'))),
        h('p', { class: 'card-about' }, shortHashes(questionHead(question.text))))));
      keys = { buttons: [], hold: null };
      return;
    }
    // Answered (here, a moment ago, or by the node's word), decided by its timer, or withdrawn: one quiet line.
    if (pendingAnswer || !card.open) {
      el.classList.add('closed');
      const state = pendingAnswer ? 'answered' : question.state;
      if (state === 'withdrawn') el.append(closedLine(icon('close', 13), t('cWithdrawn'), question.withdrawReason || 'no reason given'));
      else if (state === 'autoDecided') el.append(closedLine(icon('check', 13), t('cWentAhead'), h('strong', null, question.answer), t('cNoAnswerIn')));
      else el.append(closedLine(icon('check', 13), t('cYouAnswered'), h('strong', null, optionWords(card, pendingAnswer || question.answer || ''))));
      if (card.notice) el.append(h('p', { class: 'card-notice' }, card.notice));
      keys = { buttons: [], hold: null };
      return;
    }

    const held = acting.kind === 'hold' || (!!question.proposal && !question.decideBy);
    const counting = !!question.decideBy && !held;
    const rank = PRIORITY[question.priority] ? question.priority : 'important';
    const priority = h('span', { class: 'priority ' + rank }, PRIORITY[rank]);
    const asked = h('time', { class: 'asked', data: { ago: card.at } }, t('askedAgo', { d: since(card.at) }));
    // Who asks: the lead, and the task its question is about when it says (its title from the board).
    const task = question.task ? app.store.state.boards.get(card.project)?.tasks?.find((one) => one.slug === question.task)?.title || question.task : null;
    const who = h('span', { class: 'card-asker' }, task ? t('askerTask', { task }) : t('askerLead'));
    el.append(h('header', { class: 'card-head' }, priority, who, asked));

    // The question's line (the sentence that asks), a few lines of what follows, the key facts; the whole text in the
    // side sheet, drawn from its markdown.
    const head = shortHashes(questionHead(question.text));
    if (collapsed) {
      el.classList.add('folded');
      el.append(h('button', { class: 'card-question card-unfold', type: 'button', 'aria-expanded': 'false', onclick: () => expand?.(card) }, head));
      keys = { buttons: [], hold: null };
      return;
    }
    el.append(h('h3', { class: 'card-question' }, head));
    const context = contextOf(question.text, questionHead(question.text));
    // An approval's face is its question line and its key facts (the lead's prose is one click away).
    if (context && card.kind !== 'approval') el.append(h('p', { class: 'card-lines' }, context));
    // "Read it all" when there is more than those lines show: a long text, its markdown, or an approval's files.
    if (context.length > 200 || /\n|\*\*|`/.test(question.text || '') || card.kind === 'approval') el.append(h('p', { class: 'card-whole' }, readAll()));
    if (card.kind === 'approval' && card.approval) el.append(keyFacts(card.approval));
    // What the vault says beside the lead's words, on a question the lead's audit asked (which model may audit a task).
    if (Array.isArray(card.facts) && card.facts.length) {
      el.append(h('div', { class: 'facts' }, h('div', { class: 'facts-head' }, t('cVaultFacts')),
        h('ul', null, card.facts.map((fact) => h('li', null, fact)))));
    }
    if (question.whyNow) el.append(h('p', { class: 'card-why' }, question.whyNow));
    if (question.revisionNote) el.append(h('p', { class: 'card-revised' }, `${t('cUpdated')}: ${question.revisionNote}`));

    if (counting) {
      el.append(h('div', { class: 'timer' },
        h('span', { class: 'timer-text' }, t('cGoingWith'), h('strong', null, question.proposal), ' ', h('span', { data: { until: question.decideBy } }, until(question.decideBy))),
        app.store.can('hold') ? kit.button('plain', { title: t('cHoldTitle'), onclick: hold }, icon('pause', 12), t('cHold')) : null));
    } else if (held) {
      el.append(h('p', { class: 'timer held' }, t('cHeld'), h('strong', null, question.proposal), t('ccWaitsAnswer')));
    }

    if (!actsFor(app, 'answer') && app.store.can('draft')) {
      buildDraft(question, counting);
      return;
    }

    if (!actsFor(app, 'answer')) {
      el.append(...readOnlyAnswer(card, counting).filter(Boolean));
      if (card.notice) el.append(h('p', { class: 'card-notice' }, card.notice));
      el.append(h('p', { class: 'card-foot' }, counting
        ? t('cIfNobody', { x: question.proposal, time: clock(question.decideBy) })
        : t('cKeepsWorking')));
      keys = { buttons: [], hold: null };
      return;
    }

    const list = optionList(question.options, { proposed: question.proposal, choose, words: (option) => optionWords(card, option) });
    el.append(list.el);

    const draft = input?.value || '';
    const send = kit.button('primary', { type: 'submit', disabled: !draft.trim(), title: t('cmAnswerTitle') }, t('cAnswer'));
    const box = answerBox({ value: draft, placeholder: question.options.length ? t('cOwnWords') : t('yourAnswer'), button: send,
      onSend: (way, text) => choose(text), onInput: () => { send.disabled = !input.value.trim(); } });
    input = box.input;
    el.append(box.el);

    if (acting.refused) el.append(h('p', { class: 'card-notice', role: 'alert' }, refusalWords({ code: acting.code, message: acting.refused })));
    else if (card.notice) el.append(h('p', { class: 'card-notice' }, card.notice));

    el.append(h('p', { class: 'card-foot' }, counting
      ? t('cPickOrHold', { x: question.proposal, time: clock(question.decideBy) })
      : t('cKeepsWorking')));
    // The keys, as a tooltip on the options.
    list.el.title = t('cKeysAnswers', { n: Math.max(question.options.length, 1) }) + (counting ? t('cKeysHold') : '');
    keys = { buttons: list.buttons, values: list.values, hold: counting ? hold : null };
  }

  // A page that drafts (the node's): the options pick a draft, the box drafts its own words, and the draft shows
  // with the line that sends it from a terminal.
  function buildDraft(question, counting) {
    const drafted = app.store.draftOf(card.id);
    const pick = (answer) => {
      const text = answer.trim();
      if (text && text !== drafted?.text) app.store.draft(card.id, text);
    };
    // An option picked: the box's own words, if any, give way to it.
    const choose = (option) => { if (input) input.value = ''; pick(option); };
    const list = optionList(question.options, { proposed: question.proposal, choose, words: (option) => optionWords(card, option) });
    list.buttons.forEach((button, index) => {
      const chosen = drafted?.text === question.options[index];
      button.setAttribute('aria-pressed', String(chosen));
      if (chosen) { button.classList.add('chosen'); button.append(icon('check', 13)); }
    });
    el.append(list.el);

    const own = drafted && !question.options.includes(drafted.text) ? drafted.text : '';
    const typed = input?.value ?? '';
    // Acting is on for the node but not in this tab (it isn't paired): a pick isn't a draft for a terminal, it's a choice
    // this tab can't send; the banner at the top says how to make it act.
    const level = app.store.state.node?.web?.acts?.level ?? (app.store.state.node?.web?.acts?.on ? 'trust' : 'off');
    const notYet = level !== 'off';
    const start = typed || own;
    const send = kit.button('plain', { type: 'submit', disabled: !start.trim() || start.trim() === drafted?.text }, t(notYet ? 'cChoose' : 'cDraft'));
    const box = answerBox({ value: start, placeholder: question.options.length ? t('cOwnWords') : t('yourAnswer'), button: send, maxLength: 4000,
      onSend: (way, text) => pick(text), onInput: () => { send.disabled = !input.value.trim() || input.value.trim() === app.store.draftOf(card.id)?.text; } });
    input = box.input;
    el.append(box.el);

    const refused = app.store.state.draftRefused.get(card.id);
    if (refused) el.append(h('p', { class: 'card-notice', role: 'alert' }, refused));
    else if (card.notice) el.append(h('p', { class: 'card-notice' }, card.notice));

    // One line once picked; the terminal's way one click away, never the pile of it.
    if (drafted) el.append(h('p', { class: 'card-notsent' }, notYet ? t('cNotSent') : t('cDrafted')));
    if (drafted || counting) {
      el.append(h('details', { class: 'card-terminal' }, h('summary', null, t('cUseTerminal')),
        drafted ? confirmBox(card, drafted, () => app.store.draft(card.id, null)) : null,
        counting ? h('div', { class: 'card-hold' }, h('span', { class: 'card-hold-label' }, t('cToStop')), copyLine(`vibeswitcher hold ${cardShort(card.id)}`, 'the command that holds the timer')) : null,
        counting ? h('p', { class: 'card-foot' }, t('cUntilConfirm', { x: question.proposal, time: clock(question.decideBy) })) : null));
    }
    list.el.title = question.options.length > 1 ? t('cKeysPicks', { n: question.options.length }) : t('cKeysMove');
    keys = { buttons: list.buttons, values: list.values, hold: null };
  }

  // "Read it all": the side sheet with the question's whole text from its markdown (and an approval's facts whole).
  // On a project's screen it is the address's `sheet=`, so back closes it; elsewhere it opens over the screen.
  function readAll() {
    const route = app.ui?.state?.route;
    const key = lineKey('card', app.store.cardKey(card.id));
    if (route?.name === 'project') return h('a', { class: 'link', href: routeHref(route, { sheet: key }) }, t('ccReadAll'));
    return kit.button('quiet', { size: 's', onclick: () => app.sheet?.open(cardSheet(card)) }, t('ccReadAll'));
  }

  // The card is built again only when what it shows changed, so typing into it survives every other delta.
  function update(next, fold = collapsed) {
    card = next;
    collapsed = fold;
    const acting = app.store.state.acting.get(card.id);
    const drafting = [app.store.draftOf(card.id), app.store.state.draftRefused.get(card.id) || null, app.store.can('draft')];
    const now = JSON.stringify([card, acting || null, actsFor(app, 'answer'), drafting, collapsed, app.ui?.state?.route?.id || null]);
    if (now === shape) return;
    const focused = el.contains(document.activeElement);
    // The option that had the focus keeps it (a pick never sends it to the text box, nor opens a phone's keyboard).
    const option = [...el.querySelectorAll('.option')].indexOf(document.activeElement);
    const copy = document.activeElement?.closest?.('.copy-line') ? [...el.querySelectorAll('.copy-button')].indexOf(document.activeElement) : -1;
    shape = now;
    build();
    if (!focused) return;
    const target = option >= 0 ? el.querySelectorAll('.option')[option] : copy >= 0 ? el.querySelectorAll('.copy-button')[copy] : el.querySelector('.answer-input');
    (target || el).focus();
  }

  // With the keys too, a page that drafts drafts.
  const drafts = () => !actsFor(app, 'answer') && app.store.can('draft');
  cardKeys(el, () => ({ ...keys, choose: drafts() ? (answer) => { if (input) input.value = ''; if (answer.trim()) app.store.draft(card.id, answer.trim()); } : choose }));
  update(first);
  return { el, update };
}

// What the side sheet shows of a question card: its line, its whole text (markdown), and an approval's facts whole.
export function cardSheet(card) {
  const question = card.question || {};
  return {
    kicker: card.kind === 'approval' ? t('cMergeToApprove') : t('cAQuestion'), title: shortHashes(questionHead(question.text)), at: card.at, text: question.text || '',
    more: [card.kind === 'approval' && card.approval ? approvalFacts(card.approval) : null, question.whyNow ? h('p', { class: 'card-why' }, question.whyNow) : null].filter(Boolean),
  };
}

// The push the lead asks for, while it's open: what goes where, from git and the vault, and the two lines that settle
// it in a terminal. Nothing on the page pushes unless the node lets it act (`push`): then Push and Decline are buttons,
// `onPush`/`onDecline` (the waiting block's, which waits a few seconds first); `said` is the node's refusal, kept on
// the card; `settle: false` draws it with no buttons (its request is gone).
export function pushCard(lead, app = null, { onPush = null, onDecline = null, said: refusal = null, notice = null, settle = true } = {}) {
  const said = pushLines(lead.push, lead.root);
  const fact = (name, ...value) => [h('dt', null, name), h('dd', null, value)];
  const acts = app && actsFor(app, 'push');
  const button = (label, kind, go, plain) => (go
    ? kit.button(plain ? 'plain' : 'primary', { onclick: go }, label)
    : doButton(app, { label, kind, plain, args: () => ({ folder: lead.root, request: lead.push.id }) }).el);
  return h('article', { class: 'card push-card', 'aria-label': t('cPushAsk') },
    h('header', { class: 'card-head' }, h('span', { class: 'priority important' }, t('cPush')), h('span', { class: 'card-asker' }, t('askerLead')),
      h('time', { class: 'asked', data: { ago: lead.push.askedAt } }, t('askedAgo', { d: since(lead.push.askedAt) }))),
    h('h3', { class: 'card-question' }, t('cPushAsk')),
    h('div', { class: 'facts' },
      h('div', { class: 'facts-head' }, t('cFacts')),
      h('dl', null,
        fact(t('cPush'), said.what),
        fact(t('cTo'), h('code', null, said.url)),
        fact(t('cCommits'), h('ul', { class: 'files' }, said.subjects.map((subject) => h('li', null, h('code', null, subject))),
          said.more ? h('li', null, t('cAndMore', { n: said.more })) : null)))),
    notice ? h('p', { class: 'card-notice' }, notice) : null,
    refusal ? h('p', { class: 'card-notice push-refused', role: 'alert' }, refusal) : null,
    !settle ? null : acts ? h('div', { class: 'card-acts' },
      button(t('acPush'), 'push', onPush, false),
      actsFor(app, 'push.decline') ? button(t('acDecline'), 'push.decline', onDecline, true) : null)
      : h('div', { class: 'card-command' },
        h('span', { class: 'card-command-label' }, t('cSettle')),
        copyLine(said.push, 'the command that pushes it'),
        copyLine(said.decline, 'the command that declines it')),
    settle ? h('p', { class: 'card-foot' }, acts ? t('acPushNote') : t('cPushNote')) : null);
}

// The lead's push in the waiting block, settled the way a Blocking answer is: Push (or Decline) shows "Pushing <short>
// to <target>… · Undo" for UNDO_MS, then sends the same request as ever, the request's id, sha and target taken at the
// click (dropped, nothing sent, if the lead's request changes while it waits). What came of it: a receipt for the
// conversation (`receipts()`, this page's), or the node's refusal on the card with the buttons back. `onChange`: drawn
// again by itself (the wait ran out, the node replied), so whoever holds it may draw too.
export function pushBlock(app, { onChange = () => {} } = {}) {
  const el = h('div', { class: 'stack-cards push-slot' });
  const later = app.later || ((fn, ms) => { const timer = setTimeout(fn, ms); return () => clearTimeout(timer); });
  let lead = null;
  let shape = null;
  // Waiting to go ({ kind, request, root, short, target, cancel }); out (sent, no reply yet); the node's refusal
  // ({ request, words, lead as it was drawn }); the request ids settled here (not drawn again before the node's delta).
  let waiting = null;
  let out = null;
  let refused = null;
  let changed = false;
  const settled = new Set();
  const receipts = [];

  const live = () => (lead?.push && lead.root && !settled.has(lead.push.id) ? lead : null);
  const start = (kind) => {
    const now = live();
    if (waiting || out || !now) return;
    waiting = { kind, request: now.push.id, root: now.root, short: now.push.short || String(now.push.commit || '').slice(0, 8), target: now.push.target, drawn: now,
      cancel: later(go, UNDO_MS) };
    refused = null;
    changed = false;
    draw();
  };
  const undo = () => { waiting?.cancel(); waiting = null; draw(); el.querySelector?.('.push-card .button')?.focus?.(); };
  function go() {
    const going = waiting;
    if (!going) return;
    waiting = null;
    out = going;
    draw();
    onChange();
    app.store.request(going.kind, { folder: going.root, request: going.request }).then((reply) => {
      out = null;
      const result = reply.ok ? reply.result || {} : null;
      // The node's `ok: false` (git refused, nothing pushed) is a refusal too, in its words.
      if (reply.ok && result.ok !== false) {
        settled.add(going.request);
        receipts.push({ id: going.request, at: new Date().toISOString(), outcome: going.kind === 'push' ? (result.settled === 'upToDate' ? 'upToDate' : 'pushed') : 'declined',
          short: going.short, target: result.target || going.target });
      } else {
        refused = { request: going.request, words: reply.ok ? (result.said || t('acRefused')) : refusalWords(reply.error, t(going.kind === 'push' ? 'acPush' : 'acDecline')), lead: going.drawn };
      }
      draw();
      onChange();
    });
  }

  function draw() {
    const now = live();
    // The request changed (a newer one, or settled elsewhere) while one waited to go: it doesn't go.
    if (waiting && (now?.push.id !== waiting.request || now?.root !== waiting.root)) { waiting.cancel(); waiting = null; changed = !!now; }
    if (refused && now && now.push.id !== refused.request) refused = null;
    const next = JSON.stringify([now?.push || null, now?.root || null, waiting && [waiting.kind, waiting.request], out && [out.kind, out.request], refused, changed, app.store.acts(), lang()]);
    if (next === shape) return;
    shape = next;
    const going = waiting || out;
    if (going) {
      const words = t(going.kind === 'push' ? 'puPushing' : 'puDeclining', { short: going.short, target: going.target });
      el.replaceChildren(h('article', { class: 'card push-card closed sending', 'aria-label': t('cPushAsk') }, h('div', { class: 'card-closed', role: 'status' }, icon('send', 13), h('div', null,
        h('p', null, words, waiting ? [' · ', kit.button('quiet', { size: 's', class: 'card-undo', onclick: undo }, t('cUndo'))] : null),
        h('p', { class: 'card-about' }, t('cPushAsk'))))));
      return;
    }
    const shown = now || refused?.lead || null;
    el.replaceChildren(...(shown ? [pushCard(shown, app, { onPush: () => start('push'), onDecline: () => start('push.decline'), said: refused?.words || null,
      notice: changed ? t('puChanged') : null, settle: !!now })] : []));
  }

  return {
    el,
    update(next) { lead = next; draw(); return !!el.firstChild; },
    shown: () => !!el.firstChild,
    receipts: () => receipts.slice(),
  };
}

// How a card's priority ranks in the waiting block: Blocking first, then Important, then Whenever.
const RANK = { blocking: 0, important: 1, whenever: 2 };
export const rankOf = (card) => RANK[card.question?.priority] ?? (card.blocking ? 0 : 1);

// How long an answered card stays in the waiting block, saying it was answered: the conversation is the record.
export const ANSWERED_SHOWN = 4000;

// The waiting block's cards: Blocking first (oldest first), then Important, then Whenever, then the lead's push. Every
// Blocking card is shown whole; with several open, the others fold to their question line (one the user opens shows
// whole), and with none Blocking the first shows whole. `others()`: the project's other cards, drawn by the caller
// ({ key, at, priority, el }: held config, a base move, a plugin's request), placed among them by their priority.
// `onChange`: an answered card left (its few seconds over), or the push changed by itself, so whoever holds the stack
// may draw again.
export function questionStack(app, project, { onChange = () => {}, now = () => Date.now(), others = () => [] } = {}) {
  const count = h('h2', { class: 'stack-title' });
  const order = h('span', { class: 'stack-note' }, t('anyOrder'));
  const list = h('div', { class: 'stack-cards' });
  const push = pushBlock(app, { onChange });
  const el = h('section', { class: 'stack', 'aria-label': t('cQuestionsForYou') }, h('header', { class: 'stack-head' }, count, order), list, push.el);
  const rows = new Map();
  // Each card's place: keyed by its first id and ordered by when that card was first asked, so a question the node
  // posts again after a restart (a new card id, the same question) keeps its row, its place and what was typed in it.
  const keyOf = (card) => app.store.cardKey(card.id);
  const firstAt = new Map();
  // The one the user opened, shown whole among folded ones.
  let chosen = null;
  const expand = (card) => { chosen = keyOf(card); update(); };
  // When each card closed here (answered, decided, withdrawn): shown that long, then gone. One already closed when
  // first seen is never shown.
  const closedAt = new Map();
  let leaving = null;
  let shownOthers = [];

  function update() {
    const cards = [...app.store.state.cards.values()].filter((card) => card.project === project && (card.kind === 'question' || card.kind === 'approval'));
    for (const card of cards) if (!firstAt.has(keyOf(card))) firstAt.set(keyOf(card), Date.parse(card.at));
    const isOpen = (card) => card.open && app.store.state.acting.get(card.id)?.kind !== 'answer';
    const open = cards.filter(isOpen);
    const at = now();
    for (const card of cards) {
      const key = keyOf(card);
      if (isOpen(card)) closedAt.delete(key);
      else if (!closedAt.has(key)) closedAt.set(key, rows.has(key) ? at : 0);
    }
    const stays = (card) => isOpen(card) || at - (closedAt.get(keyOf(card)) || 0) < ANSWERED_SHOWN;
    cards.splice(0, cards.length, ...cards.filter(stays));
    // The next answered card to leave: drawn again then, and the holder told.
    const soonest = Math.min(...cards.filter((card) => !isOpen(card)).map((card) => closedAt.get(keyOf(card)) + ANSWERED_SHOWN));
    clearTimeout(leaving);
    if (Number.isFinite(soonest)) leaving = setTimeout(() => { update(); onChange(); }, Math.max(0, soonest - at) + 20);
    // Open before answered; then by priority; then oldest first. The caller's other cards (always open) among them.
    const extra = others();
    const items = [...cards.map((card) => ({ card, open: isOpen(card), rank: rankOf(card), at: firstAt.get(keyOf(card)) })),
      ...extra.map((other) => ({ other, open: true, rank: RANK[other.priority] ?? 1, at: Date.parse(other.at) || 0 }))];
    items.sort((a, b) => (b.open - a.open) || (a.rank - b.rank) || (a.at - b.at));
    const pushShown = push.update(app.store.state.leads.get(project) || null);
    el.hidden = items.length === 0 && !pushShown;
    const asking = open.length + extra.length;
    setText(count, asking ? t('questionsForYou', { n: asking }) + (pushShown ? t('andAPush') : '') : pushShown ? t('pushWaits') : t('cNoQuestions'));
    setClass(count, 'blocking', open.some((card) => card.blocking));
    order.hidden = asking < 2;
    const before = rows.size;
    const whole = open.some((card) => keyOf(card) === chosen) ? chosen : null;
    const firstWhole = open.some((card) => rankOf(card) === 0) ? null : items.find((item) => item.card && item.open)?.card;
    // Built by hand rather than with `keyed`'s slide: a card that closes shrinks in place.
    const next = new Map();
    let cursor = list.firstChild;
    for (const item of items) {
      let node;
      if (item.other) node = item.other.el;
      else {
        const card = item.card;
        let row = rows.get(keyOf(card));
        const fresh = !row;
        const fold = item.open && open.length > 1 && item.rank !== 0 && keyOf(card) !== whole && card !== firstWhole;
        if (fresh) row = questionCard(app, card, { expand });
        row.update(card, fold);
        next.set(keyOf(card), row);
        if (fresh && before > 0) row.el.classList.add('enter');
        node = row.el;
      }
      if (node === cursor) cursor = cursor.nextSibling; else list.insertBefore(node, cursor);
    }
    for (const [id, row] of rows) if (!next.has(id)) row.el.remove();
    for (const node of shownOthers) if (!extra.some((other) => other.el === node)) node.remove();
    shownOthers = extra.map((other) => other.el);
    rows.clear();
    for (const [id, row] of next) rows.set(id, row);
    return asking + (pushShown ? 1 : 0);
  }

  return { el, update, receipts: push.receipts, focusLast() { const cards = el.querySelectorAll('.card:not(.closed)'); cards[cards.length - 1]?.querySelector('.option, .answer-input')?.focus(); } };
}

// A feature plugin's card (js/plugincard.js): who asks, the node's facts, what it asks whole, the agent's own words,
// and the lines that settle it. Never acts.
export function pluginCard(card, app = null) {
  if (card.tooLarge) return tooLargeCard(card);
  // With the `act` right, each answer word is a button (its request the card, its seen and the word); the command the
  // agent asks for stays shown whole above it.
  const acting = app && actsFor(app, 'answer');
  const f = pluginFacts(card), wait = f.state === 'waiting', fact = (n, ...v) => [h('dt', null, n), h('dd', null, v)];
  return h('article', { class: 'card' + (wait ? '' : ' closed') },
    h('header', { class: 'card-head' }, h('span', { class: `priority ${PRIORITY[f.severity] ? f.severity : 'important'}` }, f.title),
      wait && f.expiresAt ? h('time', { class: 'asked', data: { until: f.expiresAt } }, t('cExpires', { d: until(f.expiresAt) })) : null),
    h('div', { class: 'facts' }, h('div', { class: 'facts-head' }, t('cExactly')), h('dl', null,
      fact(t('cAskedBy'), f.asker),
      f.facts.map((item) => fact(item.label, item.folder ? h('code', null, item.value) : item.value)),
      // What it asks, whole, as the agent wrote it: marked as the agent's words.
      fact(t('ccAgentWords', { name: f.body.name }), h('pre', { class: 'plugin-body' }, f.body.lines.join('\n')), f.body.note ? `${f.body.size}, ${f.body.note}` : f.body.size))),
    // The agent's own words beside it, never among the node's facts.
    f.context ? h('p', { class: 'card-context' }, h('span', { class: 'card-context-label' }, `${f.context.label}: `), f.context.text) : null,
    wait && acting ? h('div', { class: 'card-acts' }, f.actions.map((action) => doButton(app, { label: action.label || action.word, kind: 'answer',
      args: () => answerArgs(card, action.word), plain: action.word !== f.actions[0]?.word }).el))
      : wait ? h('div', { class: 'card-command' }, h('span', { class: 'card-command-label' }, t('settleInTerminal')),
        f.actions.map((action) => copyLine(action.line, action.says)))
      : h('p', { class: 'card-notice' }, f.outcome || f.state),
    card.notice ? h('p', { class: 'card-notice' }, card.notice) : null);
}

// An agent's own question on its screen (a permission prompt, a plan to approve), as a row of its chat: the Mac's
// AnswerCard. Answered, it folds to a line.
export function askCard(app, session, item, local, asked, redraw) {
  const agent = app.store.state.sessions.get(session)?.agent === 'codex' ? 'Codex' : 'Claude';
  const answer = item.answer || local?.answer;
  if (answer) {
    return h('div', { class: 'card closed ask' }, h('div', { class: 'card-closed' }, icon('check', 13),
      h('div', null, h('p', null, t('cYouAnswered'), h('strong', null, answer)), h('p', { class: 'card-about' }, item.text.split('\n')[0]))));
  }
  const el = h('article', { class: 'card ask', tabindex: -1 });
  // Shown as answered at once; back to the question, saying why, if the node refuses.
  const choose = (option) => {
    asked.set(item.id, { answer: option });
    redraw();
    app.store.request('ask.answer', { session, item: item.id, answer: option }).then((reply) => {
      if (reply.ok) return;
      asked.set(item.id, { refused: reply.error?.message || t('ccTheNodeRefusedIt') });
      redraw();
    });
  };
  const list = optionList(item.options, { numbered: true, choose });
  el.append(
    h('header', { class: 'card-head' }, h('span', { class: 'priority blocking' }, t('ccIsAsking', { agent }))),
    h('h3', { class: 'card-question' }, item.title),
    h('pre', { class: 'ask-text' }, item.text),
    list.el);
  if (local?.refused) el.append(h('p', { class: 'card-notice', role: 'alert' }, local.refused));
  list.el.title = t('cKeysAnswers', { n: item.options.length });
  cardKeys(el, () => ({ buttons: list.buttons, values: list.values, choose, hold: null }));
  return el;
}
