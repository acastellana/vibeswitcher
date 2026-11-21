// A lead's team, twice: the strip above its chat (one line of counts, the first line of the Mac's Team strip) and the
// tasks of the inspector's Team tab (every task with what it's doing, the Mac's Team tab). Both read the lead's board.

import { h, keyed, setText, setClass } from '../dom.js';
import { icon } from '../marks.js';
import { taskDetails } from './results.js';
import { TASKS, TASK_ORDER, TASK_GROUPS, taskCount, taskGroup, taskState, taskTone, since, clock } from '../words.js';
import { sessionHref, boardHref } from '../ui.js';

// The node's groups first (needs attention, running, waiting, done), then the board's order; the mock's boards by status.
const groupRank = (task) => TASK_GROUPS.findIndex((group) => group.id === taskGroup(task));
const byAttention = (a, b) => groupRank(a) - groupRank(b) || (a.position ?? 0) - (b.position ?? 0) || TASK_ORDER.indexOf(a.status) - TASK_ORDER.indexOf(b.status);
const dot = (status) => h('span', { class: `dot tone-${TASKS[status]?.tone || 'idle'}`, 'aria-hidden': 'true' });

// The session to open for a task: its verifier while it's in review, else its worker.
const sessionOf = (task) => (task.status === 'review' && task.verifier) || task.worker || null;

export function teamStrip(app) {
  const counts = h('span', { class: 'strip-counts' });
  const teamButton = h('button', { class: 'strip-team', type: 'button', title: 'Show the team in the inspector', onclick: () => app.ui.showInspector('team') }, icon('team', 14), 'Team');
  const boardLink = h('a', { class: 'strip-board', title: 'The lead’s board, on a page of its own' }, 'Board');
  const el = h('section', { class: 'strip', 'aria-label': 'Team' }, teamButton, counts, boardLink);
  let drawn = '';

  return {
    el,
    update(lead) {
      const tasks = app.store.state.boards.get(lead.lead)?.tasks || [];
      boardLink.hidden = !app.store.state.boards.has(lead.lead);
      if (!boardLink.hidden) boardLink.setAttribute('href', boardHref(lead.lead));
      const said = TASK_ORDER.map((status) => [status, tasks.filter((task) => task.status === status).length]).filter(([, count]) => count > 0);
      const now = JSON.stringify(said);
      if (now === drawn) return;
      drawn = now;
      counts.replaceChildren(...(said.length ? said.map(([status, count]) => h('span', { class: 'strip-count' }, dot(status), taskCount(status, count))) : ['No tasks yet']));
    },
  };
}

// What a task's row says under its title: the node's line, else (the mock's boards) what it waits on, else its last
// checkpoint.
function dimLine(task, board) {
  if (task.line !== undefined) return task.line || '';
  if (task.status === 'blocked' && task.after?.length) {
    const titles = task.after.map((slug) => board.tasks.find((other) => other.slug === slug)?.title || slug);
    return 'Waits on ' + titles.join(', ');
  }
  if (task.blocker) return task.blocker;
  const last = task.checkpoints?.[task.checkpoints.length - 1];
  if (last) return last.text;
  if (task.status === 'review') return 'Checking the work';
  if (task.merged) return `Merged ${task.merged.commit} at ${clock(task.merged.at)}${task.merged.tested ? ', tests passed' : ', no tests ran'}`;
  return '';
}

// The board's tasks: what's moving first, the finished ones folded into one line ("Merged (2) · Reverted (1)"). A
// task's row opens the session doing it; the one the selected session works on is marked.
export function teamTasks(app) {
  const list = h('ul', { class: 'tasks' });
  const finishedList = h('ul', { class: 'tasks', hidden: true });
  const fold = h('button', { class: 'fold', type: 'button', 'aria-expanded': 'false' }, h('span', { class: 'fold-text' }), icon('chevron', 10));
  const empty = h('p', { class: 'inspect-note', hidden: true }, 'Nothing on the board yet. Tell the lead what to build.');
  const el = h('section', { class: 'inspect-group' }, h('h2', { class: 'group-head' }, 'Tasks'), empty, list, fold, finishedList);
  const rows = new Map();
  const finishedRows = new Map();
  let open = false;
  let board = null;
  let selected = null;
  fold.addEventListener('click', () => {
    open = !open;
    fold.setAttribute('aria-expanded', String(open));
    finishedList.hidden = !open;
  });

  const row = () => {
    const mark = h('span', { class: 'dot' });
    const title = h('span', { class: 'task-title' });
    const state = h('span', { class: 'task-state' });
    const time = h('time');
    const dim = h('span', { class: 'task-dim' });
    const link = h('a', { class: 'task-link' }, h('span', { class: 'task-line' }, mark, title, h('span', { class: 'task-when' }, state, ' ', time)), dim);
    // Its details as it opens (views/results.js: the Mac's `TeamRowDetails`).
    const details = taskDetails(app);
    const el = h('li', { class: 'task' }, h('div', { class: 'task-row' }, link, details.button), details.el);
    return {
      el,
      update(task) {
        details.set(board?.project, task.slug);
        mark.className = `dot tone-${taskTone(task)}`;
        setText(title, task.title);
        setText(state, taskState(task));
        time.dataset.since = task.since;
        setText(time, since(task.since));
        setText(dim, dimLine(task, board));
        const target = sessionOf(task);
        if (target && app.store.state.sessions.has(target)) link.setAttribute('href', sessionHref(target)); else link.removeAttribute('href');
        setClass(el, 'current', !!selected && (task.worker === selected || task.verifier === selected));
      },
    };
  };

  return {
    el,
    // `session`: the selected one, a lead or a member of its team (its `lead` is the board's project).
    update(session) {
      board = app.store.state.boards.get(session.lead);
      selected = session.role === 'lead' ? null : session.id;
      const tasks = [...(board?.tasks || [])].sort(byAttention);
      const current = tasks.filter((task) => taskGroup(task) !== 'done');
      const finished = tasks.filter((task) => taskGroup(task) === 'done');
      empty.hidden = tasks.length > 0;
      keyed(list, rows, current, (task) => task.slug, row, { move: true, enter: true });
      keyed(finishedList, finishedRows, finished, (task) => task.slug, row);
      fold.hidden = finished.length === 0;
      const groups = ['done', 'folded', 'kept', 'reverted', 'abandoned']
        .map((status) => [TASKS[status].label, finished.filter((task) => task.status === status).length])
        .filter(([, count]) => count > 0)
        .map(([label, count]) => `${label} (${count})`);
      setText(fold.firstChild, groups.join(' · '));
    },
  };
}
