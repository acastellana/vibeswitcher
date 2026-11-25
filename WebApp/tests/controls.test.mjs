// Settings' controls and This node's one line (the UX review of 2026-11-25, U14 and U15): a setting's Change looks
// pressable and an open setting shows one way to apply it (Set where the page acts for you, else the terminal's line);
// This node's detail opens with whether the node is healthy. On tests/fakedom.mjs's stand-in DOM with the node's own
// shapes (wire/vectors.json), in English and in Spanish. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { installDom, find, findAll, byClass, button } from './fakedom.mjs';

process.env.TZ = 'UTC';
const here = dirname(fileURLToPath(import.meta.url));
const vectors = JSON.parse(readFileSync(join(here, '..', 'wire', 'vectors.json'), 'utf8'));
const settingsReply = () => structuredClone(vectors.settings[1].result);
const nodeValue = () => structuredClone(vectors['snapshot.node'].entries[0].value);

installDom();
const { setLanguage, t } = await import('../js/i18n.js');
const { settingsView, editor } = await import('../js/views/settings.js');
const settle = () => new Promise((resolve) => setImmediate(resolve));

// An app as the views read it: a store over `state`, the kinds this connection may send, whether it acts, the requests
// sent (each answered by `reply`), and the route with its listeners.
function fakeApp({ route = { name: 'settings', id: null }, state = {}, kinds = null, acts = false, reply = () => ({ ok: true, result: {} }), read = null } = {}) {
  const sent = [];
  const topics = new Map();
  const store = {
    state: { node: null, connection: 'live', phrase: null, pageWords: null, sessions: new Map(), leads: new Map(), boards: new Map(), cards: new Map(),
      cardKeys: new Map(), acting: new Map(), draftRefused: new Map(), ...state },
    acts: () => acts,
    can: (kind) => kinds === null || kinds.includes(kind),
    subscribe(topic, fn) { if (!topics.has(topic)) topics.set(topic, []); topics.get(topic).push(fn); },
    read: read || (() => Promise.resolve({ ok: false, error: { code: 'unknown-kind' } })),
    request: (kind, args) => { sent.push({ kind, args }); return Promise.resolve(reply(kind, args)); },
  };
  const listeners = [];
  const ui = { state: { route }, subscribe(fn) { listeners.push(fn); }, go() {} };
  const goTo = (next) => { ui.state.route = next; for (const fn of listeners) fn('route'); };
  const changed = (topic) => { for (const fn of topics.get(topic) || []) fn(); };
  return { store, ui, sent, goTo, changed, leave: () => goTo({ name: 'home' }) };
}

const slots = { key: 'node_heavy_slots', title: 'Test and build slots at once', form: 'count', scope: 'node', limits: '1 to 12', value: '3', default: '2' };
const workers = { key: 'max_workers', title: 'Workers at once, at most', form: 'count', scope: 'project', limits: '1 to 8', value: '4', default: '4' };
const buttons = (el) => findAll(el, (node) => node.tag === 'button').map((one) => one.textContent);
const copies = (el) => findAll(el, byClass('copy-button'));

// ---- U14: Settings ----

test('U14: a setting’s Change is the page’s ordinary (quiet) button at the row’s end, in English and in Spanish', async (ctx) => {
  for (const [code, change, close] of [['en', 'Change', 'Close'], ['es', 'Cambiar', 'Cerrar']]) {
    setLanguage(code);
    const app = fakeApp({ route: { name: 'settings', id: null, section: 'boost' }, reply: () => ({ ok: true, result: settingsReply() }) });
    // Left even when an assertion fails, so its refresh timer stops with the test.
    ctx.after(() => app.leave());
    const view = settingsView(app);
    await settle();
    const row = find(view.columns.detail, byClass('setting'));
    const control = find(row, button(change));
    assert.ok(control, `${change} in ${row.textContent}`);
    assert.equal(control.tag, 'button');
    assert.ok(control.classList.contains('button') && control.classList.contains('quiet'), control.className);
    assert.ok(!control.classList.contains('confirm-clear'), 'no longer grey text');
    // At the row's end, with the value beside it.
    const end = find(row, byClass('setting-end'));
    assert.ok(end && end.children.at(-1) === control && end.children[0].classList.contains('setting-value'));
    control.click();
    assert.ok(find(view.columns.detail, button(close)), 'open: the same button closes it');
    app.leave();
  }
  setLanguage('en');
});

