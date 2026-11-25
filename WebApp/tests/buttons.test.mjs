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
    assert.match(detail.textContent, new RegExp(t('upCheckedNewer', { commit: '5b8e1d2a9c4f' }).replace(/[()]/g, '.')));
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
