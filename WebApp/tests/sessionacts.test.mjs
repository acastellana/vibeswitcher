// A session's own question answered from the page, and a session or a project's lead started from it (the UX review's
// U1 and U12, 2026-11-25), where the page acts and the node lists the kind (`session.reply`, `session.new`, `lead`);
// elsewhere the terminal's line and why. And the mock, which lists exactly those of a real acting node's kinds it
// answers, answers them as the node does, and with `older` lists none of them. Drawn on tests/fakedom.test.mjs's stand-in
// DOM over the real store, with an injected clock for the seconds an answer waits. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { installDom, find, findAll, byClass, button } from './fakedom.test.mjs';

installDom();
const { setLanguage } = await import('../js/i18n.js');
const { createStore, REPLIED_MS } = await import('../js/store.js');
const { promptCard, newSessionForm, newLeadForm, newProjectForm } = await import('../js/views/drive.js');
const { UNDO_MS } = await import('../js/views/cards.js');
const { createMock } = await import('../js/mock.js');

// Every promise the page chained on a reply has run.
const flush = () => new Promise((resolve) => setImmediate(resolve));

const QUESTION = 'Bash command\n  pytest tests/test_payouts.py\nDo you want to proceed?';
const OPTIONS = ['Yes', 'Yes, and don’t ask again for this command', 'No, and tell Claude what to do differently (esc)'];
const SID = 'local:e91d05a3-4f6a-4c1e-9b7d-2e5a8c0d1f3b';
const prompt = (fields = {}) => ({ question: QUESTION, options: OPTIONS, descriptions: [null, null, null], text: [], multiSelect: false, at: '2026-11-25T09:00:00.000Z', ...fields });
const asking = (fields = {}) => ({ id: SID, terminal: 'pts/7', agent: 'claude', cwd: '/home/dev/projects/example-api', status: 'needs-you', since: '2026-11-25T09:00:00.000Z',
  hosted: true, role: null, title: 'Why does the payout job run twice?', prompt: prompt(), ...fields });

// The real store over a feed that records each request and answers it with `replies[kind](args)` (a promise or a
// value); `later` the tests' clock: `fire()` runs what waits on it.
function rig({ kinds = ['session.reply', 'session.new', 'session.presets', 'lead'], rights = ['read', 'draft', 'watch', 'act'], replies = {}, sessions = [asking()] } = {}) {
  const waiting = [];
  const later = (fn, ms) => { const timer = { fn, ms, on: true }; waiting.push(timer); return () => { timer.on = false; }; };
  const store = createStore({ later });
  const sent = [];
  store.connect({
    request(message) {
      // A read of the presets isn't a request the page makes for the user: answered, not recorded.
      if (message.kind === 'session.presets') return Promise.resolve({ ok: true, result: { presets: [], problems: [] } });
      sent.push(message);
      return Promise.resolve((replies[message.kind] || (() => ({ ok: true, result: {} })))(message.args));
    },
    subscribeChat() {}, unsubscribeChat() {}, resync() {},
  });
  store.setKinds(kinds, null, rights);
  store.reconcile('sessions', sessions);
  store.reconcile('leads', []);
  const went = [];
  const app = {
    store,
    ui: { state: { route: { name: 'sessions' } }, go(hash) { went.push(hash); }, subscribe() {} },
    later,
  };
  const fire = () => { for (const timer of waiting.splice(0)) if (timer.on) timer.fn(); };
  return { store, app, sent, went, waiting, fire };
}

function card(r) {
  const view = promptCard(r.app);
  const draw = () => view.update(r.store.state.sessions.get(SID));
  r.store.subscribe('sessions', draw);
  draw();
  return view;
}
const optionButton = (el, text) => find(el, (node) => node.tag === 'button' && node.classList.contains('option') && node.textContent.includes(text));

