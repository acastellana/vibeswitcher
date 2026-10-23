// A phone reply is sent once, and ✓ shows only once the Mac says it went in: two quick Enters post it once, a bare 502
// or 504 from Tailscale (the Mac may still be typing) says to check the screen rather than "not running", and sending
// the same text again carries the same request id (the Mac types it at most once). A phone the Mac unpaired goes to the
// pairing screen with the reason, never to an empty list; a restart (503) keeps its token.
// Runs the unmodified Web/app.js in node on a fake DOM with a fake fetch: nothing is served, paired or typed.
// Run by PhoneWebTests (swift test), or by hand: node Tests/Web/phone-replies.test.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../../Web/app.js', import.meta.url), 'utf8');
let ready = null;   // app.js's DOMContentLoaded handler

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
  addEventListener(type, handler) { if (type === 'DOMContentLoaded') ready = handler; },
};
const $ = id => document.getElementById(id);
// The page's elements as index.html has them: present, and hidden where it says so.
const page = readFileSync(new URL('../../Web/index.html', import.meta.url), 'utf8');
for (const [, attributes] of page.matchAll(/<\w+\s([^>]*\bid="[^"]+"[^>]*)>/g)) {
  const node = $(attributes.match(/\bid="([^"]+)"/)[1]);
  node.hidden = /(^|\s)hidden(\s|$|=)/.test(attributes);
}
for (const id of ['askCard', 'askText', 'askOptions', 'quickReplies', 'quickEditor', 'inputStatus']) {
  assert.ok(page.includes(`id="${id}"`), `index.html has #${id}`);
}


// ---------- A fake Mac: each request waits for the test to answer it ----------

const requests = [];   // { path, body, answer(status, body) }
async function fakeFetch(path, options = {}) {
  return new Promise(resolve => {
    requests.push({
      path, body: options.body ? JSON.parse(options.body) : null,
      answer(status, body) {
        resolve({ ok: status >= 200 && status < 300, status,
                  json: async () => { if (body === undefined) throw new SyntaxError('not JSON'); return body; } });
      },
    });
  });
}
const pending = path => requests.filter(r => r.path.startsWith(path) && !r.answered);
function answer(path, status, body) {
  const request = pending(path)[0];
  assert.ok(request, `a request to ${path} is waiting`);
  request.answered = true;
  request.answer(status, body);
}
function answerAll(path, status, body) { while (pending(path).length) answer(path, status, body); }

const storage = new Map([['vs.token', 'test-token']]);
const location = { hash: '', reload() {} };
const context = vm.createContext({
  document, window: { addEventListener() {} }, navigator: {}, location,
  history: { replaceState() {} }, fetch: fakeFetch, AbortController, URLSearchParams, JSON, console,
  setTimeout: () => 0, clearTimeout() {}, setInterval: () => 0, clearInterval() {},
  localStorage: { getItem: key => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, String(value)),
                  removeItem: key => storage.delete(key) },
});
vm.runInContext(source, context, { filename: 'app.js' });
const run = code => vm.runInContext(code, context);
const flush = async () => { for (let i = 0; i < 5; i++) await new Promise(resolve => setImmediate(resolve)); };

const session = { tty: 'ttys001', sid: 's1', number: 1, name: 'shop', project: 'shop', agent: 'claude', status: 'idle',
                  statusLabel: 'Idle', inTerminal: true, inWindow: false, viewing: false, hasTranscript: false };
const macState = { sessions: [session], today: { agentsWorking: 0, waitingOnYou: 0, projects: [] }, inputAllowed: true,
                   web: '', devPagesAllowed: false, device: { id: 'd', name: 'Phone', push: true }, mac: 'Mac',
                   now: Date.now() / 1000 };

// The page starts paired, on the list.
ready();
await flush();
answerAll('/api/state', 200, macState);
await flush();
run(`state = ${JSON.stringify(macState)}; current = 'ttys001'; currentSid = 's1';`);
const reply = $('reply');
const submit = () => { for (const handler of $('replyForm').listeners.submit) handler({ preventDefault() {} }); };
const inputs = () => requests.filter(r => r.path === '/api/input');

