// The app's vocabulary, copied from the Mac app so every surface says the same thing: the state words (StateWord,
// Sources/VibeCore/Models.swift), the attention groups (WindowGroups.swift), durations (Durations, BackgroundJobs.swift)
// and a board task's words (LeadTask.Status, LeadViews.swift). Colours are the same names in style.css.

// The node writes a status in kebab case (`Requests.statusWord`): needs-you, working, background, done, idle, unknown.
// A session can also be paused or ended, which aren't statuses of its agent.
export const STATES = {
  'needs-you': { label: 'Needs you', mark: 'alert', one: 'needs you', many: 'need you' },
  working: { label: 'Working', mark: 'spinner', one: 'working', many: 'working' },
  background: { label: 'Background', mark: 'half', one: 'in background', many: 'in background' },
  done: { label: 'Done', mark: 'check', one: 'done', many: 'done' },
  idle: { label: 'Idle', mark: 'dot', one: 'idle', many: 'idle' },
  paused: { label: 'Paused', mark: 'paused', one: 'paused', many: 'paused' },
  ended: { label: 'Ended', mark: 'outline', one: 'ended', many: 'ended' },
  unknown: { label: 'Unknown', mark: 'outline', one: 'unknown', many: 'unknown' },
};

// The word a session's row shows: paused and ended first, else its status. A lead with an open question for you
// reads needs you, as the Mac's row does (`shownStatus`); the node already folds that into `status`.
export function stateOf(session) {
  if (session.ended) return 'ended';
  if (session.paused) return 'paused';
  return STATES[session.status] ? session.status : 'unknown';
}

// "1 needs you", "2 need you", "1 in background", "3 working" (StateWord.counted).
export function counted(state, count) {
  const word = STATES[state];
  return `${count} ${count === 1 ? word.one : word.many}`;
}

// The Attention grouping's groups, in order (AttentionGroup): background work counts as working, the rest as idle.
export const ATTENTION = [
  { id: 'needs-you', title: 'Needs you', has: (state) => state === 'needs-you' },
  { id: 'working', title: 'Working', has: (state) => state === 'working' || state === 'background' },
  { id: 'done', title: 'Done', has: (state) => state === 'done' },
  { id: 'idle', title: 'Idle', has: (state) => !['needs-you', 'working', 'background', 'done'].includes(state) },
];

// 45s, 12m, 3h 5m, 2d 4h (Durations.short).
export function short(seconds) {
  const s = Math.max(0, Math.floor(seconds));
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return s % 3600 >= 60 ? `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m` : `${Math.floor(s / 3600)}h`;
  return `${Math.floor(s / 86400)}d ${Math.floor((s % 86400) / 3600)}h`;
}

export function since(iso, now = Date.now()) {
  const at = Date.parse(iso);
  return Number.isFinite(at) ? short((now - at) / 1000) : '';
}

// 14:03, in the reader's own time zone.
export function clock(iso) {
  const at = new Date(iso);
  if (Number.isNaN(at.getTime())) return '';
  return `${String(at.getHours()).padStart(2, '0')}:${String(at.getMinutes()).padStart(2, '0')}`;
}

// 14:03 for a moment of today, "Nov 16, 14:03" for one of another day.
export function moment(iso, now = Date.now()) {
  const at = new Date(iso);
  if (Number.isNaN(at.getTime())) return '';
  if (at.toDateString() === new Date(now).toDateString()) return clock(iso);
  return `${at.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })}, ${clock(iso)}`;
}

// "in 8 min", "in 45 s", "now": how long a question's timer has left (the Mac's question card).
export function until(iso, now = Date.now()) {
  const left = Math.ceil((Date.parse(iso) - now) / 1000);
  if (!(left > 0)) return 'now';
  return left < 60 ? `in ${left} s` : `in ${Math.round(left / 60)} min`;
}

// A board task's status: its word, and the colour its dot takes (LeadTask.Status and LeadViews.swift's table).
export const TASKS = {
  running: { label: 'Working', tone: 'working' },
  review: { label: 'In review', tone: 'background' },
  blocked: { label: 'Blocked', tone: 'blocked' },
  failed: { label: 'Failed', tone: 'needs-you' },
  kept: { label: 'Kept', tone: 'kept' },
  planned: { label: 'Queued', tone: 'idle' },
  done: { label: 'Merged', tone: 'done' },
  reverted: { label: 'Reverted', tone: 'needs-you' },
  folded: { label: 'Folded', tone: 'done' },
  abandoned: { label: 'Abandoned', tone: 'idle' },
};
// The order tasks are shown in: what's moving first (LeadTask's attention order).
export const TASK_ORDER = ['running', 'review', 'blocked', 'failed', 'kept', 'planned', 'done', 'reverted', 'folded', 'abandoned'];
export const FINISHED = new Set(['done', 'reverted', 'folded', 'abandoned', 'kept']);

