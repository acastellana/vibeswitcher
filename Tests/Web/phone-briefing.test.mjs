// Brief me on the phone: the button posts /api/briefing with the phone's token, shows a spinner while the Mac writes
// it, asks until it's written, then plays its audio from a blob through the page's <audio> and shows its text; Stop
// stops it. Runs the unmodified Web/app.js in node on a fake DOM with a fake fetch: nothing is served or played.
// Run by PhoneWebTests (swift test), or by hand: node Tests/Web/phone-briefing.test.mjs
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
  // app.js must never parse the Mac's text as HTML.
  set innerHTML(_) { throw new Error('innerHTML used'); }
  get innerHTML() { throw new Error('innerHTML used'); }
  insertAdjacentHTML() { throw new Error('insertAdjacentHTML used'); }
  append(...nodes) {
    for (const node of nodes) this.childNodes.push(node instanceof FakeElement || node instanceof FakeText ? node : new FakeText(node));
  }
  replaceChildren(...nodes) { this.childNodes = []; this.append(...nodes); }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  getAttribute(name) { return this.attributes[name] ?? null; }
  addEventListener(type, handler) { (this.listeners[type] ||= []).push(handler); }
  dispatch(type) { for (const handler of this.listeners[type] || []) handler({ type, preventDefault() {} }); }
  click() { if (!this.disabled) this.dispatch('click'); }
  focus() {}
  requestSubmit() {}
}

// The page's <audio>: what it was given to play, and when it was told to play or stop.
class FakeAudio extends FakeElement {
  constructor() {
    super('audio');
    this.src = '';
    this.paused = true;
    this.ended = false;
    this.currentTime = 0;
    this.played = [];       // the src at each play()
    this.pauses = 0;
    this.refuse = false;    // a phone that won't start audio without a tap
  }
  play() {
    this.played.push(this.src);
    if (this.refuse) return Promise.reject(new Error('NotAllowedError'));
    this.paused = false;
    this.ended = false;
    this.dispatch('play');
    return Promise.resolve();
  }
  pause() { this.pauses++; this.paused = true; this.dispatch('pause'); }
  finish() { this.paused = true; this.ended = true; this.dispatch('ended'); }
}

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
  querySelector: () => new FakeElement('header'),
  querySelectorAll: () => [],
  readyListeners: [],
  addEventListener(type, handler) { if (type === 'DOMContentLoaded') this.readyListeners.push(handler); },
};
const $ = id => document.getElementById(id);
// The page's elements as index.html has them: present, and hidden where it says so.
const page = readFileSync(new URL('../../Web/index.html', import.meta.url), 'utf8');
for (const [, tag, attributes] of page.matchAll(/<(\w+)\s([^>]*\bid="[^"]+"[^>]*)>/g)) {
  const id = attributes.match(/\bid="([^"]+)"/)[1];
  if (tag === 'audio') elements.set(id, new FakeAudio());
  const node = $(id);
  node.hidden = /(^|\s)hidden(\s|$|=)/.test(attributes);
}
for (const id of ['briefCard', 'briefMe', 'briefSpinner', 'briefLabel', 'briefPlay', 'briefAudio', 'briefText', 'briefNotice', 'briefError']) {
  assert.ok(page.includes(`id="${id}"`), `index.html has #${id}`);
}
assert.ok($('briefAudio') instanceof FakeAudio, '#briefAudio is an <audio>');

// ---------- A fake Mac: /api/briefing ----------

const requests = [];
let briefingAsks = [];   // what GET /api/briefing answers, one per ask (the last one repeats)
let startReply = { status: 200, body: { writing: true } };
const macState = { sessions: [], today: { agentsWorking: 0, waitingOnYou: 0, projects: [] }, inputAllowed: true, web: '',
                   devPagesAllowed: false, device: { id: 'd', name: 'Phone', push: true }, mac: 'Mac', now: Date.now() / 1000 };

