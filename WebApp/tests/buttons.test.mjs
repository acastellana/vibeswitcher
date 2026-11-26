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
  const routeListeners = [];
  const ui = { state: { route }, subscribe(fn) { routeListeners.push(fn); }, go(hash) { went.push(hash); } };
  const goTo = (next) => { ui.state.route = next; for (const fn of routeListeners) fn('route'); };
  const later = (fn, ms) => { const timer = { fn, ms, on: true }; waiting.push(timer); return () => { timer.on = false; }; };
  const fire = () => { for (const timer of waiting.splice(0)) if (timer.on) timer.fn(); };
  return { store, sent, ui, went, later, waiting, fire, goTo };
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

// This node as the node sends it (wire/vectors.json), with an update watch's record.
import { readFileSync } from 'node:fs';
const vectors = JSON.parse(readFileSync(new URL('../wire/vectors.json', import.meta.url), 'utf8'));
const nodeValue = () => ({ ...structuredClone(vectors['snapshot.node'].entries[0].value),
  update: { checkedAt: '2026-11-25T03:00:00.000Z', commit: null, aheadBy: null, install: null, problem: null, running: 'f62aef61' } });
async function nodeGroup(group, options) {
  const { nodeView } = await import('../js/views/node.js');
  const app = fakeApp({ route: { name: 'node', group }, state: { node: nodeValue() }, ...options });
  const view = nodeView(app);
  return { app, view, detail: view.columns.detail };
}

test('B4: Check now asks the node to look, says Checking…, then what it found; refused, the node’s words beside it and the button back', async () => {
  for (const code of ['es', 'en']) {
    setLanguage(code);
    const found = { checkedAt: '2026-11-25T09:00:00.000Z', commit: '5b8e1d2a9c4f7e3b6a0d', aheadBy: 3, install: null, problem: null, running: 'f62aef61', notice: null };
    let answer = null;
    const { app, detail } = await nodeGroup('updates', { kinds: ['update.check', 'web.revoke'], reply: () => new Promise((resolve) => { answer = resolve; }) });
    assert.doesNotMatch(detail.textContent, /--check-updates/, `${code}: no line where the button does it`);
    const check = buttonNamed(detail, t('upCheckNow'));
    assert.ok(check, code);
    check.click();
    assert.equal(check.disabled, true, 'busy while it looks');
    assert.equal(check.textContent, t('upChecking'));
    assert.deepEqual(app.sent, [{ kind: 'update.check', args: {} }]);
    assert.equal(app.sent[0].kind, 'update.check');
    answer({ ok: true, result: found });
    await flush();
    assert.equal(check.disabled, false);
    assert.match(detail.textContent, new RegExp(t('upCheckedNewer', { commit: '5b8e1d2' }).replace(/[()]/g, '.')));
    // Refused: in the node's words, the button back.
    check.click();
    answer({ ok: false, error: { code: 'refused', message: 'this server doesn’t check for updates (a scratch node asks GitHub nothing)' } });
    await flush();
    assert.equal(check.disabled, false);
    assert.match(find(detail, byClass('refused')).textContent, /scratch node asks GitHub nothing/);
  }
  setLanguage('en');
});

test('B4: where the page doesn’t act, or the node lists no update.check, the line that checks now and no button', async () => {
  for (const options of [{ acts: false, kinds: ['update.check'] }, { acts: true, kinds: ['set'] }]) {
    const { detail } = await nodeGroup('updates', options);
    assert.equal(buttonNamed(detail, 'Check now'), null);
    assert.match(detail.textContent, /vibeswitcher status --check-updates/);
  }
});

test('A5: Remove all paired browsers asks again in place, says this page goes too, then says how many were unpaired', async () => {
  for (const code of ['es', 'en']) {
    setLanguage(code);
    const { app, view, detail } = await nodeGroup('web', { kinds: ['update.check', 'web.revoke'], reply: () => ({ ok: true, result: { revoked: 2, tailnetRevoked: 1 } }) });
    assert.match(detail.textContent, new RegExp(t('noRevokeWords').slice(0, 30)));
    const remove = buttonNamed(detail, t('noRevokeAll'));
    assert.ok(remove, code);
    assert.ok(remove.classList.contains('danger'), 'drawn as what ends something');
    remove.click();
    assert.equal(app.sent.length, 0, 'the first click only asks');
    assert.equal(remove.textContent, t('noRevokeSure'));
    assert.ok(buttonNamed(detail, t('acCancel')), 'Cancel beside it');
    remove.click();
    await flush();
    assert.deepEqual(app.sent.map((one) => one.kind), ['web.revoke']);
    assert.match(detail.textContent, new RegExp(t('noRevoked', { n: 3 })));
    // A node update draws the groups again: the same control, its words kept.
    const before = find(view.columns.detail, byClass('revoke'));
    app.store.state.node = { ...nodeValue(), web: { ...nodeValue().web, tokens: 0 } };
    app.store.notify('node');
    assert.match(view.columns.detail.textContent, new RegExp(t('noPagesPaired') + '0'), 'drawn again');
    assert.equal(find(view.columns.detail, byClass('revoke')), before);
    assert.match(view.columns.detail.textContent, new RegExp(t('noRevoked', { n: 3 })));
  }
  setLanguage('en');
});

test('A5: elsewhere, the line that unpairs every browser, and why', async () => {
  for (const options of [{ acts: false, kinds: ['web.revoke'] }, { acts: true, kinds: ['set'] }]) {
    const { detail } = await nodeGroup('web', options);
    assert.equal(buttonNamed(detail, 'Remove all paired browsers'), null);
    assert.match(detail.textContent, /vibeswitcher web --revoke/);
    assert.match(detail.textContent, options.acts ? /doesn’t take it from a page/ : /reads and drafts/);
  }
});

