// The app's vocabulary, copied from the Mac app so every surface says the same thing: the state words (StateWord,
// Sources/VibeCore/Models.swift), the attention groups (WindowGroups.swift), durations (Durations, BackgroundJobs.swift)
// and a board task's words (LeadTask.Status, LeadViews.swift). Colours are the same names in style.css.

import { t } from './i18n.js';

// The node writes a status in kebab case (`Requests.statusWord`): needs-you, working, background, done, idle, unknown.
// A session can also be paused or ended, which aren't statuses of its agent.
export const STATES = {
  'needs-you': { label: t('wNeedsYou'), mark: 'alert', one: t('wNeedsYouOne'), many: t('wNeedYouMany') },
  working: { label: t('wWorking'), mark: 'spinner', one: t('wWorkingOne'), many: t('wWorkingOne') },
  background: { label: t('wBackground'), mark: 'half', one: t('wBackgroundOne'), many: t('wBackgroundOne') },
  done: { label: t('wDone'), mark: 'check', one: t('wDoneOne'), many: t('wDoneOne') },
  idle: { label: t('wIdle'), mark: 'dot', one: t('wIdleOne'), many: t('wIdleOne') },
  paused: { label: t('wPaused'), mark: 'paused', one: t('wPausedOne'), many: t('wPausedOne') },
  ended: { label: t('wEnded'), mark: 'outline', one: t('wEndedOne'), many: t('wEndedOne') },
  unknown: { label: t('wUnknown'), mark: 'outline', one: t('wUnknownOne'), many: t('wUnknownOne') },
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
  if (!(left > 0)) return t('wNow');
  return left < 60 ? t('wInSeconds', { n: left }) : t('wInMinutes', { n: Math.round(left / 60) });
}

// A board task's status: its word, and the colour its dot takes (LeadTask.Status and LeadViews.swift's table).
export const TASKS = {
  running: { label: t('wWorking'), tone: 'working' },
  review: { label: t('wInReview'), tone: 'background' },
  blocked: { label: t('wBlocked'), tone: 'blocked' },
  failed: { label: t('wFailed'), tone: 'needs-you' },
  kept: { label: t('wKept'), tone: 'kept' },
  planned: { label: t('wQueued'), tone: 'idle' },
  done: { label: t('wMerged'), tone: 'done' },
  reverted: { label: t('wReverted'), tone: 'needs-you' },
  folded: { label: t('wFolded'), tone: 'done' },
  abandoned: { label: t('wAbandoned'), tone: 'idle' },
};
// The order tasks are shown in: what's moving first (LeadTask's attention order).
export const TASK_ORDER = ['running', 'review', 'blocked', 'failed', 'kept', 'planned', 'done', 'reverted', 'folded', 'abandoned'];

// A lead's board as the node groups it (BoardValue.groups): what needs someone, what's moving, what waits, what's done.
// The node sends each task's `group`, `state` and `line`; a board without them (the mock's) is read from its status.
export const TASK_GROUPS = [
  { id: 'attention', title: t('wNeedsAttention') },
  { id: 'running', title: t('wRunning') },
  { id: 'waiting', title: t('wWaiting') },
  { id: 'done', title: t('wDoneToday') },
];
const GROUP_OF = { blocked: 'attention', failed: 'attention', running: 'running', review: 'running', planned: 'waiting', kept: 'waiting' };
export const taskGroup = (task) => task.group || GROUP_OF[task.status] || 'done';
export const taskState = (task) => task.state || TASKS[task.status]?.label || task.status;
// The dot's colour: a task that needs attention is red, but a blocked one keeps its own purple.
export function taskTone(task) {
  if (taskGroup(task) === 'attention' && task.status !== 'blocked') return 'needs-you';
  return TASKS[task.status]?.tone || 'idle';
}
// The strip's counts: "1 working", "1 in review", "4 done".
export function taskCount(status, count) {
  const words = { running: 'wCountWorking', review: 'wCountReview', done: 'wCountDone', planned: 'wCountQueued' };
  return words[status] ? t(words[status], { n: count }) : `${count} ${TASKS[status].label.toLowerCase()}`;
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
export const ROLES = { lead: t('wLead'), worker: t('wWorker'), verifier: t('wVerifier') };

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
  return t('wDecided') + (keep ? text : text[0].toLowerCase() + text.slice(1));
}

const OUTCOME_WORDS = { merged: t('wOutMerged'), folded: t('wOutFolded'), abandoned: t('wOutAbandoned'), reverted: t('wOutReverted') };

// A board's all-done card (the board's `allDone`, the app's `AllDoneCard`): its summary, what it cost, "5 tasks · 4
// merged", and each task with how it ended. Null for none.
export function allDoneCard(mark) {
  if (!mark) return null;
  const count = mark.tasks.length;
  return {
    headline: mark.summary?.headline || null,
    bullets: mark.summary?.bullets || [],
    cost: mark.receipts ? t('wCost', { x: mark.receipts }) : null,
    costNote: mark.pricesAsOf ? t('wCostNote', { date: mark.pricesAsOf }) : null,
    count: t('wTasksMerged', { n: count, merged: mark.merged }),
    tasks: mark.tasks.map((task) => ({ title: task.title, word: OUTCOME_WORDS[task.outcome] || task.outcome, merged: task.outcome === 'merged' })),
  };
}

// Boost's mark (the node's `boost`, the app's `BoostMark`): its label and its hover's words while on; null while off.
export function boostMarkText(boost) {
  if (!boost?.on) return null;
  const limits = boost.limits || {};
  return {
    label: t('wBoostOn', { why: boost.why }),
    help: t('wBoostHelp', { why: boost.why, load: limits.loadThreshold, sessions: limits.maxSessions, workers: limits.maxWorkers, slots: limits.heavySlots }),
  };
}