test('U1: a click on a choice waits as a Blocking answer does, Undo shown, then answers with the question it was made on, and says so on the card', async () => {
  setLanguage('en');
  const r = rig({ replies: { 'session.reply': (args) => ({ ok: true, result: { session: args.session, terminal: 'pts/7', choice: args.choice, option: OPTIONS[args.choice - 1], question: QUESTION } }) } });
  const view = card(r);
  assert.equal(find(view.el, byClass('copy-button')), null, 'no line to paste where the page answers');
  optionButton(view.el, 'Yes').click();
  assert.match(view.el.shownText, /Sending “Yes”…/);
  assert.ok(find(view.el, button('Undo')), 'Undo while it waits');
  assert.equal(r.sent.length, 0, 'nothing sent while it waits');
  assert.deepEqual(r.waiting.map((timer) => timer.ms), [UNDO_MS], 'the Blocking answer’s seconds, on the injected clock');
  r.fire();
  assert.equal(r.sent.length, 1);
  assert.equal(r.sent[0].kind, 'session.reply');
  assert.deepEqual(r.sent[0].args, { session: SID, choice: 1, question: QUESTION, options: OPTIONS });
  await flush();
  assert.match(view.el.shownText, /You answered Yes/);
  assert.equal(view.el.hidden, false, 'the receipt stays on the card');
  // It no longer needs you: the store shows it working, its question closed, until the node reads its screen again.
  const shown = r.store.state.sessions.get(SID);
  assert.equal(shown.status, 'working');
  assert.equal(shown.prompt, null);
  r.store.change('sessions', [{ id: SID, value: asking() }]);
  assert.equal(r.store.state.sessions.get(SID).status, 'working', 'the node’s value still showing the answered question doesn’t bring it back');
  assert.match(view.el.shownText, /You answered Yes/);
  r.store.change('sessions', [{ id: SID, value: asking({ prompt: prompt({ question: 'Edit file\nDo you want to make this edit?', at: '2026-11-25T09:01:00.000Z' }) }) }]);
  assert.equal(r.store.state.sessions.get(SID).status, 'needs-you', 'another question needs you again');
  assert.match(view.el.shownText, /Do you want to make this edit\?/);
  assert.doesNotMatch(view.el.shownText, /You answered/);
});

test('U1: answered, but the node still shows that question once its seconds are over: it shows again, needing you, and says the answer may not have gone in', async () => {
  setLanguage('en');
  const r = rig();
  const view = card(r);
  optionButton(view.el, 'Yes').click();
  r.fire();
  await flush();
  assert.equal(r.store.state.sessions.get(SID).status, 'working');
  assert.deepEqual(r.waiting.filter((timer) => timer.on).map((timer) => timer.ms), [REPLIED_MS], 'the store hides it only for its seconds');
  r.fire();
  assert.equal(r.store.state.sessions.get(SID).status, 'needs-you', 'fails closed: the node’s value again');
  assert.match(view.el.shownText, /It still asks: your answer may not have gone in/);
  assert.ok(optionButton(view.el, 'Yes'), 'the choices back');
  // A snapshot (a reconnect) shows what the node says, never this page's hiding.
  const again = rig();
  const other = card(again);
  optionButton(other.el, 'Yes').click();
  again.fire();
  await flush();
  again.store.reconcile('sessions', [asking()]);
  assert.equal(again.store.state.sessions.get(SID).status, 'needs-you');
});

test('U1: Undo then another choice: only the second goes, after its own seconds', () => {
  setLanguage('en');
  const r = rig();
  const view = card(r);
  optionButton(view.el, 'Yes').click();
  const first = r.waiting.at(-1);
  find(view.el, button('Undo')).click();
  optionButton(view.el, 'don’t ask again').click();
  first.fn();
  assert.equal(r.sent.length, 0, 'the undone timer sends nothing, even if its cancel didn’t hold');
  r.fire();
  assert.equal(r.sent.length, 1);
  assert.equal(r.sent[0].args.choice, 2);
});

test('U1: Undo takes it back, and nothing is sent', () => {
  setLanguage('en');
  const r = rig();
  const view = card(r);
  optionButton(view.el, 'Yes').click();
  find(view.el, button('Undo')).click();
  r.fire();
  assert.equal(r.sent.length, 0);
  assert.ok(optionButton(view.el, 'Yes'), 'the choices are back');
});