// An ended session of yours, as the node lists it (`node.ended`), and the session it is started again as.
const ENDED = { session: 'local:5c1e7a92-0000-4000-8000-000000000001', folder: '/home/dev/projects/example-api', name: 'example-api',
  conversation: '7a3f0c21-9b4d-4e8a-a1f2-3c5d7e9b0a14', at: '2026-11-25T08:00:00.000Z', exit: { status: 0, cause: 'exited 0', at: '2026-11-25T08:00:00.000Z' } };
const AGAIN = 'local:aa11bb22-0000-4000-8000-000000000002';

test('B3: an ended session’s own view has Resume: Resuming…, then the page goes to it once listed; refused, the node’s words', async () => {
  // What the session view's terminal and chat watch for, which the stand-in DOM doesn't have: nothing to watch here.
  globalThis.MutationObserver ??= class { observe() {} disconnect() {} };
  globalThis.ResizeObserver ??= class { observe() {} unobserve() {} disconnect() {} };
  const { sessionView } = await import('../js/views/session.js');
  for (const code of ['es', 'en']) {
    setLanguage(code);
    let answer = null;
    const app = fakeApp({ route: { name: 'session', id: ENDED.session }, state: { node: { ...nodeValue(), ended: [ENDED] } }, kinds: ['session.resume'],
      reply: () => new Promise((resolve) => { answer = resolve; }) });
    app.ui.inspectorShown = () => false;
    app.ui.inspectorWide = () => false;
    const view = sessionView(app);
    view.show?.(ENDED.session);
    view.render?.();
    const el = view.el;
    assert.doesNotMatch(el.textContent, /vibeswitcher resume/, `${code}: no line where Resume does it`);
    assert.match(el.textContent, new RegExp(t('seItEndedResume').slice(0, 12)));
    const resume = buttonNamed(el, t('acResume'));
    assert.ok(resume, code);
    resume.click();
    assert.equal(resume.textContent, t('drResuming'));
    assert.deepEqual(app.sent, [{ kind: 'session.resume', args: { session: ENDED.session } }]);
    answer({ ok: true, result: { reopened: [{ was: ENDED.session, folder: ENDED.folder, conversation: ENDED.conversation, session: AGAIN, terminal: 'pts/9' }], refused: [] } });
    await flush();
    assert.match(el.textContent, new RegExp(t('drStartedWaiting').slice(0, 10)), 'started: it opens once listed');
    app.store.state.sessions.set(AGAIN, { id: AGAIN, hosted: true, cwd: ENDED.folder, status: 'working' });
    app.store.notify('sessions');
    assert.deepEqual(app.went, ['#/s/' + encodeURIComponent(AGAIN)]);
  }
  setLanguage('en');
});

test('B3: Resume refused says the node’s words, the button back; where the page doesn’t act, the line and why', async () => {
  const { resumeOrLine } = await import('../js/views/drive.js');
  setLanguage('en');
  const holder = (nodes) => { const el = document.createElement('div'); el.append(...nodes); return el; };
  // Nothing to resume (its conversation wasn't recorded): said, nothing opened.
  const none = fakeApp({ kinds: ['session.resume'], reply: () => ({ ok: true, result: { reopened: [], refused: [{ was: ENDED.session, folder: ENDED.folder, why: 'its conversation id wasn’t recorded: nothing to resume' }] } }) });
  const a = holder(resumeOrLine(none, ENDED));
  buttonNamed(a, 'Resume').click();
  await flush();
  assert.match(a.textContent, /The node didn’t start it again: its conversation id wasn’t recorded/);
  assert.deepEqual(none.went, []);
  // Refused outright: the node's words, the button back.
  const gone = fakeApp({ kinds: ['session.resume'], reply: () => ({ ok: false, error: { code: 'gone', message: 'no ended session local:5c1e of yours to resume' } }) });
  const b = holder(resumeOrLine(gone, ENDED));
  buttonNamed(b, 'Resume').click();
  await flush();
  assert.match(find(b, byClass('refused')).textContent, /no ended session local:5c1e of yours to resume/);
  assert.equal(buttonNamed(b, 'Resume').disabled, false);
  for (const options of [{ acts: false, kinds: ['session.resume'] }, { acts: true, kinds: ['send'] }]) {
    const c = holder(resumeOrLine(fakeApp(options), ENDED));
    assert.equal(buttonNamed(c, 'Resume'), null);
    assert.match(c.textContent, /vibeswitcher resume 5c1e7a92/);
    assert.match(c.textContent, options.acts ? /resumes a session only from a terminal/ : /doesn’t act for you here/);
  }
});