test('U14: where the page acts for you, an open setting shows Set alone, and Set sends what it always sent', async () => {
  for (const [code, set] of [['en', 'Set'], ['es', 'Fijar']]) {
    setLanguage(code);
    const app = fakeApp({ kinds: ['set'], acts: true });
    const editing = new Map([[slots.key, '4']]);
    const box = editor(slots, null, editing, app);
    assert.deepEqual(buttons(box).filter((word) => word === set), [set]);
    assert.deepEqual(copies(box), [], 'no line to copy beside Set');
    assert.doesNotMatch(box.textContent, /vibeswitcher set/);
    assert.doesNotMatch(box.textContent, code === 'en' ? /Run it in a terminal|terminal/ : /Ejecútalo en una terminal|terminal/);
    assert.match(box.textContent, new RegExp(t('svSetNow').slice(0, 20)));
    find(box, button(set)).click();
    await settle();
    assert.deepEqual(app.sent, [{ kind: 'set', args: { key: 'node_heavy_slots', value: '4' } }]);
    // A project's: its folder, as before.
    const project = fakeApp({ kinds: ['set'], acts: true });
    const one = editor(workers, '/home/u/acme-site', new Map([[workers.key, '5']]), project);
    find(one, button(set)).click();
    await settle();
    assert.deepEqual(project.sent, [{ kind: 'set', args: { folder: '/home/u/acme-site', key: 'max_workers', value: '5' } }]);
    assert.match(one.textContent, new RegExp(t('svSetNowProject').slice(0, 20)));
  }
  setLanguage('en');
});

test('U14: where the page doesn’t act (or may not set this one), the open setting shows the terminal’s line with Copy alone', () => {
  for (const code of ['en', 'es']) {
    setLanguage(code);
    const set = t('acSet');
    for (const [app, setting, value, line] of [
      [fakeApp({ kinds: ['set'], acts: false }), slots, '4', 'vibeswitcher set node_heavy_slots 4'],
      [fakeApp({ kinds: ['answer'], acts: true }), slots, '4', 'vibeswitcher set node_heavy_slots 4'],
      [fakeApp({ kinds: ['set'], acts: true }), { ...slots, key: 'web_acts', form: 'choice', choices: ['off', 'confirm', 'trust'], limits: null, value: 'off' }, 'trust', 'vibeswitcher set web_acts trust'],
    ]) {
      const box = editor(setting, null, new Map([[setting.key, value]]), app);
      assert.deepEqual(buttons(box).filter((word) => word === set), [], 'no Set');
      assert.equal(copies(box).length, 1);
      assert.match(box.textContent, new RegExp(line));
      assert.match(box.textContent, new RegExp(t('svRunItInATerminal2').slice(0, 20)));
    }
  }
  setLanguage('en');
});

test('U14: a value out of range says so as before, with nothing to set or copy; the page says which way Change applies', async (ctx) => {
  setLanguage('en');
  const box = editor(slots, null, new Map([[slots.key, '99']]), fakeApp({ kinds: ['set'], acts: true }));
  const problem = find(box, byClass('card-notice'));
  assert.equal(problem.hidden, false);
  assert.equal(problem.textContent, 'node_heavy_slots is a whole number, 1 to 12.');
  assert.deepEqual(buttons(box).filter((word) => word === 'Set'), []);
  assert.deepEqual(copies(box), []);
  for (const [acts, intro] of [[true, 'Change a value, then press Set.'], [false, 'Change drafts the line that sets it; run it in a terminal.']]) {
    const app = fakeApp({ kinds: ['set'], acts, reply: () => ({ ok: true, result: settingsReply() }) });
    ctx.after(() => app.leave());
    const view = settingsView(app);
    await settle();
    assert.match(find(view.columns.list, byClass('tc-note')).textContent, new RegExp(intro.replace(/[.;]/g, '.')));
    app.leave();
  }
});

// ---- U15: This node ----

const { nodeView, nodeVerdict } = await import('../js/views/node.js');
// A node with nothing wrong: connected, no notice, a calm health digest, no limit holding work back.
function healthyNode() {
  const node = nodeValue();
  node.notices = [];
  node.health = { freezes: [], errors: [], waiting: [], slowRefreshes: 0, serverRestarts: 0 };
  for (const limit of node.usage.limits) { limit.holds = false; limit.reached = false; }
  return node;
}
const verdictOf = (view) => find(view.columns.detail, byClass('node-verdict'));
const linksOf = (el) => findAll(el, (node) => node.tag === 'a').map((link) => [link.textContent, link.getAttribute('href')]);

