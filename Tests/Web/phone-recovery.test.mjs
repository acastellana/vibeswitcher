// What the phone does when the connection or the Mac goes away and comes back, and that what it then shows is current:
// a restart's 503, a dropped poll on a lead's page, coming back from the background, a removed token, a slow network,
// a dropped poll during a briefing; and the kinds the board grew (folded, over budget).
// Runs the unmodified Web/app.js in node on a fake DOM with a fake fetch: nothing is served, paired or answered.
// Run by scripts/test.sh, or by hand: node Tests/Web/phone-recovery.test.mjs
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
  append(...nodes) {
    for (const node of nodes) {
      if (node instanceof FakeFragment) this.childNodes.push(...node.childNodes);
      else this.childNodes.push(node instanceof FakeElement || node instanceof FakeText ? node : new FakeText(node));
    }
  }
  prepend(...nodes) { const kept = this.childNodes; this.childNodes = []; this.append(...nodes); this.childNodes.push(...kept); }
  replaceChildren(...nodes) { this.childNodes = []; this.append(...nodes); }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  getAttribute(name) { return this.attributes[name] ?? null; }
  addEventListener(type, handler) { (this.listeners[type] ||= []).push(handler); }
  click() { if (!this.disabled) for (const handler of this.listeners.click || []) handler({ preventDefault() {} }); }
  focus() { document.activeElement = this; }
  blur() { if (document.activeElement === this) document.activeElement = document.body; }
  querySelectorAll() { return []; }
  querySelector() { return null; }
  requestSubmit() {}
  pause() {}
  play() { return Promise.resolve(); }
}
class FakeFragment extends FakeElement { constructor() { super('#fragment'); } }

const elements = new Map();
const documentListeners = {};
const document = {
  hidden: false,
  body: new FakeElement('body'),
  documentElement: new FakeElement('html'),
  activeElement: null,
  getElementById(id) {
    if (!elements.has(id)) elements.set(id, new FakeElement(id === 'reply' ? 'textarea' : 'div'));
    return elements.get(id);
  },
  createElement: tag => new FakeElement(tag),
  createDocumentFragment: () => new FakeFragment(),
  querySelector: () => new FakeElement('header'),
  querySelectorAll: () => [],
  addEventListener(type, handler) { (documentListeners[type] ||= []).push(handler); },
};
const $ = id => document.getElementById(id);
function* walk(node) { for (const child of node.children) { yield child; yield* walk(child); } }
const all = (node, className) => [...walk(node)].filter(n => n.classList.contains(className));
const one = (node, className) => all(node, className)[0];

// ---------- A fake Mac ----------

const reply = (status, body) => ({ ok: status >= 200 && status < 300, status, json: async () => { if (body === undefined) throw new Error('no json'); return body; } });
const requests = [];
const routes = new Map();
const on = (path, answer) => routes.set(path, answer);

async function fakeFetch(path, options = {}) {
  const method = options.method || 'GET';
  const route = path.split('?')[0];
  // The longest timer api() armed for this request: what it allows this read to take.
  requests.push({ path, method, timeout: lastTimer });
  const answer = routes.get(`${method} ${route}`) ?? routes.get(route);
  if (answer === undefined) return reply(404, { error: 'not found' });
  return typeof answer === 'function' ? answer(path, options) : answer;
}
const dropped = () => { throw new TypeError('network'); };

let lastTimer = 0;
const timers = [];
let timerID = 0;
// Fires the newest timer armed for `ms` (api()'s timeout, say), as the clock reaching it would.
const fire = ms => { const timer = timers.filter(t => t.ms === ms).at(-1); assert.ok(timer, `a ${ms} ms timer is armed`); timer.fn(); };
// A body that never finishes, or a request that hangs: it rejects when api()'s timer aborts it, as a real one does.
const hangs = options => new Promise((_, reject) => options.signal.addEventListener('abort', () => reject(new Error('aborted'))));
let clock = 1_800_000_000_000;
class FakeDate extends Date {
  constructor(...args) { super(...(args.length ? args : [clock])); }
  static now() { return clock; }
}
const storage = new Map([['vs.token', 'test-token']]);
const notifications = { permission: 'granted' };
const context = vm.createContext({
  document, window: { addEventListener() {}, PushManager: function PushManager() {} }, navigator: {}, location: { hash: '', reload() { reloads += 1; } },
  history: { replaceState() {} }, fetch: fakeFetch, AbortController, URLSearchParams, JSON, console, Promise, Date: FakeDate, Notification: notifications,
  Blob, URL: Object.assign(function () {}, { createObjectURL: () => 'blob:x', revokeObjectURL() {} }), Uint8Array, DataView, CSS: { escape: s => s },
  atob: s => Buffer.from(s, 'base64').toString('binary'),
  setTimeout: (fn, ms) => { lastTimer = ms; const id = ++timerID; timers.push({ fn, ms, id }); if (ms === 1000) setImmediate(fn); return id; },
  clearTimeout: id => { const at = timers.findIndex(t => t.id === id); if (at >= 0) timers.splice(at, 1); }, setInterval: () => 0, clearInterval() {},
  localStorage: { getItem: key => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, String(value)), removeItem: key => storage.delete(key) },
});
let reloads = 0;
vm.runInContext(source, context, { filename: 'app.js' });
const run = code => vm.runInContext(code, context);
const flush = async () => { for (let i = 0; i < 8; i++) await new Promise(resolve => setImmediate(resolve)); };
const visibility = hidden => { document.hidden = hidden; for (const handler of documentListeners.visibilitychange || []) handler(); };