test('B2: Recent projects get New session and Start the lead; each starts from here and opens what started; elsewhere their lines', async () => {
  const { newProjectView } = await import('../js/views/own.js');
  const SITE = '/home/dev/projects/example-site';
  for (const code of ['es', 'en']) {
    setLanguage(code);
    const started = 'local:cc33dd44-0000-4000-8000-000000000003';
    const app = fakeApp({ route: { name: 'new' }, state: { node: { ...nodeValue(), home: '/home/dev', ended: [] } }, kinds: ['recent', 'session.new', 'lead'],
      reply: (kind) => (kind === 'recent' ? { ok: true, result: { projects: [{ folder: SITE, lastUsed: '2026-11-25T08:00:00.000Z', lead: null }] } }
        : kind === 'session.new' ? { ok: true, result: { session: started, terminal: 'pts/4', agent: 'claude', folder: SITE, model: null, preset: null } }
          : { ok: true, result: { happened: 'started', session: 'local:lead0000-0000-4000-8000-000000000004', program: '/usr/bin/claude', notes: [] } }) });
    const view = newProjectView(app);
    view.render();
    await flush();
    view.render();
    const recent = find(view.el, byClass('recent'));
    assert.doesNotMatch(recent.textContent, /vibeswitcher new|vibeswitcher lead/, `${code}: no lines where the buttons do it`);
    assert.match(recent.textContent, new RegExp(t('owRecentActs').slice(0, 14)));
    buttonNamed(recent, t('owNewSessionHere')).click();
    await flush();
    assert.deepEqual(app.sent.at(-1), { kind: 'session.new', args: { folder: SITE, agent: 'claude' } });
    app.store.state.sessions.set(started, { id: started, hosted: true, cwd: SITE, status: 'working' });
    app.store.notify('sessions');
    assert.deepEqual(app.went, ['#/s/' + encodeURIComponent(started)]);
    buttonNamed(recent, t('acStartLead')).click();
    await flush();
    assert.deepEqual(app.sent.at(-1), { kind: 'lead', args: { folder: SITE } });
    assert.match(recent.textContent, new RegExp(t('drLeadStartedWaiting').slice(0, 10)));
  }
  // A page that reads: the lines, and why.
  setLanguage('en');
  const reads = fakeApp({ route: { name: 'new' }, acts: false, state: { node: { ...nodeValue(), home: '/home/dev', ended: [] } }, kinds: ['recent', 'session.new', 'lead'],
    reply: () => ({ ok: true, result: { projects: [{ folder: SITE, lastUsed: '2026-11-25T08:00:00.000Z', lead: null }] } }) });
  const view = newProjectView(reads);
  view.render();
  await flush();
  view.render();
  const recent = find(view.el, byClass('recent'));
  assert.equal(buttonNamed(recent, 'New session'), null);
  assert.match(recent.textContent, /vibeswitcher new/);
  assert.match(recent.textContent, /vibeswitcher lead/);
  assert.match(recent.textContent, /doesn’t act for you here/);
});

test('B1: the Shells tab lists the folder’s shells first, then Close N finished shells, asked twice; the receipt says what ended and what was left', async () => {
  const { actionsStrip } = await import('../js/views/drive.js');
  const SITE = '/home/dev/projects/example-site';
  const shells = [
    { session: 'local:5e11a001-4f6a-4c1e-9b7d-2e5a8c0d1f3b', folder: SITE, terminal: 'pts/31', finished: true },
    { session: 'local:5e11a002-4f6a-4c1e-9b7d-2e5a8c0d1f3b', folder: `${SITE}/web`, terminal: 'pts/32', finished: true },
    { session: 'local:5e11a003-4f6a-4c1e-9b7d-2e5a8c0d1f3b', folder: SITE, terminal: 'pts/33', finished: false },
  ];
  const session = { id: 'local:e91d05a3-4f6a-4c1e-9b7d-2e5a8c0d1f3b', hosted: true, cwd: SITE, agent: 'claude', status: 'idle' };
  for (const code of ['es', 'en']) {
    setLanguage(code);
    const app = fakeApp({ kinds: ['shells', 'session.close-shells'], state: { node: { home: '/home/dev', ended: [] } },
      reply: (kind) => (kind === 'shells' ? { ok: true, result: { shells } } : { ok: true, result: { ended: [shells[0].session], left: [shells[1].session] } }) });
    const strip = actionsStrip(app);
    strip.update(session, app.store.state.node);
    strip.open('shells');
    await flush();
    assert.deepEqual(app.sent[0], { kind: 'shells', args: { folder: SITE } }, 'the shells listed first');
    assert.doesNotMatch(strip.el.textContent, /vibeswitcher close-shells/, `${code}: no line where the button does it`);
    assert.match(strip.el.textContent, /~\/projects\/example-site\/web · pts\/32/);
    assert.match(strip.el.textContent, new RegExp(t('drShellRunning')));
    const close = buttonNamed(strip.el, t('drCloseNShells', { n: 2 }));
    assert.ok(close, code);
    close.click();
    assert.equal(app.sent.length, 1, 'the first click only asks');
    assert.equal(close.textContent, t('drCloseShellsSure', { n: 2 }));
    close.click();
    assert.equal(close.textContent, t('drClosing'));
    await flush();
    assert.deepEqual(app.sent[1], { kind: 'session.close-shells', args: { sessions: [shells[0].session, shells[1].session] } }, 'the finished ones listed, not the running one');
    assert.match(strip.el.textContent, new RegExp(t('drShellsClosed', { n: 1 })));
    assert.match(strip.el.textContent, new RegExp(t('drShellsLeft', { n: 1 })));
  }
  setLanguage('en');
});

test('B1: refused, the node’s words and the button back; none finished, no button; where the page doesn’t act, the line', async () => {
  const { actionsStrip } = await import('../js/views/drive.js');
  setLanguage('en');
  const SITE = '/home/dev/projects/example-site';
  const session = { id: 'local:e91d05a3-4f6a-4c1e-9b7d-2e5a8c0d1f3b', hosted: true, cwd: SITE, agent: 'claude', status: 'idle' };
  const finished = [{ session: 'local:5e11a001-4f6a-4c1e-9b7d-2e5a8c0d1f3b', folder: SITE, terminal: 'pts/31', finished: true }];
  const refusing = fakeApp({ kinds: ['shells', 'session.close-shells'], state: { node: { ended: [] } },
    reply: (kind) => (kind === 'shells' ? { ok: true, result: { shells: finished } } : { ok: false, error: { code: 'refused', message: 'none of them is a finished shell now (back at its prompt): nothing ended' } }) });
  const a = actionsStrip(refusing);
  a.update(session, refusing.store.state.node);
  a.open('shells');
  await flush();
  const close = buttonNamed(a.el, 'Close 1 finished shell');
  close.click();
  close.click();
  await flush();
  assert.match(find(a.el, byClass('refused')).textContent, /nothing ended/);
  assert.equal(close.disabled, false);
  const running = fakeApp({ kinds: ['shells', 'session.close-shells'], state: { node: { ended: [] } },
    reply: () => ({ ok: true, result: { shells: [{ ...finished[0], finished: false }] } }) });
  const b = actionsStrip(running);
  b.update(session, running.store.state.node);
  b.open('shells');
  await flush();
  assert.equal(find(b.el, (node) => node.tag === 'button' && /finished shell/.test(node.textContent)), null);
  assert.match(b.el.textContent, /None of them is finished/);
  for (const options of [{ acts: false, kinds: ['shells', 'session.close-shells'] }, { acts: true, kinds: ['session.close-shells'] }]) {
    const app = fakeApp({ ...options, state: { node: { ended: [] } } });
    const c = actionsStrip(app);
    c.update(session, app.store.state.node);
    c.open('shells');
    await flush();
    assert.equal(app.sent.length, 0, 'nothing asked of a node that doesn’t take it');
    assert.match(c.el.textContent, /vibeswitcher close-shells/);
  }
});

