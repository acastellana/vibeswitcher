// The project leads on the phone: a lead's row with its team folded under it and its team's summary, its questions as
// the Mac's answer cards (priority, options, a proposal's timer, a revision, a withdrawn one as a dim line), an answer
// posted once for the version shown, and the lead's page (all-done card, updates, tasks by state, scorecard).
// Runs the unmodified Web/app.js in node on a fake DOM with a fake fetch: nothing is served, paired or answered.
// Run by scripts/test.sh, or by hand: node Tests/Web/phone-leads.test.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../../Web/app.js', import.meta.url), 'utf8');

// ---------- A fake DOM: just what app.js touches ----------

class FakeClassList {
  constructor(node) { this.node = node; }
  get names() { return new Set(this.node.className.split(/\s+/).filter(Boolean)); }
  set(names) { this.node.className = [...names].join(' '); }
  add(...names) { const set = this.names; names.forEach(n => set.add(n)); this.set(set); }
  remove(...names) { const set = this.names; names.forEach(n => set.delete(n)); this.set(set); }
  contains(name) { return this.names.has(name); }
  toggle(name, force) {
    const on = force === undefined ? !this.contains(name) : Boolean(force);
    if (on) this.add(name); else this.remove(name);
    return on;
  }
}

class FakeText {
  constructor(text) { this.text = String(text); }
  get textContent() { return this.text; }
}

class FakeElement {
  constructor(tag) {
    this.tagName = tag.toUpperCase();
    this.className = '';
    this.childNodes = [];
    this.hidden = false;
    this.disabled = false;
    this.value = '';
    this.dataset = {};
    this.attributes = {};
    this.listeners = {};
    this.style = { setProperty() {} };
    this.offsetHeight = 0;
    this.scrollHeight = 0;
    this.scrollTop = 0;
    this.clientHeight = 0;
    this.classList = new FakeClassList(this);
  }
  get children() { return this.childNodes.filter(n => n instanceof FakeElement); }
  get textContent() { return this.childNodes.map(n => n.textContent).join(''); }
  set textContent(text) { this.childNodes = text === '' ? [] : [new FakeText(text)]; }
  // app.js must never parse session text as HTML.
  set innerHTML(_) { throw new Error('innerHTML used'); }
  get innerHTML() { throw new Error('innerHTML used'); }
  insertAdjacentHTML() { throw new Error('insertAdjacentHTML used'); }
  append(...nodes) {
    for (const node of nodes) {
      if (node instanceof FakeFragment) this.childNodes.push(...node.childNodes);
      else this.childNodes.push(node instanceof FakeElement || node instanceof FakeText ? node : new FakeText(node));
    }
  }
  replaceChildren(...nodes) { this.childNodes = []; this.append(...nodes); }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  getAttribute(name) { return this.attributes[name] ?? null; }
  addEventListener(type, handler) { (this.listeners[type] ||= []).push(handler); }
  click() { if (!this.disabled) for (const handler of this.listeners.click || []) handler({ preventDefault() {} }); }
  focus() {}
  requestSubmit() {}
}

class FakeFragment extends FakeElement { constructor() { super('#fragment'); } }

const elements = new Map();
const document = {
  hidden: false,
  body: new FakeElement('body'),
  documentElement: new FakeElement('html'),
  getElementById(id) {
    if (!elements.has(id)) elements.set(id, new FakeElement(id === 'reply' ? 'textarea' : 'div'));
    return elements.get(id);
  },
  createElement: tag => new FakeElement(tag),
  createDocumentFragment: () => new FakeFragment(),
  querySelector: () => new FakeElement('header'),
  querySelectorAll: () => [],
  addEventListener() {},
};
const $ = id => document.getElementById(id);
const page = readFileSync(new URL('../../Web/index.html', import.meta.url), 'utf8');
for (const id of ['lead', 'leadPage', 'sessions']) assert.ok(page.includes(`id="${id}"`), `index.html has #${id}`);

// Every node under `node` (depth first), and those with a class.
function* walk(node) {
  for (const child of node.children) { yield child; yield* walk(child); }
}
const all = (node, className) => [...walk(node)].filter(n => n.classList.contains(className));
const one = (node, className) => all(node, className)[0];