// ---------- The state the Mac sends ----------

const now = clock / 1000;
function session(tty, name, extra) {
  return { tty, sid: `s-${tty}`, number: 1, name, project: name, agent: 'claude', status: 'working', statusLabel: 'Working',
           inTerminal: true, inWindow: true, viewing: false, hasTranscript: false, ...extra };
}
function macState(extra = {}) {
  return {
    sessions: [session('ttys001', 'notes'), session('ttys002', 'shop', { role: 'lead', lead: 'L1' }),
               session('ttys003', 'sync', { role: 'worker', lead: 'L1', teamTask: 'sync', statusLabel: 'Waits on lead' })],
    leads: [{ id: 'L1', project: 'shop', summary: 'team: 1 working', questions: [], open: 0, blocking: 0, allDone: false }],
    today: { agentsWorking: 0, waitingOnYou: 0, projects: [] }, inputAllowed: true, web: 'v1', devPagesAllowed: false,
    device: { id: 'd', name: 'Phone', push: true }, mac: 'Mac', now, briefingProjects: [], ...extra,
  };
}
const page = {
  id: 'L1', project: 'shop', summary: 'team: 1 working', updates: [],
  tasks: [{ title: 'Ledger', state: 'Working', stateText: 'Working 4m', group: 'working', mark: 'working' }],
  finished: { title: 'Merged (0)', count: 0, shown: 0 },
};

for (const handler of documentListeners.DOMContentLoaded || []) handler();
on('/api/state', () => reply(200, macState()));
on('/api/lead', () => reply(200, page));
await flush();

// ---------- 1. A restart: the Mac answers 503 "restarting" as JSON, and the list must not sit there looking live ----------

const restarting = 'Phone Access is restarting on the Mac. Try again in a moment.';
run('show("list")');
await flush();
assert.equal($('offline').hidden, true, 'online to begin with');
assert.equal(all($('sessions'), 'row').length >= 1, true, 'the list is drawn');
on('/api/state', () => reply(503, { error: restarting }));
await run('refreshList()');
await flush();
assert.equal($('offline').hidden, false, 'a restart shows the banner: the list is as of the last answer');
assert.equal($('offline').textContent, restarting);
// …and an answer from another route during it doesn't take the banner away.
on('/api/screen', () => reply(503, { error: "Couldn't read that tab right now." }));
await run('api("/api/screen?tty=x").catch(() => {})');
assert.equal($('offline').hidden, false, 'a 503 elsewhere leaves it up');
// The Mac is back: it goes by itself.
on('/api/state', () => reply(200, macState()));
await run('refreshList()');
await flush();
assert.equal($('offline').hidden, true, 'gone once the Mac answers');

// The other refusals the gate answers as JSON: the wrong tailnet account, too many tries.
on('/api/state', () => reply(403, { error: 'not your tailnet account' }));
await run('refreshList()');
assert.equal($('offline').textContent, 'not your tailnet account');
assert.equal($('offline').hidden, false);
on('/api/state', () => reply(200, macState()));
await run('refreshList()');
assert.equal($('offline').hidden, true);

// ---------- 2. A lead's page: one dropped poll doesn't blank it; a lead that's gone says so ----------

