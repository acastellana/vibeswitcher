// The redesigned page's parts with no page in them (docs/superpowers/specs/2026-11-23-v2-web-ui-design.md): the lead
// conversation's lines and the dial's counts from the node's own board vector, a long text's head line, a task's steps
// and colour, whom a blocked task waits on, the projects the left lists and which opens first, the deep links, and the
// string table. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { leadLines, shownLines, dialCounts, questionHead, cut, shortHashes, firstSentence, taskStep, taskTone, teamCounts, standing, waitsOn,
  waitingCards, projectsOf, firstProject, lineKey, waitingPlaces, nextPlace, goalRows } from '../js/conversation.js';
import { parseRoute, projectHref, routeHref, sessionHref, boardHref } from '../js/ui.js';
import { t, TABLES, pickLanguage, setLanguage, listed } from '../js/i18n.js';
import { tellLine } from '../js/actions.js';

const vectors = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'wire', 'vectors.json'), 'utf8'));
const board = structuredClone(vectors.board[1].result.boards[0]);
process.env.TZ = 'UTC';

test('a question’s line is the first sentence that asks, else its first sentence; hashes short, a cut at a word', () => {
  assert.equal(questionHead('The deploy failed twice overnight. Should we roll back to the build from Monday, or wait?\nMore.'), 'Should we roll back to the build from Monday, or wait?');
  assert.equal(questionHead('Asked again (reworded): **ship** the `beta` today.'), 'Ship the beta today.');
  assert.equal(questionHead('No question here. Just a note'), 'No question here.');
  assert.equal(firstSentence('One. Two.'), 'One.');
  assert.equal(shortHashes('merged 0123456789abcdef0123456789abcdef01234567 into main'), 'merged 01234567 into main');
  assert.equal(shortHashes('a word like deadbeef stays'), 'a word like deadbeef stays');
  assert.equal(cut('short'), 'short');
  const long = cut('The quick brown fox jumps over the lazy dog and keeps running', 30);
  assert.ok(long.length <= 30 && long.endsWith('…') && !/\s…$/.test(long), long);
  assert.equal(long, 'The quick brown fox jumps…');
});

test('the conversation: the questions with their answers, the results and the decisions, oldest first; the dial’s levels and counts', () => {
  board.answered = [{ id: 'q1', state: 'answered', text: 'Launch on Thursday, or wait for the review?', answer: 'Thursday', at: '2026-11-17T08:10:00.000Z' },
    { id: 'q2', state: 'autoDecided', text: 'Cache for a day?', answer: null, proposal: 'A day', at: '2026-11-17T09:40:00.000Z' }];
  const lines = leadLines(board);
  assert.deepEqual(lines.map((line) => line.kind), ['result', 'ask', 'update', 'update', 'ask']);
  assert.deepEqual(lines.map((line) => line.at), [...lines.map((line) => line.at)].sort());
  const ask = lines.find((line) => line.key === lineKey('ask', 'q1'));
  assert.equal(ask.head, 'Launch on Thursday, or wait for the review?');
  assert.equal(ask.answer, 'Thursday');
  assert.equal(lines.find((line) => line.key === lineKey('ask', 'q2')).answer, 'A day', 'decided by its timer: the proposal it went ahead with');
  assert.equal(lines.find((line) => line.kind === 'update' && line.why).head, 'Run the two small tasks side by side', 'a decision by its summary');
  assert.equal(lines.find((line) => line.kind === 'update' && !line.why).head, 'Keep the sidebar pass for after onboarding');
  assert.equal(new Set(lines.map((line) => line.key)).size, lines.length, 'each line its own key');
  assert.deepEqual(shownLines(lines, 'asks'), []);
  assert.deepEqual(shownLines(lines, 'decisions').map((line) => line.kind), ['result', 'ask', 'ask']);
  assert.equal(shownLines(lines, 'all').length, 5);
  assert.deepEqual(dialCounts(lines, 2), { asks: 2, decisions: 3, all: 5 });
  assert.deepEqual(leadLines(null), []);
});

