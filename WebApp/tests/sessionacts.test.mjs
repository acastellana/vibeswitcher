// A session's own question answered from the page, and a session or a project's lead started from it (the UX review's
// U1 and U12, 2026-11-25), where the page acts and the node lists the kind (`session.reply`, `session.new`, `lead`);
// elsewhere the terminal's line and why. And the mock, which lists exactly those of a real acting node's kinds it
// answers, answers them as the node does, and with `older` lists none of them. Drawn on tests/fakedom.mjs's stand-in
// DOM over the real store, with an injected clock for the seconds an answer waits. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { installDom } from './fakedom.mjs';

installDom();
const { createMock } = await import('../js/mock.js');

const QUESTION = 'Bash command\n  pytest tests/test_payouts.py\nDo you want to proceed?';
const OPTIONS = ['Yes', 'Yes, and don’t ask again for this command', 'No, and tell Claude what to do differently (esc)'];
const SID = 'local:e91d05a3-4f6a-4c1e-9b7d-2e5a8c0d1f3b';

// ---- The mock ----

// A store that keeps what the mock gives it; `when(test)` resolves at the first delta `test` holds for.
function recorder() {
  const watchers = [];
  const got = { kinds: null, applied: [] };
  return {
    got,
    when: (holds) => new Promise((resolve) => watchers.push({ holds, resolve })),
    apply(message) {
      got.applied.push(structuredClone(message));
      for (const watcher of [...watchers]) if (watcher.holds(message)) { watchers.splice(watchers.indexOf(watcher), 1); watcher.resolve(message); }
    },
    setKinds(list) { got.kinds = list; }, setConnection() {}, chatSnapshot() {}, chatOps() {},
  };
}
async function started(options = {}) {
  const store = recorder();
  const mock = createMock(store, { still: true, ...options });
  const snapshot = store.when((message) => message.kind === 'snapshot');
  mock.start();
  await snapshot;
  return { store, mock, snapshot: store.got.applied[0] };
}
const STARTS = ['lead', 'session.new', 'session.reply', 'session.resume'];
const changed = (sid, holds) => (message) => message.kind === 'delta' && message.changes.some((change) => change.in === 'sessions' && change.id === sid && holds(change.value));

test('the mock lists a real acting node’s session starts and reply, answers every kind it lists, and none it doesn’t (ask.answer is no node’s)', async () => {
  const { store, mock } = await started();
  for (const kind of STARTS) assert.ok(store.got.kinds.includes(kind), kind);
  assert.ok(!store.got.kinds.includes('ask.answer'));
  for (const kind of store.got.kinds.filter((one) => one !== 'chat.page' && one !== 'stop')) {
    const reply = await mock.request({ kind, args: {} });
    assert.notEqual(reply.error?.code, 'unknown-kind', `${kind} is listed and refused as unknown`);
  }
  const unlisted = await mock.request({ kind: 'ask.answer', args: {} });
  assert.equal(unlisted.error?.code, 'unknown-kind');
  mock.stop();
});

test('the mock with older lists none of them and refuses each as unknown, as a node that doesn’t take them', async () => {
  const { store, mock } = await started({ older: true });
  for (const kind of STARTS) {
    assert.ok(!store.got.kinds.includes(kind), kind);
    assert.equal((await mock.request({ kind, args: { session: SID, folder: '/home/dev/projects/example-api', choice: 1 } })).error?.code, 'unknown-kind', kind);
  }
  assert.ok(store.got.kinds.includes('answer'), 'the rest as before');
  mock.stop();
});