async function fakeFetch(path, options = {}) {
  const reply = (status, body) => ({ ok: status >= 200 && status < 300, status, json: async () => body });
  // The list's own polls (the card sits on it) get an empty Mac.
  if (path === '/api/state') return reply(200, macState);
  if (path === '/api/devpages') return reply(200, { pages: [] });
  requests.push({ path, method: options.method || 'GET', authorization: options.headers?.Authorization, body: options.body });
  if (path === '/api/briefing' && options.method === 'POST') return reply(startReply.status, startReply.body);
  if (path === '/api/briefing') return reply(200, briefingAsks.length > 1 ? briefingAsks.shift() : briefingAsks[0]);
  return reply(404, { error: 'not found' });
}

// Blob URLs: each blob the page made, by its URL.
const blobs = new Map();
const revoked = [];
const FakeURL = {
  createObjectURL(blob) { const url = `blob:vs/${blobs.size + 1}`; blobs.set(url, blob); return url; },
  revokeObjectURL(url) { revoked.push(url); },
};

const storage = new Map([['vs.token', 'test-token']]);
const context = vm.createContext({
  document, window: { addEventListener() {} }, navigator: {}, location: { hash: '', reload() {} },
  history: { replaceState() {} }, fetch: fakeFetch, AbortController, URLSearchParams, URL: FakeURL, Blob, atob, JSON, console,
  // Every wait is over at once: the phone's asks follow each other without the second between them.
  setTimeout: fn => { setImmediate(fn); return 0; }, clearTimeout() {}, setInterval: () => 0, clearInterval() {},
  localStorage: { getItem: key => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, String(value)),
                  removeItem: key => storage.delete(key) },
});
vm.runInContext(source, context, { filename: 'app.js' });
for (const ready of document.readyListeners) ready();
const flush = async (times = 20) => { for (let i = 0; i < times; i++) await new Promise(resolve => setImmediate(resolve)); };
const bytesOf = async blob => Buffer.from(await blob.arrayBuffer());
const audio = $('briefAudio');
const mp3 = Buffer.from('ID3-fake-briefing-mp3');
const attack = '<img src=x onerror="alert(1)">';

// 0. Before a press: the button, no spinner, no stop control, no text.
assert.ok(!source.includes('innerHTML'), 'app.js uses innerHTML');
assert.equal($('briefCard').hidden, false);
assert.equal($('briefSpinner').hidden, true);
assert.equal($('briefPlay').hidden, true);
assert.equal($('briefText').hidden, true);

// 1. A press: posted with the phone's token, the spinner shows, and a moment of silence starts from the tap itself
//    (before anything is awaited), so the briefing may play when it arrives.
briefingAsks = [{ writing: true }, { writing: true },
                { text: `Two tasks landed. ${attack}`, language: 'es', at: 1000, voice: 'elevenlabs',
                  audio: mp3.toString('base64'), audioType: 'audio/mpeg' }];
$('briefMe').click();
assert.equal(requests[0].path, '/api/briefing');
assert.equal(requests[0].method, 'POST');
assert.equal(requests[0].authorization, 'Bearer test-token');
assert.equal($('briefSpinner').hidden, false);
assert.equal($('briefLabel').textContent, 'Writing your briefing…');
assert.equal($('briefMe').disabled, true);
assert.equal($('briefPlay').hidden, false);
assert.equal($('briefPlay').textContent, '■ Stop');
assert.equal(audio.played.length, 1, 'played from the tap');
assert.equal(blobs.get(audio.played[0]).type, 'audio/wav');
const wav = await bytesOf(blobs.get(audio.played[0]));
assert.equal(wav.subarray(0, 4).toString(), 'RIFF');
assert.equal(wav.subarray(8, 12).toString(), 'WAVE');

// 2. It asks until it's written, then plays the audio from a blob of exactly the Mac's bytes, and shows the text as text.
await flush();
assert.deepEqual(requests.map(r => `${r.method} ${r.path}`),
                 ['POST /api/briefing', 'GET /api/briefing', 'GET /api/briefing', 'GET /api/briefing']);
