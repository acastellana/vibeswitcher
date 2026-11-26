// Day lines in a session's chat (the design review's D23): a quiet line before the first message of each day after the
// first one shown ("Today", "Yesterday", then the weekday and date in the page's language), made from the messages'
// own times as rows of the chat's list, so they are measured, kept in place and paged like every other row. The lead's
// conversation draws its days with the same kit piece.
// Times are built on the reader's calendar (new Date(y, m, d, …)), so the tests hold in any time zone.
// Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { installDom, findAll, byClass } from './fakedom.test.mjs';

installDom();
globalThis.matchMedia = () => ({ matches: false, addEventListener() {} });
globalThis.MutationObserver ??= class { observe() {} disconnect() {} };
globalThis.ResizeObserver ??= class { observe() {} unobserve() {} disconnect() {} };
const { chatView } = await import('../js/views/chat.js');
const { createStore } = await import('../js/store.js');
const { setLanguage } = await import('../js/i18n.js');
const { withDays } = await import('../js/chatops.js');
const { dayKey, dayWords } = await import('../js/words.js');
const kit = await import('../js/kit.js');

const local = (day, hours = 12, minutes = 0, seconds = 0, ms = 0) => new Date(2026, 10, day, hours, minutes, seconds, ms).toISOString();
let n = 0;
const prompt = (at, text = 'Ask') => ({ id: 'p' + ++n, type: 'prompt', at, text, steered: false, fromLead: false, images: [] });
const reply = (at, text = 'Said') => ({ id: 'r' + ++n, type: 'reply', at, text });
const tools = (at) => ({ id: 'tools:' + ++n, type: 'tools', at, summary: 'Ran 1 command', tools: [{ id: 't' + n, name: 'Bash', title: 'ls', at, detail: { type: 'command', command: 'ls' }, result: { output: '', failed: false, at, images: [] } }] });
const days = (rows) => rows.filter((row) => row.type === 'day').map((row) => row.id);

test('one day: no line; the first day shown never has one', () => {
  const rows = withDays([prompt(local(25, 9)), tools(local(25, 9, 1)), reply(local(25, 9, 2)), prompt(local(25, 22))]);
  assert.deepEqual(days(rows), []);
  assert.equal(rows.length, 4);
});

test('two days: one line, just before the first message of the second, carrying that message’s time', () => {
  const second = prompt(local(26, 8));
  const rows = withDays([prompt(local(25, 9)), reply(local(25, 9, 2)), second, reply(local(26, 8, 1))]);
  assert.deepEqual(rows.map((row) => row.type), ['prompt', 'reply', 'day', 'prompt', 'reply']);
  assert.equal(rows[2].id, 'day:2026-11-26');
  assert.equal(rows[2].at, second.at);
});

test('local midnight is the boundary: 23:59:59.999 and 00:00 are two days, 00:00 and 00:00:01 one', () => {
  assert.deepEqual(days(withDays([reply(local(25, 23, 59, 59, 999)), reply(local(26, 0, 0, 0, 0))])), ['day:2026-11-26']);
  assert.deepEqual(days(withDays([reply(local(26, 0, 0, 0, 0)), reply(local(26, 0, 0, 1))])), []);
  assert.equal(dayKey(local(26, 0)), '2026-11-26');
  assert.equal(dayKey(local(25, 23, 59, 59, 999)), '2026-11-25');
  assert.equal(dayKey('not a time'), '');
});

test('days only go forward, so a day’s line is never drawn twice; no time or a kind with no row draws none', () => {
  // A clock set back: the 25th after the 26th draws no second line for either.
  const back = withDays([reply(local(25)), reply(local(26)), reply(local(25, 13)), reply(local(26, 14)), reply(local(27))]);
  assert.deepEqual(days(back), ['day:2026-11-26', 'day:2026-11-27']);
  // An item with no time, and one this client doesn't draw, belong to the day above them: no line stands alone.
  const quiet = withDays([reply(local(25)), { id: 'x', type: 'someday', at: local(26) }, { id: 'y', type: 'reply', text: '' }, reply(local(25, 18))],
    (item) => item.type !== 'someday');
  assert.deepEqual(days(quiet), []);
});