// A lead's board as the node groups it (BoardValue.groups): what needs someone, what's moving, what waits, what's done.
// The node sends each task's `group`, `state` and `line`; a board without them (the mock's) is read from its status.
export const TASK_GROUPS = [
  { id: 'attention', title: 'Needs attention' },
  { id: 'running', title: 'Running' },
  { id: 'waiting', title: 'Waiting' },
  { id: 'done', title: 'Done today' },
];
const GROUP_OF = { blocked: 'attention', failed: 'attention', running: 'running', review: 'running', planned: 'waiting', kept: 'waiting' };
export const taskGroup = (task) => task.group || GROUP_OF[task.status] || 'done';
export const taskState = (task) => task.state || TASKS[task.status]?.label || task.status;
// The dot's colour: a task that needs attention is red, but a blocked one keeps its own purple.
export function taskTone(task) {
  if (taskGroup(task) === 'attention' && task.status !== 'blocked') return 'needs-you';
  return TASKS[task.status]?.tone || 'idle';
}
// When it finished: its merge, else when it took its last status.
const finishedAt = (task) => Date.parse(task.merged?.at || task.since || '') || 0;
// A finished task from today (the reader's day): the board's "Done today" shows these, and drops older ones.
export function doneToday(task, now = Date.now()) {
  const at = finishedAt(task);
  return at > 0 && new Date(at).toDateString() === new Date(now).toDateString();
}
// The board's tasks by group, in the board's order within each; done ones only from today.
export function boardGroups(board, now = Date.now()) {
  const tasks = board?.tasks || [];
  return TASK_GROUPS.map((group) => ({
    ...group,
    tasks: tasks.filter((task) => taskGroup(task) === group.id && (group.id !== 'done' || doneToday(task, now))),
  }));
}
// "1 needs attention · 2 running · 1 waiting · 3 done today".
export function boardSummary(groups) {
  const words = { attention: (n) => (n === 1 ? '1 needs attention' : `${n} need attention`), done: (n) => `${n} done today` };
  return groups.filter((group) => group.tasks.length).map((group) => (words[group.id] || ((n) => `${n} ${group.id}`))(group.tasks.length)).join(' · ');
}

// The strip's counts: "1 working", "1 in review", "4 done".
export function taskCount(status, count) {
  const words = { running: 'working', review: 'in review', done: 'done', planned: 'queued' };
  return `${count} ${words[status] || TASKS[status].label.toLowerCase()}`;
}

export function plural(count, one, many = one + 's') {
  return `${count} ${count === 1 ? one : many}`;
}

// A folder for reading: the home folder as ~ (the node sends whole paths; `home` is its own, when it says).
export function tilde(path, home) {
  if (!path) return '';
  if (home && (path === home || path.startsWith(home + '/'))) return '~' + path.slice(home.length);
  return path;
}

export function lastPart(path) {
  return (path || '').replace(/\/+$/, '').split('/').pop() || '';
}

export const AGENTS = { claude: 'Claude', codex: 'Codex', shell: 'Shell' };
export const ROLES = { lead: 'Lead', worker: 'Worker', verifier: 'Verifier' };

// ⌘ on a Mac, Ctrl elsewhere; ⌥ on a Mac, Alt elsewhere.
export const MAC = typeof navigator !== 'undefined' && /Mac|iPhone|iPad/.test(navigator.platform || '');
export const KEY = { mod: MAC ? '⌘' : 'Ctrl+', alt: MAC ? '⌥' : 'Alt+' };

// The dim line under a task's row: while it works, the AI summary of what its agent is doing when the node has one
// (`summary`), else the node's line; a blocked task's line is left out when its blocker's first line says the same.
export function taskLine(task) {
  if (task.summary) return task.summary;
  const text = task.blocker || '';
  const first = text.split('\n').find((line) => line.trim()) || '';
  return task.line && !(text && task.line.trim() === first.trim()) ? task.line : '';
}

// A lead's decision as the board lists it: "Decided: run the two small tasks side by side", a long one by its AI
// summary when the node has one (the app's `DecisionFeed.line`); its full text and why for the row's title.
export function decisionLine(decision) {
  const text = decision.summary || decision.text || '';
  const first = text.split(' ')[0] || '';
  const keep = !text || text[0] !== text[0].toUpperCase() || /[A-Z]/.test(first.slice(1));
  return 'Decided: ' + (keep ? text : text[0].toLowerCase() + text.slice(1));
}

const OUTCOME_WORDS = { merged: 'merged', folded: 'folded into another task', abandoned: 'set aside', reverted: 'reverted' };

// A board's all-done card (the board's `allDone`, the app's `AllDoneCard`): its summary, what it cost, "5 tasks · 4
// merged", and each task with how it ended. Null for none.
export function allDoneCard(mark) {
  if (!mark) return null;
  const count = mark.tasks.length;
  return {
    headline: mark.summary?.headline || null,
    bullets: mark.summary?.bullets || [],
    cost: mark.receipts ? `Cost: ${mark.receipts}.` : null,
    costNote: mark.pricesAsOf ? `Each task's working time and tokens, read from its sessions' transcripts; costs are estimates at the API prices of ${mark.pricesAsOf}.` : null,
    count: `${count} task${count === 1 ? '' : 's'} · ${mark.merged} merged`,
    tasks: mark.tasks.map((task) => ({ title: task.title, word: OUTCOME_WORDS[task.outcome] || task.outcome, merged: task.outcome === 'merged' })),
  };
}

// Boost's mark (the node's `boost`, the app's `BoostMark`): its label and its hover's words while on; null while off.
export function boostMarkText(boost) {
  if (!boost?.on) return null;
  const limits = boost.limits || {};
  return {
    label: `Boost on: ${boost.why}`,
    help: `Boost on (${boost.why})\nRaised limits: a load of ${limits.loadThreshold}, ${limits.maxSessions} team sessions on this node, `
      + `${limits.maxWorkers} workers per project, ${limits.heavySlots} test and build slots\nClick for Settings`,
  };
}