run(`state = ${JSON.stringify(macState())}; openLead('L1')`);
await flush();
assert.equal(all($('leadPage'), 'taskRow').length, 1, 'the page is drawn');
on('/api/lead', dropped);
on('/api/state', dropped);
await run('refreshLead()');
await flush();
assert.equal(all($('leadPage'), 'taskRow').length, 1, 'a dropped poll keeps the page');
assert.equal($('offline').hidden, false, 'under the banner');
on('/api/lead', () => reply(200, page));
on('/api/state', () => reply(200, macState()));
await run('refreshLead()');
await flush();
assert.equal($('offline').hidden, true);
// A restart during the page: the same banner, the page kept.
on('/api/lead', () => reply(503, { error: restarting }));
on('/api/state', () => reply(503, { error: restarting }));
await run('refreshLead()');
await flush();
assert.equal(all($('leadPage'), 'taskRow').length, 1);
assert.equal($('offline').textContent, restarting);
on('/api/lead', () => reply(200, page));
on('/api/state', () => reply(200, macState()));
await run('refreshLead()');
await flush();
const noLead = "That lead isn't running any more. Go back to the list.";
on('/api/lead', () => reply(404, { error: noLead }));
await run('refreshLead()');
await flush();
assert.equal($('leadPage').textContent, noLead, 'a lead that is gone says so instead of its old page');
assert.equal($('offline').hidden, true, 'that is not the connection');
on('/api/lead', () => reply(200, page));
await run('refreshLead()');
await flush();
assert.equal(all($('leadPage'), 'taskRow').length, 1, 'and it comes back if the lead does');

// ---------- 3. Coming back from the background ----------

// On a lead's page: asked again at once, not on its next tick.
requests.length = 0;
visibility(true);
clock += 5 * 60_000;
visibility(false);
assert.equal($('offline').hidden, false, 'after a while away it says it is checking until the Mac answers');
assert.match($('offline').textContent, /Updating/);
await flush();
assert.ok(requests.some(r => r.path.startsWith('/api/lead?')), 'the lead page is asked for on return');
assert.equal($('offline').hidden, true, 'gone with the answer');

// Back after a blink: no banner to flash.
visibility(true);
clock += 1000;
visibility(false);
assert.equal($('offline').hidden, true, 'a blink shows nothing');
await flush();

