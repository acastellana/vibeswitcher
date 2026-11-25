// The buttons for what the node already takes from an acting page (docs/process/v2-no-terminal.md, table B and A5):
// each shown only where the page acts and the node lists its kind (`actsFor`), its terminal line and a plain reason
// otherwise; each with a busy state, a receipt in words, the node's refusal beside it with the control back, and a
// confirm in place for what ends or removes something. Drawn on tests/fakedom.test.mjs's stand-in DOM, in English and
// Spanish. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { installDom, find, findAll, byClass, button } from './fakedom.test.mjs';

process.env.TZ = 'UTC';
installDom();
const { setLanguage, t } = await import('../js/i18n.js');
const { pageMaySet } = await import('../js/acting.js');

// Every promise the page chained on a reply has run.
export const flush = () => new Promise((resolve) => setImmediate(resolve));

// An app as the views read it: a store over `state`, the kinds this connection may send, whether it acts, and every
// request and read sent (each answered by `reply(kind, args)`, a value or a promise); `later` the tests' clock.
export function fakeApp({ route = { name: 'node' }, state = {}, kinds = null, acts = true, reply = () => ({ ok: true, result: {} }) } = {}) {
  const sent = [];
  const waiting = [];
  const answer = (kind, args) => { sent.push({ kind, args }); return Promise.resolve(reply(kind, args)); };
  const listeners = new Map();
  const store = {
    state: { node: null, connection: 'live', phrase: null, pageWords: null, sessions: new Map(), leads: new Map(), boards: new Map(), cards: new Map(),
      cardKeys: new Map(), acting: new Map(), draftRefused: new Map(), sessionDraftRefused: new Map(), plugins: null, ...state },
    acts: () => acts,
    can: (kind) => kinds === null || kinds.includes(kind),
    subscribe(topic, fn) { (listeners.get(topic) || listeners.set(topic, []).get(topic)).push(fn); return () => {}; },
    notify(topic) { for (const fn of listeners.get(topic) || []) fn(); },
    read: answer,
    request: answer,
    cardKey: (id) => id,
    draftOf: () => null,
    sessionDraftOf: () => null,
  };
  const went = [];
  const ui = { state: { route }, subscribe() {}, go(hash) { went.push(hash); } };
  const later = (fn, ms) => { const timer = { fn, ms, on: true }; waiting.push(timer); return () => { timer.on = false; }; };
  const fire = () => { for (const timer of waiting.splice(0)) if (timer.on) timer.fn(); };
  return { store, sent, ui, went, later, waiting, fire };
}

export const buttonNamed = (el, text) => find(el, (node) => node.tag === 'button' && !node.hidden && node.textContent.trim() === text);

// B10: the settings the node keeps to a terminal (`NodeSettings`' `terminalOnly`, every plugin's) offer no Set.
test('B10: no Set for a setting the node keeps to a terminal; the line and why, where the page acts', async () => {
  const { editor } = await import('../js/views/settings.js');
  for (const key of ['lead_mail', 'verifier_model', 'security_audit_model', 'max_workers', 'policy', 'floor_strict_paths', 'shell_allow', 'some_new_setting']) {
    assert.equal(pageMaySet(key, '1'), false, key);
  }
  for (const key of ['node_heavy_slots', 'boost', 'lead_model', 'lead_rotation', 'projects_folder', 'ai_summaries']) assert.equal(pageMaySet(key, '1'), true, key);
  for (const [code, set] of [['en', 'Set'], ['es', 'Fijar']]) {
    setLanguage(code);
    const app = fakeApp({ kinds: ['set'], acts: true });
    for (const setting of [
      { key: 'max_workers', title: 'Workers at once, at most', form: 'count', scope: 'project', limits: '1 to 99', value: '4', default: '4' },
      { key: 'lead_mail', title: 'Let project leads message each other', form: 'flag', scope: 'node', value: 'off', default: 'off', draft: 'on' },
      { key: 'verifier_model', title: 'Verifier’s model', form: 'model', scope: 'project', value: 'opus', default: '', draft: 'sonnet' },
      { key: 'shell_allow', title: 'Allowed commands', form: 'text', scope: 'node', home: 'plugin', value: '', default: '', draft: 'ls' },
    ]) {
      const box = editor(setting, setting.scope === 'project' ? '/home/u/site' : null, new Map([[setting.key, setting.draft || '5']]), app);
      assert.equal(buttonNamed(box, set), null, `${code} ${setting.key}: no Set`);
      assert.match(box.textContent, /vibeswitcher set/, `${setting.key}: its line`);
      assert.match(box.textContent, new RegExp(t('svTerminalKeeps').slice(0, 24)), `${setting.key}: why there is no Set`);
    }
    // One the page may set still has Set, and no reason.
    const slots = editor({ key: 'node_heavy_slots', title: 'Test and build slots', form: 'count', scope: 'node', value: '3', default: '2' }, null, new Map([['node_heavy_slots', '4']]), app);
    assert.ok(buttonNamed(slots, set));
    assert.doesNotMatch(slots.textContent, new RegExp(t('svTerminalKeeps').slice(0, 24)));
  }
  setLanguage('en');
});
