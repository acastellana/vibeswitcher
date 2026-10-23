// PH-1: the phone draws a menu from /api/state as option buttons and a tap posts its index with the menu's fingerprint.
// Runs the unmodified Web/app.js in node on a fake DOM with a fake fetch: nothing is served, paired or typed.
// Run by PhoneWebTests (swift test), or by hand: node Tests/Web/phone-menu.test.mjs
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
// The page's elements as index.html has them: present, and hidden where it says so.
const page = readFileSync(new URL('../../Web/index.html', import.meta.url), 'utf8');
for (const [, attributes] of page.matchAll(/<\w+\s([^>]*\bid="[^"]+"[^>]*)>/g)) {
  const node = $(attributes.match(/\bid="([^"]+)"/)[1]);
  node.hidden = /(^|\s)hidden(\s|$|=)/.test(attributes);
}
for (const id of ['askCard', 'askText', 'askOptions', 'quickReplies', 'quickEditor', 'inputStatus']) {
  assert.ok(page.includes(`id="${id}"`), `index.html has #${id}`);
}

// ---------- A fake Mac: /api/state, /api/input ----------

const posts = [];
let macState = null;
let inputReply = { status: 200, body: { ok: true } };

async function fakeFetch(path, options = {}) {
  const reply = (status, body) => ({ ok: status >= 200 && status < 300, status, json: async () => body });
  if (path === '/api/state') return reply(200, macState);
  if (path === '/api/input') {
    posts.push(JSON.parse(options.body));
    return reply(inputReply.status, inputReply.body);
  }
  if (path.startsWith('/api/screen')) return reply(200, { tty: 'ttys001', text: '' });
  return reply(404, { error: 'not found' });
}

const storage = new Map([['vs.token', 'test-token']]);
const context = vm.createContext({
  document, window: { addEventListener() {} }, navigator: {}, location: { hash: '', reload() {} },
  history: { replaceState() {} }, fetch: fakeFetch, AbortController, URLSearchParams, JSON, console,
  setTimeout: () => 0, clearTimeout() {}, setInterval: () => 0, clearInterval() {},
  localStorage: { getItem: key => storage.get(key) ?? null, setItem: (key, value) => storage.set(key, String(value)),
                  removeItem: key => storage.delete(key) },
});
vm.runInContext(source, context, { filename: 'app.js' });
const run = code => vm.runInContext(code, context);

// ---------- The state the Mac sends ----------

const attack = '<img src=x onerror="alert(1)">';
function session(menu) {
  return { tty: 'ttys001', sid: 's1', number: 1, name: 'shop', project: 'shop', agent: 'claude', status: 'needsInput',
           statusLabel: 'Needs you', inTerminal: true, inWindow: true, viewing: false, hasTranscript: false,
           detail: 'Run: npm publish --tag next', ...(menu ? { menu } : {}) };
}
function stateWith(sessionRow, inputAllowed = true) {
  return { sessions: [sessionRow], today: { agentsWorking: 0, waitingOnYou: 1, projects: [] }, inputAllowed, web: '',
           devPagesAllowed: false, device: { id: 'd', name: 'Phone', push: true }, mac: 'Mac', now: Date.now() / 1000 };
}
const menu = {
  question: 'Bash command\nnpm publish --tag next\nDo you want to proceed?',
  options: ['Yes', `Yes, and don't ask again for ${attack}`, 'No, and tell Claude what to do differently (esc)'],
  descriptions: [null, 'For npm commands in this project', null], selected: 0, fingerprint: 'fp-one',
};

function open(state) {
  macState = state;
  run(`state = ${JSON.stringify(state)}; current = 'ttys001'; currentSid = 's1';`);
  $('conversation').hidden = true;   // the Terminal tab is shown: no transcript is asked for
  run('renderQuickReplies(); renderSessionMeta();');
}
const labels = () => $('askOptions').children.map(button => button.children[0].textContent);
const flush = () => new Promise(resolve => setImmediate(resolve));

// 1. The menu is drawn as one full-width button per option, its text set as text only.
assert.ok(!source.includes('innerHTML'), 'app.js uses innerHTML');
open(stateWith(session(menu)));
assert.equal($('askCard').hidden, false);
assert.equal($('askText').textContent, menu.question);
assert.equal($('askOptions').hidden, false);
assert.equal($('askOptions').children.length, 3, 'one button per option');
assert.ok($('askOptions').children.every(button => button.tagName === 'BUTTON' && button.type === 'button'));
assert.deepEqual(labels(), menu.options);
assert.equal($('askOptions').children[1].children[0].children.length, 0, 'a label is text, never markup');
assert.equal($('askOptions').children[1].children[1].textContent, 'For npm commands in this project');
assert.ok($('askOptions').children[0].classList.contains('selected'));
assert.ok($('askOptions').children.every(button => !button.disabled));
// The quick replies hide while a menu is up (typed text doesn't answer it).
assert.equal($('quickReplies').hidden, true);

// 2. A tap posts its index with the menu's fingerprint, for the session shown.
$('askOptions').children[2].click();
await flush();
assert.equal(posts.length, 1);
assert.deepEqual(posts[0], { tty: 'ttys001', sid: 's1', choose: 2, fingerprint: 'fp-one' });
assert.equal($('inputStatus').textContent, `“${menu.options[2]}” ✓`);

// 3. A stale tap: the Mac answers 409 and says so, and the menu it shows now replaces the old buttons.
open(stateWith(session(menu)));
inputReply = { status: 409, body: { error: 'That question changed or is gone, so nothing was typed. Here it is now.' } };
const changed = { ...menu, question: 'Bash command\nrm -rf build\nDo you want to proceed?', options: ['Yes', 'No'],
                  descriptions: [null, null], fingerprint: 'fp-two' };
macState = stateWith(session(changed));
$('askOptions').children[0].click();
await flush(); await flush(); await flush();
assert.equal(posts.length, 2);
assert.deepEqual(posts[1], { tty: 'ttys001', sid: 's1', choose: 0, fingerprint: 'fp-one' });
assert.equal($('inputStatus').textContent, inputReply.body.error);
assert.ok($('inputStatus').classList.contains('error'));
assert.deepEqual(labels(), ['Yes', 'No'], 'redrawn from the menu on the screen now');
assert.equal($('askText').textContent, changed.question);

// 4. Replies off on the Mac: the options show, but can't be tapped.
inputReply = { status: 200, body: { ok: true } };
open(stateWith(session(menu), false));
assert.deepEqual(labels(), menu.options);
assert.ok($('askOptions').children.every(button => button.disabled));
$('askOptions').children[0].click();
await flush();
assert.equal(posts.length, 2, 'nothing posted');

// 5. A multi-select: its boxes, and its Submit row as the last button.
open(stateWith(session({ question: 'Which toppings?', options: ['Cream', 'Nuts'], descriptions: [null, null], selected: 1,
                         checked: [true, false], submit: 'Submit', fingerprint: 'fp-three' })));
assert.deepEqual(labels(), ['☑ Cream', '☐ Nuts', 'Submit']);
$('askOptions').children[2].click();
await flush();
assert.deepEqual(posts[2], { tty: 'ttys001', sid: 's1', choose: 2, fingerprint: 'fp-three' });

// 6. The 1/2/3 keys while a menu is shown: a tap on that option with the menu's fingerprint, never a bare digit (one
//    would answer whatever question is up by the time it arrives).
const pressKey = async text => {
  context.keyButton = Object.assign(new FakeElement('button'), { dataset: { text } });
  run('pressKey(keyButton)');
  await flush();
};
open(stateWith(session(menu)));
await pressKey('2');
assert.equal(posts.length, 4);
assert.deepEqual(posts[3], { tty: 'ttys001', sid: 's1', choose: 1, fingerprint: 'fp-one' });
assert.equal($('inputStatus').textContent, `“${menu.options[1]}” ✓`);
// A digit the menu has no option for: nothing sent.
open(stateWith(session(changed)));
await pressKey('3');
assert.equal(posts.length, 4, 'nothing posted');
assert.equal($('inputStatus').textContent, "There's no option 3.");

// 7. Waiting on you with no menu read (yet): the question's text, no buttons, the quick replies back.
open(stateWith(session(null)));
assert.equal($('askCard').hidden, false);
assert.equal($('askText').textContent, 'Run: npm publish --tag next');
assert.equal($('askOptions').hidden, true);
assert.equal($('askOptions').children.length, 0);
assert.equal($('quickReplies').hidden, false);
// With no menu shown, a digit key is the digit.
await pressKey('1');
assert.deepEqual(posts[4], { tty: 'ttys001', sid: 's1', text: '1', submit: false });

// 8. ⏎ and the arrows while a menu is shown go with its fingerprint too: ⏎ is a tap on the highlighted option, ↑ ↓ move
//    only while that menu is still up. With none shown they're the raw keys, as before.
const pressNamedKey = async key => {
  context.keyButton = Object.assign(new FakeElement('button'), { dataset: { key } });
  context.keyButton.textContent = key;
  run('pressKey(keyButton)');
  await flush();
};
open(stateWith(session({ ...menu, selected: 1 })));
await pressNamedKey('enter');
assert.deepEqual(posts[5], { tty: 'ttys001', sid: 's1', choose: 1, fingerprint: 'fp-one' });
assert.equal($('inputStatus').textContent, `“${menu.options[1]}” ✓`);
open(stateWith(session(menu)));
await pressNamedKey('down');
assert.deepEqual(posts[6], { tty: 'ttys001', sid: 's1', key: 'down', fingerprint: 'fp-one' });
await pressNamedKey('up');
assert.deepEqual(posts[7], { tty: 'ttys001', sid: 's1', key: 'up', fingerprint: 'fp-one' });
// A multi-select's cursor on its Submit row: ⏎ is a tap on Submit.
open(stateWith(session({ question: 'Which toppings?', options: ['Cream', 'Nuts'], descriptions: [null, null], selected: 2,
                         checked: [true, false], submit: 'Submit', fingerprint: 'fp-three' })));
await pressNamedKey('enter');
assert.deepEqual(posts[8], { tty: 'ttys001', sid: 's1', choose: 2, fingerprint: 'fp-three' });
// Esc stays a raw key (it only cancels).
await pressNamedKey('escape');
assert.deepEqual(posts[9], { tty: 'ttys001', sid: 's1', key: 'escape' });
// No menu shown: the raw keys.
open(stateWith(session(null)));
await pressNamedKey('enter');
await pressNamedKey('down');
assert.deepEqual(posts.slice(10), [{ tty: 'ttys001', sid: 's1', key: 'enter' }, { tty: 'ttys001', sid: 's1', key: 'down' }]);
// A paused session's menu isn't offered: raw too.
open(stateWith({ ...session(menu), paused: true }));
await pressNamedKey('enter');
assert.deepEqual(posts[12], { tty: 'ttys001', sid: 's1', key: 'enter' });

console.log('phone-menu: ok');
process.exit(0);
