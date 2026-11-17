// What the user answers: a lead's question, a merge to approve, and an agent's own prompt in its chat. The wording is
// the Mac's question card (LeadViews.swift). An answer shows at once and is taken back, saying why, if the node
// refuses it (the design's "Actions").
//
// Keys, with the focus anywhere in a card: 1–9 answer with that option, ↑ ↓ move, ↩ answers with the focused one,
// H holds the timer. ↑ from an empty message box steps into the last card.

import { h, setText, setClass } from '../dom.js';
import { icon } from '../marks.js';
import { since, until, clock, plural } from '../words.js';

const PRIORITY = { blocking: 'Blocking', important: 'Important', whenever: 'Whenever' };

// The options as buttons, the proposed one marked, and the keys that work across them.
function optionList(options, { proposed = null, numbered = false, choose }) {
  const buttons = options.map((option, index) => h('button', { class: 'option', type: 'button', onclick: () => choose(option) },
    numbered ? h('span', { class: 'option-key', 'aria-hidden': 'true' }, String(index + 1)) : null,
    h('span', { class: 'option-text' }, option),
    option === proposed ? h('span', { class: 'option-note' }, 'Proposed') : null));
  buttons.forEach((button, index) => { if (options[index] === proposed) button.classList.add('proposed'); });
  return { el: h('div', { class: 'options' }, buttons), buttons };
}

// The keys every card shares, attached once; `now()` gives the card's buttons and actions as it's drawn at the
// moment (`hold` is null where there's no timer).
function cardKeys(el, now) {
  el.addEventListener('keydown', (event) => {
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    const { buttons, choose, hold } = now();
    const stops = [...el.querySelectorAll('.option, .answer-input')].filter((node) => !node.disabled);
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      const to = stops[stops.indexOf(document.activeElement) + (event.key === 'ArrowDown' ? 1 : -1)];
      if (to) { to.focus(); event.preventDefault(); }
      return;
    }
    if (event.target.matches('input, textarea')) return;
    if (/^[1-9]$/.test(event.key) && buttons[Number(event.key) - 1]) {
      event.preventDefault();
      choose(buttons[Number(event.key) - 1].querySelector('.option-text').textContent);
    } else if ((event.key === 'h' || event.key === 'H') && hold) {
      event.preventDefault();
      hold();
    }
  });
}

// What git and the vault say about a merge, apart from anything the lead wrote (the design's security rule 2: the
// person approves facts, not prose). Nothing here is shortened: these fields are what an approval covers.
function approvalFacts(approval) {
  const fact = (name, ...value) => [h('dt', null, name), h('dd', null, value)];
  return h('div', { class: 'facts' },
    h('div', { class: 'facts-head' }, 'From git and the vault'),
    h('dl', null,
      fact('Commit', h('code', null, approval.commit)),
      fact('Subject', approval.subject || '(no subject)'),
      fact('Into', approval.base || 'the base'),
      fact('Changes', approval.diffstat, h('ul', { class: 'files' }, approval.files.map((file) => h('li', null, h('code', null, file))))),
      Object.entries(approval.verdicts || {}).map(([task, verdict]) => fact('Verdict', `${task}: ${verdict}`)),
      approval.sensitive ? fact('Sensitive paths', approval.sensitive.length ? approval.sensitive.join(', ') : 'none touched') : fact('Sensitive paths', 'couldn’t be checked'),
      (approval.problems || []).map((problem) => fact('Note', problem))));
}