test('U1: the question changing or closing while the answer waits drops it; acting ending meanwhile does too', () => {
  setLanguage('en');
  const changed = rig();
  const view = card(changed);
  optionButton(view.el, 'Yes').click();
  changed.store.change('sessions', [{ id: SID, value: asking({ prompt: prompt({ options: ['Yes', 'No'], at: '2026-11-25T09:02:00.000Z' }) }) }]);
  changed.fire();
  assert.equal(changed.sent.length, 0, 'not sent to another question');
  assert.match(view.el.shownText, /The question changed before your answer went: nothing was sent/);

  const closed = rig();
  const other = card(closed);
  optionButton(other.el, 'Yes').click();
  closed.store.change('sessions', [{ id: SID, value: asking({ prompt: null, status: 'working' }) }]);
  closed.fire();
  assert.equal(closed.sent.length, 0, 'not sent once it closed');
  assert.equal(other.el.hidden, true);

  const ended = rig();
  const third = card(ended);
  optionButton(third.el, 'Yes').click();
  ended.store.setKinds(['session.new'], null, ['read', 'draft']);
  ended.fire();
  assert.equal(ended.sent.length, 0, 'not sent once the page no longer acts');
});

test('U1: a refusal stays on the card in words, with the choices back; Spanish too', async () => {
  for (const [code, words] of [['en', /Not answered: session e91d05a3: no question is open on its screen/], ['es', /No se respondió: session e91d05a3: no question is open on its screen/]]) {
    setLanguage(code);
    const r = rig({ replies: { 'session.reply': () => ({ ok: false, error: { code: 'refused', message: 'session e91d05a3: no question is open on its screen' } }) } });
    const view = card(r);
    optionButton(view.el, 'Yes').click();
    r.fire();
    await flush();
    assert.match(view.el.shownText, words);
    assert.ok(optionButton(view.el, 'Yes'), 'the choices back');
    assert.equal(r.store.state.sessions.get(SID).status, 'needs-you', 'still needs you');
  }
  setLanguage('en');
});

test('U1: an option that takes words opens a field; the answer carries them', async () => {
  setLanguage('en');
  const r = rig({ sessions: [asking({ prompt: prompt({ options: ['Yes', 'Type something.'], text: [1], descriptions: [null, null] }) })] });
  const view = card(r);
  optionButton(view.el, 'Type something.').click();
  assert.equal(r.waiting.length, 0, 'nothing waits before the words');
  const input = find(view.el, byClass('answer-input'));
  input.value = 'Use the staging database';
  input.dispatch('input');
  find(view.el, (node) => node.tag === 'form').dispatch('submit');
  assert.match(view.el.shownText, /Sending “Type something.: Use the staging database”…/);
  r.fire();
  assert.deepEqual(r.sent[0].args, { session: SID, choice: 2, question: QUESTION, options: ['Yes', 'Type something.'], text: 'Use the staging database' });
});

// C5 (the no-terminal inventory, 2026-11-26): a multi-select's ticks and Submit, where the page acts.
const MULTI = { question: 'Which checks should run before the payout fix ships?', options: ['Unit tests', 'Integration tests', 'Lint', 'Type something'],
  descriptions: ['tests/test_payouts.py', null, null, null], text: [3], multiSelect: true };
const boxes = (el) => findAll(el, (node) => node.tag === 'input' && node.attrs.type === 'checkbox');
const tick = (box, on = true) => { box.checked = on; box.dispatch('change'); };
const submitButton = (el) => find(el, (node) => node.tag === 'button' && node.classList.contains('ticks-submit'));