test('B5: an image on the node, given by its path: Send sends it with the box’s words, says what became of it; refused, the node’s words', async () => {
  globalThis.MutationObserver ??= class { observe() {} disconnect() {} };
  globalThis.ResizeObserver ??= class { observe() {} unobserve() {} disconnect() {} };
  const { chatView } = await import('../js/views/chat.js');
  const SID = 'local:e91d05a3-4f6a-4c1e-9b7d-2e5a8c0d1f3b';
  const session = { id: SID, terminal: 'pts/7', agent: 'claude', cwd: '/home/dev/projects/example-api', status: 'idle', hosted: true, sendWays: ['step', 'now'] };
  for (const code of ['es', 'en']) {
    setLanguage(code);
    // The real store, over a feed that records each request (`answer` settles the one out).
    const { createStore } = await import('../js/store.js');
    const store = createStore();
    const sent = [];
    let answer = null;
    store.connect({ request(message) { sent.push({ kind: message.kind, args: message.args }); return new Promise((resolve) => { answer = resolve; }); },
      subscribeChat() {}, unsubscribeChat() {}, resync() {} });
    store.setKinds(['send', 'chat.page'], null, ['read', 'draft', 'watch', 'act']);
    store.reconcile('sessions', [session]);
    store.apply?.({ v: 1, kind: 'snapshot', epoch: 'e', seq: 0, state: { node: { home: '/home/dev', ended: [] }, sessions: [session], leads: [], cards: [], boards: [] } });
    const app = { store, ui: { state: { route: { name: 'session', id: SID } }, subscribe() {}, go() {} }, sent };
    let chat;
    try { chat = chatView(app); } catch (error) { assert.fail(`the chat view: ${error.stack}`); }
    chat.show(SID);
    const fromNode = find(chat.el, (node) => node.tag === 'button' && node.textContent === t('chAnImageOnTheNode'));
    fromNode.click();
    const path = find(chat.el, byClass('node-image-path'));
    const box = find(chat.el, (node) => node.tag === 'textarea');
    box.value = 'Here is the broken layout';
    path.value = '~/shots/layout.png';
    path.dispatch('input');
    const image = find(chat.el, byClass('node-image'));
    assert.doesNotMatch(image.textContent, /vibeswitcher send/, `${code}: no line where Send does it`);
    const send = buttonNamed(image, t('acSend'));
    assert.ok(send, code);
    send.click();
    assert.equal(send.textContent, t('chSendingImage'));
    assert.deepEqual(app.sent.at(-1), { kind: 'send', args: { session: SID, text: 'Here is the broken layout', when: 'step', images: ['/home/dev/shots/layout.png'] } });
    answer({ ok: true, result: { session: SID, when: 'step' } });
    await flush();
    assert.match(image.textContent, new RegExp(t('swSentStep').slice(0, 10)));
    assert.equal(box.value, '', 'the box empties once it went');
    // Refused: the node's words beside it, the button back.
    path.value = '/home/dev/shots/missing.png';
    path.dispatch('input');
    const again = buttonNamed(image, t('acSend'));
    again.click();
    answer({ ok: false, error: { code: 'refused', message: 'no image file /home/dev/shots/missing.png' } });
    await flush();
    assert.match(find(image, byClass('refused')).textContent, /no image file/);
    assert.equal(again.disabled, false);
  }
  setLanguage('en');
});