test('a task’s five steps and its colour, one meaning each; the team’s counts', () => {
  assert.equal(taskStep({ status: 'planned' }), 1);
  assert.equal(taskStep({ status: 'running', state: 'Rework 1' }), 2);
  assert.equal(taskStep({ status: 'review' }), 3);
  assert.equal(taskStep({ status: 'running', state: 'Ready to merge' }), 4);
  assert.equal(taskStep({ status: 'done' }), 5);
  assert.equal(taskTone({ status: 'running' }), 'working');
  assert.equal(taskTone({ status: 'running', state: 'Ready to merge' }), 'ready');
  assert.equal(taskTone({ status: 'review' }), 'review');
  assert.equal(taskTone({ status: 'review', state: 'Ready to merge' }), 'ready', 'an audit passed: ready, in review or running');
  assert.equal(taskStep({ status: 'review', state: 'Ready to merge' }), 4);
  assert.equal(taskTone({ status: 'blocked' }), 'blocked');
  assert.equal(taskTone({ status: 'failed', group: 'attention' }), 'blocked');
  assert.equal(taskTone({ status: 'planned' }), 'queued');
  assert.equal(taskTone({ status: 'done' }), 'merged');
  const now = Date.parse('2026-11-17T09:30:00.000Z');
  const counts = teamCounts(board, now);
  const team = standing(board, now);
  assert.equal(counts.blocked, team.blocked.length);
  assert.equal(counts.queued, team.queued.length);
  assert.equal(counts.working + counts.review + counts.ready, team.motion.length);
  assert.deepEqual(team.queued.map((task) => task.position), [...team.queued.map((task) => task.position)].sort((a, b) => a - b), 'the queue in the lead’s order');
});

test('whom a blocked task waits on, when the board says: the user, other tasks, the lead', () => {
  const tasks = { tasks: [{ slug: 'a', title: 'Sync main', status: 'running' }, { slug: 'b', title: 'Old', status: 'done' }] };
  const card = { id: 'c', open: true, question: { task: 'x', text: 'Which names?' } };
  assert.equal(waitsOn({ slug: 'x', blocker: 'Which names?' }, tasks, [card]).who, 'you');
  assert.deepEqual(waitsOn({ slug: 'y', after: ['a', 'b'] }, tasks, [card]), { who: 'tasks', titles: ['Sync main'] }, 'a merged one waits on nothing');
  assert.equal(waitsOn({ slug: 'z', blocker: 'The done-check was refused' }, tasks, []).who, 'lead');
  assert.equal(waitsOn({ slug: 'z' }, tasks, []).who, null);
});

test('the projects the left lists, what waits in each, and which `#/` opens', () => {
  const state = {
    leads: new Map([['p1', { project: 'p1', root: '/home/u/site', session: 's1' }], ['p2', { project: 'p2', root: '/home/u/api', session: null, push: { id: 'x' } }]]),
    boards: new Map([['p1', board], ['p3', { project: 'p3', root: '/home/u/docs', tasks: [] }]]),
    cards: new Map([['c1', { id: 'c1', kind: 'question', project: 'p1', open: true, at: '2026-11-17T09:00:00.000Z' }], ['c2', { id: 'c2', kind: 'question', project: 'p1', open: false, at: '2026-11-17T09:00:00.000Z' }],
      ['c3', { id: 'c3', kind: 'config', project: 'p3', open: true, at: '2026-11-17T08:00:00.000Z' }], ['c4', { id: 'c4', kind: 'config', project: 'p3', open: true, at: '2026-11-17T07:00:00.000Z' }]]),
    sessions: new Map([['s1', { id: 's1' }]]),
  };
  const projects = projectsOf(state);
  assert.deepEqual(projects.map((one) => [one.project, one.name, one.waiting, one.live]), [['p1', 'site', 1, true], ['p2', 'api', 1, false], ['p3', 'docs', 2, false]]);
  assert.deepEqual(waitingCards(state.cards.values(), 'p3').map((card) => card.id), ['c4', 'c3'], 'oldest first');
  assert.equal(firstProject(projects), 'p3', 'the most waiting on the user');
  assert.equal(firstProject([]), null);
});