// ---------- A fake Mac: /api/state, /api/lead, /api/lead/answer ----------

const posts = [];
let macState = null;
let answerReply = { status: 200, body: { ok: true, saw: 2 } };
let hold = null;   // an answer the Mac hasn't answered yet: resolved by the test

async function fakeFetch(path, options = {}) {
  const reply = (status, body) => ({ ok: status >= 200 && status < 300, status, json: async () => body });
  if (path === '/api/state') return reply(200, macState);
  if (path.startsWith('/api/lead?')) return reply(200, leadPage);
  if (path === '/api/lead/answer') {
    posts.push(JSON.parse(options.body));
    await new Promise(resolve => { hold = resolve; });
    return reply(answerReply.status, answerReply.body);
  }
  return reply(404, { error: 'not found' });
}

const storage = new Map([['vs.token', 'test-token']]);
const context = vm.createContext({
  document, window: { addEventListener() {} }, navigator: {}, location: { hash: '', reload() {} },
  history: { replaceState() {} }, fetch: fakeFetch, AbortController, URLSearchParams, JSON, console, Promise, Date,
  setTimeout: () => 0, clearTimeout() {}, setInterval: () => 0, clearInterval() {},
  localStorage: { getItem: key => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, String(value)),
                  removeItem: key => storage.delete(key) },
});
vm.runInContext(source, context, { filename: 'app.js' });
const run = code => vm.runInContext(code, context);
const flush = async () => { for (let i = 0; i < 6; i++) await new Promise(resolve => setImmediate(resolve)); };

// ---------- The state the Mac sends ----------

const now = Date.now() / 1000;
const attack = '<img src=x onerror="alert(1)">';
function session(tty, name, extra) {
  return { tty, sid: `s-${tty}`, number: 1, name, project: name, agent: 'claude', status: 'working', statusLabel: 'Working',
           inTerminal: true, inWindow: true, viewing: false, hasTranscript: false, ...extra };
}
const questions = [
  { id: 'q-block', version: 2, text: `Launch to the testers on Thursday? ${attack}`, options: ['Thursday', 'Wait'], priority: 'blocking',
    state: 'open', askedAt: now - 300,
    revised: { at: now - 120, note: 'Testers first', earlier: [{ version: 1, text: 'Launch to everyone?', options: ['Yes', 'No'], until: now - 120 }] } },
  { id: 'q-timer', version: 1, text: 'Keep a PNG fallback?', options: ['WebP only', 'Keep a PNG fallback'], priority: 'whenever',
    state: 'open', askedAt: now - 60, whyNow: 'Images next', proposal: 'Keep a PNG fallback', decideIn: 10, decideBy: now + 450, timeLeft: '8 min' },
  { id: 'q-gone', version: 1, text: 'Re-plan the sidebar?', options: [], priority: 'important', state: 'withdrawn', askedAt: now - 900,
    withdrawReason: 'Not needed', closedAt: now - 30 },
];
const lead = { id: 'L1', project: 'shop', summary: 'team: 1 working · 1 waits on lead', questions, open: 2, blocking: 1, allDone: false };
function stateWith(inputAllowed = true) {
  return {
    sessions: [session('ttys001', 'notes', { status: 'needsInput', statusLabel: 'Needs you' }),
               session('ttys002', 'shop', { status: 'needsInput', statusLabel: 'Needs you', role: 'lead', lead: 'L1' }),
               session('ttys003', 'sync-landing', { status: 'working', statusLabel: 'Waits on lead', role: 'worker', lead: 'L1', teamTask: 'sync-landing' })],
    leads: [lead], today: { agentsWorking: 0, waitingOnYou: 1, projects: [] }, inputAllowed, web: '', devPagesAllowed: false,
    device: { id: 'd', name: 'Phone', push: true }, mac: 'Mac', now,
  };
}
const leadPage = {
  id: 'L1', project: 'shop', summary: lead.summary,
  allDone: { at: now - 30, count: '2 tasks · 1 merged', headline: 'The landing page is ready', bullets: ['Copy merged'],
             cost: 'Cost: 2 tasks, 1.2 h of worker time, 3M tokens, est. $4.10.', tasks: [{ title: 'Landing copy', outcome: 'merged' }, { title: 'Paste images', outcome: 'reverted' }] },
  updates: [{ title: 'Board done', body: `Checked in the sandbox. ${attack}`, at: now - 100, images: 1 }],
  tasks: [{ title: 'Badge counts', state: 'Blocked', stateText: 'Blocked 3m', group: 'needsYou', mark: 'blocked', line: 'Waits on Ledger' },
          { title: 'Ledger reconciles', state: 'Working', stateText: 'Working 4m', group: 'working', mark: 'working', line: 'Tests written' },
          { title: 'Clean up folders', state: 'Needs audit', stateText: 'Needs audit 2m', group: 'review', mark: 'review', line: 'Audited: it deletes files' },
          { title: 'Landing copy', state: 'Merged', stateText: 'Merged 15m', group: 'finished', mark: 'merged' },
          { title: 'Paste images', state: 'Reverted', stateText: 'Reverted 10m', group: 'finished', mark: 'reverted', line: 'Froze on a large paste' }],
  finished: { title: 'Merged (1) · Reverted (1)', count: 2, shown: 2 },
  scorecard: 'Scorecard (2 merged): — audit rounds to pass, 0 reverts.', cost: 'This batch: 2 tasks, est. $4.10.',
};

