// A project's board: what its lead's team is doing, to read at a glance. On top, what is asked of you (the lead's open
// cards for this project: they are answered in the lead's chat); then the tasks as the node groups them: needs
// attention, running, waiting, done today. A blocked task shows its blocker's first lines, the rest a click away; a
// task's row opens its worker's chat. Read-only: nothing here changes a board. The node streams it (`boards`), so a
// task that moves moves here in the same frame; rows are keyed by slug and updated in place.

import { h, keyed, setText, setClass, framed } from '../dom.js';
import { icon } from '../marks.js';
import { boardGroups, boardSummary, taskState, taskTone, taskGroup, taskLine, decisionLine, allDoneCard, since, moment, plural, tilde, lastPart } from '../words.js';
import { sessionHref } from '../ui.js';
import { allDoneView } from './alldone.js';
import { boardRecords } from './records.js';

// A blocker longer than this many lines (or characters) is folded to its first lines until asked.
const FOLD_LINES = 2;
const FOLD_CHARS = 180;

// The session a task's row opens: its verifier while one checks it, else its worker; only one the node lists.
function target(task, sessions) {
  const id = (task.status === 'review' && task.verifier) || task.worker;
  return id && sessions.has(id) ? id : null;
}

// The small facts under a row: its round, its audit, its budget; a merged one's commit.
function facts(task) {
  const parts = [];
  if (task.merged?.commit) parts.push(`merged ${task.merged.commit.slice(0, 8)}${task.merged.tested ? ', tests passed' : ''}`);
  if ((task.attempts || 1) > 1 && taskGroup(task) !== 'done') parts.push(`attempt ${task.attempts}`);
  if (task.audit) {
    const open = task.audit.open || 0;
    parts.push(task.audit.verdict === 'passed' ? 'audit passed' : open ? `audit: ${plural(open, 'open finding')}` : task.audit.verdict === 'failed' ? 'audit failed' : 'audit under way');
  }
  if (task.overBudget) parts.push('over its budget');
  else if (task.budgetMin && taskGroup(task) !== 'done') parts.push(`${task.budgetMin} min budget`);
  return parts.join(' · ');
}

function taskRow(app) {
  const mark = h('span', { class: 'dot', 'aria-hidden': 'true' });
  const title = h('span', { class: 'board-task-title' });
  const state = h('span', { class: 'board-task-state' });
  const time = h('time');
  const dim = h('span', { class: 'board-task-dim' });
  const small = h('span', { class: 'board-task-facts' });
  const link = h('a', { class: 'board-task-link' },
    h('span', { class: 'board-task-line' }, mark, title, h('span', { class: 'board-task-when' }, state, ' ', time)), dim, small);
  const blockerText = h('p', { class: 'board-blocker-text' });
  const more = h('button', { class: 'board-more', type: 'button', 'aria-expanded': 'false' });
  const blocker = h('div', { class: 'board-blocker' }, blockerText, more);
  const el = h('li', { class: 'board-task' }, link, blocker);
  let open = false;
  more.addEventListener('click', () => {
    open = !open;
    more.setAttribute('aria-expanded', String(open));
    setClass(blocker, 'open', open);
    setText(more, open ? 'Show less' : 'Show all');
  });

  return {
    el,
    update(task) {
      mark.className = `dot tone-${taskTone(task)}`;
      setText(title, task.title);
      setText(state, taskState(task));
      const done = taskGroup(task) === 'done';
      const at = done ? task.merged?.at || task.since : task.since;
      if (at && !done) time.dataset.since = at; else delete time.dataset.since;
      setText(time, at ? (done ? moment(at) : since(at)) : '');
      // A blocked task's blocker is shown whole below; its first line isn't said twice. A task at work: its AI summary.
      const text = task.blocker || '';
      const line = taskLine(task);
      setText(dim, line);
      setClass(dim, 'summary', !!task.summary);
      dim.hidden = !line;
      const said = facts(task);
      setText(small, said);
      small.hidden = !said;
      blocker.hidden = !text;
      setText(blockerText, text);
      const long = text.split('\n').length > FOLD_LINES || text.length > FOLD_CHARS;
      more.hidden = !long;
      if (!long && open) { open = false; setClass(blocker, 'open', false); }
      if (long) setText(more, open ? 'Show less' : 'Show all');
      const session = target(task, app.store.state.sessions);
      if (session) {
        link.setAttribute('href', sessionHref(session));
        link.title = task.status === 'review' && task.verifier === session ? 'Open its verifier’s chat' : 'Open its worker’s chat';
      } else {
        link.removeAttribute('href');
        link.removeAttribute('title');
      }
      setClass(el, 'done', done);
      setClass(el, 'needs', taskGroup(task) === 'attention');
    },
  };
}