// Coming back with the Mac unreachable: the banner says so.
on('/api/lead', dropped);
on('/api/state', dropped);
visibility(true);
clock += 60_000;
visibility(false);
await flush();
assert.match($('offline').textContent, /Can't reach your Mac/);
on('/api/lead', () => reply(200, page));
on('/api/state', () => reply(200, macState()));
await run('refreshLead()');
await flush();
assert.equal($('offline').hidden, true);

// An answer being typed when the phone locks: the box lets go, so the page updates again on return (its text is kept).
run('$("back").click()');
run(`state = ${JSON.stringify(macState())}; show("list")`);
await flush();
const box = new FakeElement('input');
box.className = 'qInput';
box.focus();
visibility(true);
assert.notEqual(document.activeElement, box, 'the answer box lets go when the phone locks');
visibility(false);
await flush();

// The web app's version is watched on a lead's page too, not only on the list.
run(`openLead('L1')`);
await flush();
reloads = 0;
on('/api/state', () => reply(200, macState({ web: 'v2' })));
await run('refreshLead()');
await flush();
assert.equal(reloads, 1, 'a newer web app is loaded from a lead page too');
on('/api/state', () => reply(200, macState()));
run('webVersion = "v1"; $("back").click()');
run('show("list")');
await flush();

// ---------- 4. A removed phone: back to pairing, and no banner left over it ----------

on('/api/state', dropped);
await run('refreshList()');
assert.equal($('offline').hidden, false);
on('/api/state', () => reply(401, { error: "This phone isn't paired with the Mac any more." }));
await run('refreshList()');
await flush();
assert.equal($('pair').hidden, false, 'the pairing screen');
assert.equal($('offline').hidden, true, 'no offline banner over it');
assert.match($('pairError').textContent, /isn't paired/);
// Forgetting it on the phone while the Mac can't be reached: no poll is left to take the banner away.
on('/api/state', dropped);
run('token = "test-token"; show("list")');
await flush();
assert.equal($('offline').hidden, false);
run('forgetToken()');
assert.equal($('offline').hidden, true, 'nothing left to clear it, so the pairing screen does');
// Paired again for the rest of the checks.
run('token = "test-token"');
on('/api/state', () => reply(200, macState()));
run('show("list")');
await flush();

// ---------- 4a. A body that never finishes, or arrives torn: not an answer ----------

on('/api/state', (path, options) => ({ ok: true, status: 200, json: () => hangs(options) }));
run('refreshList()');
await flush();
assert.equal($('offline').hidden, true, 'nothing wrong yet');
assert.equal(run('listBusy'), true, 'a poll is waiting on the body');
fire(10000);
await flush();
assert.equal(run('listBusy'), false, 'the timer covers the body too: polls go on');
assert.match($('offline').textContent, /Can't reach your Mac/);
assert.equal($('offline').hidden, false);
on('/api/state', () => ({ ok: true, status: 200, json: async () => { throw new SyntaxError('torn'); } }));
const before = run('state');
await run('refreshList()');
await flush();
assert.equal(run('state'), before, 'a torn answer is not a state');
assert.equal($('offline').hidden, false, 'and the banner stays');
on('/api/state', () => reply(200, macState()));
await run('refreshList()');
await flush();
assert.equal($('offline').hidden, true);

// A pairing code the Mac refuses is an answer: no banner from before stays over the pairing screen.
on('/api/state', dropped);
run('token = "test-token"; show("list")');
await flush();
assert.equal($('offline').hidden, false);
run('forgetToken()');
on('/api/pair', () => reply(403, { error: 'Wrong or expired code.' }));
on('/api/state', () => reply(200, macState()));
await run('setOnline(false); api("/api/pair", { method: "POST", body: "{}" }, null).catch(() => {})');
await flush();
assert.equal($('offline').hidden, true, 'a refused code clears it');
// A request left over from before unpairing that fails now doesn't put the banner back over the pairing screen.
on('/api/state', dropped);
await run('api("/api/state", {}, "the-old-token").catch(() => {})');
await flush();
assert.equal($('offline').hidden, true, 'a request for a token this phone no longer has');
run('token = "test-token"');
on('/api/state', () => reply(200, macState()));
run('show("list")');
await flush();

// ---------- 5. Slow network: the big reads get time, and a timeout there isn't "unreachable" ----------

run(`state = ${JSON.stringify(macState({ sessions: [session('ttys001', 'notes', { hasTranscript: true, eventAt: 5 })] }))}; openSession('ttys001'); showTab('conversation')`);
on('/api/conversation', () => reply(200, { tty: 'ttys001', entries: [], cursor: 10, file: 'f', fresh: true, pending: false, truncatedBefore: false }));
await flush();
const conversationRequest = requests.filter(r => r.path.startsWith('/api/conversation')).at(-1);
assert.ok(conversationRequest, 'the conversation was read');
assert.ok(conversationRequest.timeout >= 30000, `a transcript tail is given time on a slow network (allowed ${conversationRequest.timeout} ms)`);
on('/api/history', () => reply(200, { tty: 'ttys001', lines: [], start: 0, total: 0, first: 0 }));
run('showTab("terminal"); loadEarlier()');
await flush();
const historyRequest = requests.filter(r => r.path.startsWith('/api/history')).at(-1);
assert.ok(historyRequest.timeout >= 30000, `a scrollback page is given time (allowed ${historyRequest.timeout} ms)`);

run('$("back").click(); show("list")');
await flush();

// ---------- 7. Lists a team whose lead has no board yet: not lost ----------

const noBoard = macState({ leads: [] });
run(`state = ${JSON.stringify(noBoard)}; renderList()`);
assert.equal(all($('sessions'), 'row').length, 3, 'the lead, its worker and the rest are all listed');
assert.ok(all($('sessions'), 'roleLine').some(line => line.textContent === 'worker · sync'), 'the worker stays where it is');

// ---------- 8. Notifications turned off on the phone: the bell doesn't say they're on ----------

on('/api/state', () => reply(200, macState()));
await run('refreshList()');
await flush();
assert.ok($('bell').classList.contains('on'), 'on while the Mac has this phone\'s subscription and the phone allows them');
notifications.permission = 'denied';
await run('refreshList()');
await flush();
assert.ok(!$('bell').classList.contains('on'), 'not on when the phone has turned them off');
assert.equal($('notifyCard').hidden, false, 'and it offers them again');
notifications.permission = 'granted';
await run('refreshList()');
await flush();
assert.equal($('notifyCard').hidden, true);

// ---------- 9. Brief me: a poll dropped while it's written doesn't lose the briefing ----------

let asks = 0;
on('POST /api/briefing', () => reply(200, { writing: true }));
on('GET /api/briefing', () => {
  asks += 1;
  if (asks === 1) throw new TypeError('network');
  if (asks === 2) return reply(200, { writing: true });
  return reply(200, { text: 'All quiet.', language: 'en', at: now });
});
await run('briefMe()');
await flush();
await flush();
assert.equal($('briefText').textContent, 'All quiet.', 'the briefing arrives after the connection comes back');
// A request that hangs until its timer: asked again, not given up on.
asks = 0;
on('GET /api/briefing', (path, options) => {
  asks += 1;
  if (asks === 1) return hangs(options);
  return reply(200, { text: 'Still quiet.', language: 'en', at: now });
});
run('briefMe()');
await flush();
await flush();
fire(60000);
await flush();
await flush();
assert.equal($('briefText').textContent, 'Still quiet.', 'a hung ask is asked again');
assert.equal($('briefError').hidden, true);
assert.equal($('briefError').hidden, true, 'and no error is left');
assert.ok(requests.filter(r => r.path === '/api/briefing' && r.method === 'GET').at(-1).timeout >= 60000, 'the audio is given time to download');
// An error that isn't the connection still shows at once.
asks = 10;
on('GET /api/briefing', () => reply(404, { error: 'No briefing yet: press Brief me.' }));
await run('briefMe()');
await flush();
await flush();
assert.equal($('briefError').textContent, 'No briefing yet: press Brief me.');

// ---------- 10. The board's newer states ----------

const stale = { at: now - 86400 * 2, count: '2 tasks · 1 merged', headline: 'Old batch', bullets: [], current: false,
                tasks: [{ title: 'Folded away', outcome: 'folded' }, { title: 'Dropped', outcome: 'abandoned' }, { title: 'Done', outcome: 'merged' }] };
const fresh = { ...stale, at: now - 60, current: true };
const budgetPage = { ...page, allDone: stale, tasks: [
  { title: 'Long one', state: 'Working', stateText: 'Working 3h', group: 'working', mark: 'working', overBudget: 'Over its 120 min budget (3h worked); told to stop at 14:02, no over_budget report yet' },
  { title: 'Held', state: 'Kept', stateText: 'Kept', group: 'finished', mark: 'kept', line: 'A prototype' },
  { title: 'Merged in', state: 'Folded', stateText: 'Folded', group: 'finished', mark: 'folded' },
] };
on('/api/lead', () => reply(200, budgetPage));
run(`openLead('L1')`);
await flush();
const lead = $('leadPage');
assert.equal(one(lead, 'allDoneHead').children[0].textContent, 'Earlier batch finished', 'an old all-done card, with work under way, does not claim everything is finished');
assert.match(one(lead, 'allDoneHead').children[1].textContent, /[A-Z][a-z]{2} \d\d:\d\d/, 'and says which day');
const pageSections = lead.children.map(node => node.className);
assert.ok(pageSections.indexOf('allDone') > pageSections.indexOf('card tasks'), 'after the tasks, as history');
const outcomes = all(lead, 'outcome').map(node => node.textContent);
assert.deepEqual(outcomes, ['↳ Folded away', '− Dropped', '✓ Done'], 'a folded task reads folded, not given up');
const longOne = all(lead, 'taskRow').find(row => one(row, 'taskTitle').textContent === 'Long one');
assert.match(one(longOne, 'overBudget').textContent, /Over its 120 min budget/, 'over budget is said on its row');
assert.ok(all(lead, 'taskRow').some(row => one(row, 'mark').classList.contains('kept')));
assert.ok(all(lead, 'taskRow').some(row => one(row, 'mark').classList.contains('folded')));
on('/api/lead', () => reply(200, { ...budgetPage, allDone: fresh }));
await run('refreshLead()');
await flush();
assert.equal(one(lead, 'allDoneHead').children[0].textContent, '✓ All tasks finished', 'the card that is still true says so');
const sectionsNow = lead.children.map(node => node.className);
assert.ok(sectionsNow.indexOf('allDone') < sectionsNow.indexOf('card tasks'), 'first, as before');

// ---------- 11. A session that ended leaves no controls for it ----------

run(`state = ${JSON.stringify(macState({ sessions: [session('ttys001', 'notes')], inputAllowed: false }))}; openSession('ttys001')`);
await flush();
assert.ok(!$('pauseSelect').hidden, 'a live session can be paused');
run(`state = ${JSON.stringify(macState({ sessions: [], inputAllowed: false }))}; renderSessionMeta()`);
assert.equal($('title').textContent, 'Session ended');
assert.equal($('pauseSelect').hidden, true, 'nothing to pause');
assert.equal($('inputOff').hidden, true, 'nothing to reply to');

console.log('phone-recovery: all checks passed');