test('the deep links: what is on screen in the address, the old addresses still working, and every id surviving', () => {
  const id = 'local:project:a/b c#d';
  assert.deepEqual(parseRoute(projectHref(id)), { name: 'project', id, view: 'lead', show: 'decisions', tab: 'team', task: null, sheet: null });
  const full = projectHref(id, { show: 'all', tab: 'stats', task: 'sync-main', sheet: 'r1x2' });
  assert.match(full, /\/lead\?show=all&tab=stats&task=sync-main&sheet=r1x2$/);
  assert.deepEqual(parseRoute(full), { name: 'project', id, view: 'lead', show: 'all', tab: 'stats', task: 'sync-main', sheet: 'r1x2' });
  const road = projectHref(id, { view: 'roadmap', open: ['queue', 'goal-2'] });
  assert.match(road, /\/roadmap\?open=queue,goal-2$/);
  assert.deepEqual(parseRoute(road), { name: 'project', id, view: 'roadmap', open: ['queue', 'goal-2'] });
  assert.equal(routeHref(parseRoute(full), { sheet: null, task: null }), projectHref(id, { show: 'all', tab: 'stats' }));
  assert.equal(parseRoute(projectHref(id, { show: 'nonsense', tab: 'team' })).show, 'decisions', 'a level the page doesn’t have is the default');
  assert.deepEqual(parseRoute('#/p/' + encodeURIComponent(id)).view, 'lead', 'the board page’s address');
  assert.equal(boardHref(id), projectHref(id));
  assert.deepEqual(parseRoute(sessionHref('local:7d3c')), { name: 'session', id: 'local:7d3c' });
  assert.deepEqual(parseRoute('#/sessions'), { name: 'sessions' });
  assert.deepEqual(parseRoute('#/node'), { name: 'node' });
  assert.deepEqual(parseRoute('#/new'), { name: 'new' });
  assert.deepEqual(parseRoute('#/'), { name: 'home' });
  assert.deepEqual(parseRoute(''), { name: 'home' });
});

test('the page’s words: the browser’s language when the table has it, counted, filled, and every English word in Spanish', () => {
  assert.equal(pickLanguage(['es-ES', 'en']), 'es');
  assert.equal(pickLanguage(['fr-FR', 'es']), 'es');
  assert.equal(pickLanguage(['fr-FR']), 'en');
  assert.equal(pickLanguage(['en-GB'], 'es'), 'es', '?lang=es');
  setLanguage('en');
  assert.equal(t('thingsNeedYou', { n: 1 }), '1 thing needs you');
  assert.equal(t('thingsNeedYou', { n: 3 }), '3 things need you');
  assert.equal(t('toLead', { p: 'site' }), 'To the lead of site');
  assert.equal(t('no-such-word'), 'no-such-word');
  assert.equal(listed(['a', 'b', 'c']), 'a, b and c');
  setLanguage('es');
  assert.equal(t('thingsNeedYou', { n: 2 }), '2 cosas te necesitan');
  assert.equal(listed(['a', 'b']), 'a y b');
  setLanguage('en');
  const missing = Object.keys(TABLES.en).filter((key) => !(key in TABLES.es));
  assert.deepEqual(missing, []);
  for (const [key, word] of Object.entries(TABLES.en)) {
    assert.equal(typeof word === 'object', typeof TABLES.es[key] === 'object', `${key}: counted in both or neither`);
    const names = (text) => JSON.stringify(text).match(/\{\w+\}/g)?.sort() || [];
    assert.deepEqual([...new Set(names(TABLES.es[key]))], [...new Set(names(word))], `${key}: the same blanks`);
  }
});