test('C5: an acting page ticks a multi-select’s options and submits them: the Blocking answer’s seconds, then choices, and the card says so', async () => {
  setLanguage('en');
  const r = rig({ sessions: [asking({ prompt: prompt(MULTI) })],
    replies: { 'session.reply': (args) => ({ ok: true, result: { session: args.session, terminal: 'pts/7', choices: args.choices, options: ['Unit tests', 'Lint'], question: MULTI.question } }) } });
  const view = card(r);
  assert.match(view.el.shownText, /Tick any that apply, then Submit\./);
  assert.equal(boxes(view.el).length, 4, 'a box for each option');
  assert.equal(find(view.el, byClass('copy-button')), null, 'no line to paste where the page answers');
  const submit = submitButton(view.el);
  assert.equal(submit.disabled, true, 'nothing ticked: nothing to submit');
  const [unit, , lint, other] = boxes(view.el);
  tick(unit);
  tick(lint);
  // A tick changes the card in place: the same box, the same Submit, nothing drawn again (the focus stays put).
  assert.equal(boxes(view.el)[0], unit, 'not drawn again');
  assert.equal(submitButton(view.el), submit);
  assert.equal(submit.disabled, false);
  assert.ok(find(view.el, (node) => node.tag === 'label' && node.classList.contains('chosen') && node.textContent.includes('Lint')), 'a ticked row shows it');
  const words = find(view.el, byClass('ticks-words'));
  assert.equal(words.hidden, true, 'no field for words until the row that takes them is ticked');
  tick(other);
  assert.equal(words.hidden, false);
  assert.equal(submit.disabled, true, 'the free-text row ticked takes words first');
  tick(other, false);
  assert.equal(submit.disabled, false);
  submit.click();
  assert.match(view.el.shownText, /Sending “Unit tests, Lint”…/);
  assert.ok(find(view.el, button('Undo')));
  assert.equal(r.sent.length, 0, 'nothing sent while it waits');
  assert.deepEqual(r.waiting.map((timer) => timer.ms), [UNDO_MS]);
  r.fire();
  assert.deepEqual(r.sent.map((one) => one.kind), ['session.reply']);
  assert.deepEqual(r.sent[0].args, { session: SID, choices: [1, 3], question: MULTI.question, options: MULTI.options });
  await flush();
  assert.match(view.el.shownText, /You answered Unit tests, Lint/);
});

test('C5: the free-text row goes with its words; Undo keeps the ticks; a refusal says why and the ticks stay to answer again', async () => {
  setLanguage('en');
  const r = rig({ sessions: [asking({ prompt: prompt(MULTI) })],
    replies: { 'session.reply': () => ({ ok: false, error: { code: 'refused', message: 'session e91d05a3: its boxes didn’t show the ticks asked before Submit (a key lost?): nothing submitted, answer again' } }) } });
  const view = card(r);
  const [, integration, , other] = boxes(view.el);
  tick(integration);
  tick(other);
  const words = find(view.el, byClass('ticks-words'));
  words.value = 'Load test the scheduler';
  words.dispatch('input');
  submitButton(view.el).click();
  assert.match(view.el.shownText, /Sending “Integration tests, Load test the scheduler”…/);
  find(view.el, button('Undo')).click();
  assert.deepEqual(boxes(view.el).map((box) => box.checked), [false, true, false, true], 'Undo: the ticks as they were');
  assert.equal(find(view.el, byClass('ticks-words')).value, 'Load test the scheduler');
  submitButton(view.el).click();
  r.fire();
  assert.deepEqual(r.sent[0].args, { session: SID, choices: [2, 4], question: MULTI.question, options: MULTI.options, text: 'Load test the scheduler' });
  await flush();
  assert.match(view.el.shownText, /nothing submitted, answer again/);
  assert.deepEqual(boxes(view.el).map((box) => box.checked), [false, true, false, true], 'refused: the ticks stay');
});

test('C5: the multi-select’s card in Spanish', () => {
  setLanguage('es');
  const r = rig({ sessions: [asking({ prompt: prompt(MULTI) })] });
  const view = card(r);
  assert.match(view.el.shownText, /Marca las que correspondan y pulsa Enviar\./);
  assert.ok(submitButton(view.el).textContent.includes('Enviar'));
  setLanguage('en');
});

test('U1: a multi-select on a page that doesn’t act keeps saying to answer it in its terminal, and sends nothing', () => {
  setLanguage('en');
  const r = rig({ rights: ['read', 'draft'], sessions: [asking({ prompt: prompt({ multiSelect: true }) })] });
  const view = card(r);
  assert.equal(optionButton(view.el, 'Yes'), null, 'no choice to click');
  assert.equal(boxes(view.el).length, 0, 'no box to tick');
  assert.match(view.el.shownText, /It takes several ticks: answer it in the session’s own terminal/);
  assert.equal(r.sent.length, 0);
});

