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