test('B6: Save, Add and Remove for your presets send presets.edit with the change the line carries; refused, the node’s words', async () => {
  const { presetEditor } = await import('../js/views/drive.js');
  const SITE = '/home/dev/projects/example-site';
  const opus = { name: 'Opus', kind: 'claude', command: 'claude --model opus', env: ['MAX_THINKING_TOKENS'], keepShell: false, project: true, default: true, builtIn: false, digest: 'mock-opus', refused: null };
  const presets = [opus, { name: 'Claude', kind: 'claude', builtIn: true, digest: 'mock-claude' }];
  for (const code of ['es', 'en']) {
    setLanguage(code);
    let saved = 0;
    let answer = () => ({ ok: true, result: { op: 'edit', name: 'Opus', folder: SITE, env: ['MAX_THINKING_TOKENS'], held: true } });
    const app = fakeApp({ kinds: ['presets.edit'], reply: (kind, args) => answer(args) });
    const editor = presetEditor({ folder: () => SITE, app, saved: () => { saved += 1; } });
    editor.el.hidden = false;
    editor.update(presets, true);
    // Edit: the arguments changed, then Save.
    buttonNamed(editor.el, t('drEdit')).click();
    const args = findAll(editor.el, (node) => node.tag === 'input' && node.attrs['aria-label'] === t('drClaudeSArguments'))[0];
    assert.doesNotMatch(editor.el.textContent, /vibeswitcher preset/, `${code}: no line where Save does it`);
    args.value = '--model sonnet';
    args.dispatch('input');
    const save = buttonNamed(editor.el, t('drSavePreset'));
    save.click();
    assert.equal(save.textContent, t('drSaving'));
    await flush();
    assert.deepEqual(app.sent.at(-1), { kind: 'presets.edit', args: { op: 'edit', name: 'Opus', folder: SITE, digest: 'mock-opus', args: '--model sonnet' } });
    assert.match(editor.el.textContent, new RegExp(t('drPresetSaved', { name: 'Opus' })));
    assert.match(editor.el.textContent, new RegExp(t('drPresetHeld').slice(0, 20)));
    assert.equal(saved, 1, 'the node’s list asked again');
    // Remove: asked twice.
    answer = () => ({ ok: true, result: { op: 'remove', name: 'Opus', folder: SITE, env: null, held: true } });
    buttonNamed(editor.el, t('drRemove')).click();
    const remove = buttonNamed(editor.el, t('drRemovePreset', { name: 'Opus' }));
    remove.click();
    assert.equal(remove.textContent, t('drRemovePresetSure'));
    const before = app.sent.length;
    remove.click();
    await flush();
    assert.equal(app.sent.length, before + 1);
    assert.deepEqual(app.sent.at(-1), { kind: 'presets.edit', args: { op: 'remove', name: 'Opus', folder: SITE, digest: 'mock-opus' } });
    assert.match(editor.el.textContent, new RegExp(t('drPresetRemoved', { name: 'Opus' })));
    // Add: a name and its arguments, for this folder.
    answer = () => ({ ok: true, result: { op: 'add', name: 'Fast', folder: SITE, env: [], held: true } });
    buttonNamed(editor.el, t('drAddAPreset')).click();
    const [name, words] = findAll(editor.el, (node) => node.tag === 'input' && node.attrs.type === 'text').slice(0, 2);
    name.value = 'Fast';
    name.dispatch('input');
    words.value = '--model haiku';
    words.dispatch('input');
    buttonNamed(editor.el, t('drAddPreset')).click();
    await flush();
    assert.deepEqual(app.sent.at(-1), { kind: 'presets.edit', args: { op: 'add', name: 'Fast', folder: SITE, kind: 'claude', args: '--model haiku' } });
    // Refused: the node's words beside the button, the button back.
    answer = () => ({ ok: false, error: { code: 'refused', message: 'preset Opus changed since it was shown (or the node’s server restarted since): nothing changed' } });
    buttonNamed(editor.el, t('drEdit')).click();
    const again = findAll(editor.el, (node) => node.tag === 'input' && node.attrs['aria-label'] === t('drClaudeSArguments'))[0];
    again.value = '--model opus --verbose';
    again.dispatch('input');
    const retry = buttonNamed(editor.el, t('drSavePreset'));
    retry.click();
    await flush();
    assert.match(find(editor.el, byClass('refused')).textContent, /changed since it was shown/);
    assert.equal(retry.disabled, false);
  }
  setLanguage('en');
  // Where the page doesn't act: the lines.
  const reads = presetEditor({ folder: () => SITE, app: fakeApp({ acts: false, kinds: ['presets.edit'] }) });
  reads.update(presets, true);
  buttonNamed(reads.el, 'Remove').click();
  assert.match(reads.el.textContent, /vibeswitcher preset remove Opus --folder/);
});

test('B7: Between leads, a project with more than its newest shown has Show all: Loading…, then every message; refused, the node’s words', async (context) => {
  const { mailView } = await import('../js/views/mail.js');
  const SITE = '/home/dev/projects/example-site';
  const message = (n) => ({ at: '2026-11-25T08:00:00.000Z', from: 'example-api', to: 'example-site', received: true, kind: 'note', text: `note ${n}`, outcome: 'delivered', sent: true, detail: 'Delivered.' });
  const all = Array.from({ length: 26 }, (_, n) => message(n));
  for (const code of ['es', 'en']) {
    setLanguage(code);
    let refuse = false;
    const app = fakeApp({ route: { name: 'home' }, kinds: ['mail'], acts: false, state: { node: { home: '/home/dev' } },
      reply: (kind, args) => (refuse && args.all ? { ok: false, error: { code: 'refused', message: 'this server keeps no leads' } }
        : { ok: true, result: { projects: [{ root: SITE, project: 'example-site', total: 26, messages: args.all ? all : all.slice(0, 20) }] } }) });
    const view = mailView(app);
    app.goTo({ name: 'mail' });
    // Left whatever happens, so its 15 s refresh stops with the test.
    context.after(() => app.goTo({ name: 'home' }));
    await flush();
    assert.doesNotMatch(view.el.textContent, /vibeswitcher mail/, `${code}: no line where Show all does it (a read: a page that doesn’t act shows it too)`);
    assert.equal(findAll(view.el, byClass('mail-message')).length, 20);
    // Refused: the node's words beside it, the button back.
    refuse = true;
    const show = buttonNamed(view.el, t('mvShowAll', { n: 26 }));
    show.click();
    assert.equal(show.textContent, t('mvLoading'));
    await flush();
    assert.match(find(view.el, byClass('refused')).textContent, /this server keeps no leads/);
    assert.equal(show.disabled, false);
    refuse = false;
    show.click();
    await flush();
    assert.deepEqual(app.sent.at(-1), { kind: 'mail', args: { folder: SITE, all: true } });
    assert.equal(findAll(view.el, byClass('mail-message')).length, 26);
    assert.match(view.el.textContent, new RegExp(t('mvAllShown', { n: 26 })));
    app.goTo({ name: 'home' });
  }
  setLanguage('en');
  // A node that doesn't list mail for this page: the line (the view says it can't read the record either).
  const { mailCommand } = await import('../js/mail.js');
  assert.match(mailCommand('~/projects/example-site'), /vibeswitcher mail .* --all/);
});

// A project whose settings files are held and whose base moved (each a card), its lead quiet.
const P = 'local:project:Zx3kQ0aVtLmN';
const SITE_ROOT = '/home/dev/projects/example-site';
const HELD = { id: 'local:card:held', kind: 'config', project: P, root: SITE_ROOT, open: true, at: '2026-11-25T08:00:00.000Z', seen: 'held-1',
  config: { lastAccept: '2026-11-22T08:00:00.000Z', items: [
    { name: '.claude/settings.json', changedAt: '2026-11-25T07:50:00.000Z', hash: '3b7f0e21a9c4', change: 'hooks.PostToolUse added', outside: true, files: [], sinceAccept: 'changed' },
    { name: '.claude/agents', hash: 'a40c2f9d7e13', change: null, outside: true, files: [{ path: 'reviewer.md', change: 'added' }], sinceAccept: 'changed' }],
  guarded: [{ key: 'test_command', value: 'npm test -- --runInBand', sinceAccept: 'changed' }] } };