function groupSection(app) {
  const title = h('span');
  const count = h('span', { class: 'count' });
  const list = h('ul', { class: 'board-tasks' });
  const el = h('section', { class: 'board-group' }, h('h2', { class: 'section-title board-group-head' }, title, count), list);
  const rows = new Map();
  return {
    el,
    update(group) {
      setText(title, group.title);
      setText(count, String(group.tasks.length));
      el.hidden = group.tasks.length === 0;
      keyed(list, rows, group.tasks, (task) => task.slug, () => taskRow(app), { move: true, enter: true });
    },
    clear() { rows.clear(); list.replaceChildren(); },
  };
}

// One open card of the project: what the lead asks, and where it's answered.
function askRow(app) {
  const text = h('span', { class: 'board-ask-text' });
  const where = h('span', { class: 'board-ask-where' });
  const link = h('a', { class: 'board-ask-link' }, icon('question', 14), h('span', { class: 'board-ask-body' }, text, where));
  const el = h('li', { class: 'board-ask' }, link);
  return {
    el,
    update({ card, lead }) {
      const words = card.question?.text || (card.kind === 'approval' ? `Approve the merge of ${card.approval?.commit?.slice(0, 8) || 'a commit'}` : card.kind === 'config' ? 'Held config waits for you' : card.kind === 'base' ? 'A base move waits for you' : 'The lead asks you something');
      setText(text, words);
      setClass(el, 'blocking', !!card.blocking);
      const session = lead?.session && app.store.state.sessions.has(lead.session) ? lead.session : null;
      setText(where, (card.blocking ? 'Blocking · ' : '') + (session ? 'answer it in the lead’s chat' : 'answer it with vibeswitcher answer'));
      if (session) link.setAttribute('href', sessionHref(session)); else link.removeAttribute('href');
    },
  };
}

