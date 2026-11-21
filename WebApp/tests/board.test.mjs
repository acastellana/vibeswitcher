// A lead's board on the page (views/board.js's data, the `boards` collection): the node's own vectors through the feed
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
import { boardGroups, boardSummary, taskGroup, taskState, taskTone, taskLine, doneToday } from '../js/words.js';
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

test('the board reads in its groups: needs attention, running, waiting, done today', async () => {
  const { store } = await page();
  const groups = boardGroups(store.state.boards.get(PROJECT), NOW);
  assert.deepEqual(groups.map((group) => [group.title, group.tasks.map((task) => task.slug)]), [
    ['Needs attention', ['pricing-copy']],
    ['Running', ['onboarding-steps', 'upload-retry']],
    ['Waiting', ['sidebar-pass']],
    ['Done today', ['cache-assets']],
  ]);
  assert.equal(boardSummary(groups), '1 needs attention · 2 running · 1 waiting · 1 done today');
  const blocked = groups[0].tasks[0];
  assert.equal(taskState(blocked), 'Blocked');
  assert.match(blocked.blocker, /^Which plan names/);
  assert.equal(blocked.blocker.split('\n').length, 3, 'the blocker keeps its lines, for the row to fold');
  assert.equal(taskTone(blocked), 'blocked');
  assert.equal(groups[1].tasks[0].worker, 'local:8d1f0c2b-6e4a-4b3d-9c7e-5a2f1e0d9b84', 'a running task names its worker’s session');
});

test('a board’s delta moves a task in place: its question answered, it runs; its review passed, it’s ready', async () => {
  const { store, say } = await page();
  const before = store.state.boards.get(PROJECT);
  say(vector('delta.board-task'));
  const after = store.state.boards.get(PROJECT);
  assert.notEqual(after, before);
  const groups = boardGroups(after, NOW + 60_000);
  assert.deepEqual(groups[0].tasks, [], 'nothing needs attention any more');
  assert.deepEqual(groups[1].tasks.map((task) => [task.slug, taskState(task)]),
    [['pricing-copy', 'Working'], ['onboarding-steps', 'Rework 1'], ['upload-retry', 'Ready to merge']]);
});

test('a done task from yesterday isn’t "done today"', () => {
  const task = { status: 'done', group: 'done', merged: { at: '2026-11-16T09:00:00.000Z' } };
  assert.equal(doneToday(task, NOW), false);
  assert.equal(doneToday({ ...task, merged: { at: '2026-11-17T08:00:00.000Z' } }, NOW), true);
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

test('a board has an address of its own, and any project id survives it', () => {
  const id = 'local:project:a/b c#d';
  assert.deepEqual(parseRoute(boardHref(id)), { name: 'board', id });
  assert.deepEqual(parseRoute('#/p/%E0%A4%A'), { name: 'home' }, 'a broken escape is the start page');
});