assert.ok(requests.every(r => r.authorization === 'Bearer test-token'));
assert.match(audio.src, /^blob:vs\/\d+$/);
assert.equal(audio.played.at(-1), audio.src, 'the briefing is what plays');
assert.equal(blobs.get(audio.src).type, 'audio/mpeg');
assert.deepEqual(await bytesOf(blobs.get(audio.src)), mp3);
assert.ok(revoked.includes(audio.played[0]), "the silence's URL is let go");
assert.equal($('briefText').hidden, false);
assert.equal($('briefText').textContent, `Two tasks landed. ${attack}`);
assert.equal($('briefText').children.length, 0, 'the text is text, never markup');
assert.equal($('briefText').lang, 'es');
assert.equal($('briefNotice').hidden, true);
assert.equal($('briefSpinner').hidden, true);
assert.equal($('briefMe').disabled, false);
assert.equal($('briefLabel').textContent, 'Brief me');
assert.equal($('briefPlay').textContent, '■ Stop');

// 3. Stop stops it; Play plays it again; at its end the control says Play.
const pauses = audio.pauses;
$('briefPlay').click();
assert.equal(audio.pauses, pauses + 1);
assert.equal(audio.paused, true);
assert.equal(audio.currentTime, 0);
assert.equal($('briefPlay').textContent, '▶ Play');
$('briefPlay').click();
assert.equal(audio.played.at(-1), audio.src);
assert.equal($('briefPlay').textContent, '■ Stop');
audio.finish();
assert.equal($('briefPlay').textContent, '▶ Play');

// 4. The Mac's own voice, with its notice; a phone that won't start it on its own leaves ▶ Play to tap.
requests.length = 0;
audio.refuse = true;
const m4a = Buffer.from('ftyp-fake-m4a');
briefingAsks = [{ text: 'Todo tranquilo.', language: 'es', at: 2000, voice: 'mac', audio: m4a.toString('base64'),
                  audioType: 'audio/mp4', notice: "ElevenLabs refused the key (HTTP 401), so the Mac's voice reads it." }];
$('briefMe').click();
await flush();
assert.deepEqual(requests.map(r => `${r.method} ${r.path}`), ['POST /api/briefing', 'GET /api/briefing']);
assert.equal(blobs.get(audio.src).type, 'audio/mp4');
assert.deepEqual(await bytesOf(blobs.get(audio.src)), m4a);
assert.equal($('briefNotice').hidden, false);
assert.equal($('briefNotice').textContent, "ElevenLabs refused the key (HTTP 401), so the Mac's voice reads it.");
assert.equal($('briefPlay').hidden, false);
assert.equal($('briefPlay').textContent, '▶ Play');
audio.refuse = false;
$('briefPlay').click();
assert.equal(audio.played.at(-1), audio.src);
assert.equal($('briefPlay').textContent, '■ Stop');

// 5. Stop while it's written: no more asks, and nothing plays when it would have arrived.
requests.length = 0;
briefingAsks = [{ writing: true }];
$('briefMe').click();
$('briefPlay').click();
assert.equal($('briefSpinner').hidden, true);
assert.equal($('briefMe').disabled, false);
const playedBefore = audio.played.length;
await flush();
assert.ok(requests.filter(r => r.method === 'GET').length <= 1, 'stopped asking');
assert.equal(audio.played.length, playedBefore);

// 6. The Mac says no (throttled): its message, and the button back.
requests.length = 0;
startReply = { status: 429, body: { error: "That's a lot of briefings; wait a few minutes." } };
$('briefMe').click();
await flush();
assert.equal($('briefError').hidden, false);
assert.equal($('briefError').textContent, "That's a lot of briefings; wait a few minutes.");
assert.equal($('briefSpinner').hidden, true);
assert.equal($('briefMe').disabled, false);
assert.deepEqual(requests.map(r => `${r.method} ${r.path}`), ['POST /api/briefing']);

console.log('phone-briefing: ok');
process.exit(0);