const MOVED = { id: 'local:card:base', kind: 'base', project: P, root: SITE_ROOT, open: true, at: '2026-11-25T08:05:00.000Z', seen: 'base-1',
  base: { branch: 'landing-base', from: '4be1c0d97a3f', fromIs: 'recorded', to: 'e5a90b1c2d34', reason: 'a commit no session of yours was seen making',
    commits: [{ sha: 'e5a90b1c2d34f', subject: 'Hotfix: the hero image path' }] } };
const quietLead = { project: P, root: SITE_ROOT, session: 'local:dead0001-4f6a-4c1e-9b7d-2e5a8c0d1f3b', named: null, bound: null, replaced: [], held: 0, reportsWaiting: 0,
  notice: null, starting: false, lastStart: null, lastStartAt: '2026-11-25T06:00:00.000Z', looks: 3, questions: { open: 0, blocking: 0 }, cards: [], told: [], push: null };

test('B8: a held config or a moved base: Show it whole reads it from the node and opens it whole in the side sheet; refused, the node’s words', async () => {
  const { projectView } = await import('../js/views/project.js');
  for (const code of ['es', 'en']) {
    setLanguage(code);
    const opened = [];
    let refuse = false;
    const app = fakeApp({ route: { name: 'project', id: P, view: 'lead', show: 'asks' }, kinds: ['config.held', 'config.accept', 'base.show', 'base.accept', 'base.keep', 'lead'],
      state: { cards: new Map([[HELD.id, HELD], [MOVED.id, MOVED]]), leads: new Map([[P, quietLead]]) },
      reply: (kind, args) => (refuse ? { ok: false, error: { code: 'refused', message: 'this server keeps no cards' } }
        : kind === 'config.held' ? { ok: true, result: { card: HELD, ...(args.diff ? { difference: ['--- accepted', '+++ now', '+    "PostToolUse": []'] } : {}) } }
          : kind === 'base.show' ? { ok: true, result: { card: MOVED } } : { ok: true, result: {} }) });
    const view = projectView(app, { sheet: { open(parts) { opened.push(parts); }, close() {}, shown: () => false } });
    view.render();
    const box = find(view.el, byClass('wait-box'));
    assert.doesNotMatch(box.textContent, /vibeswitcher config held|vibeswitcher base show/, `${code}: no line where Show it whole does it`);
    const [config, base] = findAll(box, (node) => node.tag === 'button' && node.textContent === t('shShowWhole'));
    assert.ok(config && base, code);
    config.click();
    assert.equal(config.textContent, t('shReading'));
    await flush();
    assert.deepEqual(app.sent.at(-1), { kind: 'config.held', args: { folder: SITE_ROOT } });
    const sheet = document.createElement('div');
    sheet.append(...opened.at(-1).more);
    assert.equal(opened.at(-1).title, t('heldConfig'));
    assert.match(sheet.textContent, /\.claude\/settings\.json/);
    assert.match(sheet.textContent, /hooks\.PostToolUse added/);
    assert.match(sheet.textContent, new RegExp(t('shOutside')));
    assert.match(sheet.textContent, /reviewer\.md/);
    assert.match(sheet.textContent, /test_command/);
    assert.doesNotMatch(sheet.textContent, /3b7f0e21a9c4/, 'no hash where a person reads');
    // One held thing's difference, asked in the sheet.
    buttonNamed(sheet, t('shShowChanges')).click();
    await flush();
    assert.deepEqual(app.sent.at(-1), { kind: 'config.held', args: { folder: SITE_ROOT, diff: '.claude/settings.json' } });
    assert.match(find(sheet, byClass('held-diff')).textContent, /PostToolUse/);
    base.click();
    await flush();
    assert.deepEqual(app.sent.at(-1), { kind: 'base.show', args: { folder: SITE_ROOT } });
    const moved = document.createElement('div');
    moved.append(...opened.at(-1).more);
    assert.equal(opened.at(-1).title, t('baseMove'));
    assert.match(moved.textContent, /Hotfix: the hero image path/);
    assert.match(moved.textContent, /landing-base/);
    // Refused: the node's words beside it, the button back, nothing opened.
    refuse = true;
    const count = opened.length;
    config.click();
    await flush();
    assert.equal(opened.length, count);
    assert.match(find(box, byClass('refused')).textContent, /keeps no cards/);
    assert.equal(config.disabled, false);
  }
  setLanguage('en');
});

test('B8: where the node doesn’t list config.held or base.show for this page, their lines and no Show it whole', async () => {
  const { projectView } = await import('../js/views/project.js');
  setLanguage('en');
  for (const options of [{ acts: true, kinds: ['config.accept', 'base.accept'] }, { acts: false, kinds: ['config.held', 'base.show'] }]) {
    const app = fakeApp({ route: { name: 'project', id: P, view: 'lead', show: 'asks' }, ...options, state: { cards: new Map([[HELD.id, HELD], [MOVED.id, MOVED]]), leads: new Map([[P, quietLead]]) } });
    const view = projectView(app, { sheet: { open() {}, close() {}, shown: () => false } });
    view.render();
    const box = find(view.el, byClass('wait-box'));
    assert.equal(buttonNamed(box, 'Show it whole'), null);
    assert.match(box.textContent, /vibeswitcher config held/);
    assert.match(box.textContent, /vibeswitcher base show/);
  }
});