test('the mock answers session.reply as the node does: the question checked again, refusals in its words, the question closing after the reply', async () => {
  const { store, mock } = await started();
  const ask = (args) => mock.request({ kind: 'session.reply', args: { session: SID, question: QUESTION, options: OPTIONS, ...args } });
  assert.match((await ask({ choice: 1, question: 'Something else?' })).error.message, /the question on its screen isn’t the one you were shown/);
  assert.match((await ask({ choice: 1, options: ['Yes'] })).error.message, /its options aren’t the ones you were shown/);
  assert.match((await ask({ choice: 4 })).error.message, /has 3 options, not 4/);
  assert.match((await ask({ choice: 1, text: 'more' })).error.message, /takes no words/);
  assert.equal((await ask({ choice: 0 })).error.code, 'bad-args');
  assert.equal((await ask({ session: 'local:00000000-4f6a-4c1e-9b7d-2e5a8c0d1f3b', choice: 1 })).error.code, 'gone', 'a session not running');
  const closes = store.when(changed(SID, (value) => value.prompt === null && value.status === 'working'));
  const done = await ask({ choice: 1 });
  assert.deepEqual(done, { ok: true, result: { session: SID, terminal: done.result.terminal, choice: 1, option: 'Yes', question: QUESTION } });
  await closes;
  assert.match((await ask({ choice: 1 })).error.message, /no question is open on its screen/, 'answered: nothing open any more');
  mock.stop();
});

test('the mock with toggle refuses a Space-toggled option as the node does', async () => {
  const { snapshot, mock } = await started({ toggle: true });
  const shown = snapshot.state.sessions.find((one) => one.id === SID).prompt;
  const reply = await mock.request({ kind: 'session.reply', args: { session: SID, choice: 2, question: shown.question, options: shown.options } });
  assert.match(reply.error.message, /option 2 is a setting toggled with Space \(Also scan shell history\): set it in the session’s terminal, or choose its Continue/);
  mock.stop();
});

test('the mock answers session.new, session.resume and lead as the node does: a bad folder refused, a session listed after the reply, an ended session gone', async () => {
  const { store, mock } = await started();
  const ask = (kind, args) => mock.request({ kind, args });
  assert.match((await ask('session.new', { folder: '/home/dev/nowhere' })).error.message, /isn’t a folder/);
  assert.equal((await ask('session.new', { folder: 'relative' })).error.code, 'bad-args');
  assert.equal((await ask('session.new', { folder: '/home/dev/projects/example-api', preset: 'Opus' })).error.code, 'bad-args', 'a preset needs its digest');
  assert.match((await ask('session.new', { folder: '/home/dev/projects/example-api', preset: 'Opus', digest: 'stale' })).error.message, /changed since it was shown/);
  const made = await ask('session.new', { folder: '/home/dev/projects/example-api', preset: 'Opus', digest: 'mock-opus' });
  assert.equal(made.ok, true, JSON.stringify(made));
  await store.when(changed(made.result.session, (value) => value?.cwd === '/home/dev/projects/example-api'));

  assert.match((await ask('lead', { folder: '/home/dev/nowhere' })).error.message, /isn’t in a git repository/);
  assert.match((await ask('lead', { folder: '/home/dev/projects/notes' })).error.message, /has no commits yet/);
  assert.equal((await ask('lead', { folder: '/home/dev/projects/example-site' })).result.happened, 'shown');
  const lead = await ask('lead', { folder: '/home/dev/projects/example-api' });
  assert.equal(lead.result.happened, 'started');
  await store.when((message) => message.kind === 'delta' && message.changes.some((change) => change.in === 'leads' && change.value?.session === lead.result.session));

  assert.equal((await ask('session.resume', { session: 'local:00000000' })).error.code, 'gone');
  const notes = await ask('session.resume', { session: 'local:9d2b4f60-4f6a-4c1e-9b7d-2e5a8c0d1f3b' });
  assert.deepEqual(notes.result.reopened, []);
  assert.match(notes.result.refused[0].why, /conversation id wasn’t recorded/);
  const back = await ask('session.resume', { session: 'local:5c1e7a92-4f6a-4c1e-9b7d-2e5a8c0d1f3b' });
  assert.equal(back.result.reopened.length, 1);
  assert.match((await ask('session.reply', { session: 'local:5c1e7a92-4f6a-4c1e-9b7d-2e5a8c0d1f3b', choice: 1 })).error.message, /no live session/, 'an ended session isn’t answered');
  mock.stop();
});