// 1. Two quick Enters: one POST. Nothing says sent until the Mac answers.
reply.value = 'fix the login bug';
submit();
submit();
await flush();
assert.equal(inputs().length, 1, 'one POST for two submits');
assert.equal(inputs()[0].body.text, 'fix the login bug');
const firstID = inputs()[0].body.request;
assert.ok(typeof firstID === 'string' && firstID.length > 0 && firstID.length <= 64, 'the reply carries a request id');
assert.notEqual($('inputStatus').textContent, 'Sent ✓');
answer('/api/input', 200, { ok: true });
await flush();
assert.equal($('inputStatus').textContent, 'Sent ✓');
assert.equal(reply.value, '', 'the box empties once it went in');
// Sent, the next one is a new reply with a new id.
reply.value = 'fix the login bug';
submit();
await flush();
assert.equal(inputs().length, 2);
assert.notEqual(inputs()[1].body.request, firstID);
answer('/api/input', 200, { ok: true });
await flush();

// 2. Tailscale's bare 502 while the Mac may still be typing: "check the screen", not "isn't running", and the text stays.
reply.value = 'and add a test';
submit();
await flush();
answer('/api/input', 502);
await flush();
assert.equal($('inputStatus').textContent, "The Mac didn't confirm in time. Check the screen before sending again.");
assert.ok($('inputStatus').classList.contains('error'));
assert.equal($('offline').hidden, true, 'not reported as the Mac being off');
assert.equal(reply.value, 'and add a test');
// Sent again: the same id, so the Mac types it at most once. Its answer is a duplicate: sent.
submit();
await flush();
assert.equal(inputs().length, 4);
assert.equal(inputs()[3].body.request, inputs()[2].body.request);
answer('/api/input', 200, { ok: true, duplicate: true });
await flush();
assert.equal($('inputStatus').textContent, 'Sent ✓');
// A 504 likewise.
reply.value = 'run it';
submit();
await flush();
answer('/api/input', 504);
await flush();
assert.equal($('inputStatus').textContent, "The Mac didn't confirm in time. Check the screen before sending again.");
// Edited, it's another reply: a new id.
reply.value = 'run it now';
submit();
await flush();
assert.notEqual(inputs()[5].body.request, inputs()[4].body.request);
answer('/api/input', 200, { ok: true });
await flush();
// A bare 502 to anything else is still the Mac being off.
run('refreshList(false)');
await flush();
answer('/api/state', 502);
await flush();
assert.equal($('offline').hidden, false);
assert.equal($('offline').textContent, "VibeSwitcher isn't running on your Mac, or Phone Access is off.");

// 3. A restart on the Mac (503 with its reason): the phone keeps its token.
run('refreshList(false)');
await flush();
answer('/api/state', 503, { error: 'Phone Access is restarting on the Mac. Try again in a moment.' });
await flush();
assert.equal(storage.get('vs.token'), 'test-token');
assert.equal(run('token'), 'test-token');

// 4. Unpaired on the Mac, opened from a notification: the pairing screen with the reason, never an empty list over it.
location.hash = '#s=ttys001';
run('route()');
await flush();
answer('/api/state', 401, { error: "This phone isn't paired with the Mac any more." });
await flush();
assert.equal(run('token'), null);
assert.equal(storage.has('vs.token'), false);
assert.equal($('pair').hidden, false);
assert.equal($('list').hidden, true);
assert.equal($('pairError').hidden, false);
assert.equal($('pairError').textContent, "This phone isn't paired with the Mac any more. Pair it again to keep using it.");
// The pairing screen's directions name the Mac's real place for it.
assert.ok(page.includes('Pair a Phone… in VibeSwitcher › Settings… › Phone'));

console.log('phone-replies: ok');
process.exit(0);
