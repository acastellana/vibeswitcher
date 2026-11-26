// What passes between the user and a project's lead, and the project's shape, read from the node's board and cards
// with no page in it (the redesign, docs/superpowers/specs/2026-11-23-v2-web-ui-design.md): the conversation's lines
// and the dial's counts, the head line a long text shows, a task's five steps and its colour, the team's counts, the
// projects the left column lists and which one opens first. Every string is the sessions' writing, used as text.

// Hashes shortened to eight characters (a commit's 40, a digest's 64).
export function shortHashes(text) {
  return String(text ?? '').replace(/\b([0-9a-f]{8})[0-9a-f]{12,}\b/g, '$1');
}

// Cut at a word, with an ellipsis, to `limit` characters at most.
export function cut(text, limit = 110) {
  const flat = String(text ?? '').replace(/\s+/g, ' ').trim();
  if (flat.length <= limit) return flat;
  const head = flat.slice(0, limit - 1);
  const word = head.replace(/[\s,;:(]+\S*$/, '');
  return (word.length > limit / 2 ? word : head) + '…';
}

// A long text's first sentence (to a full stop, a question mark or the line's end).
export function firstSentence(text) {
  const line = String(text ?? '').trim().split('\n')[0].trim();
  const match = line.match(/^(.+?[?.!])(\s|$)/);
  return match ? match[1] : line;
}

// A question's line: the first sentence that asks (in its first few lines), else its first sentence. "Asked again
// (…):" and markdown's ** and ` are dropped from the line (the sheet shows the whole text as written).
export function questionHead(text) {
  const plain = String(text ?? '').replace(/^\s*Asked again \([^)]*\):\s*/i, '').replace(/\*\*|`/g, '');
  const flat = plain.trim().split('\n').slice(0, 4).join(' ');
  const asks = flat.match(/[^.?!]*\?/g)?.map((one) => one.trim()).find((one) => one.length > 20);
  const head = asks || firstSentence(plain);
  return head.charAt(0).toUpperCase() + head.slice(1);
}

// A question's words past its line, plain (markdown's marks dropped), for the card's few lines of context.
export function contextOf(text, head) {
  const plain = String(text ?? '').replace(/^\s*Asked again \([^)]*\):\s*/i, '').replace(/\*\*|__|`/g, '').replace(/^\s*(?:[-*+]|\d+\.)\s+/gm, '').replace(/^#+\s*/gm, '');
  const flat = plain.replace(/\s+/g, ' ').trim();
  const bare = head.replace(/\s+/g, ' ').trim();
  const at = flat.toLowerCase().indexOf(bare.toLowerCase());
  return shortHashes(at >= 0 ? (flat.slice(0, at) + ' ' + flat.slice(at + bare.length)).replace(/\s+/g, ' ').trim().replace(/^[:;,.\s]+/, '') : flat);
}

// A short, stable key for a line (its kind and the node's id), for the address's `sheet=`.
export function lineKey(kind, id) {
  let hash = 5381;
  for (const char of String(id)) hash = ((hash * 33) ^ char.codePointAt(0)) >>> 0;
  return `${kind[0]}${hash.toString(36)}`;
}

// The conversation's lines, oldest first: the questions the lead asked and their answers (`answered`), its results
// (`results`) and its decisions, which are its status updates (`decisions`). Each:
// { key, kind: 'ask' | 'result' | 'update', at, head, full, answer, state, why }.
export function leadLines(board) {
  if (!board) return [];
  const lines = [];
  for (const question of board.answered || []) {
    lines.push({ key: lineKey('ask', question.id), kind: 'ask', at: question.at, head: questionHead(question.text), full: question.text || '',
      answer: question.state === 'autoDecided' ? question.proposal : question.answer, state: question.state, why: question.why || null,
      // Whether the lead has read the answer (`delivered`: a date, null not yet; absent where the node doesn't say),
      // and what replacing it names (its card and version).
      id: question.id, delivered: 'delivered' in question ? question.delivered : undefined, card: question.card || null, version: question.version ?? null,
      // Whether the node would take `answer.replace` for it now (followed, not taken, a question's, not replaced).
      replaceable: question.replaceable === true });
  }
  for (const result of board.results || []) {
    lines.push({ key: lineKey('result', result.id), kind: 'result', at: result.at, head: firstSentence(result.title), full: result.body || result.title || '', title: result.title });
  }
  for (const decision of board.decisions || []) {
    lines.push({ key: lineKey('update', decision.id), kind: 'update', at: decision.at, head: decision.summary || firstSentence(decision.text), full: decision.text || '', why: decision.why || null });
  }
  return lines.filter((line) => Number.isFinite(Date.parse(line.at))).sort((a, b) => Date.parse(a.at) - Date.parse(b.at));
}

// The lines with the pushes settled from this page among them by time (the waiting block's receipts, `{ id, at, … }`),
// each `{ key, kind: 'push', at, head, outcome }`, `words(receipt)` its line.
export function withPushLines(lines, receipts, words) {
  if (!receipts?.length) return lines;
  return [...lines, ...receipts.map((one) => ({ key: lineKey('push', one.id), kind: 'push', at: one.at, head: words(one), outcome: one.outcome }))]
    .sort((a, b) => Date.parse(a.at) - Date.parse(b.at));
}

// The dial's levels: only what waits on the user, decisions and results (the default), everything.
export function shownLines(lines, level) {
  if (level === 'asks') return [];
  return level === 'all' ? lines : lines.filter((line) => line.kind !== 'update');
}
export function dialCounts(lines, waiting) {
  return { asks: waiting, decisions: lines.filter((line) => line.kind !== 'update').length, all: lines.length };
}

// The cards of `project` that wait on the user, oldest first: questions, approvals, held config, a base move, and a
// plugin's request filed by one of the project's sessions.
export function waitingCards(cards, project) {
  return [...cards].filter((card) => card.project === project && card.open && ['question', 'approval', 'config', 'base', 'plugin'].includes(card.kind))
    .sort((a, b) => Date.parse(a.at) - Date.parse(b.at));
}

// What waits on the user in a project: its open cards and the lead's push.
export function waitingCount(state, project) {
  return waitingCards(state.cards.values(), project).length + (state.leads.get(project)?.push ? 1 : 0);
}

// A task's place on the five steps (queued, working, audit, ready to merge, merged) and its colour, one meaning each:
// working, review, ready, blocked, queued, merged.
// "Ready to merge" is the node's word for a task whose audit passed, in review or running.
const readyToMerge = (task) => ['running', 'review'].includes(task.status) && /ready to merge|merging/i.test(task.state || '');
export function taskStep(task) {
  if (task.status === 'done' || task.status === 'folded') return 5;
  if (readyToMerge(task)) return 4;
  if (task.status === 'review') return 3;
  if (['running', 'blocked', 'failed'].includes(task.status)) return 2;
  return 1;
}
export function taskTone(task) {
  if (task.status === 'blocked' || task.status === 'failed' || task.group === 'attention') return 'blocked';
  if (task.status === 'done' || task.status === 'folded') return 'merged';
  if (readyToMerge(task)) return 'ready';
  if (task.status === 'review') return 'review';
  if (task.status === 'running') return 'working';
  return 'queued';
}

// The board's tasks by where they stand: in motion (the node's `running` group), blocked (`attention`), queued
// (`waiting`, in the lead's order) and merged today.
export function standing(board, now = Date.now()) {
  const tasks = board?.tasks || [];
  const group = (task) => task.group || (['blocked', 'failed'].includes(task.status) ? 'attention' : ['running', 'review'].includes(task.status) ? 'running'
    : ['planned', 'kept'].includes(task.status) ? 'waiting' : 'done');
  const today = (task) => new Date(Date.parse(task.merged?.at || task.since || '') || 0).toDateString() === new Date(now).toDateString();
  return {
    motion: tasks.filter((task) => group(task) === 'running'),
    blocked: tasks.filter((task) => group(task) === 'attention'),
    queued: tasks.filter((task) => group(task) === 'waiting').sort((a, b) => (a.position ?? 1e9) - (b.position ?? 1e9)),
    merged: tasks.filter((task) => group(task) === 'done' && (task.status === 'done' || task.status === 'folded') && today(task)),
  };
}

// The team strip's and the ring's counts, by colour.
export function teamCounts(board, now = Date.now()) {
  const team = standing(board, now);
  const counts = { working: 0, review: 0, ready: 0, blocked: team.blocked.length, queued: team.queued.length, merged: team.merged.length };
  for (const task of team.motion) counts[taskTone(task)] = (counts[taskTone(task)] || 0) + 1;
  return counts;
}

// Whom a blocked task waits on, when the board says: the user (an open card about it), other tasks (`after`), or the
// lead (its blocker's words). { who: 'you' | 'tasks' | 'lead' | null, titles, card }.
export function waitsOn(task, board, cards = []) {
  const card = [...cards].find((one) => one.open && one.question?.task && one.question.task === task.slug);
  if (card) return { who: 'you', card };
  const after = (task.after || []).map((slug) => board?.tasks?.find((other) => other.slug === slug)).filter((other) => other && other.status !== 'done');
  if (after.length) return { who: 'tasks', titles: after.map((other) => other.title) };
  if (task.blocker) return { who: 'lead' };
  return { who: null };
}

// The projects the left column lists: each lead's (the node's order), then each board with no lead. { project, root,
// name, lead, board, waiting, motion, live }.
export function projectsOf(state) {
  const ids = [...new Set([...state.leads.keys(), ...state.boards.keys()])];
  return ids.map((project) => {
    const lead = state.leads.get(project) || null;
    const board = state.boards.get(project) || null;
    const root = lead?.root || board?.root || '';
    const team = standing(board);
    return {
      project, root, name: root.split('/').filter(Boolean).pop() || project, lead, board,
      waiting: waitingCount(state, project), motion: team.motion.length + team.blocked.length,
      live: !!lead?.session && state.sessions.has(lead.session),
    };
  });
}

// The project `#/` opens: the one with the most waiting on the user, else the most recently active, else none.
export function firstProject(projects) {
  if (!projects.length) return null;
  const active = (one) => Math.max(0, ...[...(one.board?.tasks || [])].map((task) => Date.parse(task.since || '') || 0), Date.parse(one.lead?.lastStartAt || '') || 0);
  return [...projects].sort((a, b) => (b.waiting - a.waiting) || (b.live - a.live) || (active(b) - active(a)))[0].project;
}

// The day a line belongs to: 'today', 'yesterday' or the date in the reader's words.
export function dayOf(iso, now = Date.now(), locale = undefined) {
  const at = new Date(iso);
  const today = new Date(now);
  if (at.toDateString() === today.toDateString()) return 'today';
  if (at.toDateString() === new Date(now - 86400000).toDateString()) return 'yesterday';
  return at.toLocaleDateString(locale, { weekday: 'long', day: 'numeric', month: 'short' });
}

// Everything that waits on the user, place by place in the left column's order: each project with something waiting,
// each of the user's own sessions that needs them, and the node's cards no listed project holds (a held config of the
// home folder: This node). { kind: 'project' | 'session' | 'node', id, count }. `own`: whether a session is the user's own.
export function waitingPlaces(state, own) {
  const projects = projectsOf(state);
  const listed = new Set(projects.map((one) => one.project));
  const places = projects.filter((one) => one.waiting).map((one) => ({ kind: 'project', id: one.project, count: one.waiting }));
  const sessionPlace = (id, count) => {
    const found = places.find((place) => place.kind === 'session' && place.id === id);
    if (found) found.count += count; else places.push({ kind: 'session', id, count });
  };
  for (const session of state.sessions.values()) if (own(session) && session.status === 'needs-you') sessionPlace(session.id, 1);
  let elsewhere = 0;
  for (const card of state.cards.values()) {
    if (!card.open || listed.has(card.project)) continue;
    // A plugin's request waits under its asker's chat; one whose asker isn't listed, on This node.
    const asker = card.kind === 'plugin' ? [...state.sessions.keys()].find((id) => id.toLowerCase() === String(card.plugin?.session || '').toLowerCase()) : null;
    if (asker) sessionPlace(asker, state.sessions.get(asker).status === 'needs-you' ? 0 : 1); else elsewhere += 1;
  }
  if (elsewhere) places.push({ kind: 'node', id: null, count: elsewhere });
  return places;
}

// The place to go next from `route`: the first after the one shown, round again; the first when none is shown.
export function nextPlace(places, route) {
  if (!places.length) return null;
  const here = places.findIndex((place) => (place.kind === 'project' && route.name === 'project' && route.id === place.id)
    || (place.kind === 'session' && route.name === 'session' && route.id === place.id) || (place.kind === 'node' && route.name === 'node'));
  return places[(here + 1) % places.length];
}

// The roadmap with goals (the redesign's "The roadmap view"): one row per open goal in the lead's order, then the
// tasks with no goal (or one the board doesn't list) as Unsorted, then the done goals. Each row's tasks in motion first,
// then blocked, queued and merged today. { goal (null: Unsorted), tasks, counts: { motion, blocked, queued, merged } }.
export function goalRows(board, now = Date.now()) {
  const goals = board?.goals || [];
  const team = standing(board, now);
  const order = [...team.motion, ...team.blocked, ...team.queued, ...team.merged];
  const where = (task) => (team.motion.includes(task) ? 'motion' : team.blocked.includes(task) ? 'blocked' : team.queued.includes(task) ? 'queued' : 'merged');
  const known = new Set(goals.map((goal) => goal.id));
  const row = (goal, tasks) => {
    const counts = { motion: 0, blocked: 0, queued: 0, merged: 0 };
    for (const task of tasks) counts[where(task)] += 1;
    return { goal, tasks, counts };
  };
  const open = goals.filter((goal) => goal.state !== 'done').map((goal) => row(goal, order.filter((task) => task.goal === goal.id)));
  const unsorted = order.filter((task) => !task.goal || !known.has(task.goal));
  const done = goals.filter((goal) => goal.state === 'done').map((goal) => row(goal, order.filter((task) => task.goal === goal.id)));
  return { open, unsorted: unsorted.length ? row(null, unsorted) : null, done };
}
