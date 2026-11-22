// The inspector's parts that need no page: which tab shows for the one remembered, whose team a session is in, and the
// Activity tab's ledger, made from a chat's items and nothing else. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { inspectorTab, teamOf } from '../js/ui.js';
import { ledger, fileWords, LIMIT } from '../js/activity.js';
import { session as wireSession } from '../js/wire.js';

const CWD = '/home/dev/projects/example-site';
const at = (seconds, ms = 0) => new Date(Date.UTC(2026, 10, 17, 9, 0, seconds, ms)).toISOString();
const prompt = (id) => ({ id, kind: 'prompt', text: 'Go on', at: at(0) });
const edit = (id, path, changes, result = { output: '', failed: false, at: at(2) }) => ({ id, kind: 'tool', name: 'Edit', title: 'Edit', at: at(1), detail: { type: 'edit', path, changes }, result });
const write = (id, path, content) => ({ id, kind: 'tool', name: 'Write', title: 'Write', at: at(1), detail: { type: 'write', path, content }, result: { output: '', failed: false, at: at(2) } });
const command = (id, line, fields = {}) => ({ id, kind: 'tool', name: 'Bash', title: line, at: at(10), detail: { type: 'command', command: line }, result: { output: '', failed: false, at: at(13) }, ...fields });

test('the tab shown is the one remembered, and Team on a session with no team is Overview there', () => {
  assert.equal(inspectorTab('team', true), 'team');
  assert.equal(inspectorTab('team', false), 'overview');
  assert.equal(inspectorTab('activity', false), 'activity');
  assert.equal(inspectorTab('overview', true), 'overview');
  assert.equal(inspectorTab('something else', true), 'overview');
});

test('a session is in a team when it has a role and the node knows its lead or its board', () => {
  const project = 'local:project:Zx3k';
  const store = { leads: new Map([[project, { project }]]), boards: new Map() };
  assert.equal(teamOf(store, { role: 'lead', lead: project }), project);
  assert.equal(teamOf(store, { role: 'worker', lead: project }), project);
  assert.equal(teamOf(store, { role: null, lead: project }), null, 'no role, no team');
  assert.equal(teamOf(store, { role: 'worker', lead: null }), null, 'a worker whose lead the node doesn’t say');
  assert.equal(teamOf(store, { role: 'worker', lead: 'local:project:other' }), null, 'a lead the node doesn’t list');
  assert.equal(teamOf({ leads: new Map(), boards: new Map([[project, { project, tasks: [] }]]) }, { role: 'verifier', lead: project }), project);
  assert.equal(teamOf(store, undefined), null);
});

test('a live worker has no Team to show: the node doesn’t say whose team it is in', () => {
  const worker = wireSession({ id: 'local:w', role: 'worker', status: 'working', shownStatus: 'working', since: at(0), task: 'Login fix', activity: 'Run unit tests', detail: null }, new Map());
  assert.equal(worker.lead, null);
  assert.equal(worker.activity, 'Run unit tests', 'the tool call it runs is the node’s own field, kept');
  assert.equal(teamOf({ leads: new Map([['local:project:p', {}]]), boards: new Map() }, worker), null);
});

test('the ledger counts an edit’s lines, sums a file’s edits in one turn, and starts again at the next prompt', () => {
  const items = [
    prompt('p1'),
    edit('t1', `${CWD}/tools/cleanup.py`, [{ old: 'a\nb', new: 'a\nc\nd' }]),
    { id: 'r1', kind: 'tool', name: 'Read', title: 'Read cleanup.py', at: at(3), detail: { type: 'read', path: `${CWD}/tools/cleanup.py` }, result: { output: '', failed: false, at: at(3) } },
    edit('t2', `${CWD}/tools/cleanup.py`, [{ old: 'x', new: 'y' }, { old: '', new: 'z' }]),
    { id: 'm1', kind: 'reply', text: 'Done.', at: at(4) },
    prompt('p2'),
    edit('t3', `${CWD}/tools/cleanup.py`, [{ old: 'y', new: '' }]),
  ];
  const rows = ledger(items, { cwd: CWD });
  assert.deepEqual(rows.map((row) => row.key), [`file|p1|${CWD}/tools/cleanup.py`, `file|p2|${CWD}/tools/cleanup.py`]);
  assert.deepEqual({ ...rows[0], key: undefined }, { key: undefined, kind: 'file', path: 'tools/cleanup.py', folder: 'tools/', name: 'cleanup.py', verb: 'Edited', edits: 2, added: 4, removed: 2, replaced: true });
  assert.equal(fileWords(rows[0]), 'Edited, 2 times');
  assert.equal(rows[1].added, 0);
  assert.equal(rows[1].removed, 1);
  assert.equal(fileWords(rows[1]), 'Edited');
});

