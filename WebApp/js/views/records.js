// What the Mac's Team tab shows under a lead's tasks (its `TeamRecords`, `DecisionFeedView`): the scorecard, the lead's
// decisions, the answered and withdrawn questions, its results (`ResultsList`: each post_update's title and markdown),
// the messages between this project's lead and others' (`LeadMailList`, asked of the node: `mail`, a page's read), and
// where the lead's files are. The node sends them in the board's
// value (`BoardRecords`); the Team tab and the board page both show them. Read-only.
//
// - The newest few of each list are in view, the rest folded under "Earlier (n)", as the Mac's; one opens to say the
//   whole of it (a decision's why, a question's answer). What is open stays open while the board changes.
// - Every string is the sessions' writing: drawn as text, never markup.

import { h, setText } from '../dom.js';
import { clock, moment, decisionLine, plural } from '../words.js';
import { markdown } from '../text.js';
import { mailLine } from '../mail.js';
import { resultScreenshots } from './results.js';

// How many of each list show before "Earlier".
export const SHOWN = 3;
// How often the open Team tab asks for the record between leads again (it changes only as leads message each other).
const MAIL_EVERY = 30000;

// A question's line, as the Mac's `ClosedQuestionList` says it: its first line and what it closed with.
export function questionLine(question) {
  const gist = String(question.text || '').split('\n')[0].trim();
  if (question.state === 'withdrawn') return { gist, outcome: null, withdrawn: true };
  const with_ = question.state === 'autoDecided' ? question.proposal : question.answer;
  return { gist, outcome: with_ ? '→ ' + clipped(with_) : null, withdrawn: false };
}

// A long answer's start, so the question's gist keeps room on its line.
function clipped(answer) {
  const line = String(answer).split('\n')[0].trim();
  return line.length > 36 || line !== String(answer).trim() ? line.slice(0, 34) + '…' : line;
}

// What opens under a closed question: the wording answered, and how it closed.
export function questionDetail(question) {
  if (question.state === 'withdrawn') return [question.answer ? `Answered anyway → ${question.answer}` : 'Withdrawn by the lead.', question.why ? `Why: ${question.why}` : ''].filter(Boolean);
  if (question.state === 'autoDecided') return [`No answer in time: the lead went ahead with ${question.proposal || 'its proposal'}` + (question.answer ? `; you answered later: ${question.answer}` : '') + '.'];
  return [`Answered → ${question.answer || ''}`, question.reworded ? 'It was reworded after you answered.' : ''].filter(Boolean);
}

// "workflow.md is kept in ~/site/.vibeswitcher (not committed); decisions.md, progress.md and incidents.md in
// ~/site/docs/lead, committed to the lead's branch." (the Mac's line under its Files buttons).
export function filesLine(board, home) {
  const root = board.root && home && (board.root === home || board.root.startsWith(home + '/')) ? '~' + board.root.slice(home.length) : board.root || '';
  return board.recordsDir
    ? `workflow.md is kept in ${root}/.vibeswitcher (not committed); decisions.md, progress.md and incidents.md in ${root}/${board.recordsDir}, committed to the lead’s branch.`
    : `Kept in ${root}/.vibeswitcher (not committed).`;
}

