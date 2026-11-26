// New project from the page (the no-terminal inventory's C1, `project.new`, 2026-11-26): where the page acts and the
// node lists the kind, the New project form's one button makes the project (its folder, git repository and first commit,
// then its lead), says what it is doing while the node works, then what it made, and opens the project once the node
// lists its lead (it shows in the left column); a refusal says why in a sentence, in the page's words, and nothing
// opens. A name the node would refuse is said before anything is sent. Elsewhere the `vibeswitcher new-project` line,
// as before (tests/sections.test.mjs, tests/sessionacts.test.mjs). In English and Spanish, on tests/fakedom.test.mjs's
// stand-in DOM over the real store; and the mock, which answers `project.new` as the node does.
// Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { installDom, find, findAll, byClass } from './fakedom.test.mjs';

installDom();
const { setLanguage, t } = await import('../js/i18n.js');
const { createStore } = await import('../js/store.js');
const { newProjectForm, projectNameProblem, projectWords } = await import('../js/views/drive.js');
const { createMock } = await import('../js/mock.js');
const { projectsOf } = await import('../js/conversation.js');
const { projectHref } = await import('../js/ui.js');

const flush = () => new Promise((resolve) => setImmediate(resolve));
const PROJECT = 'local:project:N3wSh0pAbCdE';
const LEAD_SID = 'local:5ab0c1d2-4f6a-4c1e-9b7d-2e5a8c0d1f3b';
const MADE = { made: true, name: 'Shop', folder: '/home/dev/projects/shop', commit: 'a'.repeat(40), lead: 'started', session: LEAD_SID,
  refused: null, said: '“Shop” is made in ~/projects/shop, with its git repository and first commit; its lead started.', notes: [] };

// The real store over a feed that records each request and answers `project.new` when the test says (`answer(reply)`).
function rig({ kinds = ['project.new', 'lead'], rights = ['read', 'draft', 'watch', 'act'] } = {}) {
  const store = createStore({ later: () => () => {} });
  const sent = [];
  let answer = null;
  store.connect({
    request(message) {
      sent.push(message);
      return new Promise((resolve) => { answer = resolve; });
    },
    subscribeChat() {}, unsubscribeChat() {}, resync() {},
  });
  store.setKinds(kinds, null, rights);
  store.reconcile('sessions', []);
  store.reconcile('leads', []);
  const went = [];
  const app = { store, ui: { state: { route: { name: 'new' } }, go(hash) { went.push(hash); }, subscribe() {} }, later: () => () => {} };
  return { store, app, sent, went, answer: (reply) => answer(reply) };
}

const field = (el, label) => find(el, (node) => (node.tag === 'input' || node.tag === 'textarea') && node.attrs['aria-label'] === label);
function typeIn(el, label, text) {
  const one = field(el, label);
  one.value = text;
  one.dispatch('input');
}
const primary = (el) => find(el, (node) => node.tag === 'button' && node.classList.contains('start-button'));

test('C1: where the page acts, one button named for the project; nothing is sent before the click; the click sends project.new with the name, where and the goal', () => {
  for (const code of ['en', 'es']) {
    setLanguage(code);
    const r = rig();
    const form = newProjectForm(r.app);
    assert.equal(primary(form.el).disabled, true, 'nothing to make until it has a name');
    assert.equal(find(form.el, byClass('copy-line')), null, 'no line to paste where the page makes it');
    typeIn(form.el, t('drProjectName'), 'Shop');
    typeIn(form.el, t('drWhere'), '/home/dev/projects/clients');
    typeIn(form.el, t('drGoal'), 'sell the prints');
    const make = primary(form.el);
    assert.equal(make.disabled, false);
    assert.equal(make.textContent, t('drMakeProjectNamed', { name: 'Shop' }));
    assert.match(form.el.shownText, new RegExp(t('drItsFolder', { folder: 'shop' })));
    assert.equal(r.sent.length, 0, 'nothing sent before the click');
    make.click();
    assert.deepEqual(r.sent.map((one) => [one.kind, one.args]), [['project.new', { name: 'Shop', location: '/home/dev/projects/clients', goal: 'sell the prints' }]]);
    assert.doesNotMatch(form.el.shownText, /vibeswitcher|new-project|local:/, 'no command or id where a person reads');
  }
  setLanguage('en');
});

