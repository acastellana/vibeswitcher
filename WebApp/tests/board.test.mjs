// A lead's board on the page (the `boards` collection, read by the redesigned page's columns): the node's own vectors through the feed
// into the store, grouped as the board shows them (needs attention, running, waiting, done today), a task that moves
// moving in place, a node from before the boards still going live, and the words the rows say. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createStore } from '../js/store.js';
import { connectSocket } from '../js/socket.js';
import { validate } from '../wire/validators.js';
import { taskGroup, taskState, taskTone, taskLine, decisionLine, allDoneCard } from '../js/words.js';
import { standing, taskTone as conversationTone } from '../js/conversation.js';
import { parseRoute, boardHref } from '../js/ui.js';

const vectors = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'wire', 'vectors.json'), 'utf8'));
const vector = (name) => structuredClone(vectors[name]);
const PROJECT = vector('snapshot.boards').entries[0].id;
// The vectors' board is made at 09:30 on Nov 17 (UTC); its merged task finished at 08:30 the same day. "Today" is the
// reader's day, so these run on UTC's.
process.env.TZ = 'UTC';
const NOW = Date.parse('2026-11-17T09:30:00.000Z');

// A page on a fake socket, served each subscription's snapshot vector; `refuse`: collections the node doesn't have.
async function page({ refuse = [] } = {}) {
  const store = createStore();
  const sockets = [];
  class FakeSocket {
    constructor() { this.sent = []; this.readyState = 0; sockets.push(this); }
    send(text) { this.sent.push(JSON.parse(text)); }
    close() { this.readyState = 3; this.onclose?.(); }
  }
  const warnings = [];
  const feed = connectSocket(store, {
    url: 'ws://127.0.0.1:47830/ws', WebSocket: FakeSocket, storage: { getItem: () => 'token', setItem() {}, removeItem() {} }, validate,
    build: Promise.resolve(null), setTimeout: () => 0, clearTimeout: () => {}, location: { hash: '', pathname: '/', search: '' },
    history: { replaceState() {} }, reload() {}, log: (...args) => warnings.push(args.join(' ')),
  });
  store.connect(feed);
  await feed.start();
  const socket = sockets[0];
  socket.readyState = 1;
  socket.onopen();
  socket.onmessage({ data: JSON.stringify(vector('hello.web')) });
  for (const request of socket.sent.filter((message) => message.kind === 'subscribe')) {
    const { sub, collection } = request.args;
    if (refuse.includes(collection)) {
      socket.onmessage({ data: JSON.stringify({ v: 1, re: request.id, ok: false, error: { code: 'bad-args', message: `no such collection: ${collection}` } }) });
      continue;
    }
    socket.onmessage({ data: JSON.stringify({ v: 1, re: request.id, ok: true, result: { sub, mode: 'snapshot' } }) });
    socket.onmessage({ data: JSON.stringify({ ...vector('snapshot.' + collection), sub }) });
  }
  await new Promise((resolve) => setImmediate(resolve));
  const say = (message) => socket.onmessage({ data: JSON.stringify(message) });
  return { store, socket, say, warnings };
}

test('the boards are followed, and a lead’s board is in the store by its project', async () => {
  const { store, socket } = await page();
  const asked = socket.sent.find((message) => message.kind === 'subscribe' && message.args.collection === 'boards');
  assert.ok(asked, 'the page subscribes to boards');
  assert.equal(validate('frame', asked), null);
  assert.equal(store.state.connection, 'live');
  const board = store.state.boards.get(PROJECT);
  assert.equal(board.project, PROJECT);
  assert.deepEqual(board.tasks.map((task) => task.slug), ['pricing-copy', 'onboarding-steps', 'upload-retry', 'sidebar-pass', 'cache-assets']);
});

test('the board reads as the page stands it: blocked, in motion, queued, merged today', async () => {
  const { store } = await page();
  const team = standing(store.state.boards.get(PROJECT), NOW);
  assert.deepEqual(Object.entries(team).map(([where, tasks]) => [where, tasks.map((task) => task.slug)]), [
    ['motion', ['onboarding-steps', 'upload-retry']],
    ['blocked', ['pricing-copy']],
    ['queued', ['sidebar-pass']],
    ['merged', ['cache-assets']],
  ]);
  const blocked = team.blocked[0];
  assert.equal(taskState(blocked), 'Blocked');
  assert.match(blocked.blocker, /^Which plan names/);
  assert.equal(blocked.blocker.split('\n').length, 3, 'the blocker keeps its lines');
  assert.equal(conversationTone(blocked), 'blocked');
  assert.equal(team.motion[0].worker, 'local:8d1f0c2b-6e4a-4b3d-9c7e-5a2f1e0d9b84', 'a running task names its worker’s session');
});

test('a board’s delta moves a task in place: its question answered, it runs; its review passed, it’s ready', async () => {
  const { store, say } = await page();
  const before = store.state.boards.get(PROJECT);
  say(vector('delta.board-task'));
  const after = store.state.boards.get(PROJECT);
  assert.notEqual(after, before);
  const team = standing(after, NOW + 60_000);
  assert.deepEqual(team.blocked, [], 'nothing blocked any more');
  assert.deepEqual(team.motion.map((task) => [task.slug, taskState(task), conversationTone(task)]),
    [['pricing-copy', 'Working', 'working'], ['onboarding-steps', 'Rework 1', 'working'], ['upload-retry', 'Ready to merge', 'ready']]);
});