test('a note for the lead is the tell line, quoted as the shell needs', () => {
  assert.equal(tellLine('/home/u/site', 'Use the new parser'), "vibeswitcher tell /home/u/site 'Use the new parser'");
  assert.equal(tellLine('/home/u/my site', "it's done"), "vibeswitcher tell '/home/u/my site' 'it'\\''s done'");
});

test('what waits, place by place, and the next place from the one shown: projects, your own sessions, This node', () => {
  const state = {
    leads: new Map([['p1', { project: 'p1', root: '/home/u/site', session: 's1' }], ['p2', { project: 'p2', root: '/home/u/api', session: 's2' }]]),
    boards: new Map(),
    cards: new Map([['c1', { id: 'c1', kind: 'question', project: 'p1', open: true, at: '2026-11-17T09:00:00.000Z' }],
      ['c2', { id: 'c2', kind: 'config', project: 'home', open: true, at: '2026-11-17T09:00:00.000Z' }],
      ['c3', { id: 'c3', kind: 'plugin', project: null, open: true, at: '2026-11-17T09:00:00.000Z', plugin: { session: 'O2' } }],
      ['c4', { id: 'c4', kind: 'plugin', project: null, open: true, at: '2026-11-17T09:00:00.000Z', plugin: { session: 'O1' } }]]),
    sessions: new Map([['s1', { id: 's1', role: 'lead' }], ['s2', { id: 's2', role: 'lead' }], ['o1', { id: 'o1', role: null, status: 'needs-you' }], ['o2', { id: 'o2', role: null, status: 'working' }]]),
  };
  const own = (session) => !session.role;
  const places = waitingPlaces(state, own);
  assert.deepEqual(places, [{ kind: 'project', id: 'p1', count: 1 }, { kind: 'session', id: 'o1', count: 1 }, { kind: 'session', id: 'o2', count: 1 }, { kind: 'node', id: null, count: 1 }],
    'a plugin’s request waits under its asker’s chat, counted once there (a session that needs you already counts it)');
  assert.deepEqual(nextPlace(places, { name: 'project', id: 'p1' }), places[1], 'from the project shown: the next place');
  assert.deepEqual(nextPlace(places, { name: 'node' }), places[0], 'round again');
  assert.deepEqual(nextPlace(places, { name: 'session', id: 'o1' }), places[2]);
  assert.deepEqual(nextPlace(places, { name: 'settings' }), places[0], 'from elsewhere: the first');
  assert.equal(nextPlace([], { name: 'home' }), null);
});

test('the roadmap with goals: a row per open goal in the lead’s order, Unsorted after, the done goals last, each with its tasks’ counts', () => {
  const now = Date.parse('2026-11-17T09:30:00.000Z');
  const fresh = structuredClone(vectors.board[1].result.boards[0]);
  const rows = goalRows(fresh, now);
  assert.deepEqual(rows.open.map((row) => [row.goal.id, row.tasks.map((task) => task.slug), row.counts]),
    [['launch', ['onboarding-steps', 'pricing-copy'], { motion: 1, blocked: 1, queued: 0, merged: 0 }]], 'in motion first, then blocked');
  assert.deepEqual(rows.unsorted.tasks.map((task) => task.slug), ['sidebar-pass', 'cache-assets']);
  assert.deepEqual(rows.done.map((row) => [row.goal.id, row.tasks.map((task) => task.slug)]), [['uploads', ['upload-retry']]]);
  fresh.tasks[0].goal = 'gone';
  assert.ok(goalRows(fresh, now).unsorted.tasks.some((task) => task.slug === fresh.tasks[0].slug), 'a goal the board doesn’t list: Unsorted');
  assert.deepEqual(goalRows({ tasks: [] }, now), { open: [], unsorted: null, done: [] });
});
