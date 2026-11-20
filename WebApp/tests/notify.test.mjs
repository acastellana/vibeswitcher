// The notifications' decisions (js/notify.js): what needs you (open cards, a prompt waiting; never a worker's or a
// verifier's, nor a lead's whose question is a card), what is told between two looks (each new ask, a lead that
// stopped), the first line only and inert, and the title bar's count. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { summarize, changes, firstLine, titled } from '../js/notify.js';

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
