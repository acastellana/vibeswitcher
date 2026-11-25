// A stand-in for the node: it sends the store a snapshot, then deltas on a timer, and answers its requests. The
// WebSocket feed replaces this file; nothing else knows it exists. It plays one small story so the page looks alive:
// a lead's team moves three tasks across its board (workers and verifiers come and go), a question arrives, a
// session finishes its turn. Everything here is invented, and every shape is the one README.md documents.
//
//   ?rows=10000   gives one session a long chat, to see the list and the scroll hold up
//   ?still        sends the snapshot and nothing after it (for screenshots)
//   ?empty        a node with no sessions
//   ?older        a node from before a page could answer a session's question or start one: it lists none of
//                 session.reply, session.new, session.resume and lead (as a node that doesn't take them from a page)
//   ?toggle       the asking session's question is Claude's auto-mode popup, whose second option is a setting toggled
//                 with Space: the node refuses it from a page, as it does there

import { diffOps, summaryOf } from './chatops.js';
import { taskGroup, taskState } from './words.js';

const HOME = '/home/dev';
const SITE = `${HOME}/projects/example-site`;
const API = `${HOME}/projects/example-api`;
const PAYOUTS = `${HOME}/projects/example-payouts`;
const DOCS = `${HOME}/projects/example-docs`;
const SITE_PROJECT = 'local:project:Zx3kQ0aVtLmN';

const id = (n) => `local:${n}-4f6a-4c1e-9b7d-2e5a8c0d1f3b`;
const LEAD = id('7d3c9a10');
const W_SYNC = id('1b8e22f4');
const W_CLEAN = id('5a0c7de9');
const V_CLEAN = id('c2f41b77');
const ASKING = id('e91d05a3');
const WEBHOOKS = id('3f6b8c21');
const DARK = id('a47e9d05');
const PREVIEW = id('0d5c3e88');

const CARD_LAUNCH = 'local:card:5b1f0c3e-8a2d-4e6f-b7c9-1d0a2f3e4b5c';
const CARD_HERO = 'local:card:9e4a7b2c-1f3d-4a5b-8c6e-7f0d1e2a3b4c';
const CARD_APPROVE = 'local:card:2c8d6e0f-3b4a-4c5d-9e7f-0a1b2c3d4e5f';
const COMMIT = '4e1c9a7b2d6f8035a1c4e7b9d2f60813a5c7e9b1';