test('a written file counts its lines and none removed; a change that failed isn’t one; a path outside the folder is whole', () => {
  const rows = ledger([
    write('t1', `${CWD}/notes.md`, 'one\ntwo\n'),
    edit('t2', `${CWD}/broken.py`, [{ old: 'a', new: 'b' }], { output: 'no such text', failed: true, at: at(2) }),
    edit('t3', '/home/dev/.config/tool.toml', [{ old: 'a', new: 'b' }]),
    edit('t4', '/etc/hosts', [{ old: 'a', new: 'b' }]),
  ], { cwd: CWD + '/', home: '/home/dev' });
  assert.deepEqual(rows.map((row) => [row.path, row.verb, row.added, row.removed, row.replaced]), [
    ['notes.md', 'Written', 2, 0, false],
    ['~/.config/tool.toml', 'Edited', 1, 1, true],
    ['/etc/hosts', 'Edited', 1, 1, true],
  ]);
  assert.deepEqual([rows[0].folder, rows[0].name], ['', 'notes.md']);
  assert.deepEqual([rows[2].folder, rows[2].name], ['/etc/', 'hosts']);
});

test('a command says its first line, its time from call to result, and that it failed or still runs', () => {
  const rows = ledger([
    command('c1', 'npm test'),
    command('c2', 'for i in 1 2; do\n  npm test\ndone', { title: 'Run the tests twice' }),
    command('c3', 'pytest', { result: { output: '1 failed', failed: true, at: at(10, 400) } }),
    command('c4', 'npm run dev', { result: null }),
  ]);
  assert.deepEqual(rows, [
    { key: 'command|c1', kind: 'command', title: 'npm test', line: null, took: 3, failed: false, running: false },
    { key: 'command|c2', kind: 'command', title: 'Run the tests twice', line: 'for i in 1 2; do …', took: 3, failed: false, running: false },
    { key: 'command|c3', kind: 'command', title: 'pytest', line: null, took: 0.4, failed: true, running: false },
    { key: 'command|c4', kind: 'command', title: 'npm run dev', line: null, took: null, failed: false, running: true },
  ]);
});

test('the ledger keeps the newest rows, counts an edit once however often it is asked, and ignores what it doesn’t know', () => {
  const many = [];
  for (let i = 0; i < LIMIT + 20; i++) many.push(command('c' + i, 'echo ' + i));
  const rows = ledger(many);
  assert.equal(rows.length, LIMIT);
  assert.equal(rows[0].title, 'echo 20');
  assert.equal(rows.at(-1).title, `echo ${LIMIT + 19}`);

  const counts = new Map();
  const changes = [{ old: 'a', new: 'b' }];
  const first = ledger([edit('t1', '/x/a.txt', changes)], { counts });
  // The same call given again (a chat's items are replaced whole at every change): the count kept is used.
  changes[0].new = 'b\nc\nd';
  const again = ledger([edit('t1', '/x/a.txt', changes)], { counts });
  assert.equal(first[0].added, 1);
  assert.equal(again[0].added, 1);

  assert.deepEqual(ledger([{ id: 'n', kind: 'team', text: 'A report' }, { id: 'u', kind: 'tool', name: 'Other', title: 'Other', at: at(0) },
    { id: 'v', kind: 'tool', name: 'Todo', title: 'Todo', at: at(0), detail: { type: 'todos', todos: [] }, result: null }]), []);
});

test('a lead’s row says it was replaced, and shows the all-done check while its board’s mark is unseen', async () => {
  const { leadMarks } = await import('../js/ui.js');
  const state = (replaced, allDone) => ({ leads: new Map([['p', { project: 'p', session: 'new', replaced }]]), boards: new Map([['p', { project: 'p', allDone }]]) });
  const lead = (id) => ({ id, role: 'lead', lead: 'p' });
  assert.deepEqual(leadMarks(state(['old'], null), lead('old')), { replaced: true, allDone: false });
  assert.deepEqual(leadMarks(state([], { id: 'm', seen: false }), lead('new')), { replaced: false, allDone: true });
  assert.deepEqual(leadMarks(state([], { id: 'm', seen: true }), lead('new')), { replaced: false, allDone: false });
  assert.deepEqual(leadMarks(state(['old'], { id: 'm', seen: false }), lead('old')), { replaced: true, allDone: false });
  assert.deepEqual(leadMarks(state([], null), { id: 'w', role: 'worker', lead: 'p' }), { replaced: false, allDone: false });
});