// A lead's question or approval. Returns { el, update(card) }; `el` keeps its text field and its focus across updates.
export function questionCard(app, first) {
  const el = h('article', { class: 'card', tabindex: -1 });
  let card = first;
  let shape = '';
  let input = null;
  let keys = { buttons: [], hold: null };

  const choose = (answer) => { if (answer.trim()) app.store.act(card.id, 'answer', { answer: answer.trim() }); };
  const hold = () => app.store.act(card.id, 'hold');

  function closedLine(mark, ...text) {
    return h('div', { class: 'card-closed' }, mark, h('div', null, h('p', null, text), h('p', { class: 'card-about' }, card.question.text)));
  }

  function build() {
    const question = card.question;
    const acting = app.store.state.acting.get(card.id) || {};
    const pendingAnswer = acting.kind === 'answer' ? acting.answer : null;
    el.replaceChildren();
    el.className = 'card';

    // Answered (here, a moment ago, or by the node's word), decided by its timer, or withdrawn: one quiet line.
    if (pendingAnswer || !card.open) {
      el.classList.add('closed');
      const state = pendingAnswer ? 'answered' : question.state;
      if (state === 'withdrawn') el.append(closedLine(icon('close', 13), 'Withdrawn: ', question.withdrawReason || 'no reason given'));
      else if (state === 'autoDecided') el.append(closedLine(icon('check', 13), 'Went ahead with ', h('strong', null, question.answer), ': no answer in 10 min'));
      else el.append(closedLine(icon('check', 13), 'You answered ', h('strong', null, pendingAnswer || question.answer || '')));
      if (card.notice) el.append(h('p', { class: 'card-notice' }, card.notice));
      keys = { buttons: [], hold: null };
      return;
    }

    const held = acting.kind === 'hold' || (!!question.proposal && !question.decideBy);
    const counting = !!question.decideBy && !held;
    const rank = PRIORITY[question.priority] ? question.priority : 'important';
    const priority = h('span', { class: 'priority ' + rank }, PRIORITY[rank]);
    const asked = h('time', { class: 'asked', data: { ago: card.at } }, `asked ${since(card.at)} ago`);
    el.append(h('header', { class: 'card-head' }, priority, asked));

    if (card.kind === 'approval' && card.approval) {
      el.append(approvalFacts(card.approval));
      el.append(h('p', { class: 'said-by' }, 'The lead says'));
    }
    el.append(h('h3', { class: 'card-question' }, question.text));
    if (question.whyNow) el.append(h('p', { class: 'card-why' }, question.whyNow));
    if (question.revisionNote) el.append(h('p', { class: 'card-revised' }, `Updated: ${question.revisionNote}`));

    if (counting) {
      el.append(h('div', { class: 'timer' },
        h('span', { class: 'timer-text' }, 'Going with ', h('strong', null, question.proposal), ' ', h('span', { data: { until: question.decideBy } }, until(question.decideBy))),
        h('button', { class: 'button quiet', type: 'button', title: 'Stop the timer: the lead waits for your answer', onclick: hold }, icon('pause', 12), 'Hold')));
    } else if (held) {
      el.append(h('p', { class: 'timer held' }, 'Held: the timer is off. The lead proposed ', h('strong', null, question.proposal), '; it waits for your answer.'));
    }

    const list = optionList(question.options, { proposed: question.proposal, choose });
    el.append(list.el);

    const draft = input?.value || '';
    input = h('input', { class: 'answer-input', type: 'text', placeholder: question.options.length ? 'Or answer in your own words' : 'Your answer', 'aria-label': 'Your answer', autocomplete: 'off' });
    input.value = draft;
    const send = h('button', { class: 'button', type: 'submit', disabled: !draft.trim() }, 'Answer');
    input.addEventListener('input', () => { send.disabled = !input.value.trim(); });
    el.append(h('form', { class: 'answer', onsubmit: (event) => { event.preventDefault(); choose(input.value); } }, input, send));

    if (acting.refused) el.append(h('p', { class: 'card-notice', role: 'alert' }, acting.refused));
    else if (card.notice) el.append(h('p', { class: 'card-notice' }, card.notice));

    el.append(h('p', { class: 'card-foot' }, counting
      ? `Pick another answer or hold it; if you don’t, the lead goes ahead with ${question.proposal} at ${clock(question.decideBy)}.`
      : 'It keeps working while you think; the answer reaches it at its next step.'),
      h('p', { class: 'card-keys', 'aria-hidden': 'true' }, `1–${Math.max(question.options.length, 1)} answers · ↑ ↓ and ↩${counting ? ' · H holds' : ''}`));
    keys = { buttons: list.buttons, hold: counting ? hold : null };
  }

  // The card is built again only when what it shows changed, so typing into it survives every other delta.
  function update(next) {
    card = next;
    const acting = app.store.state.acting.get(card.id);
    const now = JSON.stringify([card, acting || null]);
    if (now === shape) return;
    const focused = el.contains(document.activeElement);
    shape = now;
    build();
    if (focused) (el.querySelector('.answer-input') || el).focus();
  }

  cardKeys(el, () => ({ ...keys, choose }));
  update(first);
  return { el, update };
}

