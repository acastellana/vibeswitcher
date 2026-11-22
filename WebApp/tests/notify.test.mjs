// The notifications' decisions (js/notify.js): what needs you (open cards, a prompt waiting; never a worker's or a
// verifier's, nor a lead's whose question is a card), what is told between two looks (each new ask, a lead that
// stopped), the first line only and inert, and the title bar's count. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { summarize, changes, firstLine, titled, sounding, chime, kindOf, wanted } from '../js/notify.js';

const session = (id, fields = {}) => ({ id, terminal: 'pts/1', agent: 'claude', cwd: '/home/dev/projects/app', status: 'idle', since: '2026-11-20T09:00:00.000Z', role: null, ...fields });
const card = (id, fields = {}) => ({ id, kind: 'question', project: 'p1', root: '/home/dev/projects/app', open: true, question: { text: 'Ship it?\nMore detail.' }, ...fields });

function state({ sessions = [], cards = [], leads = [], cardKeys = new Map() } = {}) {
  return {
    sessions: new Map(sessions.map((entry) => [entry.id, entry])),
    cards: new Map(cards.map((entry) => [entry.id, entry])),
    leads: new Map(leads.map((entry) => [entry.project, entry])),
    cardKeys,
  };
}

test('the first line only, without controls or bidirectional marks, cut with an ellipsis', () => {
  assert.equal(firstLine('\n  Ship it?  \nsecond line'), 'Ship it?');
  assert.equal(firstLine('a\u202eb\u0007c\u200bd\u2066e'), 'abcde');
  assert.equal(firstLine('x'.repeat(200), 10), 'xxxxxxxxx…');
  assert.equal(firstLine(null), '');
});

test('what needs you: open cards and prompts waiting; not a worker, a verifier, a closed card, or a lead whose question is a card', () => {
  const now = summarize(state({
    leads: [{ project: 'p1', session: 'lead-1' }],
    cards: [card('c1'), card('c2', { open: false }), card('c3', { kind: 'approval', question: undefined, approval: { subject: 'Add dark mode\nbody', commit: 'abc' } })],
    sessions: [
      session('lead-1', { role: 'lead', status: 'needs-you', leadAsks: true }),
      session('w1', { role: 'worker', status: 'needs-you' }),
      session('v1', { role: 'verifier', status: 'needs-you' }),
      session('s1', { status: 'needs-you', title: 'Fix the build', detail: 'Run: npm publish\nmore' }),
      session('s2', { status: 'needs-you', paused: true }),
    ],
  }));
  assert.deepEqual([...now.asks.keys()], ['card:c1', 'card:c3', 'prompt:s1:2026-11-20T09:00:00.000Z']);
  assert.deepEqual(now.asks.get('card:c1'), { title: 'A question for you · app', body: 'Ship it?', href: '#/s/lead-1' });
  assert.equal(now.asks.get('card:c3').body, 'Add dark mode');
  assert.deepEqual(now.asks.get('prompt:s1:2026-11-20T09:00:00.000Z'), { title: 'Fix the build needs you', body: 'Run: npm publish', href: '#/s/s1' });
});

test('each new ask is told once; one already there, or a card back under a new id after a restart, is not', () => {
  const before = summarize(state({ cards: [card('c1')] }));
  const after = summarize(state({ cards: [card('c1'), card('c2', { question: { text: 'Blue or red?' } })] }));
  assert.deepEqual(changes(before, after).map((note) => [note.key, note.body]), [['card:c2', 'Blue or red?']]);
  assert.deepEqual(changes(after, after), []);
  const restarted = summarize(state({ cards: [card('c9')], cardKeys: new Map([['c9', 'c1']]) }));
  assert.deepEqual(changes(before, restarted), []);
});

test('a lead that was working and stops is told: its turn over, or its session gone; one that wasn’t working is not', () => {
  const lead = (status, fields = {}) => session('lead-1', { role: 'lead', status, title: 'Lead · app', ...fields });
  const working = summarize(state({ sessions: [lead('working')] }));
  assert.deepEqual(changes(working, summarize(state({ sessions: [lead('done')] }))).map((note) => [note.key, note.title, note.href]),
    [['stopped:lead-1', 'Lead · app stopped', '#/s/lead-1']]);
  assert.deepEqual(changes(working, summarize(state())).map((note) => [note.key, note.body]), [['stopped:lead-1', 'The lead’s session ended.']]);
  assert.deepEqual(changes(working, summarize(state({ sessions: [lead('background')] }))), []);
  assert.deepEqual(changes(summarize(state({ sessions: [lead('idle')] })), summarize(state({ sessions: [lead('done')] }))), []);
});

test('the title bar counts what needs you', () => {
  assert.equal(titled('VibeSwitcher', 2), '(2) VibeSwitcher');
  assert.equal(titled('(2) VibeSwitcher', 3), '(3) VibeSwitcher');
  assert.equal(titled('(3) Fix it · VibeSwitcher', 0), 'Fix it · VibeSwitcher');
});

test('the sound is for something new that needs you, not a lead that stopped', () => {
  assert.equal(sounding([{ key: 'card:c1' }]), true);
  assert.equal(sounding([{ key: 'prompt:s1:2026-11-20T09:00:00.000Z' }]), true);
  assert.equal(sounding([{ key: 'stopped:lead-1' }]), false);
  assert.equal(sounding([]), false);
});