export function boardView(app) {
  const { store } = app;
  const title = h('h1', { class: 'head-title' });
  const summary = h('span', { class: 'head-state' });
  const place = h('div', { class: 'head-place' });
  const leadLink = h('a', { class: 'board-lead icon-button', title: 'Open the lead’s chat', 'aria-label': 'Open the lead’s chat' }, icon('chat', 15));
  const asksList = h('ul', { class: 'board-asks' });
  const asksCount = h('span', { class: 'count' });
  const asks = h('section', { class: 'board-group asks' }, h('h2', { class: 'section-title board-group-head' }, h('span', null, 'Asked of you'), asksCount), asksList);
  const note = h('p', { class: 'board-note', hidden: true });
  // The batch that cleared the board (the board's `allDone`, the app's card), for a day.
  const doneCard = h('section', { class: 'board-group all-done', hidden: true, 'aria-label': 'All tasks finished' });
  let seenAsked = null;
  const groupsEl = h('div', { class: 'board-groups' });
  const sections = [0, 1, 2, 3].map(() => groupSection(app));
  groupsEl.append(...sections.map((section) => section.el));
  const more = h('p', { class: 'board-more-note', hidden: true });
  // The lead's latest decisions, newest first (the board's `decisions`).
  const decisionsList = h('ul', { class: 'board-decisions' });
  const decisions = h('section', { class: 'board-group decisions', hidden: true },
    h('h2', { class: 'section-title board-group-head' }, h('span', null, 'Decisions')), decisionsList);
  // The Team tab's other records under them (views/records.js): its decisions are the list above.
  const records = boardRecords(app, { decisions: false });
  const el = h('section', { class: 'board', 'aria-label': 'Board' },
    h('header', { class: 'head' },
      h('a', { class: 'back icon-button', href: '#/', 'aria-label': 'Sessions' }, icon('back', 16)),
      h('div', { class: 'head-text' }, h('div', { class: 'head-line' }, title, summary), place),
      leadLink),
    h('div', { class: 'pane board-pane' }, h('div', { class: 'board-column' }, asks, doneCard, note, groupsEl, more, decisions, records.el)));
  const askRows = new Map();
  let shown = null;

  function render() {
    if (app.ui.state.route.name !== 'board') return;
    const project = app.ui.state.route.id;
    if (project !== shown) {
      sections.forEach((section) => section.clear());
      askRows.clear();
      asksList.replaceChildren();
      shown = project;
    }
    const board = store.state.boards.get(project);
    const lead = store.state.leads.get(project);
    const root = board?.root || lead?.root || '';
    const name = lastPart(root) || 'Board';
    setText(title, name);
    document.title = `${name} board · VibeSwitcher`;
    setText(place, [tilde(root, store.state.node?.home), board?.baseBranch ? `base ${board.baseBranch}` : ''].filter(Boolean).join(' · '));
    const session = lead?.session && store.state.sessions.has(lead.session) ? lead.session : null;
    leadLink.hidden = !session;
    if (session) leadLink.setAttribute('href', sessionHref(session));

    const cards = [...store.state.cards.values()].filter((card) => card.project === project && card.open)
      .sort((a, b) => Number(b.blocking) - Number(a.blocking));
    asks.hidden = cards.length === 0;
    setText(asksCount, String(cards.length));
    keyed(asksList, askRows, cards.map((card) => ({ card, lead })), ({ card }) => store.cardKey(card.id), () => askRow(app), { enter: true });

    const groups = boardGroups(board);
    groups.forEach((group, index) => sections[index].update(group));
    const said = boardSummary(groups);
    setText(summary, said);
    summary.hidden = !said;

    let words = '';
    if (store.state.connection === 'connecting') words = '';
    else if (!board && !store.follows('boards')) words = 'This node doesn’t send its leads’ boards yet.';
    else if (!board) words = lead ? 'The board is on its way.' : 'No lead runs for this project.';
    else if (board.unreadable) words = `The board can’t be shown: ${board.unreadable}.`;
    else if (!groups.some((group) => group.tasks.length)) words = 'Nothing on the board yet. Tell the lead what to build.';
    setText(note, words);
    note.hidden = !words;
    setText(more, board?.more ? `The board is long: ${plural(board.more, 'more task')} past these aren’t shown.` : '');
    more.hidden = !board?.more;
    records.update(board);
    const card = allDoneCard(board?.allDone);
    doneCard.hidden = !card;
    if (card) {
      const drawn = JSON.stringify(board.allDone);
      if (doneCard.dataset.drawn !== drawn) {
        doneCard.dataset.drawn = drawn;
        doneCard.replaceChildren(...allDoneView(board.allDone).childNodes);
      }
      // Seen once the page has shown it a moment (the app's: the user opened the lead).
      if (!board.allDone.seen && seenAsked !== board.allDone.id && store.can?.('seen') && document.visibilityState === 'visible') {
        seenAsked = board.allDone.id;
        setTimeout(() => { if (app.ui.state.route.name === 'board' && app.ui.state.route.id === project) store.request('seen', { project }); }, 1500);
      }
    }
    const decided = board?.decisions || [];
    decisions.hidden = decided.length === 0;
    decisionsList.replaceChildren(...decided.map((decision) => h('li', { class: 'board-decision', title: [decision.text, decision.why].filter(Boolean).join('\n\nWhy: ') },
      h('span', { class: 'board-decision-text' }, decisionLine(decision)),
      decision.at ? h('time', { class: 'board-task-when', data: { since: decision.at } }, since(decision.at)) : null)));
  }

  const schedule = framed(render);
  for (const topic of ['boards', 'leads', 'cards', 'sessions', 'node', 'connection']) store.subscribe(topic, schedule);
  app.ui.subscribe((what) => { if (what === 'route') render(); });
  render();
  return { el };
}