export function createMock(store, options = {}) {
  const now = () => Date.now();
const ago = (seconds) => new Date(now() - seconds * 1000).toISOString();
  const soon = (seconds) => new Date(now() + seconds * 1000).toISOString();
  let seq = 0;
  let epoch = crypto.randomUUID();
  let counter = 0;
  const next = (prefix) => `${prefix}:${++counter}`;
  const timers = new Set();
  const subscribed = new Set();
  // Each followed chat as last sent, in the wire's items: a change is sent as the ops from it, as the node sends them.
  const sentChats = new Map();

  // ---- The node's state, as the server would hold it ----

  // Every fact the inspector's Overview can show, so the mock shows the finished look. The node sends the first rows
  // today; `branch`, `agentSession`, `pid`, `command` and `size` are asked of it (README.md, "Session").
  const session = (sid, fields) => {
    const agent = fields.agent || 'claude';
    const hosted = fields.hosted !== false;
    const hex = /^[0-9a-f]{8}$/.test(sid.slice(6, 14)) ? sid.slice(6, 14) : 'c7e40b18';
    return {
      id: sid, terminal: 'pts/' + (3 + sessions.size), agent, cwd: SITE, status: 'idle', since: ago(60), hosted, role: null,
      title: null, detail: null, paused: false, lead: null, task: null, prompt: null, draft: null, queued: [],
      startedAt: fields.since || ago(60), activity: null, activitySince: null, branch: 'main',
      agentSession: `${hex.split('').reverse().join('')}-0c2e-4a71-b3d5-9f6e8a1c2b40`, pid: 51022 + 37 * sessions.size,
      command: hosted ? agent : null, size: hosted ? { cols: 132, rows: 38 } : null, hasTranscript: true,
      // The node's facts the views don't show (WebApp/tests/mock.test.mjs holds the mock to the wire's shapes).
      project: SITE_PROJECT, hasHooks: true, leadAsks: false, startFolder: null, backgroundJobs: 0, ...fields,
      // A worker's or verifier's task by its slug on the board (the node's `boardTask`; its `task` is words).
      boardTask: fields.boardTask ?? (fields.role && fields.role !== 'lead' ? fields.task : null),
    };
  };
  const sessions = new Map();
  const add = (sid, fields) => sessions.set(sid, session(sid, fields));
  if (!options.empty) {
    add(LEAD, { sendWays: ['step', 'now', 'interrupt'], status: 'needs-you', since: ago(39), startedAt: ago(5400), role: 'lead', lead: SITE_PROJECT, branch: 'landing-base', title: 'Sync the landing pages and finish the sidebar review' });
    add(W_SYNC, { status: 'working', since: ago(252), role: 'worker', lead: SITE_PROJECT, task: 'sync-landing-base', branch: 'agent/sync-landing-base', title: 'Sync landing-base with main', detail: 'Resolving the hero’s conflicts', activity: 'Edit pages/hero.html', activitySince: ago(12) });
    add(W_CLEAN, { agent: 'codex', status: 'idle', since: ago(130), startedAt: ago(1300), role: 'worker', lead: SITE_PROJECT, task: 'cleanup-ended-folders', branch: 'agent/cleanup-ended-folders', title: 'Clean up ended sessions’ folders' });
    add(V_CLEAN, { status: 'working', since: ago(118), role: 'verifier', lead: SITE_PROJECT, task: 'cleanup-ended-folders', branch: 'agent/cleanup-ended-folders', title: 'Clean up ended sessions’ folders', detail: 'Checking the work', activity: 'Read tools/cleanup.py', activitySince: ago(60) });
    // Its own question, as the node reads it off the session's screen (`prompt`, SessionPrompt.value), and a message
    // drafted for it on a page (`draft`, session.draft).
    add(ASKING, { cwd: API, status: 'needs-you', since: ago(20), startedAt: ago(140), title: 'Why does the payout job run twice?', detail: 'Bash: pytest tests/test_payouts.py',
      prompt: options.toggle
        ? { question: 'Auto mode lets Claude run commands without asking first.', options: ['Continue', 'Also scan shell history'], descriptions: [null, 'on'], text: [], multiSelect: false, at: ago(20) }
        : { question: 'Bash command\n  pytest tests/test_payouts.py\nDo you want to proceed?', options: ['Yes', 'Yes, and don’t ask again for this command', 'No, and tell Claude what to do differently (esc)'],
          descriptions: [null, null, null], text: [], multiSelect: false, at: ago(20) },
      draft: { text: 'Once the tests pass, also add one for two regions at once.', images: [], at: ago(8), action: 'mock-draft' },
      queued: [{ text: 'And keep the old job name in the logs.', images: 0, at: ago(5), action: 'mock-queued' }] });
    add(WEBHOOKS, { agent: 'codex', cwd: PAYOUTS, status: 'working', since: ago(95), startedAt: ago(400), branch: 'retry-webhooks', title: 'Retry failed bank webhooks', detail: 'Running the retry tests', activity: 'pytest tests/test_webhook_retry.py', activitySince: ago(95) });
    add(DARK, { status: 'done', since: ago(380), startedAt: ago(1900), branch: 'settings-dark-mode', title: 'Add dark mode to the settings page' });
    add(PREVIEW, { cwd: DOCS, status: 'background', since: ago(720), startedAt: ago(760), title: 'Preview the docs site', detail: '1 shell · 12m: npm run dev' });
    add('local:pts/9', { cwd: DOCS, status: 'idle', since: ago(5400), startedAt: ago(5600), hosted: false, terminal: 'pts/9', pid: 40312, title: 'Tidy the README' });
  }

  const leads = new Map(options.empty ? [] : [[SITE_PROJECT, {
    project: SITE_PROJECT, root: SITE, session: LEAD, named: null, bound: LEAD, replaced: [], held: 0, reportsWaiting: 0, notice: null,
    starting: false, lastStart: null, lastStartAt: ago(5400), looks: 14, questions: { open: 1, blocking: 1 }, cards: [CARD_LAUNCH],
    // What the user told the lead (by action), and whether it has read it (the node's `delivered`).
    told: [],
    // The push the lead asked for (push_remote), open: its card in the lead's chat drafts the two lines that settle it.
    push: { id: '3c9e1f20', commit: 'c41d7e09b2a65f38d1e0c7b94a2f6e1d3b8c5a70', short: 'c41d7e09', branch: 'landing-base', remote: 'origin',
      target: 'origin/landing-base', url: 'git@example.invalid:example-site.git', ahead: 2,
      subjects: ['c41d7e0 Landing copy', '9b2a65f Hero image'], askedAt: ago(600) },
  }]]);

  // A task in the node's shape (BoardValue.task): its group and state as the node words them, its last checkpoint.
  let position = 0;
  const task = (slug, title, status, fields = {}) => {
    const value = { id: slug, slug, title, status, since: ago(300), worker: null, verifier: null, branch: 'agent/' + slug, after: [], checkpoints: [], blocker: null, merged: null,
      summary: null, line: null, review: status === 'review' ? 'audit' : 'none', position: position++, createdAt: ago(7200), startedAt: status === 'planned' ? null : ago(3600),
      attempts: status === 'planned' ? 0 : 1, budgetMin: null, overBudget: false, audit: null, ...fields };
    return { ...value, group: taskGroup(value), state: taskState(value), checkpoint: value.checkpoints.at(-1) || null };
  };
  const boards = new Map(options.empty ? [] : [[SITE_PROJECT, {
    project: SITE_PROJECT, root: SITE, baseBranch: 'landing-base', more: 0, unreadable: null, allDone: null,
    counts: { attention: 1, running: 2, waiting: 1, done: 2 },
    score: { estimated: 3, ratioPct: 140, insideWorstPct: 67, enough: false, correctionPct: 100, clamped: false, medianMin: 75, line: 'Estimates: fewer than 5 estimated merges here (3), so the dates are the workers’ own, uncorrected.' },
    // The lead's goals (the node's `goals`), each task's `goal`.
    goals: [
      { id: 'landing', title: 'The new landing page is live', done: 'The hero, copy and footer are on main and on the site', state: 'open', toGo: 2, finished: 1, forecast: { basis: 'estimated', likely: soon(2400), worst: soon(5400), waitsOn: null, overdueMin: null, over: false, undated: 0 } },
      { id: 'reliable', title: 'Uploads and sessions never lose work', done: 'Uploads retry and ended sessions leave nothing behind', state: 'open', toGo: 2, finished: 0, forecast: { basis: 'partial', likely: soon(600), worst: soon(2100), waitsOn: null, overdueMin: null, over: false, undated: 1 } },
      { id: 'speed', title: 'Pages load fast', done: 'Static assets are cached', state: 'done', toGo: 0, finished: 1 },
    ],
    tasks: [
      task('sync-landing-base', 'Sync landing-base with main', 'running', { estimate: { likelyMin: 40, worstMin: 90, at: ago(1200), by: 'worker' }, forecast: { basis: 'estimated', likely: soon(2400), worst: soon(5400), waitsOn: null, overdueMin: null, over: false, undated: 0 }, goal: 'landing', since: ago(252), worker: W_SYNC, checkpoints: [{ text: 'Rebased onto main; resolving the hero’s conflicts', at: ago(70) }],
        summary: 'Fixing the landing page’s clashes with the latest main' }),
      task('cleanup-ended-folders', 'Clean up ended sessions’ folders', 'review', { estimate: { likelyMin: 20, worstMin: 45, at: ago(2400), by: 'worker' }, forecast: { basis: 'estimated', likely: soon(600), worst: soon(2100), waitsOn: null, overdueMin: null, over: true, undated: 0 }, goal: 'reliable', since: ago(118), worker: W_CLEAN, verifier: V_CLEAN, checkpoints: [{ text: 'Raised to audit: it has code that deletes files', at: ago(118) }] }),
      task('flaky-upload-test', 'Fix the flaky upload test', 'blocked', { forecast: { basis: 'blocked', likely: null, worst: null, waitsOn: 'Sync landing-base with main', overdueMin: null, over: false, undated: 0 }, goal: 'reliable', since: ago(1080), after: ['sync-landing-base'] }),
      task('sidebar-consistency', 'UI consistency pass over the sidebar', 'planned', { estimate: { likelyMin: 60, worstMin: 150, at: ago(4000), by: 'lead' }, forecast: { basis: 'estimated', likely: soon(6000), worst: soon(14400), waitsOn: null, overdueMin: null, over: false, undated: 0 }, since: ago(1500) }),
      task('cache-static-assets', 'Cache the static assets', 'done', { goal: 'speed', since: ago(2400), merged: { commit: '8a3f1e2', at: ago(2400), tested: true } }),
      task('footer-links', 'Fix the footer links', 'done', { goal: 'landing', since: ago(3900), merged: { commit: 'c41d7b9', at: ago(3900), tested: true } }),
    ],
    // The Team tab's records (the node's `BoardRecords`).
    scorecard: { merged: 2, reverts: 0, mergedWithoutTests: 0, footnote: 'Over 2 merged tasks.', receipts: 'This batch: 2 tasks, 1.4 h of worker time, 3.1M tokens, est. $4.80; most expensive: Cache the static assets (est. $3.10).',
      tiles: [{ value: '1.5', label: 'audit rounds to pass', note: null, help: 'The mean audit rounds a merged task took to pass.' },
        { value: '—', label: 'pass the first audit', note: 'too few audited tasks (2)', help: 'The share of merged tasks that passed their first audit.' },
        { value: '3 min', label: 'of yours per merged task', note: null, help: 'The minutes a merged task waited on you.' },
        { value: '0', label: 'reverts', note: null, help: 'Merges undone since.' }] },
    decisions: [
      { id: 'mock-decision-1', summary: 'Keep the new hero', at: ago(600), text: 'Keep the new hero and drop the old one', why: 'Both were half done; the new one passes the page tests and marketing asked for it.' },
      { id: 'mock-decision-2', summary: null, at: ago(2000), text: 'Cache the assets for a year with hashed names', why: 'A new build changes every name, so nothing stale is ever served.' },
      { id: 'mock-decision-3', summary: null, at: ago(5000), text: 'Sync landing-base before the sidebar pass', why: 'The pass touches the same files; syncing first saves a second merge.' },
      { id: 'mock-decision-4', summary: null, at: ago(9000), text: 'Run the page tests on every merge', why: 'Two merges broke the hero last week.' },
    ],
    answered: [
      { id: 'q-cache', state: 'answered', text: 'Cache for a day or a year?', answer: 'A year, with hashed names', proposal: null, why: null, reworded: false, task: 'cache-static-assets', at: ago(2100), delivered: ago(2000) },
      { id: 'q-footer', state: 'withdrawn', text: 'Should the footer link to the old blog?', answer: null, proposal: null, why: 'The blog moved; the link goes to the new one.', reworded: false, task: null, at: ago(4000) },
    ],
    files: [
      { name: 'workflow.md', path: '.vibeswitcher/workflow.md', present: true }, { name: 'decisions.md', path: 'docs/lead/decisions.md', present: true },
      { name: 'progress.md', path: 'docs/lead/progress.md', present: true }, { name: 'incidents.md', path: 'docs/lead/incidents.md', present: false },
    ],
    recordsDir: 'docs/lead',
    // The lead's Results (the node's `BoardDetails.results`), newest first.
    results: [
      { id: 'mock-result-2', title: 'Static assets cached', body: 'Every asset now has a **hashed name** and a year of cache.\n\n- `index.html` stays uncached\n- old names keep working for a day', at: ago(2300), images: 1 },
      { id: 'mock-result-1', title: 'Footer links fixed', body: 'All five links point at the new pages.', at: ago(3800), images: 0 },
    ],
  }]]);

  const cards = new Map(options.empty ? [] : [[CARD_LAUNCH, {
    id: CARD_LAUNCH, kind: 'question', project: SITE_PROJECT, root: SITE, open: true, closed: null, notice: null, at: ago(900), blocking: true, draft: null,
    question: {
      id: 'q-launch-day', short: 'q-launch', text: 'Launch to the testers on Thursday, or wait for the sidebar fixes?', options: ['Thursday', 'Wait for the fixes'],
      priority: 'blocking', whyNow: 'The testers’ invite goes out tomorrow morning.', version: 2, revisionNote: 'Only the testers get it first',
      proposal: null, decideBy: null, state: 'open', answer: null, answeredVersion: null, withdrawReason: null, task: null,
    },
  }]]);

  // The account's usage (`NodeUsage.value`): the weekly limit past the threshold, the 5-hour well under it.
  const usage = {
    account: 'u…@example.invalid', ignored: false, threshold: 80, fableHeldBack: null,
    limits: [
      { name: 'seven_day', label: 'the weekly limit', model: null, usedPercent: 84, reached: false, resetsAt: ago(-2 * 86400), holds: true, text: 'the weekly limit (every model): 84% used' },
      { name: 'five_hour', label: 'the 5-hour limit', model: null, usedPercent: 31, reached: false, resetsAt: ago(-3 * 3600), holds: false, text: 'the 5-hour limit (every model): 31% used' },
    ],
  };

  const node = {
    usage,
    boost: { mode: 'on', on: true, why: 'on in Settings', limits: { loadThreshold: '48', maxSessions: 16, maxWorkers: 6, heavySlots: 4 } },
    health: {
      since: ago(3 * 3600 + 720), stalled: null, refreshing: null, freezes: [{ at: ago(5400), seconds: 14 }], slowRefreshes: 2, slowestRefresh: 7,
      lastSlowRefresh: ago(1800), serverRestarts: 0, refusedConnections: null, hostRestartAt: null, serverEnded: null, waiting: [],
      errors: [{ at: ago(900), line: 'prompt audit: /home/u/.vibeswitcher/prompt-audit.json not written: disk full' }],
      causes: [{ kind: 'prompt audit: not written', count: 1, last: ago(900) }],
    },
    node: 'local', epoch, root: `${HOME}/.vibeswitcher`, home: HOME,
    server: { pid: 48213, startedAt: ago(3 * 3600 + 720), commit: 'f62aef61' },
    host: {
      pid: 48190, startedAt: ago(2 * 86400 + 5 * 3600), state: 'connected', liveSessions: sessions.size - 1,
      notes: { startedAt: ago(2 * 86400 + 5 * 3600), serverRestarts: 3, replacedPaths: [], refusedAppConnections: 0, lockHeldElsewhere: null, build: 'f62aef61', at: ago(4) },
    },
    rule: { mode: 'systemd', says: 'a request is the user’s when its process is in a terminal’s scope of this login', scopes: ['init.scope', 'session-*.scope'] },
    cards: { questions: 1, approvals: 0, config: 0, base: 0 },
    accepted: [{ kind: 'lead', action: 'b7e0c2d4-5a61-4f38-9c0b-1e2d3f4a5b6c', subject: SITE, at: ago(5400), pid: 51022, cgroup: '/init.scope', commandLine: ['vibeswitcher', 'lead', SITE] }],
    notices: options.empty ? [] : ['example-site: landing-base moved outside the lead’s merges; its next merge is refused until you accept the move'],
    restart: null,
    reopen: [],
    ending: [],
    // Pages acting for the user (`web_acts` on) since an hour ago.
    web: { state: 'listening', port: 8765, tokens: 1, connections: 1, acts: { on: true, since: ago(3600), pages: 1 } },
    // The update watch's last look (`UpdateWatch.value`): up to date six hours ago.
    update: { checkedAt: ago(6 * 3600), commit: null, aheadBy: null, install: null, problem: null, running: 'f62aef61' },
    // Your sessions that ended lately (`vibeswitcher resume`).
    ended: [
      { session: id('5c1e7a92'), folder: `${HOME}/projects/example-api`, name: 'example-api', conversation: '7a3f0c21-9b4d-4e8a-a1f2-3c5d7e9b0a14', at: ago(1500), exit: { status: 0, cause: 'exited 0', at: ago(1510) } },
      { session: id('9d2b4f60'), folder: `${HOME}/projects/notes`, name: 'Tidy the notes', conversation: null, at: ago(7200), exit: null },
    ],
    builds: { installRoot: `${HOME}/.local/share/vibeswitcher`, installed: ['f62aef61', '200e2c32', '5e563cf5'], rollback: { commit: '200e2c32', line: '200e2c32 v2 journal: an entry with no cgroup softens no mark' } },
    facts: [
      'plain mode: no sandbox before stage 6; what that doesn’t promise is S11’s list (`vibeswitcher start` prints it once)',
      'interop: off',
      'automount: off',
      'the manager’s environment: nothing beyond the expected',
    ],
    journal: ['journal: the node’s last start at ' + ago(2 * 86400 + 5 * 3600) + ': started by `vibeswitcher start`'],
    format: 1,
  };

  // ---- Chats ----

  const chats = new Map();
  const prompt = (text, at, images = []) => ({ id: next('m'), kind: 'prompt', text, at: ago(at), images });
  // A screenshot pasted into a prompt (`chat.image` serves its bytes, a 48 × 32 checker drawn for the mock).
  const SHOT = { id: 'mock-shot-1', mediaType: 'image/png', bytes: 1268 };
  const SHOT_DATA = 'iVBORw0KGgoAAAANSUhEUgAAADAAAAAgCAYAAABU1PscAAAEu0lEQVR42q3XsQsaeRrH4fw5Ka6wsLCwsLC44goLCwsLC4sr5DAwEAkGhJXlAgORYGBgJRgYiAQDA5FgYCASDAyshYWFhYWFXHXt1XvPX7B5iy2e7vsyfKof8+Tpv6o//kaNOg2atGjzn//+70/902bEmIQJU2bMA/cbmy0FO/aUHDgG7p88fSaAGnUaNGnRfhYIsBkxJmHClBnzwP3GZkvBjj0lB47PIgGJAGrUadCkRTsJBNiMGJMwYcqMeeB+Y7OlYMeekgPHJBLwXAA16jRo0qL9PBBgM2JMwoQpM+aB+43NloIde0oOHJ9HAl4IoEadBk1atF8EAmxGjEmYMGXGPHC/sdlSsGNPyYHji0jASwHUqNOgSYv2y0CAzYgxCROmzJgH7jc2Wwp27Ck5cHwZCZgJoEadBk1atGeBAJsRYxImTJkxD9xvbLYU7NhTcuA4iwT8IoAadRo0adH+JRBgM2JMwoQpM+aB+43NloIde0oOHAP3T342+Puv1R//oEOXHn0GDH/9+Qf+bZOyYEnGijV54L6yOXHmwpUbdx78POCVADp06dFnwPBVIMAmZcGSjBVr8sB9ZXPizIUrN+48XkUCUgF06NKjz4BhGgiwSVmwJGPFmjxwX9mcOHPhyo07jzQS8FoAHbr06DNg+DoQYJOyYEnGijV54L6yOXHmwpUbdx6vIwFvBNChS48+A4ZvAgE2KQuWZKxYkwfuK5sTZy5cuXHn8SYS8FYAHbr06DNg+DYQYJOyYEnGijV54L6yOXHmwpUbdx5vIwGZADp06dFnwDALBNikLFiSsWJNHrivbE6cuXDlxp1HFgn4TQAduvToM2D4WyDAJmXBkowVa/LAfWVz4syFKzfuPHjy9J2HjBp1GjRp0X4XeMhsRoxJmDBlxjxwv7HZUrBjT8mB47vIS/xeADXqNGjSov0+EGAzYkzChCkz5oH7jc2Wgh17Sg4c30cCcgHUqNOgSYt2HgiwGTEmYcKUGfPA/cZmS8GOPSUHjnkk4IMAatRp0KRF+0MgwGbEmIQJU2bMA/cbmy0FO/aUHDh+iAR8FECNOg2atGh/DATYjBiTMGHKjHngfmOzpWDHnpIDx4+RgE8CqFGnQZMW7U+BAJsRYxImTJkxD9xvbLYU7NhTcuD4KRJQCKBGnQZNWrSLQIDNiDEJE6bMmAfuNzZbCnbsKTlwLCIBnwVQo06DJi3anwMBNiPGJEyYMmMeuN/YbCnYsafkwPHzX/E/8MVDRocuPfoMGH4JPGQ2KQuWZKxYkwfuK5sTZy5cuXHn8SXyEn8VQIcuPfoMGH4NBNikLFiSsWJNHrivbE6cuXDlxp3H10hAKYAOXXr0GTAsAwE2KQuWZKxYkwfuK5sTZy5cuXHnUUYCvgmgQ5cefQYMvwUCbFIWLMlYsSYP3Fc2J85cuHLjzuNbJOC7ADp06dFnwPB7IMAmZcGSjBVr8sB9ZXPizIUrN+48vkcCfgigQ5cefQYMfwQCbFIWLMlYsSYP3Fc2J85cuHLjzuNHJKASQIcuPfoMGFaBAJuUBUsyVqzJA/eVzYkzF67cuPOoIgG/C6BDlx59Bgx/DwTYpCxYkrFiTR64r2xOnLlw5cadB/8HtiAPrSfGKF8AAAAASUVORK5CYII=';
  const reply = (text, at) => ({ id: next('m'), kind: 'reply', text, at: ago(at) });
  const tool = (name, title, detail, at, result = { output: '', failed: false, at: ago(at - 1) }) => ({ id: next('t'), kind: 'tool', name, title, detail, at: ago(at), result });
  const command = (line, output, at, result) => tool('Bash', line, { type: 'command', command: line }, at, result === undefined ? { output, failed: false, at: ago(at - 2) } : result);
  const read = (path, at) => tool('Read', 'Read ' + path.split('/').pop(), { type: 'read', path }, at);
  const edit = (path, changes, at) => tool('Edit', 'Edit ' + path.split('/').pop(), { type: 'edit', path, changes }, at);

  const RETRY_OLD = 'def deliver(event):\n    response = post(event.url, event.body)\n    if response.status >= 500:\n        log.warning("webhook failed", event.id)\n    return response';
  const RETRY_NEW = 'def deliver(event, attempt=1):\n    response = post(event.url, event.body)\n    if response.status >= 500 and attempt < MAX_ATTEMPTS:\n        queue.later(deliver, event, attempt + 1, delay=backoff(attempt))\n    elif response.status >= 500:\n        log.warning("webhook failed for good", event.id)\n    return response';

  if (!options.empty) {
    chats.set(ASKING, [
      prompt('Why does the payout job run twice? Here is the dashboard.', 140, [SHOT]),
      command('git log --oneline -5 -- jobs/payouts.py', '9c2e1d4 payouts: one worker per region\n51b0a77 payouts: read the schedule from the store\n0e8f3c2 payouts: nightly run', 132),
      read(`${API}/jobs/payouts.py`, 128),
      read(`${API}/jobs/scheduler.py`, 126),
      reply('The job takes its lock after it reads the schedule, so two workers can both see a run as due:\n\n- the scheduler starts one worker per region\n- each reads the schedule before it takes the lock\n- the second to get the lock runs the job again\n\nThe fix is to take the lock first, in `jobs/payouts.py`. Running its tests before I change it.', 60),
      command('pytest tests/test_payouts.py', '', 21, null),
    ]);
    chats.set(LEAD, [
      prompt('Sync the landing pages and finish the sidebar review.', 5400),
      tool('Read', 'Read workflow.md', { type: 'read', path: `${SITE}/.vibeswitcher/workflow.md` }, 5390),
      reply('Six tasks on the board. Two are independent and start now; the upload test waits on the sync, and the sidebar pass comes after the review.', 5370),
      command('git merge --no-ff agent/footer-links', 'Merge made by the ‘ort’ strategy.\n pages/footer.html | 8 ++++----\n 1 file changed, 4 insertions(+), 4 deletions(-)', 3900),
      edit(`${SITE}/docs/lead/progress.md`, [{ old: '## Merged', new: '## Merged\n\n- footer-links: the footer’s links point at the new pages (c41d7b9)' }], 3895),
      command('git merge --no-ff agent/cache-static-assets', 'Merge made by the ‘ort’ strategy.\n 3 files changed, 41 insertions(+), 6 deletions(-)', 2400),
      edit(`${SITE}/docs/lead/progress.md`, [{ old: '(c41d7b9)', new: '(c41d7b9)\n- cache-static-assets: static assets are cached for a year, by content hash (8a3f1e2)' }], 2395),
      { id: next('n'), kind: 'team', from: 'worker', title: 'Question from the worker on sidebar-consistency', text: 'Should the unread badge show 99+ past 99, or the exact count?', at: ago(1500) },
      reply('Told it 99+. The static assets and the footer links are merged; the sync and the clean-up are moving.', 1490),
      { id: next('n'), kind: 'team', from: 'worker', title: 'Report from the worker on cleanup-ended-folders', text: 'Ended sessions’ folders are removed after 7 days, and never one a live session points at. Tests added; ready for review.', at: ago(125) },
      reply('The clean-up deletes files, so it gets an audit before it merges. One thing I need from you is below.', 118),
    ]);
    chats.set(W_SYNC, [
      prompt('Task sync-landing-base: bring landing-base up to main, keep the new hero, and get the page tests green. Report when it’s ready for review.', 252),
      command('git fetch origin && git rebase origin/main', 'Auto-merging pages/hero.html\nCONFLICT (content): Merge conflict in pages/hero.html\nerror: could not apply 3d9e0a1... hero: new headline', 240),
      read(`${SITE}/pages/hero.html`, 200),
      reply('One conflict, in `pages/hero.html`: main renamed the headline’s class while this branch reworded it. Keeping the new wording on the new class.', 70),
    ]);
    chats.set(W_CLEAN, [
      prompt('Task cleanup-ended-folders: remove the folders of sessions that ended more than 7 days ago. Never touch a folder a live session points at.', 1300),
      edit(`${SITE}/tools/cleanup.py`, [{ old: 'for folder in ended:\n    remove(folder)', new: 'for folder in ended:\n    if folder in live_folders():\n        continue\n    if age(folder) < KEEP_DAYS:\n        continue\n    remove(folder)' }], 700),
      command('pytest tests/test_cleanup.py', '6 passed in 0.41s', 300),
      reply('Done: ended sessions’ folders go after 7 days, and a folder a live session points at is skipped. Six tests cover both.', 130),
    ]);
    chats.set(V_CLEAN, [
      prompt('Audit cleanup-ended-folders at its branch’s commit. Say whether it does what its contract says, and whether anything else changed.', 118),
      command('git diff landing-base...agent/cleanup-ended-folders --stat', ' tools/cleanup.py            | 14 +++++++++-----\n tests/test_cleanup.py       | 61 +++++++++++++++++++++++++++++++\n 2 files changed, 70 insertions(+), 5 deletions(-)', 100),
      read(`${SITE}/tools/cleanup.py`, 60),
    ]);
    chats.set(WEBHOOKS, [
      prompt('Bank webhooks that fail are dropped. Retry them with a backoff, five times at most.', 400),
      read(`${PAYOUTS}/webhooks/deliver.py`, 380),
      edit(`${PAYOUTS}/webhooks/deliver.py`, [{ old: RETRY_OLD, new: RETRY_NEW }], 300),
      reply('`deliver` now queues itself again on a 5xx, with a backoff that doubles from 30 s, and gives up after `MAX_ATTEMPTS` (5). Running the retry tests.', 110),
      command('pytest tests/test_webhook_retry.py', '', 95, null),
    ]);
    chats.set(DARK, [
      prompt('Add dark mode to the settings page.', 1900),
      read(`${SITE}/pages/settings.css`, 1880),
      edit(`${SITE}/pages/settings.css`, [{ old: ':root {\n  --page: #ffffff;\n  --ink: #1d1d1f;\n}', new: ':root {\n  color-scheme: light dark;\n  --page: #ffffff;\n  --ink: #1d1d1f;\n}\n@media (prefers-color-scheme: dark) {\n  :root {\n    --page: #1c1c1e;\n    --ink: #f2f2f4;\n  }\n}' }], 900),
      command('npm test -- settings', 'PASS  tests/settings.test.js\n  ✓ follows the system setting (41 ms)\n  ✓ keeps contrast at 4.5:1 in both (12 ms)', 420),
      reply('The settings page follows the system setting now. Its colours are two variables, redefined under `prefers-color-scheme: dark`; the tests check both and the contrast.', 380),
    ]);
    chats.set(PREVIEW, [
      prompt('Start the docs preview and leave it running.', 760),
      command('npm run dev', '> docs@1.0.0 dev\n> vite --port 5173\n\n  Local:   http://127.0.0.1:5173/', 740),
      reply('The preview is running on port 5173 in a background shell. I’ll leave it up.', 720),
    ]);
    chats.set('local:pts/9', [
      prompt('Tidy the README: shorter intro, and the install steps as a list.', 5600),
      edit(`${DOCS}/README.md`, [{ old: 'To install it you first need to clone it and then run the installer.', new: '1. Clone the repository.\n2. Run `./install.sh`.' }], 5450),
      reply('Shorter intro, and the install steps are a list of two.', 5400),
    ]);
    if (options.rows) {
      const long = chats.get(DARK);
      const first = long.shift();
      const filler = [];
      for (let i = 0; i < options.rows; i++) {
        filler.push(i % 3 === 0 ? prompt(`Earlier request ${i / 3 + 1}: check the contrast of token ${i}.`, 90000 - i)
          : i % 3 === 1 ? command(`npm test -- contrast-${i}`, `PASS contrast-${i}`, 90000 - i)
          : reply(`Token ${i} passes at 4.5:1 in light and dark.`, 90000 - i));
      }
      chats.set(DARK, [...filler, first, ...long]);
    }
  }

  // ---- Sending ----

  function later(ms, work) {
    const timer = setTimeout(() => { timers.delete(timer); work(); }, ms);
    timers.add(timer);
    return timer;
  }

  function snapshot() {
    node.epoch = epoch;
    return {
      v: 1, kind: 'snapshot', epoch, seq,
      state: { node: structuredClone(node), sessions: clone(sessions), leads: clone(leads), cards: clone(cards), boards: clone(boards) },
    };
  }
  const clone = (map) => [...map.values()].map((value) => structuredClone(value));

  // The changes go out as one delta, as the server batches them; a chat's as its ops, only to who follows it.
  function emit(...changes) {
    if (down) return;
    const sent = changes.filter((change) => change && change.in !== 'chat');
    for (const sid of new Set(changes.filter((change) => change?.in === 'chat').map((change) => change.session))) sendChat(sid);
    if (!sent.length) return;
    seq += 1;
    store.apply({ v: 1, kind: 'delta', seq, changes: structuredClone(sent) });
  }

  // A followed chat's change: the ops from what was sent last to the chat now.
  function sendChat(sid) {
    if (!subscribed.has(sid)) return;
    const now = wireChat(chats.get(sid) || []);
    const ops = diffOps(sentChats.get(sid) || [], now);
    sentChats.set(sid, now);
    if (ops.length) store.chatOps(sid, structuredClone(ops));
  }

  // The mock's chat items as the wire's (the contract §6): each run of tool calls one `tools` item.
  function wireChat(items) {
    const out = [];
    let run = null;
    for (const item of items) {
      if (item.kind === 'tool') {
        const tool = { id: item.id, name: item.name, title: item.title, at: item.at, detail: item.detail,
          result: item.result ? { output: item.result.output, truncated: false, failed: !!item.result.failed, at: item.result.at, images: [] } : null };
        if (!run) out.push(run = { id: 'tools:' + item.id, type: 'tools', at: item.at, summary: '', tools: [] });
        run.tools.push(tool);
        run.summary = summaryOf(run.tools);
        continue;
      }
      run = null;
      if (item.kind === 'prompt') {
        out.push({ id: item.id, type: 'prompt', at: item.at, text: item.text, steered: false, fromLead: false, images: item.images || [], ...(item.action ? { action: item.action } : {}) });
      } else if (item.kind === 'reply') {
        out.push({ id: item.id, type: 'reply', at: item.at, text: item.text, ...(item.streaming ? { streaming: true } : {}) });
      } else if (item.kind === 'team') {
        out.push({ id: item.id, type: 'team', at: item.at, text: item.text, title: item.title, sender: { kind: 'vibeSwitcher', name: `${item.from} ${item.title}`, task: null },
          message: 'report', task: null, part: null });
      } else {
        out.push({ ...item, type: item.kind });
      }
    }
    return out;
  }

  const put = (name, map, key) => ({ in: name, id: key, value: map.get(key) ?? null });

  function setSession(sid, fields) {
    const current = sessions.get(sid);
    if (!current) return null;
    Object.assign(current, fields);
    return put('sessions', sessions, sid);
  }

  // The lead's counts and status from its open cards: it needs you while one asks, else `resting`.
  function refreshLead(resting = 'working') {
    const lead = leads.get(SITE_PROJECT);
    if (!lead) return [];
    const open = [...cards.values()].filter((card) => card.open && card.project === SITE_PROJECT);
    const asks = open.filter((card) => card.kind === 'question' || card.kind === 'approval');
    lead.questions = { open: asks.length, blocking: asks.filter((card) => card.blocking).length };
    lead.cards = open.map((card) => card.id);
    node.cards = { questions: open.filter((c) => c.kind === 'question').length, approvals: open.filter((c) => c.kind === 'approval').length, config: 0, base: 0 };
    const changes = [put('leads', leads, SITE_PROJECT), { in: 'node', id: 'local', value: node }];
    const wanted = asks.length ? 'needs-you' : resting;
    if (sessions.get(LEAD)?.status !== wanted) changes.push(setSession(LEAD, { status: wanted, since: new Date().toISOString() }));
    return changes;
  }

  function chatPut(sid, item) {
    if (!chats.has(sid)) chats.set(sid, []);
    const items = chats.get(sid);
    const at = items.findIndex((existing) => existing.id === item.id);
    if (at >= 0) items[at] = item; else items.push(item);
    return { in: 'chat', session: sid, id: item.id, value: item };
  }

  // A reply that arrives a few words at a time, then whole.
  function stream(sid, text, done) {
    const item = { id: next('m'), kind: 'reply', text: '', at: new Date().toISOString(), streaming: true };
    emit(chatPut(sid, item));
    const words = text.split(/(?<=\s)/);
    let at = 0;
    const step = () => {
      if (!sessions.has(sid)) return;
      const more = words.slice(at, at + 3).join('');
      at += 3;
      item.text += more;
      emit({ in: 'chat', session: sid, id: item.id, append: { text: more } });
      if (at < words.length) later(70, step);
      else {
        item.streaming = false;
        emit(chatPut(sid, item));
        done?.();
      }
    };
    later(120, step);
  }

  // A command that runs for a while, then shows its output.
  function run(sid, line, output, ms, done, failed = false) {
    const item = { id: next('t'), kind: 'tool', name: 'Bash', title: line, detail: { type: 'command', command: line }, at: new Date().toISOString(), result: null };
    emit(chatPut(sid, item), setSession(sid, { detail: line, activity: line, activitySince: item.at }));
    later(ms, () => {
      if (!sessions.has(sid)) return;
      item.result = { output, failed, at: new Date().toISOString() };
      emit(chatPut(sid, item), setSession(sid, { activity: null, activitySince: null }));
      done?.();
    });
  }

  function taskOf(slug) { return boards.get(SITE_PROJECT)?.tasks.find((entry) => entry.slug === slug); }
  function setTask(slug, fields) {
    const changed = Object.assign(taskOf(slug), fields);
    // The node words the group, the state and the last checkpoint again with each change.
    Object.assign(changed, { group: taskGroup({ status: changed.status }), state: taskState({ status: changed.status }),
      checkpoint: changed.checkpoints.at(-1) || null });
    return put('boards', boards, SITE_PROJECT);
  }
  const checkpoint = (slug, text) => setTask(slug, { checkpoints: [...taskOf(slug).checkpoints, { text, at: new Date().toISOString() }] });

  // ---- The story ----

  function story() {
    // A worker's command finishes and it says what it did.
    later(3500, () => run(W_SYNC, 'npm test -- pages', 'PASS  tests/pages/hero.test.js\nPASS  tests/pages/pricing.test.js\n\nTests: 14 passed, 14 total', 2600, () => {
      emit(checkpoint('sync-landing-base', 'Conflicts resolved; the page tests pass'));
      stream(W_SYNC, 'The rebase is through and the 14 page tests pass. Pushing the branch and reporting to the lead.', () => later(16000, syncToReview));
    }));
    // The standalone session's tests finish and its turn ends.
    later(7000, () => {
      const pending = chats.get(WEBHOOKS).find((item) => item.kind === 'tool' && item.result === null);
      pending.result = { output: '8 passed in 2.13s', failed: false, at: new Date().toISOString() };
      emit(chatPut(WEBHOOKS, pending), setSession(WEBHOOKS, { activity: null, activitySince: null }));
      stream(WEBHOOKS, 'All 8 retry tests pass: a 5xx is retried after 30 s, 60 s, 120 s and 240 s, then logged as failed for good. A 4xx is never retried.',
        () => emit(setSession(WEBHOOKS, { status: 'done', since: new Date().toISOString(), detail: null })));
    });
    // A second question, one the lead will decide by itself if nobody answers.
    later(14000, () => {
      cards.set(CARD_HERO, {
        id: CARD_HERO, kind: 'question', project: SITE_PROJECT, root: SITE, open: true, closed: null, notice: null, at: new Date().toISOString(), blocking: false,
        question: {
          id: 'q-hero-format', short: 'q-hero-f', text: 'Ship the hero image as WebP only, or keep a PNG fallback?', options: ['WebP only', 'Keep a PNG fallback'],
          priority: 'whenever', whyNow: 'The landing copy merges next; its images need one format.', version: 1, revisionNote: null,
          proposal: 'Keep a PNG fallback', decideBy: soon(600), state: 'open', answer: null, answeredVersion: null, withdrawReason: null, task: 'sync-landing-base',
        },
      });
      emit(put('cards', cards, CARD_HERO), ...refreshLead());
      later(600000, () => {
        const card = cards.get(CARD_HERO);
        if (!card?.open || !card.question.decideBy) return;
        closeCard(card, 'decided by its timer', { state: 'autoDecided', answer: card.question.proposal });
      });
    });
    // The verifier finishes: the clean-up is ready, and the merge wants the user's approval.
    later(40000, () => {
      stream(V_CLEAN, 'Complete and clean: the contract’s two rules hold, six tests cover them, and nothing else changed.', () => {
        sessions.delete(V_CLEAN);
        sessions.delete(W_CLEAN);
        cards.set(CARD_APPROVE, {
          id: CARD_APPROVE, kind: 'approval', project: SITE_PROJECT, root: SITE, open: true, closed: null, notice: null, at: new Date().toISOString(), blocking: true,
          question: {
            id: 'q-approve-cleanup', short: 'q-approv', text: 'The clean-up passed its audit. It deletes files, so the merge is yours to approve.', options: [`Approve ${COMMIT}`, 'Not yet'],
            priority: 'blocking', whyNow: null, version: 1, revisionNote: null, proposal: null, decideBy: null, state: 'open', answer: null, answeredVersion: null, withdrawReason: null, task: 'cleanup-ended-folders',
          },
          approval: {
            commit: COMMIT, tasks: ['cleanup-ended-folders'], base: 'landing-base', files: ['tools/cleanup.py', 'tests/test_cleanup.py'],
            diffstat: '2 files changed, 70 insertions(+), 5 deletions(-)', subject: 'cleanup: remove ended sessions’ folders after 7 days',
            verdicts: { 'cleanup-ended-folders': `complete, clean at ${COMMIT.slice(0, 12)}` }, sensitive: ['tools/cleanup.py'], problems: [],
          },
        });
        emit({ in: 'sessions', id: V_CLEAN, value: null }, { in: 'sessions', id: W_CLEAN, value: null },
          setTask('cleanup-ended-folders', { worker: null, verifier: null, checkpoints: [...taskOf('cleanup-ended-folders').checkpoints, { text: 'Audit passed; waiting for your approval', at: new Date().toISOString() }] }),
          put('cards', cards, CARD_APPROVE), ...refreshLead());
      });
    });
  }

  // The sync goes to review: its worker rests and a verifier starts.
  function syncToReview() {
    if (!sessions.has(W_SYNC)) return;
    const verifier = id('6e2a9f13');
    add(verifier, { agent: 'codex', status: 'working', since: new Date().toISOString(), role: 'verifier', lead: SITE_PROJECT, task: 'sync-landing-base', title: 'Sync landing-base with main', detail: 'Checking the work' });
    chats.set(verifier, [{ id: next('m'), kind: 'prompt', text: 'Audit sync-landing-base at its branch’s commit.', at: new Date().toISOString() }]);
    emit(setSession(W_SYNC, { status: 'idle', since: new Date().toISOString(), detail: null }), put('sessions', sessions, verifier),
      setTask('sync-landing-base', { status: 'review', since: new Date().toISOString(), verifier }));
    later(8000, () => run(verifier, 'git diff main...agent/sync-landing-base --stat', ' pages/hero.html | 6 +++---\n 1 file changed, 3 insertions(+), 3 deletions(-)', 2200, () => {
      stream(verifier, 'Complete and clean: the branch is main plus the reworded headline, and the page tests pass at its commit.', () => later(9000, () => {
        // Merged: both sessions go, and the task that waited on it starts.
        sessions.delete(verifier);
        sessions.delete(W_SYNC);
        const worker = id('92c4d7e0');
        add(worker, { status: 'working', since: new Date().toISOString(), role: 'worker', lead: SITE_PROJECT, task: 'flaky-upload-test', title: 'Fix the flaky upload test', detail: 'Starting…' });
        chats.set(worker, [{ id: next('m'), kind: 'prompt', text: 'Task flaky-upload-test: the upload test fails about one run in five. Find out why and fix the cause, not the test.', at: new Date().toISOString() }]);
        emit({ in: 'sessions', id: verifier, value: null }, { in: 'sessions', id: W_SYNC, value: null }, put('sessions', sessions, worker),
          setTask('sync-landing-base', { status: 'done', since: new Date().toISOString(), worker: null, verifier: null, merged: { commit: '2b7e9c1', at: new Date().toISOString(), tested: true } }),
          setTask('flaky-upload-test', { status: 'running', since: new Date().toISOString(), worker, after: [] }));
        stream(LEAD, 'The sync is merged into landing-base. The upload test was waiting on it and has a worker now.');
        later(6000, () => upload(worker, 0));
      }));
    }));
  }

  // The last worker keeps at it, a step every so often, for as long as the page is open.
  const STEPS = [
    ['for i in $(seq 20); do npm test -- upload || break; done', 'PASS  tests/upload.test.js (run 1)\nPASS  tests/upload.test.js (run 2)\nFAIL  tests/upload.test.js (run 3)\n  ● upload › reports progress\n    expected 100, received 98', 'It fails when the last progress event arrives after the request resolves. The test reads the bar before that event.', 'Fails 1 run in 5: a progress event after the request resolves', true],
    ['grep -n "onprogress" -r src/upload', 'src/upload/client.js:41:  xhr.upload.onprogress = (event) => report(event.loaded / event.total)', 'The client never reports 100 itself: it relies on a final progress event the browser doesn’t promise. Reporting 100 when the request resolves.', 'Cause found in src/upload/client.js', false],
    ['for i in $(seq 20); do npm test -- upload || break; done', 'PASS  tests/upload.test.js (run 1)\n…\nPASS  tests/upload.test.js (run 20)', 'Twenty runs in a row pass with the fix.', '20 runs pass with the fix', false],
    ['npm test', 'Test Suites: 31 passed, 31 total\nTests:       212 passed, 212 total', 'The whole suite passes. Checking the same pattern in the download client before I report.', 'Whole suite passes; checking the download client', false],
  ];
  function upload(worker, index) {
    if (!sessions.has(worker)) return;
    const [line, output, said, mark, failed] = STEPS[index % STEPS.length];
    run(worker, line, output, 3200, () => {
      emit(checkpoint('flaky-upload-test', mark), setSession(worker, { detail: mark }));
      stream(worker, said, () => later(14000, () => upload(worker, index + 1)));
    }, failed);
    const items = chats.get(worker);
    if (items.length > 300) items.splice(0, items.length - 300);
  }

  // ---- Requests ----

  function closeCard(card, closed, question) {
    card.open = false;
    card.closed = closed;
    Object.assign(card.question, question, { decideBy: null });
    emit(put('cards', cards, card.id), ...refreshLead());
  }

  const refused = (message) => ({ ok: false, error: { code: 'refused', message } });
  const badArgs = (message) => ({ ok: false, error: { code: 'bad-args', message } });

  // The folders this invented machine has, and which of them are git repositories (notes has no commit yet).
  const NOTES = `${HOME}/projects/notes`;
  const REPOSITORIES = [SITE, API, PAYOUTS, DOCS, NOTES];
  const FOLDERS = [HOME, `${HOME}/projects`, ...REPOSITORIES];

  // A live session the host started, by its whole id or a prefix of 4 or more (the node's `hostedSession`), or the
  // reply that refuses it in the node's words.
  function hostedSession(given, kind) {
    const wanted = String(given || '').trim().toLowerCase();
    if (!wanted) return { refusal: badArgs(`${kind} needs session`) };
    const bare = wanted.startsWith('local:') ? wanted.slice(6) : wanted;
    const own = [...sessions.values()].find((one) => !one.hosted && one.id.toLowerCase() === wanted);
    if (own) return { refusal: refused(`session ${wanted} runs in a terminal of yours, not in the node’s host: VibeSwitcher only drives the sessions it started`) };
    const matching = bare.length >= 4 ? [...sessions.values()].filter((one) => one.hosted && one.id.slice(6).startsWith(bare)) : [];
    if (matching.length > 1) return { refusal: badArgs(`${matching.length} sessions start with ${wanted}: give more of its id`) };
    if (!matching.length) {
      const ended = node.ended.some((entry) => entry.session.toLowerCase() === wanted);
      return { refusal: { ok: false, error: { code: 'gone', message: ended ? `session ${wanted} has ended` : `no live session ${wanted} on this node (\`vibeswitcher status\` lists them)` } } };
    }
    return { session: matching[0] };
  }

  // The launch presets for a folder (`session.presets`): a project's own and its default first, then the built-ins.
  function presetsFor(folder) {
    const presets = [
      { name: 'Opus', kind: 'claude', command: 'claude --model opus', env: ['MAX_THINKING_TOKENS'], keepShell: false, project: true, default: true, builtIn: false, digest: 'mock-opus', refused: null },
      { name: 'Claude', kind: 'claude', command: 'claude', env: [], keepShell: false, project: false, default: false, builtIn: true, digest: 'mock-claude', refused: null },
      { name: 'Codex', kind: 'codex', command: 'codex', env: [], keepShell: false, project: false, default: false, builtIn: true, digest: 'mock-codex', refused: 'Codex doesn’t run on this node yet' },
      { name: 'Shell', kind: 'shell', command: '', env: [], keepShell: false, project: false, default: false, builtIn: true, digest: 'mock-shell', refused: null },
    ];
    return folder ? presets : presets.slice(1);
  }

  // A session the host starts in `folder`: listed a moment after the reply that names it, as the host tells the node.
  const sessionTerminal = (sid) => sessions.get(sid)?.terminal || `pts/${20 + (parseInt(sid.slice(6, 10), 16) % 50)}`;
  function startSession(folder, agent, title) {
    const sid = id(Math.random().toString(16).slice(2, 10).padEnd(8, '0'));
    const terminal = sessionTerminal(sid);
    later(200, () => {
      add(sid, { cwd: folder, agent: agent === 'shell' ? 'claude' : agent, status: agent === 'shell' ? 'idle' : 'working', since: new Date().toISOString(),
        startedAt: new Date().toISOString(), title, terminal, branch: null, project: null, detail: agent === 'shell' ? null : 'Starting', command: agent });
      emit(put('sessions', sessions, sid));
    });
    return sid;
  }

  // A session's question closed after its answer was typed: it works on (the asking session runs its tests, as the
  // story had it).
  function answered(sid) {
    const items = chats.get(sid) || [];
    const pending = items.find((item) => item.kind === 'tool' && item.result === null);
    // The messages `send` held behind the question are typed in once it closes, in their order.
    const held = sessions.get(sid)?.queued || [];
    for (const one of held) chatPut(sid, { id: next('m'), kind: 'prompt', text: one.text, at: new Date().toISOString(), action: one.action });
    emit({ in: 'chat', session: sid }, setSession(sid, { queued: [], prompt: null, status: 'working', since: new Date().toISOString(), detail: sid === ASKING ? 'Running the payout tests' : null,
      activity: sid === ASKING ? 'pytest tests/test_payouts.py' : null, activitySince: new Date().toISOString() }));
    if (sid !== ASKING || options.still) return;
    later(2400, () => {
      if (!sessions.has(sid)) return;
      if (pending) {
        pending.result = { output: '5 passed, 1 failed\n\nFAILED tests/test_payouts.py::test_two_workers_run_once', failed: true, at: new Date().toISOString() };
        emit(chatPut(sid, pending), setSession(sid, { activity: null, activitySince: null }));
      }
      stream(sid, 'One test fails, and it’s the one that names the bug: `test_two_workers_run_once`. Moving the lock above the schedule read next.',
        () => emit(setSession(sid, { status: 'done', since: new Date().toISOString(), detail: null })));
    });
  }

  // What a value set from the page made of a setting (`set`): read back in place of the invented one.
  const setValues = new Map();

  // The node's settings (`settings`' result, as `NodeSettings` makes it), the project's for the site's folder.
  const POLICY = '- One agent owns each change through completion. Separate reviewers only for security, irreversible operations, or complex changes.\n'
    + '- Run affected tests while editing, then the full suite once before merging. Repeat only when new changes justify it.\n'
    + '- Parallelize independent implementation work. Serialize expensive builds and tests so workers don\'t compete for CPU.\n'
    + '- Fix material bugs. Cosmetic observations don\'t automatically become tasks or block delivery.\n'
    + '- Stop when the requested behavior works and relevant checks pass. No recursive audit loop without a concrete unresolved concern.';
  function settingsResult(folder) {
    const at = (file) => `${HOME}/.vibeswitcher/${file}`;
    const workflow = `${SITE}/.vibeswitcher/workflow.md`;
    const row = (key, title, about, section, scope, form, home, invented, fallback, where, extra = {}) => {
      const value = setValues.has(key) ? (setValues.get(key) === 'default' ? fallback : setValues.get(key)) : invented;
      return {
      key, title, about, section, scope, form, home, choices: extra.choices || [], limits: extra.limits ?? null, value, default: fallback,
      isDefault: value === fallback, where, guardRail: !!extra.rail, note: extra.note ?? null,
      };
    };
    const limits = (key, title, about, form, value, fallback, extra) => row(key, title, about, extra?.section || 'Machine-wide limits', 'node', form, 'limits', value, fallback, at('mac-limits.json'), extra);
    const boost = (key, title, about, form, value, fallback, extra) => row(key, title, about, 'Boost', 'node', form, 'preferences', value, fallback, at('settings.plist'), extra);
    const models = (key, title, about, form, value, fallback, extra) => row(key, title, about, extra?.section || 'Models', 'project', form, 'workflow', value, fallback, workflow, extra);
    const floor = (key, title, about, form, value, fallback, extra) => row(key, title, about, 'Review rules floor', 'project', form, 'floor', value, fallback, 'the session host\'s vault', extra);
    const node = [
      limits('node_max_sessions', 'Team sessions on this node, at most', 'How many workers and verifiers, across every project, may run at once.', 'count', '10', '10', { limits: '1 to 99' }),
      limits('load_threshold', 'Start nothing above a load of', 'Leads start nothing while the load is above this; default means twice the cores (24).', 'number', 'default', 'default', { limits: 'above 0' }),
      limits('node_heavy_slots', 'Test and build slots at once', 'How many builds and full test runs may run at once on this node.', 'count', '3', '2', { limits: '1 to 12' }),
      limits('ignore_usage_limits', 'Ignore usage limits', 'Leads keep starting work at any share of a Claude limit, instead of stopping at 80 %.', 'flag', 'off', 'off', { section: 'Usage limits', limits: 'on or off' }),
      boost('boost', 'Boost', 'Raises the machine-wide limits for more throughput. On a node Automatic acts as Off: it can\'t tell whether you\'re away.', 'choice', 'off', 'off', { choices: ['off', 'on', 'automatic'], limits: 'off, on, automatic' }),
      boost('boost_load_threshold', 'Start nothing above a load of, while boosted', 'While boosted, leads start nothing once the load is above this.', 'number', '36', '36', { limits: 'above 0, at most 48' }),
      boost('boost_max_sessions', 'Team sessions while boosted, at most', 'How many workers and verifiers may run at once across every project while boosted.', 'count', '18', '18', { limits: '1 to 48' }),
      boost('boost_max_workers', 'Workers per project while boosted, at most', 'The most workers any one project may run at once while boosted.', 'count', '7', '7', { limits: '1 to 48' }),
      boost('boost_heavy_slots', 'Test and build slots while boosted', 'How many builds and full test runs may run at once while boosted.', 'count', '3', '3', { limits: '1 to 12' }),
      row('lead_mail', 'Let project leads message each other', 'Lets one project\'s lead send messages to another\'s (tell_lead).', 'Leads', 'node', 'flag', 'preferences', 'on', 'on', at('settings.plist'), { limits: 'on or off' }),
      row('policy', 'Working policy', 'The rules every project\'s lead, workers and verifiers get in their prompts; running leads are told when it changes.', 'Working policy', 'node', 'text', 'policy', POLICY, POLICY, at('policy.md'), { limits: 'at most 32000 characters' }),
    ];
    const project = folder === SITE ? [
      models('lead_model', 'The lead\'s model', 'The model the project\'s lead runs on (Opus in Fable\'s place while Fable is held back); from its next start.', 'model', 'fable', 'fable', { limits: 'a model\'s name as claude --model takes it' }),
      models('lead_advisor', 'The lead\'s advisor', 'The lead\'s advisor while it runs on Opus: fable, opus or none; from its next start.', 'choice', 'fable', 'fable', { choices: ['fable', 'opus', 'none'], limits: 'fable, opus, none' }),
      models('worker_advisor', 'Workers\' advisor', 'Every worker\'s advisor when its task sets none: none, fable or opus.', 'choice', 'none', 'none', { choices: ['none', 'fable', 'opus'], limits: 'none, fable, opus' }),
      models('verifier_model', 'Verifier\'s model', 'The model audits run on; default means another model than the workers\', at least as capable.', 'model', 'default', 'default', { limits: 'a model\'s name as claude --model takes it' }),
      models('security_audit_model', 'Security audits\' model', 'The model a sensitive or security audit runs on, whatever the verifier\'s model is.', 'model', 'mythos', 'mythos', { rail: true, limits: 'a model\'s name as claude --model takes it' }),
      models('max_workers', 'Workers at once, at most', 'How many workers the project\'s lead may run at once.', 'count', '4', '3', { section: 'Team', rail: true, limits: '1 to 99' }),
      floor('floor_sensitive_paths', 'Sensitive paths', 'Paths whose changes always count as sensitive; a lead can add to these, never remove them.', 'paths', '.claude/, .mcp.json, CLAUDE.md, AGENTS.md, .github/', 'none', { limits: 'globs, comma-separated; none for no paths' }),
      floor('floor_strict_paths', 'Strict paths', 'Paths whose changes get the strictest review; a lead can add to these, never remove them.', 'paths', 'none', 'none', { limits: 'globs, comma-separated; none for no paths' }),
      floor('floor_audit_finders', 'Audit finders, at least', 'The fewest independent checkers an audit may use in this project.', 'count', '1', '1', { limits: '1 to 3' }),
      floor('floor_merge_policy', 'Merge policy, at least', 'How much approval a merge needs at minimum, from automatic to asking you every time.', 'choice', 'ask_sensitive', 'auto', { choices: ['auto', 'ask_sensitive', 'ask_all'], limits: 'auto, ask_sensitive, ask_all' }),
      floor('floor_risk_lines', 'Risk lines, at most', 'A change bigger than this many lines counts as risky; 0 sets no floor, and the project\'s own limit applies.', 'count', '0', '0', { limits: '0 to 1000000' }),
      floor('floor_risk_model', 'Risk check\'s model pass', 'Keeps the model\'s second look at a change\'s risk switched on.', 'flag', 'off', 'off', { limits: 'on or off' }),
      floor('floor_audit_sample_percent', 'Audit sample, at least', 'The smallest share of finished work, in percent, that gets audited.', 'count', '10', '0', { limits: '0 to 100' }),
      floor('floor_verifier_different', 'Verifier never on the workers\' model', 'Keeps audits on a different model from the one the workers use.', 'flag', 'on', 'on', { limits: 'on or off' }),
    ] : null;
    return {
      node: { root: at('').replace(/\/$/, ''), settings: node },
      project: project ? { project: SITE_PROJECT, root: SITE, settings: project } : null,
      leftOut: [
        { title: 'Also on battery (Boost)', why: 'a node runs on mains: it reads no battery' },
        { title: 'Notifications (banners, sound, reminders)', why: 'the page\'s own: This node\'s toggle, in each browser' },
      ],
      usage,
    };
  }

  function handle(message) {
    const args = message.args || {};
    // A kind it doesn't list is refused as a node refuses it, whatever it could answer (`?older`'s starts).
    if (!KINDS.includes(message.kind)) return { ok: false, error: { code: 'unknown-kind', message: `this server doesn’t take ${message.kind}` } };
    // `?refuse=KIND,…`: the node's own refusal of each named kind, so the page's refused state can be seen.
    if (REFUSE.has(message.kind) && REFUSALS[message.kind]) return refused(REFUSALS[message.kind]);
    if (message.kind === 'answer') {
      // The node's words (`text`, with the card's `seen`); an older page's `answer`.
      args.answer = args.text ?? args.answer;
      const card = cards.get(args.card);
      if (!card) return { ok: false, error: { code: 'gone', message: 'That question is no longer on the board. Your answer wasn’t sent.' } };
      if (!card.open) return refused(card.question.state === 'autoDecided'
        ? `The timer had run out: the lead went ahead with ‘${card.question.answer}’. Your answer reached it as a note.`
        : `Already answered: ${card.question.answer}. Your new answer wasn’t sent.`);
      closeCard(card, 'answered', { state: 'answered', answer: args.answer, answeredVersion: card.question.version });
      // The conversation's record of it, not read by the lead until its next step (the node's `delivered`).
      const board = boards.get(SITE_PROJECT);
      const entry = { id: card.question.id, card: card.id, version: card.question.version, state: 'answered', text: card.question.text, answer: args.answer, proposal: null, why: null, reworded: false, task: card.question.task, at: new Date().toISOString(), delivered: null, replaceable: card.kind === 'question' };
      board.answered = [...(board.answered || []).filter((one) => one.id !== entry.id), entry];
      emit(put('boards', boards, SITE_PROJECT));
      later(25000, () => { entry.delivered = new Date().toISOString(); entry.replaceable = false; emit(put('boards', boards, SITE_PROJECT)); });
      if (card.kind === 'approval' && args.answer.startsWith('Approve')) {
        emit(setTask('cleanup-ended-folders', { status: 'done', since: new Date().toISOString(), merged: { commit: COMMIT.slice(0, 7), at: new Date().toISOString(), tested: true } }));
        later(700, () => stream(LEAD, 'Approved and merged: the clean-up is on landing-base.'));
      } else {
        later(700, () => stream(LEAD, `Got it: ${args.answer}. I’ll plan the rest around that.`));
      }
      return { ok: true, result: { card: card.id, state: 'answered' } };
    }
    // Changing an answer the lead hasn't read (`answer.replace`), and the user's messages to the lead (`tell`, and
    // `tell.retract` while unread).
    if (message.kind === 'answer.replace') {
      const board = boards.get(SITE_PROJECT);
      const entry = (board.answered || []).find((one) => one.card === args.card);
      if (!entry) return { ok: false, error: { code: 'gone', message: 'That answer isn’t on the board.' } };
      if (entry.delivered) return { ok: false, error: { code: 'delivered', message: 'The lead has read that answer already.' } };
      entry.answer = args.text;
      emit(put('boards', boards, SITE_PROJECT));
      return { ok: true, result: { outcome: 'replaced', card: args.card } };
    }
    if (message.kind === 'tell') {
      const lead = leads.get(SITE_PROJECT);
      const told = { action: message.action, at: new Date().toISOString(), delivered: null };
      lead.told = [...(lead.told || []), told];
      emit(put('leads', leads, SITE_PROJECT));
      later(20000, () => { if (lead.told.includes(told)) { told.delivered = new Date().toISOString(); emit(put('leads', leads, SITE_PROJECT)); } });
      return { ok: true, result: { project: SITE_PROJECT, session: LEAD } };
    }
    if (message.kind === 'tell.retract') {
      const lead = leads.get(SITE_PROJECT);
      const told = (lead.told || []).find((one) => one.action === args.action);
      if (!told) return { ok: false, error: { code: 'gone', message: 'That message was taken back already, or isn’t known.' } };
      if (told.delivered) return { ok: false, error: { code: 'delivered', message: 'The lead has read it already.' } };
      lead.told = lead.told.filter((one) => one !== told);
      emit(put('leads', leads, SITE_PROJECT));
      return { ok: true, result: { retracted: true } };
    }
    if (message.kind === 'hold') {
      const card = cards.get(args.card);
      if (!card?.open) return refused('The timer had run out: the lead went ahead. It waits for nothing now.');
      card.question.decideBy = null;
      emit(put('cards', cards, card.id));
      return { ok: true, result: { card: card.id, held: true } };
    }
    // A session's own question answered (`session.reply`, as `Requests.replySession`): the question on its screen read
    // again, refused unless it is the one the page was shown; then the keys typed, and the question closes a moment
    // after the reply, as the node's next read of the screen finds it gone.
    if (message.kind === 'session.reply') {
      if (!Number.isInteger(args.choice) || args.choice < 1) return badArgs('session.reply needs choice, an option’s number from 1');
      const text = typeof args.text === 'string' && args.text.trim() ? args.text : null;
      const found = hostedSession(args.session, 'session.reply');
      if (found.refusal) return found.refusal;
      const target = found.session;
      const short = target.id.slice(6, 14);
      const no = (why) => refused(`session ${short}: ${why}`);
      const menu = target.prompt;
      if (!menu) return no('no question is open on its screen');
      if (args.question != null && args.question !== menu.question) return no('the question on its screen isn’t the one you were shown; it asks now: ' + menu.question);
      if (args.options != null && JSON.stringify(args.options) !== JSON.stringify(menu.options)) {
        return no('its options aren’t the ones you were shown; they are now: ' + menu.options.map((option, index) => `${index + 1}. ${option}`).join('; '));
      }
      if (menu.multiSelect) return no('its question takes several ticks: answer it in the session’s terminal');
      const index = args.choice - 1;
      if (index >= menu.options.length) return no(`its question has ${menu.options.length} options, not ${args.choice}`);
      if (menu.descriptions?.[index] != null && options.toggle) {
        return no(`option ${args.choice} is a setting toggled with Space (${menu.options[index]}): set it in the session’s terminal, or choose its Continue`);
      }
      const takes = (menu.text || []).includes(index);
      if (takes && !text) return no(`option ${args.choice} takes your words: give them after the choice`);
      if (!takes && text) return no(`option ${args.choice} takes no words (${menu.options[index]})`);
      later(250, () => answered(target.id));
      return { ok: true, result: { session: target.id, terminal: target.terminal, choice: args.choice, option: menu.options[index], question: menu.question } };
    }
    // A session started (`session.new`, as `Requests.newSession`): listed a moment after the reply, as the host tells.
    if (message.kind === 'session.new') {
      const folder = args.folder;
      if (typeof folder !== 'string' || !folder.startsWith('/')) return badArgs('session.new needs folder, an absolute path');
      const name = args.preset || null;
      if (name && args.agent != null) return badArgs('session.new takes agent or preset, not both');
      if (name && !args.digest) return badArgs('session.new with a preset needs its digest, as `session.presets` gave it');
      const agent = args.agent || 'claude';
      if (!['claude', 'codex', 'shell'].includes(agent)) return badArgs(`session.new’s agent is claude, codex or shell, not ${agent}`);
      if (args.model && agent === 'shell') return badArgs('a shell takes no model');
      if (!FOLDERS.includes(folder.replace(/\/+$/, ''))) return refused(`${folder} isn’t a folder`);
      let started = { name: agent === 'shell' ? 'Shell' : agent === 'codex' ? 'Codex' : 'Claude', kind: agent };
      if (name) {
        const preset = presetsFor(folder).find((one) => one.name === name);
        if (!preset) return refused(`no preset ${name} for ${folder} (\`vibeswitcher presets ${folder}\` lists them)`);
        if (preset.refused) return refused(`preset ${name} can’t start here: ${preset.refused}`);
        if (preset.digest !== args.digest) return refused(`preset ${name} changed since it was shown (or the node’s server restarted since): nothing started; run the command again to see it as it is now`);
        if (args.model && preset.kind === 'shell') return refused(`preset ${name} starts a shell, which takes no model`);
        started = preset;
      }
      const kind = started.kind;
      if (kind === 'codex') return refused('no codex for this node');
      const sid = startSession(folder, kind, null);
      return { ok: true, result: { session: sid, terminal: sessionTerminal(sid), agent: kind, folder, model: args.model || null, preset: name ? started.name : null } };
    }
    // An ended session started again in its conversation (`session.resume`, as `Requests.resumeSession`).
    if (message.kind === 'session.resume') {
      const given = String(args.session || '').trim().toLowerCase();
      if (!given) return badArgs('session.resume needs session');
      const bare = given.startsWith('local:') ? given.slice(6) : given;
      const matching = bare.length >= 4 ? node.ended.filter((entry) => entry.session.slice(6).startsWith(bare)) : [];
      if (matching.length !== 1) {
        return matching.length ? badArgs(`${matching.length} ended sessions start with ${given}: give more of its id`)
          : { ok: false, error: { code: 'gone', message: `no ended session ${given} of yours to resume (\`vibeswitcher resume\` lists them)` } };
      }
      const entry = matching[0];
      if (!entry.conversation) return { ok: true, result: { reopened: [], refused: [{ was: entry.session, folder: entry.folder, why: 'its conversation id wasn’t recorded: nothing to resume' }] } };
      node.ended = node.ended.filter((one) => one !== entry);
      const sid = startSession(entry.folder, 'claude', entry.name);
      emit({ in: 'node', id: 'local', value: node });
      return { ok: true, result: { reopened: [{ was: entry.session, folder: entry.folder, conversation: entry.conversation, session: sid, terminal: sessionTerminal(sid) }], refused: [] } };
    }
    // A project's lead started in its folder (`lead`, as `Requests.lead` and `LeadEngine.startLead`): the running one
    // shown; a folder in no repository, or one with no commit, refused with the engine's words.
    if (message.kind === 'lead') {
      const folder = typeof args.folder === 'string' ? args.folder.replace(/\/+$/, '') : '';
      if (!folder.startsWith('/')) return badArgs('lead needs folder, an absolute path');
      const running = [...leads.values()].find((lead) => folder === lead.root || folder.startsWith(lead.root + '/'));
      if (running) {
        return { ok: true, result: { happened: 'shown', session: running.session, program: null, notes: args.goal ? ['your goal is held for the running lead: it reads it at its next step'] : [] } };
      }
      const root = REPOSITORIES.find((repo) => folder === repo || folder.startsWith(repo + '/'));
      if (!root) return refused(`${folder} isn’t in a git repository: a lead needs one (git init, and a first commit; \`vibeswitcher lead FOLDER --init\` makes them)`);
      if (root === NOTES) return refused(`${root} has no commits yet: workers branch from a commit; make one (git add, git commit), then start the lead`);
      const sid = id(Math.random().toString(16).slice(2, 10).padEnd(8, '0'));
      const project = `local:project:${Math.random().toString(36).slice(2, 14)}`;
      later(200, () => {
        add(sid, { cwd: root, role: 'lead', lead: project, status: 'working', since: new Date().toISOString(), startedAt: new Date().toISOString(),
          title: args.goal || null, detail: 'Reading the project’s records', project });
        leads.set(project, { project, root, session: sid, named: null, bound: sid, replaced: [], held: 0, reportsWaiting: 0, notice: null,
          starting: false, lastStart: 'started', lastStartAt: new Date().toISOString(), looks: 0, questions: { open: 0, blocking: 0 }, cards: [], told: [], push: null });
        emit(put('sessions', sessions, sid), put('leads', leads, project));
      });
      return { ok: true, result: { happened: 'started', session: sid, program: `${HOME}/.local/bin/claude`, notes: [] } };
    }
    if (message.kind === 'send') {
      const target = sessions.get(args.session);
      if (!target) return { ok: false, error: { code: 'gone', message: 'That session has ended.' } };
      if (!target.hosted) return refused('It runs in another terminal: it can be read here, not typed into.');
      emit(chatPut(args.session, { id: next('m'), kind: 'prompt', text: args.text, at: new Date().toISOString(), action: message.action }),
        setSession(args.session, { status: 'working', since: new Date().toISOString() }));
      later(900, () => stream(args.session, 'On it. (This is the mock node: a real session’s reply would stream in here from its transcript.)', () => {
        if (args.session === LEAD) emit(...refreshLead('done'));
        else emit(setSession(args.session, { status: 'done', since: new Date().toISOString() }));
      }));
      // What was done, in the node's words (`when`, `said`): Claude Code has no queue for after the turn.
      const when = args.when || (args.now ? 'now' : 'step');
      const said = when === 'after' && target.agent !== 'codex' ? 'Claude Code has no key for after this turn: sent at its next step.' : null;
      return { ok: true, result: { session: args.session, when: said ? 'step' : when, ...(said ? { said } : {}) } };
    }
    if (message.kind === 'session.draft' || message.kind === 'session.draft.clear') {
      const target = sessions.get(args.session);
      if (!target) return { ok: false, error: { code: 'gone', message: 'That session has ended.' } };
      if (!target.hosted) return refused('That session runs in a terminal of yours: VibeSwitcher only types into the sessions it started.');
      const drafted = message.kind === 'session.draft' ? { text: args.text, images: args.images || [], at: new Date().toISOString(), action: message.action } : null;
      emit(setSession(args.session, { draft: drafted }));
      return { ok: true, result: { session: args.session } };
    }
    // The composer's lane: what `/` and `@` complete to, a pasted image's parts, and the launch presets.
    if (message.kind === 'session.complete') {
      const query = String(args.query || '').toLowerCase();
      const items = args.kind === 'slash'
        ? [['compact', 'Summarize the conversation to free context'], ['clear', 'Start a new conversation'], ['model', 'Switch model'],
          ['review', 'Review the current changes'], ['deploy', 'Ship it to staging'], ['context', 'Show what fills the context']]
          .filter(([name]) => name.includes(query)).map(([name, note]) => ({ insert: `/${name} `, title: `/${name}`, subtitle: note }))
        : ['payouts/worker.py', 'payouts/schedule.py', 'tests/test_payouts.py', 'README.md', 'docs/regions.md']
          .filter((path) => path.toLowerCase().includes(query)).map((path) => ({ insert: `@${path} `, title: path.split('/').pop(), subtitle: path }));
      return { ok: true, result: { items } };
    }
    if (message.kind === 'session.attach') {
      if (args.part + 1 < args.parts) return { ok: true, result: { session: args.session, received: args.part + 1 } };
      const ext = { 'image/jpeg': 'jpg', 'image/gif': 'gif', 'image/webp': 'webp' }[args.type] || 'png';
      return { ok: true, result: { session: args.session, received: args.parts, path: `/home/you/.vibeswitcher/attachments/pasted-mock-${next('i')}.${ext}` } };
    }
    // The inspector's tokens and cost, and a chat's image bytes (2026-11-21).
    if (message.kind === 'session.usage') {
      const turn = (id, input, cached, output, cost) => ({ id, at: ago(140), partial: false, tokens: { input, cached, output }, cost });
      return { ok: true, result: { turns: [turn('t1', 182_400, 171_000, 3_900, 0.41), turn('t2', 96_200, 90_100, 1_250, 0.18)], count: 2, partial: false,
        tokens: { input: 278_600, cached: 261_100, output: 5_150 }, cost: 0.59, costPartial: false } };
    }
    // The Statistics window (`stats`): the Mac's words, made up.
    if (message.kind === 'stats') {
      const range = ['today', 'week', 'month'].includes(args.range) ? args.range : 'week';
      const n = { today: 1, week: 7, month: 30 }[range];
      const fig = (label, value, detail = null, more = {}) => ({ label, value, detail, help: null, meter: null, trend: [], ...more });
      const days = Array.from({ length: n }, (_, i) => (i % 5 === 3
        ? { label: `day ${i + 1}`, value: null, text: 'not counted' }
        : { label: `day ${i + 1}`, value: 1200 + ((i * 937) % 2900), text: `${((1200 + ((i * 937) % 2900)) / 1000).toFixed(1)} an hour` }));
      const figure = (label, value, detail, help) => fig(label, value, detail, { help });
      return { ok: true, result: {
        range, title: { today: 'Today', week: '7 days', month: '30 days' }[range], span: range === 'today' ? 'Today' : `The last ${n} days`,
        mac: [
          fig('Load', 'median 6.2 · p90 14 · max 31', '12 min at 24 or more, 0 min at 36 or more · 24 cores'),
          fig('Freezes per hour', '0.4', `${3 * n} freezes in ${8 * n} h counted`, { help: 'Times the main thread stopped answering for 2 s or more, an hour', trend: days }),
          fig('Boost hours', `${2 * n} h`, 'off now'),
          fig('Merges per hour', '0.31', `${4 * n} landed of ${5 * n} merge runs`),
          fig('Claude weekly', '42%', 'on pace · resets Monday at 9:00 AM', { meter: { used: 420, elapsed: 520, reached: false } }),
          fig('Claude 5-hour', '81%', 'ahead of pace', { meter: { used: 810, elapsed: 600, reached: false } }),
          fig('Codex usage', 'Not recorded'),
        ],
        columns: ['Merged', 'Abandoned', 'Audits · rounds', 'Flakes', 'Worker hours', 'Cost', 'Codex share', 'Median to merge'],
        projects: [
          { id: SITE, name: 'example-site', note: null, cells: [String(3 * n), '1', `${2 * n} · ${3 * n}`, '2', `${(4.5 * n).toFixed(1)} h`, `$${(11.2 * n).toFixed(2)}`, '12%', '2.4 h'] },
          { id: API, name: 'example-api', note: 'no archive: archived tasks not counted', cells: [String(n), '0', `${n} · ${n}`, 'Not recorded', `${(1.5 * n).toFixed(1)} h`, `≥ $${(3.1 * n).toFixed(2)}`, '–', '1.1 h'] },
        ],
        total: { id: 'total', name: 'Total', note: null, cells: [String(4 * n), '1', `${3 * n} · ${4 * n}`, '2', `${6 * n} h`, `≥ $${(14.3 * n).toFixed(2)}`, '9%', '2 h'] },
        quality: {
          sections: [
            { title: 'Quality', figures: [figure('First-audit pass rate', '67%', 'of 9 audited merges', 'The share of audited merges that passed their first audit.'), figure('Important findings per audited merge', '0.8', null, null)] },
            { title: 'Autonomy', figures: [figure('Needed nobody', '58%', 'no question, no lead message after start, no re-roll', null), figure('Questions per merge', '0.42', null, null)] },
            { title: 'Where time goes', figures: [figure('Median to merge', '2 h', null, null), figure('Waiting on you per merge', '3 min', null, null)] },
            { title: 'Cost', figures: [figure('Cost per merged task', '$3.58', 'worker and verifier', null)] },
          ],
          columns: ['Merged', 'First audit', 'Rounds to pass', 'Important / audited', 'First-try merge', 'Questions / task', 'Needed nobody', 'Median to merge', 'Cost / task'],
          columnHelp: [], modelsNote: null,
          breakdown: [
            { name: 'Claude', model: false, cells: ['24', '70%', '1.4', '0.7', '80%', '0.4', '60%', '2 h', '$3.80'] },
            { name: 'claude-opus-5-5', model: true, cells: ['20', '72%', '1.3', '0.6', '82%', '0.4', '62%', '1.9 h', '$4.10'] },
            { name: 'Codex', model: false, cells: ['4', '50%', '2', '1.2', '60%', '0.5', '50%', '2.6 h', '$1.90'] },
          ],
          trend: ['Sep 29', 'Oct 6', 'Oct 13', 'Oct 20', 'Oct 27', 'Nov 3', 'Nov 10', 'Nov 17'].map((label, i) => ({ label, merged: 3 + i * 2, passRate: `${50 + i * 4}%`, passBar: 500 + i * 40, cost: `$${(5 - i * 0.3).toFixed(2)}`, costBar: 1000 - i * 60 })),
          compared: { title: 'Compared with working solo', badge: 'Estimate', method: 'Estimated, not measured: nothing was run solo.', columns: ['All', 'Claude', 'Codex'],
            groups: [{ title: 'What it costs', rows: [{ label: 'Process cost', help: '', cells: [{ value: '+38%', detail: 'over 22 merges' }, { value: '+41%', detail: null }, { value: '+20%', detail: null }] }] }] },
        },
      } };
    }
    // A session's dev servers (2026-11-21).
    if (message.kind === 'session.ports') {
      return { ok: true, result: { ports: [{ port: 5173, address: '127.0.0.1', pid: 48311, program: 'node', url: 'http://localhost:5173/' }] } };
    }
    // A board task's details (`board.task`) and a result's screenshot (`board.image`).
    if (message.kind === 'board.task') {
      const board = boards.get(args.project);
      const found = board?.tasks.find((one) => one.slug === args.task);
      if (!found) return { ok: false, error: { code: 'gone', message: 'no such task on that board' } };
      return { ok: true, result: {
        slug: found.slug, title: found.title, failure: found.status === 'blocked' ? 'Waits on Sync landing-base with main' : null,
        checkpoints: (found.checkpoints || []).map((checkpoint) => ({ text: checkpoint.text, at: checkpoint.at })),
        report: found.status === 'review' ? 'Removes folders of sessions ended over 7 days ago; skips any a live session points at. Six tests.' : null,
        audit: found.status === 'review' ? { last: false, passes: false, completion: 'partial', integrity: 'clean', summary: 'One important finding: a folder a live session points at could be removed if its session ends mid-sweep.', vote: '2 of 3 finders agreed', panel: null } : null,
        round: found.status === 'review' ? 1 : null,
        findings: found.status === 'review' ? [{ id: 'F1', severity: 'Important', status: 'open', blocks: true, text: 'F1 tools/cleanup.py:42 — the live check runs before the sweep, not per folder' }] : [],
        merged: found.merged ? `Merged ${found.merged.commit} at 12:25, tests passed` : null, score: null, reverted: false,
        worker: found.worker || null, verifier: found.verifier || null,
      } };
    }
    if (message.kind === 'board.image') {
      if (args.update !== 'mock-result-2' || args.index !== 0) return { ok: false, error: { code: 'gone', message: 'no such image in that result' } };
      return { ok: true, result: { mediaType: SHOT.mediaType, bytes: SHOT.bytes, offset: 0, data: SHOT_DATA } };
    }
    if (message.kind === 'chat.image') {
      if (args.id !== SHOT.id) return { ok: false, error: { code: 'gone', message: 'no such image in that session’s chat' } };
      return { ok: true, result: { mediaType: SHOT.mediaType, bytes: SHOT.bytes, offset: 0, data: SHOT_DATA } };
    }
    if (message.kind === 'session.presets') return { ok: true, result: { presets: presetsFor(args.folder), problems: [] } };
    if (message.kind === 'brief') {
      return { ok: true, result: { text: options.empty ? 'No project lead is running and no session needs you.'
        : 'In example-site, the sync with main is running and the cleanup of ended folders is being checked. One question waits on you: whether to ship the new hero. One session needs you.',
        byModel: false, language: 'en', at: ago(0), notice: null, asks: options.empty ? 0 : 2, kept: false } };
    }
    if (message.kind === 'recent') {
      return { ok: true, result: { projects: options.empty ? [] : [
        { folder: SITE, lastUsed: ago(300), lead: SITE_PROJECT },
        { folder: `${HOME}/projects/notes`, lastUsed: ago(86400), lead: null },
      ] } };
    }
    if (message.kind === 'mail') {
      const messages = [
        { at: ago(600), from: 'example-api', to: 'example-site', received: true, kind: 'answer', text: '8080, behind the staging proxy.', outcome: 'waiting', sent: true, detail: 'Waiting in its inbox.' },
        { at: ago(900), from: 'example-site', to: 'example-api', received: false, kind: 'question', text: 'Which port does the API listen on in staging?', outcome: 'delivered', sent: true, detail: 'Delivered.' },
      ];
      return { ok: true, result: { projects: options.empty ? [] : [{ root: SITE, project: 'example-site', total: messages.length, messages }] } };
    }
    if (message.kind === 'settings') {
      if (args.folder && args.folder !== SITE) return { ok: false, error: { code: 'gone', message: `no lead has worked in ${args.folder} yet: \`vibeswitcher lead ${args.folder}\` starts one` } };
      return { ok: true, result: settingsResult(args.folder) };
    }
    if (message.kind === 'seen') {
      const target = sessions.get(args.session);
      if (target?.status === 'done') emit(setSession(args.session, { status: 'idle' }));
      return { ok: true, result: {} };
    }
    // What an acting page may do here as on a node (KindSpec's `.acts`): the lead's push settled, a setting set, the
    // node stopped (the mock starts again a moment later, as a restarted node would).
    if (message.kind === 'push' || message.kind === 'push.decline') {
      const lead = leads.get(SITE_PROJECT);
      if (!lead?.push || lead.push.id !== args.request) return refused('That push request is settled already.');
      const target = lead.push.target;
      lead.push = null;
      emit(put('leads', leads, SITE_PROJECT));
      const pushed = message.kind === 'push';
      later(700, () => stream(LEAD, pushed ? `Pushed: ${target} is at the merged work.` : 'Understood: nothing is pushed. It stays on this node.'));
      return { ok: true, result: { request: args.request, settled: pushed ? 'pushed' : 'declined', ok: true, said: pushed ? `pushed to ${target}` : 'declined', target: pushed ? target : null } };
    }
    if (message.kind === 'set') {
      if (args.key === 'web_acts') {
        node.web.acts = { ...node.web.acts, on: args.value !== 'off', level: args.value };
        emit({ in: 'node', id: 'local', value: node });
        return { ok: true, result: { key: 'web_acts', value: args.value, was: 'trust', scope: 'node', project: null, told: null } };
      }
      const was = settingsResult(args.folder || null);
      const found = [...was.node.settings, ...(was.project?.settings || [])].find((one) => one.key === args.key);
      if (!found) return refused(`There is no setting ${args.key}.`);
      setValues.set(args.key, String(args.value));
      return { ok: true, result: { key: args.key, value: String(args.value), was: found.value, scope: found.scope, project: found.scope === 'project' ? SITE_PROJECT : null, told: null } };
    }
    if (message.kind === 'stop') {
      later(400, () => feed.restart());
      return { ok: true, result: { sessionsEnded: sessions.size, host: 'stopped' } };
    }
    // Check for Updates now (`update.check`, `Requests.updateCheck`): the watch looks at once; here it finds a newer
    // build, its record in the `node` value too.
    if (message.kind === 'update.check') {
      node.update = { checkedAt: new Date().toISOString(), commit: '5b8e1d2a9c4f7e3b6a0d1c2e3f4a5b6c7d8e9f01', aheadBy: 3,
        install: 'curl -fsSL https://example.invalid/install.sh | sh -s -- 5b8e1d2a9c4f', problem: null, running: 'f62aef61' };
      emit({ in: 'node', id: 'local', value: node });
      return { ok: true, result: { ...node.update, notice: null } };
    }
    // Every page unpaired (`web.revoke`, `Requests.webRevoke`): the loopback's tokens and the tailnet's; this page's
    // connection is closed a moment later, as the node's is.
    if (message.kind === 'web.revoke') {
      const revoked = node.web.tokens;
      node.web = { ...node.web, tokens: 0, connections: 0 };
      emit({ in: 'node', id: 'local', value: node });
      later(1500, () => store.setConnection('revoked'));
      return { ok: true, result: { revoked, tailnetRevoked: 1 } };
    }
    return { ok: false, error: { code: 'unknown-kind', message: `This node doesn’t take ${message.kind}.` } };
  }

  // What this mock answers, as a node's `hello.kinds` lists them: a page offers a button only for a kind listed, so
  // nothing it shows here is refused as unknown. `chat.page` is the feed's own (`pageChat`).
  // `?older`: a node that doesn't take a session's reply or a start from a page (STARTS), so the page shows their lines.
  // `?older` lists none of the buttons' kinds either (BUTTONS: what an acting page sends a node in place of the lines
  // it showed before, docs/process/v2-no-terminal.md's table B and A5), so their lines can be seen.
  const STARTS = ['lead', 'session.new', 'session.reply', 'session.resume'];
  const BUTTONS = ['update.check', 'web.revoke'];
  const KINDS = ['chat.page',
    'answer', 'answer.replace', 'tell', 'tell.retract', 'hold', 'send', 'session.draft', 'session.draft.clear', 'session.complete',
    'session.attach', 'session.usage', 'stats', 'session.ports', 'board.task', 'board.image', 'chat.image', 'session.presets', 'brief', 'recent',
    'mail', 'settings', 'seen', 'push', 'push.decline', 'set', 'stop', ...STARTS, ...BUTTONS].filter((kind) => !options.older || (!STARTS.includes(kind) && !BUTTONS.includes(kind)));
  // The node's own words for refusing each (`?refuse=KIND,…`).
  const REFUSE = new Set(options.refuse || []);
  const REFUSALS = {
    'update.check': 'this server doesn’t check for updates (a scratch node asks GitHub nothing)',
    'web.revoke': 'the web tokens weren’t dropped: the token file couldn’t be written',
  };

  // ---- The feed's interface (what the WebSocket feed will offer too) ----

  let down = false;

  const feed = {
    kinds: KINDS,
    start() {
      later(options.still ? 0 : 320, () => {
        store.setKinds?.(KINDS);
        store.apply(snapshot());
        if (!options.still && !options.empty) story();
      });
    },
    // A snapshot again, after a gap.
    resync() { later(50, () => store.apply(snapshot())); },
    // A chat's newest 200 items, then its ops; older ones come with pageChat.
    subscribeChat(sid) {
      later(options.still ? 0 : 140, () => {
        if (down) return;
        subscribed.add(sid);
        const items = wireChat(chats.get(sid) || []);
        sentChats.set(sid, items);
        store.chatSnapshot(sid, { items: structuredClone(items.slice(-200)), after: null, more: items.length > 200 });
      });
    },
    unsubscribeChat(sid) { subscribed.delete(sid); },
    pageChat(sid, before) {
      return new Promise((resolve) => later(160, () => {
        const items = sentChats.get(sid) || wireChat(chats.get(sid) || []);
        const end = items.findIndex((item) => item.id === before);
        if (end < 0) return resolve({ ok: false, error: { code: 'bad-args', message: 'No such item.' } });
        const start = Math.max(0, end - 200);
        resolve({ ok: true, result: { items: structuredClone(items.slice(start, end)), more: start > 0 } });
      }));
    },
    request(message) {
      return new Promise((resolve) => later(160, () => resolve(down ? { ok: false, error: { code: 'not-yet', message: 'The node isn’t answering. It’s sent again once it’s back.' } } : handle(message))));
    },
    // What a server restart looks like from here: the connection drops, then a new epoch's snapshot.
    restart() {
      down = true;
      subscribed.clear();
      sentChats.clear();
      store.setConnection('reconnecting');
      later(2400, () => {
        down = false;
        epoch = crypto.randomUUID();
        node.server = { ...node.server, startedAt: new Date().toISOString(), pid: node.server.pid + 117 };
        node.host.notes.serverRestarts += 1;
        seq = 0;
        store.apply(snapshot());
      });
    },
    stop() { for (const timer of timers) clearTimeout(timer); timers.clear(); },
  };
  return feed;
}
