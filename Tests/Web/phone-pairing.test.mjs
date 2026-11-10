// What the phone says when it can't reach the Mac: with Phone Access switched off, the port is simply closed, the same
// as Tailscale being off or the Mac asleep, so the message has to name all three. Run by PhoneWebTests (swift test), or
// by hand: node Tests/Web/phone-pairing.test.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const source = readFileSync(new URL('../../Web/app.js', import.meta.url), 'utf8');
const message = /const UNREACHABLE = "([^"]+)"/.exec(source)?.[1];
assert.ok(message, 'UNREACHABLE is defined');
for (const cause of ['Tailscale', 'awake', 'Phone Access']) assert.ok(message.includes(cause), `names ${cause}: ${message}`);
console.log('phone-pairing: ok');

// The Mac answering 503 (restarting, or its list of phones unreadable) shows on every screen, in the banner: the list's
// poll swallows errors, and a phone staring at a blank list has been told nothing.
{
  const { default: vm } = await import('node:vm');
  const node = () => new Proxy({ hidden: true, textContent: '', style: {}, value: '', dataset: {},
    classList: { add() {}, remove() {}, toggle() {}, contains: () => false } }, {
    get: (target, key) => key in target ? target[key] : (typeof key === 'symbol' ? undefined : () => node()),
    set: (target, key, value) => { target[key] = value; return true; },
  });
  const nodes = new Map();
  let answer = { status: 503, body: { error: 'The Mac couldn\'t read its list of paired phones.' } };
  const context = vm.createContext({
    console, setTimeout, clearTimeout, setInterval: () => 0, clearInterval() {}, URLSearchParams, AbortController,
    document: { getElementById: id => nodes.get(id) ?? nodes.set(id, node()).get(id), addEventListener() {},
                querySelectorAll: () => [], querySelector: () => node(), createElement: () => node(),
                body: node(), documentElement: node(), visibilityState: 'visible' },
    window: { addEventListener() {}, visualViewport: null, matchMedia: () => ({ matches: false, addEventListener() {} }) },
    navigator: { userAgent: 'test', serviceWorker: undefined }, location: { hash: '', pathname: '/' },
    history: { replaceState() {} }, localStorage: { getItem: () => 'tok', setItem() {}, removeItem() {} },
    fetch: async () => ({ status: answer.status, ok: answer.status < 400, json: async () => answer.body }),
  });
  vm.runInContext(source, context);
  const banner = context.document.getElementById('offline');
  await context.refreshList(false);
  assert.equal(banner.hidden, false, 'the banner shows on a 503');
  assert.equal(banner.textContent, answer.body.error);
  answer = { status: 200, body: {} };
  await context.api('/api/state');
  assert.equal(banner.hidden, true, 'and goes once the Mac answers');
  console.log('phone-pairing: 503 banner ok');
}