function list(state) {
  macState = state;
  run(`state = ${JSON.stringify(state)}; clockOffset = 0; renderList();`);
}

// 1. A lead's workers aren't listed as your own sessions, nor counted as yours: they fold under the lead's row.
assert.ok(!source.includes('innerHTML'), 'app.js uses innerHTML');
list(stateWith());
const rows = $('sessions').children;
assert.equal(rows.length, 2, 'notes and the lead; the worker is under the lead');
assert.equal($('counts').textContent, '2 need you', 'the worker is not counted as yours');
const block = rows[1];
assert.ok(block.classList.contains('leadBlock'));
assert.ok(one(block, 'roleTag').textContent === 'Lead');
assert.equal(one(block, 'qCount').textContent, '? 2 questions for you');
assert.ok(one(block, 'qCount').classList.contains('blocking'), 'red while one blocks');
const toggle = one(block, 'teamToggle');
assert.equal(toggle.textContent, 'team: 1 working · 1 waits on lead ▸', 'the Mac sidebar\'s summary');
assert.equal(all(block, 'team').length, 0, 'folded to begin with');
toggle.click();
const opened = $('sessions').children[1];
const team = one(opened, 'team');
assert.ok(team, 'unfolded');
assert.equal(team.children.length, 1);
assert.equal(one(team, 'when').textContent.startsWith('Waits on lead'), true, 'a worker waiting reads Waits on lead, never Needs you');
assert.equal(one(team, 'roleLine').textContent, 'worker · sync-landing');

// 2. Its questions as the Mac's cards.
const cards = all(opened, 'qCard');
assert.equal(cards.length, 2, 'the two open ones as cards');
const [blocking, timed] = cards;
assert.ok(blocking.classList.contains('blocking'));
assert.equal(one(blocking, 'qPriority').textContent, 'Blocking');
assert.equal(one(blocking, 'qText').textContent, questions[0].text, 'text only: the markup is shown, not parsed');
assert.equal(one(blocking, 'qText').children.length, 0);
assert.match(one(blocking, 'qRevised').children[0].textContent, /^✎ Updated \d\d:\d\d: Testers first$/);
assert.equal(one(timed, 'qTimer').textContent, '⏱ Going with Keep a PNG fallback in 8 min');
assert.equal(one(timed, 'qWhy').textContent, 'Images next');
const timedOptions = all(timed, 'option');
assert.deepEqual(timedOptions.map(o => o.children[0].textContent), ['WebP only', 'Keep a PNG fallback']);
assert.ok(timedOptions[1].classList.contains('proposed'));
assert.equal(one(timedOptions[1], 'proposedTag').textContent, 'Proposed');
const gone = one(opened, 'qClosed');
assert.equal(one(gone, 'qClosedWhy').textContent, '✕ Withdrawn: Not needed');
assert.equal(all(gone, 'option').length + all(gone, 'qInput').length, 0, 'a withdrawn question can\'t be answered');