test('C1: while the node works the form says what it is doing; made, it says what it made and opens the project once the node lists its lead, which the left column lists too', async () => {
  for (const code of ['en', 'es']) {
    setLanguage(code);
    const r = rig();
    const form = newProjectForm(r.app);
    typeIn(form.el, t('drProjectName'), 'Shop');
    primary(form.el).click();
    const progress = find(form.el, byClass('project-progress'));
    assert.equal(progress.hidden, false, 'the progress line while the request is out');
    assert.equal(progress.textContent, t('drNewMaking'));
    assert.equal(primary(form.el).disabled, true);
    assert.equal(primary(form.el).textContent, t('drNewMakingShort'));
    r.answer({ ok: true, result: MADE });
    await flush();
    assert.equal(find(form.el, byClass('project-progress')).hidden, true);
    assert.match(form.el.shownText, new RegExp(t('drNewMadeStarted', { name: 'Shop', folder: '/home/dev/projects/shop' }).slice(0, 40)));
    assert.equal(primary(form.el).disabled, true, 'no second project from the same click');
    assert.deepEqual(r.went, [], 'nothing opens before the node lists its lead');
    r.store.reconcile('leads', [{ project: PROJECT, root: '/home/dev/projects/shop', session: LEAD_SID, bound: LEAD_SID, named: null, held: 0, reportsWaiting: 0,
      notice: null, looks: 0, questions: { open: 0, blocking: 0 }, cards: [], told: [], push: null }]);
    await flush();
    assert.deepEqual(r.went, [projectHref(PROJECT)]);
    assert.ok(projectsOf(r.store.state).some((one) => one.project === PROJECT && one.name === 'shop'), 'the left column lists it');
  }
  setLanguage('en');
});

test('C1: a refusal says why in a sentence of the page’s own, nothing opens, and the button can be pressed again once the name is changed', async () => {
  for (const code of ['en', 'es']) {
    setLanguage(code);
    const r = rig();
    const form = newProjectForm(r.app);
    typeIn(form.el, t('drProjectName'), 'Shop');
    primary(form.el).click();
    r.answer({ ok: true, result: { made: false, name: null, folder: null, commit: null, lead: null, session: null, refused: 'exists',
      said: 'There’s already a folder named “shop” in ~/projects.', notes: [] } });
    await flush();
    const said = form.el.shownText;
    assert.match(said, new RegExp(t('drNewRefusedExists', { folder: 'shop', where: t('drTheProjectsFolder') }).slice(0, 30)));
    if (code === 'es') assert.doesNotMatch(said, /There’s already/, 'the page’s words, not the node’s English');
    assert.deepEqual(r.went, []);
    assert.equal(primary(form.el).disabled, false, 'it can be tried again');
    typeIn(form.el, t('drProjectName'), 'Shop Two');
    assert.equal(primary(form.el).textContent, t('drMakeProjectNamed', { name: 'Shop Two' }));
    // The node's own refusal of the request (not the project's): its words, as every button says them.
    primary(form.el).click();
    r.answer({ ok: false, error: { code: 'voice', message: 'not the user’s voice' } });
    await flush();
    assert.match(form.el.shownText, new RegExp(t('acVoice').slice(0, 20)));
  }
  setLanguage('en');
});

test('C1: every reason the node gives has a sentence in both languages, with no command, id or internal name', () => {
  const reasons = ['name', 'outside', 'link', 'exists', 'location', 'identity', 'repository', 'noClaude', 'failed', 'something-new'];
  for (const code of ['en', 'es']) {
    setLanguage(code);
    for (const reason of reasons) {
      const words = projectWords({ made: false, refused: reason, said: 'the node’s words' }, { name: 'Shop', folder: 'shop', where: '~/projects' });
      assert.ok(words.length > 20 && !/\{|\}|undefined|drNew/.test(words), `${code} ${reason}: ${words}`);
      assert.doesNotMatch(words, /vibeswitcher|project\.new|noClaude|git config/, `${code} ${reason}: ${words}`);
    }
    for (const [lead, key] of [['started', 'drNewMadeStarted'], ['waiting', 'drNewMadeWaiting'], ['refused', 'drNewMadeNoLead']]) {
      const words = projectWords({ ...MADE, lead, notes: ['the session host is gone'] }, { name: 'Shop', folder: 'shop', where: '' });
      assert.match(words, new RegExp(t(key, { name: 'Shop', folder: MADE.folder, why: '' }).slice(0, 25)), `${code} ${lead}`);
    }
  }
  setLanguage('en');
});