// The stack under a lead's chat: "2 questions for you", then the cards, open ones first.
export function questionStack(app, project) {
  const count = h('h2', { class: 'stack-title' });
  const order = h('span', { class: 'stack-note' }, 'Answer in any order');
  const list = h('div', { class: 'stack-cards' });
  const el = h('section', { class: 'stack', 'aria-label': 'Questions for you' }, h('header', { class: 'stack-head' }, count, order), list);
  const rows = new Map();

  function update() {
    const cards = [...app.store.state.cards.values()].filter((card) => card.project === project && (card.kind === 'question' || card.kind === 'approval'));
    const isOpen = (card) => card.open && app.store.state.acting.get(card.id)?.kind !== 'answer';
    const open = cards.filter(isOpen);
    cards.sort((a, b) => (isOpen(b) - isOpen(a)) || (Date.parse(a.at) - Date.parse(b.at)));
    el.hidden = cards.length === 0;
    setText(count, open.length ? `${plural(open.length, 'question')} for you` : 'No questions waiting');
    setClass(count, 'blocking', open.some((card) => card.blocking));
    order.hidden = open.length < 2;
    const before = rows.size;
    // Built by hand rather than with `keyed`'s slide: a card that closes shrinks in place.
    const next = new Map();
    let cursor = list.firstChild;
    for (const card of cards) {
      let row = rows.get(card.id);
      const fresh = !row;
      if (fresh) row = questionCard(app, card); else row.update(card);
      next.set(card.id, row);
      if (row.el === cursor) cursor = cursor.nextSibling; else list.insertBefore(row.el, cursor);
      if (fresh && before > 0) row.el.classList.add('enter');
    }
    for (const [id, row] of rows) if (!next.has(id)) row.el.remove();
    rows.clear();
    for (const [id, row] of next) rows.set(id, row);
    return open.length;
  }

  return { el, update, focusLast() { const cards = el.querySelectorAll('.card:not(.closed)'); cards[cards.length - 1]?.querySelector('.option, .answer-input')?.focus(); } };
}

// An agent's own question on its screen (a permission prompt, a plan to approve), as a row of its chat: the Mac's
// AnswerCard. Answered, it folds to a line.
export function askCard(app, session, item, local, asked, redraw) {
  const agent = app.store.state.sessions.get(session)?.agent === 'codex' ? 'Codex' : 'Claude';
  const answer = item.answer || local?.answer;
  if (answer) {
    return h('div', { class: 'card closed ask' }, h('div', { class: 'card-closed' }, icon('check', 13),
      h('div', null, h('p', null, 'You answered ', h('strong', null, answer)), h('p', { class: 'card-about' }, item.text.split('\n')[0]))));
  }
  const el = h('article', { class: 'card ask', tabindex: -1 });
  // Shown as answered at once; back to the question, saying why, if the node refuses.
  const choose = (option) => {
    asked.set(item.id, { answer: option });
    redraw();
    app.store.request('ask.answer', { session, item: item.id, answer: option }).then((reply) => {
      if (reply.ok) return;
      asked.set(item.id, { refused: reply.error?.message || 'The node refused it.' });
      redraw();
    });
  };
  const list = optionList(item.options, { numbered: true, choose });
  el.append(
    h('header', { class: 'card-head' }, h('span', { class: 'priority blocking' }, `${agent} is asking`)),
    h('h3', { class: 'card-question' }, item.title),
    h('pre', { class: 'ask-text' }, item.text),
    list.el);
  if (local?.refused) el.append(h('p', { class: 'card-notice', role: 'alert' }, local.refused));
  el.append(h('p', { class: 'card-keys', 'aria-hidden': 'true' }, `1–${item.options.length} answers · ↑ ↓ and ↩`));
  cardKeys(el, () => ({ buttons: list.buttons, choose, hold: null }));
  return el;
}