// 3. A tap answers once, for the version shown; a second tap while it's on its way sends nothing.
all(blocking, 'option')[0].click();
await flush();
assert.equal(posts.length, 1);
assert.deepEqual(posts[0], { lead: 'L1', question: 'q-block', version: 2, text: 'Thursday' });
const waiting = all($('sessions'), 'qCard')[0];
assert.ok(all(waiting, 'option').every(o => o.disabled), 'its buttons wait for the answer');
all(waiting, 'option')[1].click();
run(`answerQuestion(state.leads[0], state.leads[0].questions[0], 'Wait')`);
await flush();
assert.equal(posts.length, 1, 'a double tap answers once');
hold();
await flush();
assert.equal(one(all($('sessions'), 'qCard')[0], 'qNote').textContent, 'Answered: Thursday ✓');
// Once the Mac's state no longer lists it (answered questions leave the stack), a line says it went.
const answeredState = stateWith();
answeredState.leads[0] = { ...lead, questions: questions.slice(1), open: 1, blocking: 0 };
list(answeredState);
const went = all($('sessions'), 'qClosed').find(line => line.classList.contains('answered'));
assert.equal(went.children[0].textContent, '✓ Answered: Thursday');
list(stateWith());

// 4. In your own words, through the card's box.
const card = all($('sessions'), 'qCard')[1];
const input = one(card, 'qInput');
input.value = 'Ship WebP with a fallback for old Safari';
for (const handler of one(card, 'qAnswer').listeners.submit) handler({ preventDefault() {} });
await flush();
assert.deepEqual(posts[1], { lead: 'L1', question: 'q-timer', version: 1, text: 'Ship WebP with a fallback for old Safari' });
// The Mac says it closed meanwhile: the card says so.
answerReply = { status: 409, body: { error: "That question isn't open any more, so your answer wasn't sent. Here it is now." } };
hold();
await flush();
assert.equal(one(all($('sessions'), 'qCard')[1], 'qNote').textContent, answerReply.body.error);
assert.ok(one(all($('sessions'), 'qCard')[1], 'qNote').classList.contains('error'));

// 5. Replies off on the Mac: the cards show, but can't be answered.
list(stateWith(false));
assert.ok(all($('sessions'), 'qCard').every(c => all(c, 'option').every(o => o.disabled) && one(c, 'qInput').disabled));

// 6. The lead's page: its all-done card, its updates, its tasks by state, the scorecard.
list(stateWith());
run(`openLead('L1')`);
await flush();
const leadView = $('leadPage');
assert.equal($('lead').hidden, false);
assert.equal($('title').textContent, 'shop');
assert.equal($('subtitle').textContent, lead.summary);
const done = one(leadView, 'allDone');
assert.equal(one(done, 'allDoneHeadline').textContent, 'The landing page is ready');
assert.equal(one(done, 'allDoneCost').textContent, leadPage.allDone.cost);
assert.equal(one(leadView, 'updateBody').textContent, leadPage.updates[0].body);
assert.equal(one(leadView, 'updateBody').children.length, 0, 'the lead\'s words as text only');
const taskRows = all(leadView, 'taskRow');
assert.deepEqual(taskRows.map(r => one(r, 'taskTitle').textContent), leadPage.tasks.map(t => t.title));
const audit = taskRows.find(r => one(r, 'taskTitle').textContent === 'Clean up folders');
assert.equal(one(audit, 'taskState').textContent, 'Needs audit 2m');
assert.equal(one(audit, 'detail').textContent, 'Audited: it deletes files');
assert.ok(one(taskRows[4], 'mark').classList.contains('reverted'));
assert.deepEqual(all(leadView, 'taskGroup').map(g => g.textContent), ['Merged (1) · Reverted (1)'], 'the finished ones under the Team tab\'s title');
assert.equal(one(leadView, 'scorecard').children[0].textContent, leadPage.scorecard);
assert.equal(all(leadView, 'qCard').length, 2, 'its questions on its page too');

console.log('phone-leads: all checks passed');