test('C1: a name the node would refuse is said under it before anything is sent, and its button waits', () => {
  for (const code of ['en', 'es']) {
    setLanguage(code);
    const r = rig();
    const form = newProjectForm(r.app);
    for (const [name, key] of [['a/b', 'drNameSeparator'], ['.hidden', 'drNameLeadingDot'], ['!!!', 'drNameNoLetters'], ['evil‮txt', 'drNameInvisible'], ['a'.repeat(101), 'drNameTooLong']]) {
      assert.equal(projectNameProblem(name), key, name);
      typeIn(form.el, t('drProjectName'), name);
      assert.equal(primary(form.el).disabled, true, name);
      assert.match(form.el.shownText, new RegExp(t(key).slice(0, 20)), name);
    }
    assert.equal(projectNameProblem('My App'), null);
    assert.equal(r.sent.length, 0);
  }
  setLanguage('en');
});

test('C1: a page that doesn’t act, or a node without project.new, keeps the line and says why; nothing is sent', () => {
  for (const code of ['en', 'es']) {
    setLanguage(code);
    for (const [r, why] of [[rig({ rights: ['read', 'draft'] }), 'drStartPageReads'], [rig({ kinds: ['lead'] }), 'drProjectTerminalOnly']]) {
      const form = newProjectForm(r.app);
      typeIn(form.el, t('drProjectName'), 'Shop');
      assert.equal(primary(form.el), null, 'no button');
      assert.ok(find(form.el, byClass('copy-line')));
      assert.match(form.el.shownText, new RegExp(t(why).slice(0, 30)));
      assert.equal(r.sent.length, 0);
    }
  }
  setLanguage('en');
});

// ---- The mock ----

function recorder() {
  const watchers = [];
  const got = { kinds: null, applied: [] };
  return {
    got,
    when: (holds) => new Promise((resolve) => watchers.push({ holds, resolve })),
    apply(message) {
      got.applied.push(structuredClone(message));
      for (const watcher of [...watchers]) if (watcher.holds(message)) { watchers.splice(watchers.indexOf(watcher), 1); watcher.resolve(message); }
    },
    setKinds(list) { got.kinds = list; }, setConnection() {}, chatSnapshot() {}, chatOps() {},
  };
}

test('the mock lists project.new (not with ?older), makes the project and lists its lead, and refuses as the node does', async () => {
  const store = recorder();
  const mock = createMock(store, { still: true });
  const snapshot = store.when((message) => message.kind === 'snapshot');
  mock.start();
  await snapshot;
  assert.ok(store.got.kinds.includes('project.new'));
  const listed = store.when((message) => message.kind === 'delta' && message.changes.some((change) => change.in === 'leads' && change.value?.root === '/home/dev/projects/shop'));
  const made = await mock.request({ kind: 'project.new', args: { name: 'Shop', goal: 'sell the prints' }, action: crypto.randomUUID() });
  assert.equal(made.ok, true);
  assert.equal(made.result.made, true);
  assert.equal(made.result.folder, '/home/dev/projects/shop');
  assert.equal(made.result.lead, 'started');
  await listed;
  const again = await mock.request({ kind: 'project.new', args: { name: 'Shop' }, action: crypto.randomUUID() });
  assert.equal(again.result.made, false);
  assert.equal(again.result.refused, 'exists');
  for (const [args, reason] of [[{ name: 'a/b' }, 'name'], [{ name: 'Shop', location: '/etc' }, 'outside'], [{ name: 'Elsewhere', location: '/home/dev/projects/../x' }, 'outside']]) {
    const reply = await mock.request({ kind: 'project.new', args, action: crypto.randomUUID() });
    assert.equal(reply.result.refused, reason, JSON.stringify(args));
  }
  const missing = await mock.request({ kind: 'project.new', args: {}, action: crypto.randomUUID() });
  assert.equal(missing.error.code, 'bad-args');
  mock.stop();

  const older = recorder();
  const old = createMock(older, { still: true, older: true });
  const first = older.when((message) => message.kind === 'snapshot');
  old.start();
  await first;
  assert.ok(!older.got.kinds.includes('project.new'));
  old.stop();
});