test('U15: a healthy node’s detail opens with one calm line, whichever group is chosen, in English and in Spanish', () => {
  for (const [code, words] of [['en', 'This node is healthy.'], ['es', 'El nodo está bien.']]) {
    setLanguage(code);
    const app = fakeApp({ route: { name: 'node', group: 'server' }, state: { node: healthyNode() } });
    const view = nodeView(app);
    const line = verdictOf(view);
    assert.ok(line, 'the line is there');
    assert.equal(line.textContent, words);
    assert.ok(line.classList.contains('calm') && !line.classList.contains('asked'));
    assert.deepEqual(linksOf(line), []);
    // Over the group's detail: the first thing under its header, before its body.
    const page = find(view.columns.detail, byClass('tc-page'));
    assert.deepEqual(page.children.map((one) => one.className), ['tc-dhead', 'tc-dtop', 'tc-dbody']);
    app.goTo({ name: 'node', group: 'host' });
    assert.equal(verdictOf(view).textContent, words, 'the same line over another group');
  }
  setLanguage('en');
});

test('U15: something waiting on you makes the line ask, in the asking colour, with a link to the group that says why', async () => {
  for (const [code, words] of [['en', 'This node needs you: 1 thing to accept'], ['es', 'El nodo te necesita: 1 cosa que aceptar']]) {
    setLanguage(code);
    const read = (kind) => Promise.resolve(kind === 'approve.list' ? { ok: true, result: { batch: 'b1', items: [{ kind: 'config', subject: 'max_workers 3 → 5', seen: 1, reasons: [] }], own: [] } } : { ok: false, error: { code: 'unknown-kind' } });
    const app = fakeApp({ route: { name: 'node', group: 'server' }, state: { node: healthyNode() }, kinds: ['approve', 'approve.list'], acts: true, read });
    const view = nodeView(app);
    await settle();
    const line = verdictOf(view);
    assert.equal(line.textContent, words);
    assert.ok(line.classList.contains('asked'));
    assert.deepEqual(linksOf(line), [[words.split(': ')[1], '#/node/approve']]);
  }
  // A card no project holds waits on This node too.
  setLanguage('en');
  const node = healthyNode();
  const state = { node, cards: new Map([['local:card:x', { id: 'local:card:x', kind: 'question', project: 'local:project:gone', open: true }]]) };
  assert.deepEqual(nodeVerdict(node, { cards: 1 }), { tone: 'asked', head: 'This node needs you:', parts: [{ words: '1 card for you', group: null }] });
  const view = nodeView(fakeApp({ route: { name: 'node', group: 'server' }, state }));
  assert.equal(verdictOf(view).textContent, 'This node needs you: 1 card for you');
});

test('U15: a notice, the health digest, the host and the usage limits each say so, and link to their group', () => {
  for (const [code, notice, health, both] of [
    ['en', 'This node needs you: 1 notice', 'This node needs you: a look at its health', 'This node is healthy, but a usage limit holds work back'],
    ['es', 'El nodo te necesita: 1 aviso', 'El nodo te necesita: un vistazo a su salud', 'El nodo está bien, pero un límite de uso frena el trabajo'],
  ]) {
    setLanguage(code);
    const node = healthyNode();
    node.notices = ['example-site: landing-base moved'];
    const view = nodeView(fakeApp({ route: { name: 'node', group: 'server' }, state: { node } }));
    const line = verdictOf(view);
    assert.equal(line.textContent, notice);
    assert.ok(line.classList.contains('asked'));
    assert.deepEqual(linksOf(line).map(([, href]) => href), ['#/node/notices']);
    assert.doesNotMatch(line.textContent, /landing-base/, 'the node’s own sentence stays in its group');
    const frozen = healthyNode();
    frozen.health.freezes = [{ at: '2026-11-25T10:00:00Z', seconds: 14 }];
    assert.equal(verdictOf(nodeView(fakeApp({ route: { name: 'node', group: 'server' }, state: { node: frozen } }))).textContent, health);
    const limited = healthyNode();
    limited.usage.limits[1].holds = true;
    const calmish = verdictOf(nodeView(fakeApp({ route: { name: 'node', group: 'server' }, state: { node: limited } })));
    assert.equal(calmish.textContent, both);
    assert.ok(calmish.classList.contains('working') && !calmish.classList.contains('asked'), 'a limit is no question for you');
    assert.deepEqual(linksOf(calmish).map(([, href]) => href), ['#/node/usage']);
    const down = healthyNode();
    down.host.state = 'disconnected';
    assert.deepEqual(nodeVerdict(down).parts.map((part) => part.group), ['host']);
  }
  setLanguage('en');
});

test('U15: the health digest’s lines say how long ago, in the page’s language', () => {
  setLanguage('es');
  const node = healthyNode();
  node.health.freezes = [{ at: new Date(Date.now() - 90 * 60000).toISOString(), seconds: 14 }];
  const view = nodeView(fakeApp({ route: { name: 'node', group: 'health' }, state: { node } }));
  const lines = findAll(view.columns.detail, (one) => one.tag === 'li').map((one) => one.textContent);
  assert.ok(lines.some((one) => /^hace 1h 30m · /.test(one)), lines.join(' | '));
  setLanguage('en');
});