test('the words: Today, Yesterday, then the weekday and date in the page’s language, the year only when it isn’t this one', () => {
  const now = new Date(2026, 10, 26, 0, 30).getTime();
  setLanguage('en');
  assert.equal(dayWords(local(26, 0, 0), now), 'Today');
  assert.equal(dayWords(local(25, 23, 59), now), 'Yesterday');
  assert.equal(dayWords(local(25, 0, 0), now), 'Yesterday', 'calendar days, not 24 hours before now');
  assert.equal(dayWords(local(24, 9), now), 'Tuesday, Nov 24');
  assert.equal(dayWords(new Date(2025, 10, 24, 9).toISOString(), now), 'Monday, Nov 24, 2025');
  setLanguage('es');
  assert.equal(dayWords(local(26, 10), now), 'Hoy');
  assert.equal(dayWords(local(25, 10), now), 'Ayer');
  assert.equal(dayWords(local(24, 9), now), 'Martes, 24 nov', 'a line starts with a capital, the weekday as the language writes it');
  // The first of a month after a 31-day one: yesterday is the calendar's.
  assert.equal(dayWords(new Date(2026, 11, 31, 20).toISOString(), new Date(2027, 0, 1, 9).getTime()), 'Ayer');
  assert.equal(dayWords('', now), '');
  setLanguage('en');
});