test('U1: where the node doesn’t list session.reply, or the page doesn’t act, the line to paste and why, in English and Spanish', () => {
  for (const [code, unlisted, reads] of [
    ['en', /This node takes a session’s answer only from a terminal/, /This page doesn’t act for you here, so it can’t answer/],
    ['es', /Este nodo solo acepta la respuesta de una sesión desde una terminal/, /Aquí esta página no actúa por ti, así que no puede responder/]]) {
    setLanguage(code);
    const older = rig({ kinds: ['session.new', 'lead'] });
    const one = card(older);
    optionButton(one.el, 'Yes').click();
    assert.ok(find(one.el, byClass('copy-button')), 'the line to paste');
    assert.ok(findAll(one.el, (node) => node.tag === 'code' || node.classList.contains('copy-line')).length || /vibeswitcher reply e91d05a3 1/.test(one.el.textContent));
    assert.match(one.el.shownText, unlisted);
    assert.equal(older.sent.length + older.waiting.length, 0, 'nothing sent, nothing waits');
    const reading = rig({ rights: ['read', 'draft'] });
    const two = card(reading);
    assert.match(two.el.shownText, reads);
    optionButton(two.el, 'Yes').click();
    assert.equal(reading.sent.length + reading.waiting.length, 0);
  }
  setLanguage('en');
});

// A form drawn the way its screen draws it: its folder typed.
function typed(form, value, index = 0) {
  const input = findAll(form.el, (node) => node.tag === 'input')[index];
  input.value = value;
  input.dispatch('input');
}

test('U12: Start starts the session from the page, “Starting…” while it goes, then opens it once the node lists it', async () => {
  setLanguage('en');
  let answer;
  const r = rig({ sessions: [], replies: { 'session.new': () => new Promise((resolve) => { answer = resolve; }) } });
  const form = newSessionForm(r.app, { folder: () => '' });
  typed(form, '/home/dev/projects/example-api');
  const start = find(form.el, button('Start'));
  assert.ok(start?.classList.contains('start-button'), 'a primary button');
  // It says what it will start, and where the page acts no command shows (D12).
  assert.equal(start.textContent, 'Start Claude in example-api');
  assert.doesNotMatch(form.el.shownText, /vibeswitcher new|Or in a terminal/);
  start.click();
  assert.equal(start.textContent, 'Starting…');
  assert.equal(start.disabled, true);
  assert.deepEqual(r.sent.at(-1).args, { folder: '/home/dev/projects/example-api', agent: 'claude' });
  const NEW = 'local:0badc0de-4f6a-4c1e-9b7d-2e5a8c0d1f3b';
  answer({ ok: true, result: { session: NEW, terminal: 'pts/30', agent: 'claude', folder: '/home/dev/projects/example-api', model: null, preset: null } });
  await flush();
  assert.match(form.el.shownText, /Started: it opens here as soon as the node lists it/);
  assert.deepEqual(r.went, [], 'not before the node lists it');
  assert.equal(start.disabled, true, 'started: no second start from this button');
  r.store.change('sessions', [{ id: NEW, value: asking({ id: NEW, prompt: null, status: 'working' }) }]);
  assert.deepEqual(r.went, ['#/s/' + encodeURIComponent(NEW)]);
});

test('U12: a start that the node lists only after the user went elsewhere doesn’t pull them back', async () => {
  setLanguage('en');
  const NEW = 'local:0badc0de-4f6a-4c1e-9b7d-2e5a8c0d1f3b';
  const r = rig({ sessions: [], replies: { 'session.new': () => ({ ok: true, result: { session: NEW, terminal: 'pts/30', agent: 'claude', folder: '/home/dev', model: null, preset: null } }) } });
  const form = newSessionForm(r.app, { folder: () => '' });
  typed(form, '/home/dev');
  find(form.el, button('Start')).click();
  await flush();
  r.app.ui.state.route = { name: 'session', id: SID };
  r.store.change('sessions', [{ id: NEW, value: asking({ id: NEW, prompt: null, status: 'working' }) }]);
  assert.deepEqual(r.went, []);
});

test('U12: a preset the node listed goes with its digest; a refusal is said under the button', async () => {
  setLanguage('en');
  let read = null;
  const asked = new Promise((resolve) => { read = resolve; });
  const r = rig({ sessions: [], replies: { 'session.new': () => ({ ok: false, error: { code: 'refused', message: '/home/dev/nowhere isn’t a folder' } }) } });
  r.store.read = (kind, args) => { read(args); return Promise.resolve({ ok: true, result: { presets: [
    { name: 'Opus', kind: 'claude', command: 'claude --model opus', env: [], keepShell: false, project: true, default: true, digest: 'd-opus', refused: null },
    { name: 'Claude', kind: 'claude', command: 'claude', env: [], keepShell: false, project: false, default: false, digest: 'd-claude', refused: null }], problems: [] } }); };
  const form = newSessionForm(r.app, { folder: () => '' });
  typed(form, '/home/dev/nowhere');
  await asked;
  await flush();
  find(form.el, button('Start')).click();
  assert.deepEqual(r.sent.at(-1).args, { folder: '/home/dev/nowhere', preset: 'Opus', digest: 'd-opus' });
  await flush();
  assert.match(form.el.shownText, /isn’t a folder/);
  assert.deepEqual(r.went, []);
});

