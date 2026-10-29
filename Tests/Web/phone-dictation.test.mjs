// Dictation on the phone: the mic button shows when the Mac offers dictation; the first press shows the one-time note
// about OpenAI (once per phone) instead of recording; held, it records with MediaRecorder, and let go, it posts the
// recording to the Mac's /api/dictation with the phone's token, its audio type, its length and the session; the text
// the Mac answers lands in the reply box at the cursor and is never sent. Without a key on the Mac the button says
// what's needed and nothing is recorded; a failure is said plainly.
// Runs the unmodified Web/app.js in node on a fake DOM with a fake fetch and a fake microphone: nothing is recorded or sent.
// Run by PhoneWebTests (swift test), or by hand: node Tests/Web/phone-dictation.test.mjs
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
for (const id of ['askCard', 'askText', 'askOptions', 'quickReplies', 'quickEditor', 'inputStatus', 'micButton', 'dictationNote', 'dictationOk', 'dictationStatus']) {
  assert.ok(page.includes(`id="${id}"`), `index.html has #${id}`);
}

// ---------- A fake Mac: each request waits for the test to answer it ----------

const requests = [];   // { path, options, answer(status, body) }
async function fakeFetch(path, options = {}) {
  return new Promise(resolve => {
    requests.push({
      path, options,
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

// ---------- A fake microphone ----------

let clock = 1_000_000;
const streams = [];
let micAllowed = true;
class FakeStream {
  constructor() { this.tracks = [{ stopped: false, stop() { this.stopped = true; } }]; streams.push(this); }
  getTracks() { return this.tracks; }
}
const recorders = [];
class FakeMediaRecorder {
  static isTypeSupported(type) { return type === 'audio/mp4'; }
  constructor(stream, options) {
    this.stream = stream;
    this.options = options;
    this.mimeType = options.mimeType;
    this.state = 'inactive';
    this.listeners = {};
    recorders.push(this);
  }
  addEventListener(type, handler) { (this.listeners[type] ||= []).push(handler); }
  start() { this.state = 'recording'; }
  stop() {
    this.state = 'inactive';
    for (const handler of this.listeners.dataavailable || []) handler({ data: new Blob(['fake-audio-bytes'], { type: this.mimeType }) });
    for (const handler of this.listeners.stop || []) handler({});
  }
}
const navigator = { mediaDevices: { getUserMedia: async () => { if (!micAllowed) throw new Error('NotAllowedError'); return new FakeStream(); } } };
const timers = [];

const storage = new Map([['vs.token', 'test-token']]);
const location = { hash: '', reload() {} };
const context = vm.createContext({
  document, window: { addEventListener() {}, MediaRecorder: FakeMediaRecorder }, navigator, location, MediaRecorder: FakeMediaRecorder, Blob,
  history: { replaceState() {} }, fetch: fakeFetch, AbortController, URLSearchParams, JSON, console,
  Date: { now: () => clock },
  setTimeout: (fn, ms) => { timers.push({ fn, ms }); return timers.length; }, clearTimeout(id) { if (timers[id - 1]) timers[id - 1].fn = null; },
  setInterval: () => 0, clearInterval() {},
  localStorage: { getItem: key => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, String(value)),
                  removeItem: key => storage.delete(key) },
});
vm.runInContext(source, context, { filename: 'app.js' });
const run = code => vm.runInContext(code, context);
const flush = async () => { for (let i = 0; i < 8; i++) await new Promise(resolve => setImmediate(resolve)); };

const session = { tty: 'ttys001', sid: 's1', number: 1, name: 'shop', project: 'shop', agent: 'claude', status: 'idle',
                  statusLabel: 'Idle', inTerminal: true, inWindow: false, viewing: false, hasTranscript: false };
const macState = { sessions: [session], today: { agentsWorking: 0, waitingOnYou: 0, projects: [] }, inputAllowed: true,
                   web: '', devPagesAllowed: false, device: { id: 'd', name: 'Phone', push: true }, mac: 'Mac',
                   now: Date.now() / 1000, dictation: 'on' };

ready();
await flush();
answerAll('/api/state', 200, macState);
await flush();
run(`state = ${JSON.stringify(macState)}; current = 'ttys001'; currentSid = 's1'; renderSessionMeta();`);
const mic = $('micButton');
const reply = $('reply');
const fire = (node, type, extra = {}) => { for (const handler of node.listeners[type] || []) handler({ type, preventDefault() {}, ...extra }); };
const dictations = () => requests.filter(r => r.path.startsWith('/api/dictation'));
const inputs = () => requests.filter(r => r.path === '/api/input');

// 1. The button shows when the Mac offers dictation.
assert.equal(mic.hidden, false, 'the mic shows');
assert.equal(mic.getAttribute('aria-label'), 'Hold to dictate');
assert.ok(page.includes('id="micButton"') && page.includes('aria-label="Hold to dictate"'));

// 2. The first press shows the note about OpenAI, records nothing; Got it is remembered on this phone.
fire(mic, 'pointerdown');
await flush();
assert.equal($('dictationNote').hidden, false, 'the one-time note shows');
assert.equal(recorders.length, 0, 'nothing recorded before the note is read');
fire(mic, 'pointerup');
$('dictationOk').click();
assert.equal($('dictationNote').hidden, true);
assert.equal(storage.get('vs.dictationNoted'), '1');

// 3. Held, it records; let go after 3.2 s, it posts the recording to the Mac with the phone's token.
reply.value = 'please  now';
reply.selectionStart = 7;
reply.selectionEnd = 7;
fire(mic, 'pointerdown');
await flush();
assert.equal(recorders.length, 1, 'recording');
assert.equal(recorders[0].state, 'recording');
assert.equal(recorders[0].options.mimeType, 'audio/mp4');
assert.equal(recorders[0].options.audioBitsPerSecond, 32000);
assert.ok(mic.classList.contains('recording'));
assert.equal($('dictationNote').hidden, true, 'the note shows once');
clock += 3200;
fire(mic, 'pointerup');
await flush();
assert.equal(recorders[0].state, 'inactive');
assert.ok(streams[0].tracks[0].stopped, 'the microphone is released');
assert.equal(dictations().length, 1);
const posted = dictations()[0];
assert.equal(posted.path, '/api/dictation?duration=3.2&sid=s1');
assert.equal(posted.options.method, 'POST');
assert.equal(posted.options.headers.Authorization, 'Bearer test-token');
assert.equal(posted.options.headers['Content-Type'], 'audio/mp4');
assert.ok(posted.options.body instanceof Blob);
assert.equal(await posted.options.body.text(), 'fake-audio-bytes');
assert.equal($('dictationStatus').textContent, 'Transcribing on your Mac…');
answer('/api/dictation', 200, { text: 'fix the header' });
await flush();
// In the box at the cursor, with the spaces it needs; nothing was sent.
assert.equal(reply.value, 'please fix the header now');
assert.equal(inputs().length, 0, 'never sent by itself');
assert.equal($('dictationStatus').hidden, true);

// 4. The 2-minute limit stops the recording by itself.
fire(mic, 'pointerdown');
await flush();
assert.equal(recorders.length, 2);
const limit = timers.filter(t => t.fn && t.ms === 120000).pop();
assert.ok(limit, 'a 2-minute limit is set');
clock += 120000;
limit.fn();
await flush();
assert.equal(recorders[1].state, 'inactive');
assert.ok(dictations()[1].path.startsWith('/api/dictation?duration=120.0'));
answer('/api/dictation', 200, { text: 'and more' });
await flush();
assert.equal($('dictationStatus').textContent, 'Stopped at 2 minutes, the most one dictation takes.');
fire(mic, 'pointerup');
await flush();
assert.equal(dictations().length, 2, 'letting go afterwards sends nothing more');

// 5. A failure on the Mac is said plainly, and the box keeps what's in it.
const before = reply.value;
fire(mic, 'pointerdown');
await flush();
clock += 2000;
fire(mic, 'pointerup');
await flush();
answer('/api/dictation', 502, { error: 'OpenAI refused the API key (HTTP 401). Check it in Settings › General › Dictation.' });
await flush();
assert.equal($('dictationStatus').textContent, 'OpenAI refused the API key (HTTP 401). Check it in Settings › General › Dictation.');
assert.ok($('dictationStatus').classList.contains('error'));
assert.equal(reply.value, before);

// 6. A tap too short sends nothing.
fire(mic, 'pointerdown');
await flush();
clock += 100;
fire(mic, 'pointerup');
await flush();
assert.equal(dictations().length, 3);
assert.equal($('dictationStatus').textContent, 'Nothing was recorded: hold the mic while you speak.');

// 7. Without a key on the Mac: the button says what's needed, and a press records nothing.
run(`state.dictation = 'needsKey'; renderSessionMeta();`);
assert.equal(mic.hidden, false);
assert.ok(mic.classList.contains('needsKey'));
assert.ok(mic.getAttribute('aria-label').includes('OpenAI API key on the Mac'));
const recorded = recorders.length;
fire(mic, 'pointerdown');
await flush();
assert.equal(recorders.length, recorded);
assert.ok($('dictationStatus').textContent.includes('Settings… › General › Dictation'));
fire(mic, 'pointerup');

// 8. A Mac without dictation (an older one, or none offered): no button.
run(`state.dictation = 'off'; renderSessionMeta();`);
assert.equal(mic.hidden, true);
run(`delete state.dictation; renderSessionMeta();`);
assert.equal(mic.hidden, true);

// 9. A microphone the browser refused is said.
run(`state.dictation = 'on'; renderSessionMeta();`);
micAllowed = false;
fire(mic, 'pointerdown');
await flush();
assert.ok($('dictationStatus').textContent.includes('may not use the microphone'));
assert.equal(dictations().length, 3);

console.log('phone-dictation: ok');
process.exit(0);