test('the kit draws a day line one way: its class and its words, nothing else', () => {
  const line = kit.dayLine({ tag: 'div', class: 'day-row' }, 'Today');
  assert.deepEqual(line.className.split(' '), ['day-line', 'day-row']);
  assert.equal(line.textContent, 'Today');
  assert.equal(line.children[0].className, 'day-line-text');
  // Its own class: the roadmap's midnight ticks are `.day` (project.js), and a day line's look must not reach them.
  const css = readFileSync(fileURLToPath(new URL('../style.css', import.meta.url)), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');
  assert.doesNotMatch(css, /(^|[\s,}])\.day::before/, 'no hairline before a roadmap tick');
  assert.match(css, /\.day-line::before, \.day-line::after \{/);
  // The lead's conversation and the session's chat both ask the kit; no view composes the class itself.
  const root = fileURLToPath(new URL('../js/', import.meta.url));
  for (const file of ['views/chat.js', 'views/project.js']) {
    const source = readFileSync(root + file, 'utf8');
    assert.match(source, /kit\.dayLine\(/, `${file} draws its days with kit.dayLine`);
    assert.doesNotMatch(source, /class: ['`]day['` ]/, `${file} composes no day class of its own`);
  }
});

// ---- In the chat ----

const SID = 'local:3c1e9a7d-4f6a-4c1e-9b7d-2e5a8c0d1f3b';
function open() {
  const session = { id: SID, terminal: 'pts/7', agent: 'claude', cwd: '/home/dev/x', status: 'idle', hosted: true, sendWays: ['step', 'now'] };
  const store = createStore();
  const asked = [];
  store.connect({ request: (kind, args) => { asked.push({ kind, args }); return new Promise(() => {}); }, subscribeChat() {}, unsubscribeChat() {}, resync() {} });
  store.setKinds(['send', 'chat.page'], null, ['read', 'draft', 'watch', 'act']);
  store.apply({ v: 1, kind: 'snapshot', epoch: 'e', seq: 0, state: { node: { home: '/home/dev', ended: [] }, sessions: [session], leads: [], cards: [], boards: [] } });
  const chat = chatView({ store, ui: { state: { route: { name: 'session', id: SID } }, subscribe() {}, go() {} }, later: () => () => {} });
  chat.show(SID);
  // The view's scroll, as the stand-in DOM has no layout: at its end (`end(true)`) or read up above it.
  const scroller = findAll(chat.el, byClass('chat-scroll'))[0];
  const end = (at) => Object.assign(scroller, { scrollHeight: at ? 0 : 5000, scrollTop: 0, clientHeight: at ? 0 : 600 });
  end(true);
  return { chat, store, end };
}
// The chat's drawn rows in order: a day line as its words, a message by its kind.
const drawn = (chat) => findAll(chat.el, byClass('chat-row')).filter((row) => !row.hidden)
  .map((row) => (row.classList.contains('day-line') ? 'day:' + row.textContent : row.className.split(' ')[1]));

test('in the chat: a line where the day changes, drawn as a row between the messages, the grouping of a day untouched', () => {
  setLanguage('en');
  const { chat, store } = open();
  const today = new Date();
  const at = (back, hours) => new Date(today.getFullYear(), today.getMonth(), today.getDate() - back, hours, 0).toISOString();
  store.chatSnapshot(SID, { items: [prompt(at(1, 9)), tools(at(1, 9)), reply(at(1, 9)), prompt(at(0, 8)), tools(at(0, 8)), reply(at(0, 8))], after: null, more: false });
  assert.deepEqual(drawn(chat), ['prompt', 'tools', 'reply', 'day:Today', 'prompt', 'tools', 'reply']);
  // A message of today at the end: no new line, it joins today's.
  store.chatSnapshot(SID, { items: [...store.state.chats.get(SID).items, reply(at(0, 9))], after: null, more: false });
  assert.deepEqual(drawn(chat), ['prompt', 'tools', 'reply', 'day:Today', 'prompt', 'tools', 'reply', 'reply']);
});

test('in the chat: older messages paged in above move the first day’s line to where that day starts, never twice, never alone', () => {
  setLanguage('es');
  const { chat, store, end } = open();
  const today = new Date();
  const at = (back, hours) => new Date(today.getFullYear(), today.getMonth(), today.getDate() - back, hours, 0).toISOString();
  // Held: yesterday evening and today. Yesterday is the first day shown: no line above it.
  store.chatSnapshot(SID, { items: [prompt(at(1, 20)), reply(at(1, 20)), prompt(at(0, 9)), reply(at(0, 9))], after: null, more: true });
  assert.deepEqual(drawn(chat), ['prompt', 'reply', 'day:Hoy', 'prompt', 'reply']);
  // Read up above the end, a page of older ones (two days ago, then yesterday morning) comes in above: the rows you
  // look at stay as they are.
  end(false);
  store.chatPage(SID, [prompt(at(2, 9)), reply(at(2, 9)), prompt(at(1, 8)), reply(at(1, 8))], true);
  assert.deepEqual(drawn(chat), ['prompt', 'reply', 'day:Hoy', 'prompt', 'reply'], 'nothing moves where you read');
  // Another page, from the same day as the first now held, with the view at the end so every row is drawn: no line
  // above the first day, yesterday's line where yesterday starts, each day's line once.
  end(true);
  store.chatPage(SID, [prompt(at(2, 7)), reply(at(2, 7))], false);
  assert.deepEqual(drawn(chat), ['prompt', 'reply', 'prompt', 'reply', 'day:Ayer', 'prompt', 'reply', 'prompt', 'reply', 'day:Hoy', 'prompt', 'reply']);
  setLanguage('en');
});

test('a day line is words a reader hears, found by no search and copied into no Markdown', async () => {
  setLanguage('en');
  const { findIn, chatMarkdown } = await import('../js/chatops.js');
  const items = [reply(local(25, 9), 'Today is near'), reply(local(26, 9), 'Done')];
  const rows = withDays(items);
  assert.deepEqual(days(rows), ['day:2026-11-26']);
  assert.deepEqual(findIn(rows, 'today').map((index) => rows[index].type), ['reply'], 'the line’s own words are not a match');
  assert.equal(chatMarkdown(rows), chatMarkdown(items));
  assert.equal(kit.dayLine({}, 'Today').getAttribute('role') ?? null, null, 'not a separator, whose words a reader skips');
});