test('the chime is two short soft notes made on the page, each stopped within half a second', () => {
  const made = [];
  const param = () => ({ value: 0, setValueAtTime() {}, exponentialRampToValueAtTime(value) { this.peak = Math.max(this.peak || 0, value); } });
  const context = {
    currentTime: 10, destination: {},
    createOscillator() { const tone = { frequency: param(), connect() {}, start(at) { tone.started = at; }, stop(at) { tone.stopped = at; } }; made.push(tone); return tone; },
    createGain() { return { gain: param(), connect() {} }; },
  };
  chime(context);
  assert.deepEqual(made.map((tone) => tone.frequency.value), [660, 990]);
  for (const tone of made) assert.ok(tone.started >= 10 && tone.stopped - tone.started < 0.5, JSON.stringify(tone));
});

test('a freeze the node keeps after the page looked is told once; one from before, or none, is not', () => {
  const withHealth = (freezes) => ({ ...state(), node: { health: { freezes } } });
  const none = summarize(state());
  const quiet = summarize(withHealth([]));
  const frozen = summarize(withHealth([{ at: '2026-11-21T10:00:00.000Z', seconds: 14 }]));
  // The first look at a node with a freeze already kept: nothing (the page had no digest before).
  assert.deepEqual(changes(none, frozen), []);
  const told = changes(quiet, frozen);
  assert.equal(told.length, 1);
  assert.equal(told[0].key, 'freeze:2026-11-21T10:00:00.000Z');
  assert.match(told[0].body, /didn’t answer for 14 s/);
  assert.equal(told[0].href, '#/node');
  assert.equal(sounding(told), false);
  assert.deepEqual(changes(frozen, frozen), []);
});

test('a session of yours that finishes its work is told; a worker’s, a verifier’s, a paused one or one not working is not', () => {
  const mine = (status, fields = {}) => session('s-1', { status, title: 'Fix the login', ...fields });
  const was = summarize(state({ sessions: [mine('working')] }));
  assert.deepEqual(changes(was, summarize(state({ sessions: [mine('done')] }))).map((note) => [note.key, note.title, note.body, note.href]),
    [['finished:s-1', 'Fix the login finished', 'It finished its work.', '#/s/s-1']]);
  assert.deepEqual(changes(was, summarize(state())).map((note) => note.body), ['Its session ended.']);
  assert.deepEqual(changes(was, summarize(state({ sessions: [mine('background')] }))), []);
  for (const role of ['worker', 'verifier']) {
    const team = (status) => session('w-1', { status, role });
    assert.deepEqual(changes(summarize(state({ sessions: [team('working')] })), summarize(state({ sessions: [team('done')] }))), [], role);
  }
  assert.deepEqual(changes(summarize(state({ sessions: [mine('working', { paused: true })] })), summarize(state({ sessions: [mine('done')] }))), []);
});

test('each kind is told only while its choice is on: something needs me, a session finishes', () => {
  const told = [{ key: 'card:c1' }, { key: 'prompt:s1:x' }, { key: 'freeze:t' }, { key: 'stopped:l1' }, { key: 'finished:s2' }];
  assert.deepEqual(told.map(kindOf), ['needs', 'needs', 'needs', 'done', 'done']);
  assert.deepEqual(wanted(told, { needs: true, done: true }), told);
  assert.deepEqual(wanted(told, { needs: true, done: false }).map((note) => note.key), ['card:c1', 'prompt:s1:x', 'freeze:t']);
  assert.deepEqual(wanted(told, { needs: false, done: true }).map((note) => note.key), ['stopped:l1', 'finished:s2']);
  assert.equal(sounding(wanted(told, { needs: false, done: true })), false, 'no sound for what isn’t told');
});

test('a reminder from the node is told once a wait or a stall, as its own kind, not for a paused session', () => {
  const reminder = (session, kind, since, fields = {}) => ({ session, kind, since, dueAt: since, title: 'example-app is still waiting for you',
    subtitle: 'For 11 min', body: 'Bash: npm test\u001b[2J', ...fields });
  const withNode = (reminders, sessions = [session('s1', { status: 'needs-you' })]) => ({ ...state({ sessions }), node: { reminders } });
  const none = summarize(withNode([]));
  const due = summarize(withNode([reminder('s1', 'waiting', '2026-11-22T09:00:00.000Z')]));
  const told = changes(none, due);
  assert.deepEqual(told.map((note) => [note.key, note.title, note.body, note.href]), [[
    'reminder:s1:waiting:2026-11-22T09:00:00.000Z', 'example-app is still waiting for you', 'For 11 min · Bash: npm test[2J', '#/s/s1']]);
  assert.equal(kindOf(told[0]), 'reminders');
  // The same reminder standing: told once. A new wait (another episode): told again.
  assert.deepEqual(changes(due, summarize(withNode([reminder('s1', 'waiting', '2026-11-22T09:00:00.000Z')]))), []);
  assert.equal(changes(due, summarize(withNode([reminder('s1', 'waiting', '2026-11-22T10:00:00.000Z')]))).length, 1);
  // Not counted as needing you (the title's count), and turned off by its own choice.
  assert.equal(due.asks.size, 1);
  assert.deepEqual(wanted(told, { needs: true, done: true, reminders: false }), []);
  assert.equal(wanted(told, { needs: false, done: false, reminders: true }).length, 1);
  // A paused session isn't reminded of.
  assert.equal(summarize(withNode([reminder('s1', 'stalled', 'x')], [session('s1', { paused: true })])).reminders.size, 0);
});