test('U12: Start the lead starts it and opens its project; a lead that waits for its host says so; only folder and goal are sent', async () => {
  setLanguage('en');
  const LEAD = 'local:1eadbeef-4f6a-4c1e-9b7d-2e5a8c0d1f3b';
  const r = rig({ sessions: [], replies: { lead: (args) => (args.folder.endsWith('later') ? { ok: true, result: { happened: 'waiting', session: null, program: null, notes: [] } }
    : { ok: true, result: { happened: 'started', session: LEAD, program: '/usr/bin/claude', notes: [] } }) } });
  const form = newLeadForm(r.app);
  typed(form, '/home/dev/projects/example-api');
  const goal = find(form.el, (node) => node.tag === 'textarea');
  goal.value = 'Ship the payouts fix';
  goal.dispatch('input');
  find(form.el, button('Start the lead')).click();
  assert.deepEqual(r.sent.at(-1).args, { folder: '/home/dev/projects/example-api', goal: 'Ship the payouts fix' });
  await flush();
  assert.deepEqual(r.went, []);
  assert.match(form.el.shownText, /Started: its project opens here as soon as the node lists its lead/);
  r.store.change('leads', [{ id: 'local:project:Ab12', value: { project: 'local:project:Ab12', root: '/home/dev/projects/example-api', session: LEAD } }]);
  assert.equal(r.went.length, 1);
  assert.match(r.went[0], /^#\/p\/local%3Aproject%3AAb12/);
  typed(form, '/home/dev/projects/later');
  find(form.el, button('Start the lead')).click();
  await flush();
  assert.match(form.el.shownText, /as soon as its session host is ready/);
  // In Spanish the lead is “él”: Arrancado, never the session's Arrancada.
  setLanguage('es');
  const es = rig({ sessions: [], replies: { lead: () => ({ ok: true, result: { happened: 'started', session: LEAD, program: '/usr/bin/claude', notes: [] } }) } });
  const formEs = newLeadForm(es.app);
  typed(formEs, '/home/dev/projects/example-api');
  find(formEs.el, button('Arrancar el líder')).click();
  await flush();
  assert.match(formEs.el.shownText, /Arrancado: su proyecto se abre aquí en cuanto el nodo liste su líder/);
  assert.doesNotMatch(formEs.el.shownText, /Arrancada/);
  setLanguage('en');
});

test('U12: where the node doesn’t list session.new or lead, or the page doesn’t act, the line stays and says why; New project’s folder is a terminal’s', () => {
  for (const [code, words] of [['en', [/This node starts a session only from a terminal/, /This node starts a project’s lead only from a terminal/, /This page doesn’t act for you here, so it can’t start it/, /A page can’t make a new project’s folder yet/]],
    ['es', [/Este nodo solo arranca una sesión desde una terminal/, /Este nodo solo arranca el líder de un proyecto desde una terminal/, /Aquí esta página no actúa por ti, así que no puede arrancarla/, /Una página aún no puede crear la carpeta de un proyecto nuevo/]]]) {
    setLanguage(code);
    const older = rig({ kinds: ['session.reply'], sessions: [] });
    const session = newSessionForm(older.app, { folder: () => '' });
    typed(session, '/home/dev/projects/example-api');
    assert.equal(find(session.el, byClass('start-button')), null);
    assert.ok(find(session.el, byClass('copy-button')));
    assert.match(session.el.shownText, words[0]);
    const lead = newLeadForm(older.app);
    typed(lead, '/home/dev/projects/example-api');
    assert.equal(find(lead.el, byClass('start-button')), null);
    assert.match(lead.el.shownText, words[1]);
    const reading = rig({ rights: ['read', 'draft'], sessions: [] });
    const readOnly = newSessionForm(reading.app, { folder: () => '' });
    typed(readOnly, '/home/dev/projects/example-api');
    assert.match(readOnly.el.shownText, words[2]);
    const project = newProjectForm(older.app);
    typed(project, 'tienda nueva');
    assert.ok(find(project.el, byClass('copy-button')));
    assert.match(project.el.shownText, words[3]);
    assert.equal(older.sent.length + reading.sent.length, 0, 'nothing sent');
  }
  setLanguage('en');
});

// ---- The mock ----

// A store that keeps what the mock gives it; `when(test)` resolves at the first delta `test` holds for.
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
async function started(options = {}) {
  const store = recorder();
  const mock = createMock(store, { still: true, ...options });
  const snapshot = store.when((message) => message.kind === 'snapshot');
  mock.start();
  await snapshot;
  return { store, mock, snapshot: store.got.applied[0] };
}
const STARTS = ['lead', 'session.new', 'session.reply', 'session.resume'];
const changed = (sid, holds) => (message) => message.kind === 'delta' && message.changes.some((change) => change.in === 'sessions' && change.id === sid && holds(change.value));

test('the mock lists a real acting node’s session starts and reply, answers every kind it lists, and none it doesn’t (ask.answer is no node’s)', async () => {
  const { store, mock } = await started();
  for (const kind of STARTS) assert.ok(store.got.kinds.includes(kind), kind);
  assert.ok(!store.got.kinds.includes('ask.answer'));
  for (const kind of store.got.kinds.filter((one) => one !== 'chat.page' && one !== 'stop')) {
    const reply = await mock.request({ kind, args: {} });
    assert.notEqual(reply.error?.code, 'unknown-kind', `${kind} is listed and refused as unknown`);
  }
  const unlisted = await mock.request({ kind: 'ask.answer', args: {} });
  assert.equal(unlisted.error?.code, 'unknown-kind');
  mock.stop();
});

test('the mock with older lists none of them and refuses each as unknown, as a node that doesn’t take them', async () => {
  const { store, mock } = await started({ older: true });
  for (const kind of STARTS) {
    assert.ok(!store.got.kinds.includes(kind), kind);
    assert.equal((await mock.request({ kind, args: { session: SID, folder: '/home/dev/projects/example-api', choice: 1 } })).error?.code, 'unknown-kind', kind);
  }
  assert.ok(store.got.kinds.includes('answer'), 'the rest as before');
  mock.stop();
});

test('the mock answers session.reply as the node does: the question checked again, refusals in its words, the question closing after the reply', async () => {
  const { store, mock } = await started();
  const ask = (args) => mock.request({ kind: 'session.reply', args: { session: SID, question: QUESTION, options: OPTIONS, ...args } });
  assert.match((await ask({ choice: 1, question: 'Something else?' })).error.message, /the question on its screen isn’t the one you were shown/);
  assert.match((await ask({ choice: 1, options: ['Yes'] })).error.message, /its options aren’t the ones you were shown/);
  assert.match((await ask({ choice: 4 })).error.message, /has 3 options, not 4/);
  assert.match((await ask({ choice: 1, text: 'more' })).error.message, /takes no words/);
  assert.equal((await ask({ choice: 0 })).error.code, 'bad-args');
  assert.equal((await ask({ session: 'local:00000000-4f6a-4c1e-9b7d-2e5a8c0d1f3b', choice: 1 })).error.code, 'gone', 'a session not running');
  const closes = store.when(changed(SID, (value) => value.prompt === null && value.status === 'working'));
  const done = await ask({ choice: 1 });
  assert.deepEqual(done, { ok: true, result: { session: SID, terminal: done.result.terminal, choice: 1, option: 'Yes', question: QUESTION } });
  await closes;
  assert.match((await ask({ choice: 1 })).error.message, /no question is open on its screen/, 'answered: nothing open any more');
  mock.stop();
});

test('C5: the mock with multi answers choices as the node does: only the options it offers, each once, words only for its free-text row', async () => {
  const { store, snapshot, mock } = await started({ multi: true });
  const shown = snapshot.state.sessions.find((one) => one.id === SID).prompt;
  assert.equal(shown.multiSelect, true);
  const ask = (args) => mock.request({ kind: 'session.reply', args: { session: SID, question: shown.question, options: shown.options, ...args } });
  assert.match((await ask({ choice: 1 })).error.message, /takes several ticks: give them as choices/);
  assert.match((await ask({ choices: [1, 5] })).error.message, /has 4 options, not 5/, 'an option it hasn’t');
  assert.match((await ask({ choices: [1, 2, 3, 4, 5] })).error.message, /5 choices are more than it offers/);
  assert.equal((await ask({ choices: [2, 2] })).error.code, 'bad-args', 'one twice');
  assert.equal((await ask({ choices: [] })).error.code, 'bad-args', 'none');
  assert.equal((await ask({ choices: [1], choice: 1 })).error.code, 'bad-args', 'both');
  assert.match((await ask({ choices: [1], text: 'more' })).error.message, /none of the options chosen takes words/);
  assert.match((await ask({ choices: [4] })).error.message, /option 4 takes your words/);
  const closes = store.when(changed(SID, (value) => value.prompt === null && value.status === 'working'));
  const done = await ask({ choices: [3, 1, 4], text: 'Load test' });
  assert.deepEqual(done.result, { session: SID, terminal: done.result.terminal, choices: [1, 3, 4], options: ['Unit tests', 'Lint', 'Load test'], question: shown.question });
  await closes;
  mock.stop();
});

test('the mock with toggle refuses a Space-toggled option as the node does', async () => {
  const { snapshot, mock } = await started({ toggle: true });
  const shown = snapshot.state.sessions.find((one) => one.id === SID).prompt;
  const reply = await mock.request({ kind: 'session.reply', args: { session: SID, choice: 2, question: shown.question, options: shown.options } });
  assert.match(reply.error.message, /option 2 is a setting toggled with Space \(Also scan shell history\): set it in the session’s terminal, or choose its Continue/);
  mock.stop();
});

test('the mock answers session.new, session.resume and lead as the node does: a bad folder refused, a session listed after the reply, an ended session gone', async () => {
  const { store, mock } = await started();
  const ask = (kind, args) => mock.request({ kind, args });
  assert.match((await ask('session.new', { folder: '/home/dev/nowhere' })).error.message, /isn’t a folder/);
  assert.equal((await ask('session.new', { folder: 'relative' })).error.code, 'bad-args');
  assert.equal((await ask('session.new', { folder: '/home/dev/projects/example-api', preset: 'Opus' })).error.code, 'bad-args', 'a preset needs its digest');
  assert.match((await ask('session.new', { folder: '/home/dev/projects/example-api', preset: 'Opus', digest: 'stale' })).error.message, /changed since it was shown/);
  const made = await ask('session.new', { folder: '/home/dev/projects/example-api', preset: 'Opus', digest: 'mock-opus' });
  assert.equal(made.ok, true, JSON.stringify(made));
  await store.when(changed(made.result.session, (value) => value?.cwd === '/home/dev/projects/example-api'));

  assert.match((await ask('lead', { folder: '/home/dev/nowhere' })).error.message, /isn’t in a git repository/);
  assert.match((await ask('lead', { folder: '/home/dev/projects/notes' })).error.message, /has no commits yet/);
  assert.equal((await ask('lead', { folder: '/home/dev/projects/example-site' })).result.happened, 'shown');
  const lead = await ask('lead', { folder: '/home/dev/projects/example-api' });
  assert.equal(lead.result.happened, 'started');
  await store.when((message) => message.kind === 'delta' && message.changes.some((change) => change.in === 'leads' && change.value?.session === lead.result.session));

  assert.equal((await ask('session.resume', { session: 'local:00000000' })).error.code, 'gone');
  const notes = await ask('session.resume', { session: 'local:9d2b4f60-4f6a-4c1e-9b7d-2e5a8c0d1f3b' });
  assert.deepEqual(notes.result.reopened, []);
  assert.match(notes.result.refused[0].why, /conversation id wasn’t recorded/);
  const back = await ask('session.resume', { session: 'local:5c1e7a92-4f6a-4c1e-9b7d-2e5a8c0d1f3b' });
  assert.equal(back.result.reopened.length, 1);
  assert.match((await ask('session.reply', { session: 'local:5c1e7a92-4f6a-4c1e-9b7d-2e5a8c0d1f3b', choice: 1 })).error.message, /no live session/, 'an ended session isn’t answered');
  mock.stop();
});
