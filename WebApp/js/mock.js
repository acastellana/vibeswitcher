// A stand-in for the node: it sends the store a snapshot, then deltas on a timer, and answers its requests. The
// WebSocket feed replaces this file; nothing else knows it exists. It plays one small story so the page looks alive:
// a lead's team moves three tasks across its board (workers and verifiers come and go), a question arrives, a
// session finishes its turn. Everything here is invented, and every shape is the one README.md documents.
//
//   ?rows=10000   gives one session a long chat, to see the list and the scroll hold up
//   ?still        sends the snapshot and nothing after it (for screenshots)
//   ?empty        a node with no sessions

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

  // ---- The node's state, as the server would hold it ----

  const session = (sid, fields) => ({
    id: sid, terminal: 'pts/' + (3 + sessions.size), agent: 'claude', cwd: SITE, status: 'idle', since: ago(60), hosted: true, role: null,
    title: null, detail: null, paused: false, lead: null, task: null, ...fields,
  });
  const sessions = new Map();
  const add = (sid, fields) => sessions.set(sid, session(sid, fields));
  if (!options.empty) {
    add(LEAD, { status: 'needs-you', since: ago(39), role: 'lead', lead: SITE_PROJECT, title: 'Sync the landing pages and finish the sidebar review' });
    add(W_SYNC, { status: 'working', since: ago(252), role: 'worker', lead: SITE_PROJECT, task: 'sync-landing-base', title: 'Sync landing-base with main', detail: 'Resolving the hero’s conflicts' });
    add(W_CLEAN, { agent: 'codex', status: 'idle', since: ago(130), role: 'worker', lead: SITE_PROJECT, task: 'cleanup-ended-folders', title: 'Clean up ended sessions’ folders' });
    add(V_CLEAN, { status: 'working', since: ago(118), role: 'verifier', lead: SITE_PROJECT, task: 'cleanup-ended-folders', title: 'Clean up ended sessions’ folders', detail: 'Checking the work' });
    add(ASKING, { cwd: API, status: 'needs-you', since: ago(20), title: 'Why does the payout job run twice?', detail: 'Bash: pytest tests/test_payouts.py' });
    add(WEBHOOKS, { agent: 'codex', cwd: PAYOUTS, status: 'working', since: ago(95), title: 'Retry failed bank webhooks', detail: 'Running the retry tests' });
    add(DARK, { status: 'done', since: ago(380), title: 'Add dark mode to the settings page' });
    add(PREVIEW, { cwd: DOCS, status: 'background', since: ago(720), title: 'Preview the docs site', detail: '1 shell · 12m: npm run dev' });
    add('local:pts/9', { cwd: DOCS, status: 'idle', since: ago(5400), hosted: false, terminal: 'pts/9', title: 'Tidy the README' });
  }

  const leads = new Map(options.empty ? [] : [[SITE_PROJECT, {
    project: SITE_PROJECT, root: SITE, session: LEAD, named: null, bound: LEAD, replaced: [], held: 0, reportsWaiting: 0, notice: null,
    starting: false, lastStart: null, lastStartAt: ago(5400), looks: 14, questions: { open: 1, blocking: 1 }, cards: [CARD_LAUNCH],
  }]]);

  const task = (slug, title, status, fields = {}) => ({ id: slug, slug, title, status, since: ago(300), worker: null, verifier: null, branch: 'agent/' + slug, after: [], checkpoints: [], blocker: null, merged: null, ...fields });
  const boards = new Map(options.empty ? [] : [[SITE_PROJECT, {
    project: SITE_PROJECT, baseBranch: 'landing-base',
    tasks: [
      task('sync-landing-base', 'Sync landing-base with main', 'running', { since: ago(252), worker: W_SYNC, checkpoints: [{ text: 'Rebased onto main; resolving the hero’s conflicts', at: ago(70) }] }),
      task('cleanup-ended-folders', 'Clean up ended sessions’ folders', 'review', { since: ago(118), worker: W_CLEAN, verifier: V_CLEAN, checkpoints: [{ text: 'Raised to audit: it has code that deletes files', at: ago(118) }] }),
      task('flaky-upload-test', 'Fix the flaky upload test', 'blocked', { since: ago(1080), after: ['sync-landing-base'] }),
      task('sidebar-consistency', 'UI consistency pass over the sidebar', 'planned', { since: ago(1500) }),
      task('cache-static-assets', 'Cache the static assets', 'done', { since: ago(2400), merged: { commit: '8a3f1e2', at: ago(2400), tested: true } }),
      task('footer-links', 'Fix the footer links', 'done', { since: ago(3900), merged: { commit: 'c41d7b9', at: ago(3900), tested: true } }),
    ],
  }]]);

  const cards = new Map(options.empty ? [] : [[CARD_LAUNCH, {
    id: CARD_LAUNCH, kind: 'question', project: SITE_PROJECT, root: SITE, open: true, closed: null, notice: null, at: ago(900), blocking: true,
    question: {
      id: 'q-launch-day', short: 'q-launch', text: 'Launch to the testers on Thursday, or wait for the sidebar fixes?', options: ['Thursday', 'Wait for the fixes'],
      priority: 'blocking', whyNow: 'The testers’ invite goes out tomorrow morning.', version: 2, revisionNote: 'Only the testers get it first',
      proposal: null, decideBy: null, state: 'open', answer: null, answeredVersion: null, withdrawReason: null, task: null,
    },
  }]]);

  const node = {
    node: 'local', epoch, root: `${HOME}/.vibeswitcher`, home: HOME,
    server: { pid: 48213, startedAt: ago(3 * 3600 + 720), commit: 'f62aef61' },
    host: {
      pid: 48190, startedAt: ago(2 * 86400 + 5 * 3600), state: 'connected', liveSessions: sessions.size - 1,
      notes: { startedAt: ago(2 * 86400 + 5 * 3600), serverRestarts: 3, replacedPaths: [], refusedAppConnections: 0, lockHeldElsewhere: null, build: 'f62aef61', at: ago(4) },
    },
    rule: { mode: 'systemd', says: 'a request is the user’s when its process is in a terminal’s scope of this login', scopes: ['init.scope', 'session-*.scope'] },
    cards: { questions: 1, approvals: 0, config: 0, base: 0 },
    accepted: [{ kind: 'lead', action: 'b7e0c2d4-5a61-4f38-9c0b-1e2d3f4a5b6c', at: ago(5400), pid: 51022, cgroup: '/init.scope', commandLine: ['vibeswitcher', 'lead', SITE] }],
    notices: options.empty ? [] : ['example-site: landing-base moved outside the lead’s merges; its next merge is refused until you accept the move'],
    restart: null,
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
  const prompt = (text, at) => ({ id: next('m'), kind: 'prompt', text, at: ago(at) });
  const reply = (text, at) => ({ id: next('m'), kind: 'reply', text, at: ago(at) });
  const tool = (name, title, detail, at, result = { output: '', failed: false, at: ago(at - 1) }) => ({ id: next('t'), kind: 'tool', name, title, detail, at: ago(at), result });
  const command = (line, output, at, result) => tool('Bash', line, { type: 'command', command: line }, at, result === undefined ? { output, failed: false, at: ago(at - 2) } : result);
  const read = (path, at) => tool('Read', 'Read ' + path.split('/').pop(), { type: 'read', path }, at);
  const edit = (path, changes, at) => tool('Edit', 'Edit ' + path.split('/').pop(), { type: 'edit', path, changes }, at);

  const RETRY_OLD = 'def deliver(event):\n    response = post(event.url, event.body)\n    if response.status >= 500:\n        log.warning("webhook failed", event.id)\n    return response';
  const RETRY_NEW = 'def deliver(event, attempt=1):\n    response = post(event.url, event.body)\n    if response.status >= 500 and attempt < MAX_ATTEMPTS:\n        queue.later(deliver, event, attempt + 1, delay=backoff(attempt))\n    elif response.status >= 500:\n        log.warning("webhook failed for good", event.id)\n    return response';

  if (!options.empty) {
    chats.set(ASKING, [
      prompt('Why does the payout job run twice?', 140),
      command('git log --oneline -5 -- jobs/payouts.py', '9c2e1d4 payouts: one worker per region\n51b0a77 payouts: read the schedule from the store\n0e8f3c2 payouts: nightly run', 132),
      read(`${API}/jobs/payouts.py`, 128),
      read(`${API}/jobs/scheduler.py`, 126),
      reply('The job takes its lock after it reads the schedule, so two workers can both see a run as due:\n\n- the scheduler starts one worker per region\n- each reads the schedule before it takes the lock\n- the second to get the lock runs the job again\n\nThe fix is to take the lock first, in `jobs/payouts.py`. Running its tests before I change it.', 60),
      command('pytest tests/test_payouts.py', '', 21, null),
      { id: next('a'), kind: 'ask', at: ago(20), title: 'Bash command', text: 'pytest tests/test_payouts.py\nDo you want to proceed?', options: ['Yes', 'Yes, and don’t ask again for this command', 'No, and tell Claude what to do differently'], answer: null },
    ]);
    chats.set(LEAD, [
      prompt('Sync the landing pages and finish the sidebar review.', 5400),
      tool('Read', 'Read workflow.md', { type: 'read', path: `${SITE}/.vibeswitcher/workflow.md` }, 5390),
      reply('Six tasks on the board. Two are independent and start now; the upload test waits on the sync, and the sidebar pass comes after the review.', 5370),
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

  // The changes go out as one delta, as the server batches them; a chat's only to who subscribed to it.
  function emit(...changes) {
    const sent = changes.filter((change) => change.in !== 'chat' || subscribed.has(change.session));
    if (!sent.length || down) return;
    seq += 1;
    store.apply({ v: 1, kind: 'delta', seq, changes: structuredClone(sent) });
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
    emit(chatPut(sid, item), setSession(sid, { detail: line }));
    later(ms, () => {
      if (!sessions.has(sid)) return;
      item.result = { output, failed, at: new Date().toISOString() };
      emit(chatPut(sid, item));
      done?.();
    });
  }

  function taskOf(slug) { return boards.get(SITE_PROJECT)?.tasks.find((entry) => entry.slug === slug); }
  function setTask(slug, fields) {
    Object.assign(taskOf(slug), fields);
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
      emit(chatPut(WEBHOOKS, pending));
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

  function handle(message) {
    const args = message.args || {};
    if (message.kind === 'answer') {
      const card = cards.get(args.card);
      if (!card) return { ok: false, error: { code: 'gone', message: 'That question is no longer on the board. Your answer wasn’t sent.' } };
      if (!card.open) return refused(card.question.state === 'autoDecided'
        ? `The timer had run out: the lead went ahead with ‘${card.question.answer}’. Your answer reached it as a note.`
        : `Already answered: ${card.question.answer}. Your new answer wasn’t sent.`);
      closeCard(card, 'answered', { state: 'answered', answer: args.answer, answeredVersion: card.question.version });
      if (card.kind === 'approval' && args.answer.startsWith('Approve')) {
        emit(setTask('cleanup-ended-folders', { status: 'done', since: new Date().toISOString(), merged: { commit: COMMIT.slice(0, 7), at: new Date().toISOString(), tested: true } }));
        later(700, () => stream(LEAD, 'Approved and merged: the clean-up is on landing-base.'));
      } else {
        later(700, () => stream(LEAD, `Got it: ${args.answer}. I’ll plan the rest around that.`));
      }
      return { ok: true, result: { card: card.id, state: 'answered' } };
    }
    if (message.kind === 'hold') {
      const card = cards.get(args.card);
      if (!card?.open) return refused('The timer had run out: the lead went ahead. It waits for nothing now.');
      card.question.decideBy = null;
      emit(put('cards', cards, card.id));
      return { ok: true, result: { card: card.id, held: true } };
    }
    if (message.kind === 'ask.answer') {
      const items = chats.get(args.session) || [];
      const ask = items.find((item) => item.id === args.item);
      if (!ask || ask.answer) return refused('It isn’t asking that any more.');
      ask.answer = args.answer;
      const pending = items.find((item) => item.kind === 'tool' && item.result === null);
      emit(chatPut(args.session, ask), setSession(args.session, { status: 'working', since: new Date().toISOString(), detail: 'Running the payout tests' }));
      later(2400, () => {
        if (pending) {
          pending.result = { output: '5 passed, 1 failed\n\nFAILED tests/test_payouts.py::test_two_workers_run_once', failed: true, at: new Date().toISOString() };
          emit(chatPut(args.session, pending));
        }
        stream(args.session, 'One test fails, and it’s the one that names the bug: `test_two_workers_run_once`. Moving the lock above the schedule read next.',
          () => emit(setSession(args.session, { status: 'done', since: new Date().toISOString(), detail: null })));
      });
      return { ok: true, result: {} };
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
      return { ok: true, result: {} };
    }
    if (message.kind === 'seen') {
      const target = sessions.get(args.session);
      if (target?.status === 'done') emit(setSession(args.session, { status: 'idle' }));
      return { ok: true, result: {} };
    }
    return { ok: false, error: { code: 'unknown-kind', message: `This node doesn’t take ${message.kind}.` } };
  }

  // ---- The feed's interface (what the WebSocket feed will offer too) ----

  let down = false;

  return {
    start() {
      later(options.still ? 0 : 320, () => {
        store.apply(snapshot());
        if (!options.still && !options.empty) story();
      });
    },
    // A snapshot again, after a gap.
    resync() { later(50, () => store.apply(snapshot())); },
    subscribeChat(sid) {
      later(options.still ? 0 : 140, () => {
        subscribed.add(sid);
        store.apply({ v: 1, kind: 'chat', session: sid, items: structuredClone(chats.get(sid) || []) });
      });
    },
    request(message) {
      return new Promise((resolve) => later(160, () => resolve(down ? { ok: false, error: { code: 'not-yet', message: 'The node isn’t answering. It’s sent again once it’s back.' } } : handle(message))));
    },
    // What a server restart looks like from here: the connection drops, then a new epoch's snapshot.
    restart() {
      down = true;
      subscribed.clear();
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
}