const ROLELESS = { happened: 'shown', session: 'local:7d3c9a10-4f6a-4c1e-9b7d-2e5a8c0d1f3b', program: null,
  notes: ['the lead of example-site runs (session 7d3c9a10) without its role, so its tools are off: nothing was started; `vibeswitcher lead /home/dev/projects/example-site --replace` starts a new lead, which takes the role, reads its last turns and gets what waited for it'] };

test('B9: what a lead’s start answered is read only by the engine’s own words: a lead without its role asks to replace it', async () => {
  const { leadNeeds } = await import('../js/views/drive.js');
  assert.equal(leadNeeds(ROLELESS), 'replace');
  assert.equal(leadNeeds({ happened: 'started', notes: [] }), null);
  assert.equal(leadNeeds({ happened: 'shown', notes: ['the goal is held for the running lead until it can be delivered'] }), null);
  assert.equal(leadNeeds({ happened: 'started', notes: ROLELESS.notes }), null, 'only when nothing started');
  assert.equal(leadNeeds(null), null);
});

test('B9: a lead running without its role: the start says so, then Replace it, its consequence said, asked again in place, sends replace', async () => {
  const { newLeadForm } = await import('../js/views/drive.js');
  for (const code of ['es', 'en']) {
    setLanguage(code);
    const fresh = 'local:1ead0002-4f6a-4c1e-9b7d-2e5a8c0d1f3b';
    const app = fakeApp({ route: { name: 'new' }, kinds: ['lead'], state: { node: { home: '/home/dev' } },
      reply: (kind, args) => (args.replace ? { ok: true, result: { happened: 'started', session: fresh, program: '/usr/bin/claude', notes: [] } } : { ok: true, result: ROLELESS }) });
    const form = newLeadForm(app);
    form.choose(SITE_ROOT);
    buttonNamed(form.el, t('acStartLead')).click();
    await flush();
    assert.deepEqual(app.sent.at(-1), { kind: 'lead', args: { folder: SITE_ROOT } });
    assert.match(form.el.textContent, new RegExp(t('drLeadNoRole').slice(0, 20)));
    assert.match(form.el.textContent, new RegExp(t('drReplaceWhat').slice(0, 30)), 'its consequence, in a line');
    const replace = buttonNamed(form.el, t('drReplaceLead'));
    replace.click();
    assert.equal(app.sent.length, 1, 'the first click only asks');
    assert.equal(replace.textContent, t('drReplaceSure'));
    replace.click();
    assert.equal(replace.textContent, t('drReplacing'));
    await flush();
    assert.deepEqual(app.sent.at(-1), { kind: 'lead', args: { folder: SITE_ROOT, replace: true } });
    // The new lead's project opens once the node lists it.
    app.store.state.leads.set(P, { ...quietLead, session: fresh });
    app.store.notify('leads');
    const { projectHref } = await import('../js/ui.js');
    assert.deepEqual(app.went, [projectHref(P)]);
  }
  setLanguage('en');
});

test('B9: a quiet project whose base moved: Take the base as it is, its consequence said, starts the lead with takeHead; else the lines', async () => {
  const { projectView } = await import('../js/views/project.js');
  for (const code of ['es', 'en']) {
    setLanguage(code);
    const app = fakeApp({ route: { name: 'project', id: P, view: 'lead' }, kinds: ['lead', 'base.show', 'base.accept'],
      state: { cards: new Map([[MOVED.id, MOVED]]), leads: new Map([[P, quietLead]]) },
      reply: () => ({ ok: true, result: { happened: 'started', session: 'local:1ead0003-4f6a-4c1e-9b7d-2e5a8c0d1f3b', program: '/usr/bin/claude', notes: [] } }) });
    const view = projectView(app, { sheet: { open() {}, close() {}, shown: () => false } });
    view.render();
    const quiet = find(view.el, byClass('quiet-starts'));
    assert.ok(quiet, code);
    assert.doesNotMatch(quiet.textContent, /vibeswitcher lead/, 'no lines where the buttons start it');
    assert.match(quiet.textContent, new RegExp(t('drTakeBaseWhat', { branch: 'landing-base', to: 'e5a90b1c' }).slice(0, 40)));
    buttonNamed(quiet, t('drTakeBase')).click();
    await flush();
    assert.deepEqual(app.sent.at(-1), { kind: 'lead', args: { folder: SITE_ROOT, resume: true, takeHead: true } });
  }
  setLanguage('en');
  // No moved base: the two starts alone. A page that doesn't act: the lines.
  const calm = fakeApp({ route: { name: 'project', id: P, view: 'lead' }, kinds: ['lead'], state: { leads: new Map([[P, quietLead]]) } });
  const a = projectView(calm, { sheet: { open() {}, close() {}, shown: () => false } });
  a.render();
  assert.equal(buttonNamed(a.el, 'Take the base as it is'), null);
  assert.ok(buttonNamed(a.el, 'Start a fresh one'));
  const reads = fakeApp({ route: { name: 'project', id: P, view: 'lead' }, acts: false, kinds: ['lead'], state: { cards: new Map([[MOVED.id, MOVED]]), leads: new Map([[P, quietLead]]) } });
  const b = projectView(reads, { sheet: { open() {}, close() {}, shown: () => false } });
  b.render();
  assert.equal(buttonNamed(b.el, 'Take the base as it is'), null);
  assert.match(b.el.textContent, /vibeswitcher lead \/home\/dev\/projects\/example-site --resume/);
});