test('a merged task from yesterday isn’t "merged today"', () => {
  const task = { status: 'done', group: 'done', merged: { at: '2026-11-16T09:00:00.000Z' } };
  assert.deepEqual(standing({ tasks: [task] }, NOW).merged, []);
  assert.equal(standing({ tasks: [{ ...task, merged: { at: '2026-11-17T08:00:00.000Z' } }] }, NOW).merged.length, 1);
});

test('a node from before the boards: the page goes live without them, and knows it has none', async () => {
  const { store, warnings } = await page({ refuse: ['boards'] });
  assert.equal(store.state.connection, 'live');
  assert.equal(store.follows('boards'), false);
  assert.equal(store.state.boards.size, 0);
  assert.deepEqual(warnings, [], 'a missing collection is no error');
});

test('a mock board (no group, state or line) is read from its statuses', () => {
  assert.equal(taskGroup({ status: 'blocked' }), 'attention');
  assert.equal(taskGroup({ status: 'review' }), 'running');
  assert.equal(taskGroup({ status: 'planned' }), 'waiting');
  assert.equal(taskGroup({ status: 'folded' }), 'done');
  assert.equal(taskState({ status: 'review' }), 'In review');
  assert.equal(taskTone({ status: 'failed' }), 'needs-you');
});

test('a task at work shows its AI summary as its line; without one, its own line, a blocker’s first line not said twice', () => {
  assert.equal(taskLine({ summary: 'Fixing the upload retry', line: 'Step two' }), 'Fixing the upload retry');
  assert.equal(taskLine({ summary: null, line: 'Step two' }), 'Step two');
  assert.equal(taskLine({ line: 'Waits on lead', blocker: 'Waits on lead\nmore' }), '');
  assert.equal(taskLine({ line: null }), '');
  const tasks = vector('board')[1].result.boards[0].tasks;
  assert.ok(tasks.every((task) => 'summary' in task), 'the node sends every task’s summary, null or a line');
  const working = tasks.find((task) => task.summary);
  assert.equal(working.status, 'running');
  assert.equal(taskLine(working), working.summary);
});

test('the board page’s old address is the project’s lead conversation now, and any project id survives it', () => {
  const id = 'local:project:a/b c#d';
  const lead = { name: 'project', id, view: 'lead', show: 'decisions', tab: 'team', task: null, sheet: null };
  assert.deepEqual(parseRoute(boardHref(id)), lead);
  assert.deepEqual(parseRoute('#/p/' + encodeURIComponent(id)), lead, 'the address before the redesign');
  assert.deepEqual(parseRoute('#/p/%E0%A4%A'), { name: 'home' }, 'a broken escape is the start page');
});

test('the lead’s decisions: a long one by its AI summary, each as "Decided: …", a name kept as it is', () => {
  const [long, short] = vector('board')[1].result.boards[0].decisions;
  assert.equal(validate('board.decision', long), null);
  assert.equal(decisionLine(long), 'Decided: run the two small tasks side by side');
  assert.equal(short.summary, null);
  assert.equal(decisionLine(short), 'Decided: keep the sidebar pass for after onboarding');
  assert.equal(decisionLine({ text: 'API keys stay in the vault', summary: null }), 'Decided: API keys stay in the vault');
  assert.equal(decisionLine({ text: 'VibeSwitcher builds go first', summary: null }), 'Decided: VibeSwitcher builds go first');
});

test('the batch that cleared the board: its summary, what it cost, and each task with how it ended', () => {
  const mark = vector('board')[1].result.boards[0].allDone;
  assert.equal(validate('board.allDone', mark), null);
  const card = allDoneCard(mark);
  assert.equal(card.headline, mark.summary.headline);
  assert.deepEqual(card.bullets, mark.summary.bullets);
  assert.ok(card.cost.startsWith('Cost: 2 tasks, 1.5 h of worker time'), card.cost);
  assert.equal(card.count, '3 tasks · 2 merged');
  assert.deepEqual(card.tasks.map((task) => task.word), ['merged', 'merged', 'set aside']);
  assert.equal(allDoneCard(null), null);
  assert.equal(allDoneCard({ ...mark, summary: null, receipts: null, pricesAsOf: null }).cost, null);
  assert.equal(validate('seen.args', { project: 'local:project:x', mark: mark.id }), null);
  assert.notEqual(validate('seen.args', { project: 'local:project:x', mark: 5 }), null);
});

test('the all-done card is also an item of the lead’s chat, in the node’s shape', () => {
  const { id, at, ...fields } = vector('board')[1].result.boards[0].allDone;
  const item = { id: `all-done:${id}`, type: 'allDone', at, ...fields };
  assert.equal(validate('chat.item', item), null);
  assert.notEqual(validate('chat.item', { ...item, merged: 'two' }), null);
});

test('the lead’s results come with the board, newest first, each its title, markdown body and screenshots counted', () => {
  const [result] = vector('board')[1].result.boards[0].results;
  assert.equal(validate('board.update', result), null);
  assert.equal(result.title, 'The new hero, on a phone');
  assert.ok(result.body.includes('**sized for phones**'), 'the markdown as the lead wrote it: the page draws it to nodes');
  assert.equal(result.images, 1, 'a screenshot is a file on the node: counted, never its path');
});