// `decisions: false`: without the decisions (the board page lists them itself).
export function boardRecords(app, { decisions: showDecisions = true } = {}) {
  const scoreTiles = h('div', { class: 'score-tiles' });
  const scoreFoot = h('p', { class: 'records-note' });
  const scoreReceipts = h('p', { class: 'records-note' });
  const score = section('Scorecard', scoreTiles, scoreFoot, scoreReceipts);
  const decisionsList = h('div', { class: 'records-list' });
  const decisions = section('Decisions', decisionsList);
  const answeredList = h('div', { class: 'records-list' });
  const answered = section('Answered and withdrawn', answeredList);
  const resultsList = h('div', { class: 'records-list' });
  // A result's screenshots, asked of the node (`board.image`) where it serves them (views/results.js).
  const screenshots = resultScreenshots(app);
  const results = section('Results', resultsList);
  const mailList = h('div', { class: 'records-list' });
  const mail = section('Between leads', mailList);
  const filesList = h('ul', { class: 'records-files' });
  const filesNote = h('p', { class: 'records-note' });
  const files = section('Files', filesList, filesNote);
  const el = h('div', { class: 'records' }, score.el, decisions.el, answered.el, results.el, mail.el, files.el);
  // The project's record between leads, as the node last said it (asked when the board's root changes, and again after
  // `MAIL_EVERY`), and for which root.
  let mailFor = null;
  let mailAt = 0;
  let mailMessages = [];
  // What is open, by key: kept across the board's changes.
  const open = new Set();
  let drawn = '';

  function section(title, ...content) {
    const el = h('section', { class: 'inspect-group records-section' }, h('h2', { class: 'group-head' }, title), content);
    return { el };
  }

  // A row that opens: its line, and what it says in full under it.
  function opener(key, line, detail) {
    const details = h('details', { class: 'records-row' }, h('summary', null, line), h('div', { class: 'records-detail' }, detail));
    details.open = open.has(key);
    details.addEventListener('toggle', () => { if (details.open) open.add(key); else open.delete(key); });
    return details;
  }

  // The newest `SHOWN` of `rows`, the rest under "Earlier (n)".
  function folded(rows, key, label) {
    if (rows.length <= SHOWN) return rows;
    const earlier = h('details', { class: 'records-earlier' }, h('summary', null, `${label} (${rows.length - SHOWN})`), rows.slice(SHOWN));
    earlier.open = open.has(key);
    earlier.addEventListener('toggle', () => { if (earlier.open) open.add(key); else open.delete(key); });
    return [...rows.slice(0, SHOWN), earlier];
  }

  // The record between leads for `root`, asked of the node (a page's read, `mail`) when the root changes and each
  // `MAIL_EVERY` after; a node that doesn't serve it to pages leaves the section out.
  function askMail(root) {
    const store = app.store;
    if (!root || !store.can?.('mail')) return;
    if (root === mailFor && Date.now() - mailAt < MAIL_EVERY) return;
    if (root !== mailFor) mailMessages = [];
    mailFor = root;
    mailAt = Date.now();
    store.request('mail', { folder: root }).then((reply) => {
      if (mailFor !== root || !reply?.ok) return;
      mailMessages = reply.result.projects?.[0]?.messages || [];
      drawn = '';
      if (shownBoard) self.update(shownBoard);
    });
  }
  let shownBoard = null;

  const self = {
    el,
    update(board) {
      shownBoard = board;
      el.hidden = !board || !!board.unreadable;
      if (el.hidden) return;
      askMail(board.root);
      const now = JSON.stringify([board.scorecard, board.decisions, board.answered, board.files, board.recordsDir, board.root, (board.tasks || []).length,
        board.results, mailMessages]);
      if (now === drawn) return;
      drawn = now;

      // The lead's results, newest first: a body is the lead's markdown, drawn to nodes as a reply's; a screenshot is a file
      // on the node, said to be there.
      const posted = board.results || [];
      results.el.hidden = !posted.length;
      resultsList.replaceChildren(...folded(posted.map((result) => h('article', { class: 'records-result' },
        h('div', { class: 'records-result-head' }, h('span', { class: 'records-text' }, result.title),
          h('time', { class: 'records-time', title: moment(result.at) }, clock(result.at))),
        h('div', { class: 'prose' }, markdown(result.body || '')),
        result.images ? screenshots(board.project, result) ?? h('p', { class: 'records-note' }, `${plural(result.images, 'screenshot')} kept on the node`) : null)), 'r:earlier', 'Earlier results'));

      // Between leads: this project's messages with other projects' leads (shown when there are any).
      mail.el.hidden = !mailMessages.length;
      mailList.replaceChildren(...folded(mailMessages.map((message, index) => {
        const line = mailLine(message);
        return opener('m:' + message.at + index, [
          h('span', { class: 'records-text' + (line.sent ? '' : ' quiet') }, `${line.way} · ${line.kind}`),
          h('span', { class: 'records-outcome' }, line.outcome),
          h('time', { class: 'records-time', title: moment(message.at) }, clock(message.at)),
        ], [h('p', { class: 'records-question' }, line.text), line.why ? h('p', { class: 'records-note' }, `Why: ${line.why}`) : null]);
      }), 'm:earlier', 'Earlier messages'));

      const card = board.scorecard;
      score.el.hidden = !card || !(board.tasks || []).length;
      if (card) {
        const tiles = card.tiles || [];
        scoreTiles.replaceChildren(...(tiles.length ? tiles.map((tile, index) => h('div', {
          class: 'score-tile' + (tile.note ? ' quiet' : '') + (index === 3 && card.reverts > 0 ? ' bad' : ''), title: tile.help || '',
        }, h('span', { class: 'score-value' }, tile.value), h('span', { class: 'score-label' }, tile.label),
        tile.note ? h('span', { class: 'score-note' }, tile.note) : null))
          : [h('p', { class: 'records-note' }, 'Nothing merged yet: the numbers start with the first merge.')]));
        setText(scoreFoot, card.footnote || '');
        scoreFoot.hidden = !card.footnote;
        scoreFoot.classList.toggle('warn', card.mergedWithoutTests > 0);
        setText(scoreReceipts, card.receipts || '');
        scoreReceipts.hidden = !card.receipts;
      }

      const said = board.decisions || [];
      decisions.el.hidden = !showDecisions || !said.length;
      decisionsList.replaceChildren(...folded(said.map((decision) => opener('d:' + decision.at + decision.text,
        // Its line: a long one by its AI summary when one came (the app's `DecisionFeed.line`); opened, all of it and why.
        [h('span', { class: 'records-text' }, decisionLine(decision)), decision.at ? h('time', { class: 'records-time', title: moment(decision.at) }, clock(decision.at)) : null],
        [decision.summary ? h('p', { class: 'records-question' }, decision.text) : null,
          decision.why ? h('p', null, decision.why) : h('p', { class: 'records-note' }, 'No why was written.')])), 'd:earlier', 'Earlier decisions'));

      const closed = board.answered || [];
      answered.el.hidden = !closed.length;
      answeredList.replaceChildren(...folded(closed.map((question) => {
        const line = questionLine(question);
        return opener('q:' + question.id, [
          line.withdrawn ? h('span', { class: 'records-tag' }, 'Withdrawn') : null,
          h('span', { class: 'records-text' + (line.withdrawn ? ' quiet' : '') }, line.gist),
          line.outcome ? h('span', { class: 'records-outcome' }, line.outcome) : null,
        ], [h('p', { class: 'records-question' }, question.text), ...questionDetail(question).map((text) => h('p', { class: 'records-note' }, text))]);
      }), 'q:earlier', 'Earlier'));

      const list = board.files || [];
      files.el.hidden = !list.length;
      filesList.replaceChildren(...list.map((file) => h('li', { class: 'records-file' + (file.present ? '' : ' missing'), title: file.path },
        h('span', { class: 'records-file-name' }, file.name), h('span', { class: 'records-file-path' }, file.present ? file.path : `${file.path} · not there yet`))));
      setText(filesNote, filesLine(board, app.store.state.node?.home));
    },
  };
  return self;
}