test('the mock lists the buttons’ kinds and answers each as the node does, refusals in its words; ?older lists none, ?refuse refuses each', async () => {
  const { createMock } = await import('../js/mock.js');
  const started = async (options = {}) => {
    let kinds = null;
    let shown = null;
    const ready = new Promise((resolve) => { shown = resolve; });
    const store = { apply() { shown(); }, setConnection() {}, chatSnapshot() {}, chatOps() {}, setKinds(list) { kinds = list; } };
    const mock = createMock(store, { still: true, ...options });
    mock.start();
    await ready;
    return { mock, kinds, ask: (kind, args = {}) => mock.request({ kind, args, action: crypto.randomUUID() }) };
  };
  const BUTTONS = ['shells', 'session.close-shells', 'presets.edit', 'update.check', 'web.revoke', 'config.held', 'base.show', 'mail', 'session.resume', 'session.new', 'lead', 'send'];
  const { mock, kinds, ask } = await started({ held: true });
  for (const kind of BUTTONS) assert.ok(kinds.includes(kind), kind);
  const SITE = '/home/dev/projects/example-site';
  // shells, then those still finished closed; none finished: the node's refusal.
  const shells = (await ask('shells', { folder: SITE })).result.shells;
  assert.deepEqual(shells.map((one) => one.finished), [true, true, false]);
  assert.deepEqual((await ask('session.close-shells', {})).error.code, 'bad-args');
  const closed = await ask('session.close-shells', { sessions: shells.map((one) => one.session) });
  assert.deepEqual([closed.result.ended.length, closed.result.left.length], [2, 1]);
  assert.match((await ask('session.close-shells', { sessions: [shells[2].session] })).error.message, /nothing ended/);
  // presets.edit: an edit needs the digest shown; a stale one is refused.
  assert.match((await ask('presets.edit', { op: 'edit', name: 'Opus', folder: SITE })).error.message, /needs the digest/);
  assert.match((await ask('presets.edit', { op: 'edit', name: 'Opus', folder: SITE, digest: 'old', args: '--model sonnet' })).error.message, /changed since it was shown/);
  assert.equal((await ask('presets.edit', { op: 'edit', name: 'Opus', folder: SITE, digest: 'mock-opus', args: '--model sonnet' })).result.held, true);
  assert.match((await ask('presets.edit', { op: 'remove', name: 'Claude', digest: 'x' })).error.message, /built-in/);
  // update.check: a newer build; web.revoke: how many.
  assert.match((await ask('update.check')).result.commit, /^5b8e1d2a/);
  assert.deepEqual((await ask('web.revoke')).result, { revoked: 1, tailnetRevoked: 1 });
  // config.held and base.show: the card whole, a held thing's difference.
  assert.equal((await ask('config.held', { folder: SITE })).result.card.kind, 'config');
  assert.ok((await ask('config.held', { folder: SITE, diff: '.claude/settings.json' })).result.difference.length > 2);
  assert.equal((await ask('base.show', { folder: SITE })).result.card.kind, 'base');
  // mail: its newest 20 of 26, every one with all.
  assert.equal((await ask('mail')).result.projects[0].messages.length, 20);
  assert.equal((await ask('mail', { folder: SITE, all: true })).result.projects[0].messages.length, 26);
  // send's images: checked as SessionSend checks them.
  const sid = 'local:e91d05a3-4f6a-4c1e-9b7d-2e5a8c0d1f3b';
  assert.match((await ask('send', { session: sid, text: '', images: ['shots/a.png'] })).error.message, /absolute path/);
  assert.match((await ask('send', { session: sid, text: '', images: ['/home/dev/a.txt'] })).error.message, /isn’t an image/);
  // lead: the site's lead ended (held), its base moved: started, kept checked unless takeHead.
  const kept = await ask('lead', { folder: SITE });
  assert.equal(kept.result.happened, 'started');
  assert.match(kept.result.notes.join(' '), /--take-head/);
  mock.stop();
  // A lead running without its role: shown, nothing started, until replace.
  const norole = await started({ norole: true });
  const shown = await norole.ask('lead', { folder: SITE });
  assert.equal(shown.result.happened, 'shown');
  assert.match(shown.result.notes[0], /without its role/);
  assert.equal((await norole.ask('lead', { folder: SITE, replace: true })).result.happened, 'started');
  norole.mock.stop();
  // ?older: none of them listed, each refused as unknown.
  const older = await started({ older: true });
  for (const kind of ['shells', 'session.close-shells', 'presets.edit', 'update.check', 'web.revoke', 'config.held', 'base.show']) {
    assert.ok(!older.kinds.includes(kind), kind);
    assert.equal((await older.ask(kind)).error.code, 'unknown-kind', kind);
  }
  older.mock.stop();
  // ?refuse=…: each listed, refused in the node's own words.
  const refusing = await started({ refuse: ['update.check', 'web.revoke', 'presets.edit'] });
  assert.match((await refusing.ask('update.check')).error.message, /scratch node asks GitHub nothing/);
  assert.match((await refusing.ask('web.revoke')).error.message, /weren’t dropped/);
  assert.match((await refusing.ask('presets.edit', { op: 'add', name: 'X' })).error.message, /haven’t accepted/);
  refusing.mock.stop();
});

test('B8: a held folder’s files read as their paths and what became of them, on the card and in the sheet; the node’s since-accept words in the page’s', async () => {
  const { projectView } = await import('../js/views/project.js');
  const { heldParts } = await import('../js/views/sheet.js');
  setLanguage('es');
  const app = fakeApp({ route: { name: 'project', id: P, view: 'lead', show: 'asks' }, kinds: ['config.held', 'config.accept'], state: { cards: new Map([[HELD.id, HELD]]), leads: new Map([[P, quietLead]]) } });
  const view = projectView(app, { sheet: { open() {}, close() {}, shown: () => false } });
  view.render();
  const box = find(view.el, byClass('wait-box'));
  assert.doesNotMatch(box.textContent, /object Object/);
  assert.match(box.textContent, /reviewer\.md · añadido/);
  assert.match(box.textContent, /npm test -- --runInBand \(cambiado\)/);
  const sheet = document.createElement('div');
  sheet.append(...heldParts(HELD, { root: SITE_ROOT }).more);
  assert.match(sheet.textContent, /cambiado desde tu última aceptación/);
  assert.doesNotMatch(sheet.textContent, /\bchanged\b/);
  setLanguage('en');
});
