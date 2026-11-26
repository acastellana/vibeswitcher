// The node's offers as cards (js/views/offers.js; the no-terminal inventory's C3 and C4, 2026-11-26), drawn on
// tests/fakedom.test.mjs's stand-in DOM, in English and Spanish:
//
// - The restart's reopen offer (`node.reopenOffer`): one card, its sessions by name; Reopen all, Choose and Not now
//   send `session.reopen` with all, the chosen sessions, or forget; nothing is sent before a click; each says what
//   happened, and the card says so after the offer is gone, until OK. On This node and on Your own sessions.
// - A prompt audit due (`node.promptAudits`): why, in the page's words; Run it in the lead (`send`, only with its lead
//   running), Remind me in a week and Not for this project (`prompt-audit` snooze, off); what each did, in words.
// - Where the page doesn't act: no button, the line for a terminal and why.
// Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { installDom, find, findAll, byClass } from './fakedom.test.mjs';

process.env.TZ = 'UTC';
installDom();
const { setLanguage, t } = await import('../js/i18n.js');
const { reopenCard, promptAuditCards, auditWhy, PROMPT_AUDIT_COMMAND } = await import('../js/views/offers.js');
const { nodeVerdict } = await import('../js/views/node.js');

const flush = () => new Promise((resolve) => setImmediate(resolve));
const buttonNamed = (el, text) => find(el, (node) => node.tag === 'button' && !node.hidden && node.textContent.trim() === text);
const buttons = (el) => findAll(el, (node) => node.tag === 'button' && !node.hidden).map((node) => node.textContent.trim());

// An app as the cards read it: the kinds the connection may send, whether it acts, every request sent and its answer.
function fakeApp({ kinds = null, acts = true, reply = () => ({ ok: true, result: {} }) } = {}) {
  const sent = [];
  return {
    sent,
    store: { state: { node: null }, acts: () => acts, can: (kind) => kinds === null || kinds.includes(kind), request: (kind, args) => { sent.push({ kind, args }); return Promise.resolve(reply(kind, args)); } },
    later: () => () => {},
  };
}

const today = new Date();
today.setUTCHours(9, 12, 0, 0);
const OFFER = { at: today.toISOString(), sessions: [
  { session: 'local:3b8e1f07-0000-4000-8000-000000000001', name: 'example-api', project: 'example-api', agent: 'claude' },
  { session: 'local:a41c6d92-0000-4000-8000-000000000002', name: 'Tidy the notes', project: 'notes', agent: 'claude' },
  { session: 'local:c07f5e3a-0000-4000-8000-000000000003', name: 'Sketch the onboarding', project: 'example-site', agent: 'codex' },
] };

test('C3: no offer, no card; an offer is one card naming each session, and nothing is sent before a click', () => {
  for (const [code, all, choose, later] of [['en', 'Reopen all', 'Choose…', 'Not now'], ['es', 'Reabrir todas', 'Elegir…', 'Ahora no']]) {
    setLanguage(code);
    const app = fakeApp();
    const card = reopenCard(app);
    card.update(null);
    assert.equal(card.el.children.length, 0, 'none: nothing drawn');
    assert.equal(card.shown(), false);
    card.update({ at: OFFER.at, sessions: [] });
    assert.equal(card.el.children.length, 0, 'an empty offer: nothing drawn');
    card.update(OFFER);
    assert.equal(findAll(card.el, byClass('offer-card')).length, 1, 'one card');
    assert.equal(card.shown(), true);
    assert.equal(card.count(), 3);
    const text = card.el.textContent;
    for (const one of OFFER.sessions) assert.match(text, new RegExp(one.name));
    assert.match(text, new RegExp(t('roTitle', { n: 3 })));
    assert.match(text, code === 'en' ? /restarted at 9:12 AM\./ : /se reinició a las 9:12\./);
    assert.doesNotMatch(text, /vibeswitcher|local:|\/home\//, 'no command, id or path where a person reads');
    assert.deepEqual(buttons(card.el), [all, choose, later]);
    assert.deepEqual(app.sent, [], 'nothing reopens without the click');
  }
  setLanguage('en');
});

test('C3: Reopen all sends session.reopen all, and says what it did after the offer is gone, until OK', async () => {
  const app = fakeApp({ reply: () => ({ ok: true, result: { reopened: OFFER.sessions.map((one) => ({ was: one.session, session: 'local:new' })), refused: [] } }) });
  let changed = 0;
  const card = reopenCard(app, { changed: () => { changed += 1; } });
  card.update(OFFER);
  buttonNamed(card.el, 'Reopen all').click();
  assert.deepEqual(app.sent, [{ kind: 'session.reopen', args: { all: true } }]);
  await flush();
  assert.match(card.el.textContent, /Reopened 3 sessions: they’re in Your own sessions\./);
  // The node's offer gone: the card still says what happened.
  card.update(null);
  assert.match(card.el.textContent, /Reopened 3 sessions/);
  assert.equal(card.shown(), true);
  assert.equal(card.count(), 0);
  buttonNamed(card.el, 'OK').click();
  assert.equal(card.el.children.length, 0);
  assert.equal(card.shown(), false);
  assert.equal(changed, 1, 'the list told to draw again');
});

test('C3: Choose reopens only the sessions ticked; Not now puts the offer away; a refusal is said in place', async () => {
  const app = fakeApp({ reply: (kind, args) => (args.forget ? { ok: true, result: { forgotten: 3 } }
    : args.sessions?.length ? { ok: true, result: { reopened: [{ was: args.sessions[0], session: 'local:new' }], refused: [] } }
      : { ok: false, error: { code: 'refused', message: 'nothing reopened: its folder is gone' } }) });
  const card = reopenCard(app);
  card.update(OFFER);
  buttonNamed(card.el, 'Choose…').click();
  const boxes = findAll(card.el, (node) => node.tag === 'input');
  assert.equal(boxes.length, 3);
  const reopenChosen = buttonNamed(card.el, 'Reopen the chosen ones');
  assert.ok(reopenChosen.disabled, 'none chosen: nothing to send');
  boxes[1].checked = true;
  boxes[1].dispatch('change');
  assert.equal(reopenChosen.disabled, false);
  assert.ok(buttonNamed(card.el, 'Cancel'), 'Choose turns into Cancel');
  reopenChosen.click();
  assert.deepEqual(app.sent.at(-1), { kind: 'session.reopen', args: { sessions: [OFFER.sessions[1].session] } });
  await flush();
  assert.match(card.el.textContent, /Reopened 1 session: it’s in Your own sessions\./);
  buttonNamed(card.el, 'OK').click();

  // Not now: forget, said.
  const later = reopenCard(app);
  later.update(OFFER);
  buttonNamed(later.el, 'Not now').click();
  assert.deepEqual(app.sent.at(-1), { kind: 'session.reopen', args: { forget: true } });
  await flush();
  assert.match(later.el.textContent, /Put away: those 3 sessions won’t be offered again\./);

  // Refused (nothing reopened): the node's words beside the button, the card as it was.
  const refused = reopenCard(fakeApp({ reply: () => ({ ok: false, error: { code: 'refused', message: 'nothing reopened: its folder is gone' } }) }));
  refused.update(OFFER);
  buttonNamed(refused.el, 'Reopen all').click();
  await flush();
  assert.match(refused.el.textContent, /nothing reopened: its folder is gone/);
  assert.ok(buttonNamed(refused.el, 'Reopen all'), 'the button back');
});

test('C3: where the page doesn’t act, the card has no button: the line for a terminal and why', () => {
  for (const app of [fakeApp({ acts: false }), fakeApp({ kinds: ['send'] })]) {
    const card = reopenCard(app);
    card.update(OFFER);
    assert.equal(buttonNamed(card.el, 'Reopen all'), null);
    assert.match(card.el.textContent, /vibeswitcher reopen all/);
  }
});

test('C3 and C4: This node’s verdict counts the offers, each linking to its group', () => {
  const node = { notices: [], host: { state: 'connected' }, reopenOffer: OFFER, promptAudits: [{ project: 'site', folder: '/w/site', reason: 'interval', days: 15, ranBefore: true }] };
  const verdict = nodeVerdict(node);
  assert.equal(verdict.tone, 'asked');
  assert.deepEqual(verdict.parts.map((part) => [part.words, part.group]), [['3 sessions to reopen', 'reopen'], ['1 prompt audit due', 'audits']]);
  assert.equal(nodeVerdict({ notices: [], host: { state: 'connected' }, reopenOffer: null, promptAudits: [] }).tone, 'calm');
});

const AUDIT = { project: 'example-site', folder: '/home/dev/projects/example-site', session: 'local:7d3c9a10-4f6a-4c1e-9b7d-2e5a8c0d1f3b', reason: 'interval', days: 15, ranBefore: true };

test('C4: each audit due is a card saying why in the page’s words, with its buttons; none, no card', () => {
  for (const [code, run, snooze, off] of [['en', 'Run it in the lead', 'Remind me in a week', 'Not for this project'], ['es', 'Ejecutarla en el líder', 'Recordármelo en una semana', 'No para este proyecto']]) {
    setLanguage(code);
    const app = fakeApp();
    const cards = promptAuditCards(app);
    cards.update([]);
    assert.equal(cards.el.children.length, 0);
    cards.update([AUDIT]);
    assert.equal(findAll(cards.el, byClass('offer-card')).length, 1);
    assert.match(cards.el.textContent, new RegExp(t('paTitle', { project: 'example-site' })));
    assert.match(cards.el.textContent, code === 'en' ? /The last prompt audit here was 15 days ago\./ : /La última auditoría de prompts aquí fue hace 15 días\./);
    assert.doesNotMatch(cards.el.textContent, /vibeswitcher|\/doctor|\/home\//, 'no command or path where a person reads');
    assert.deepEqual(buttons(cards.el), [run, snooze, off]);
    assert.deepEqual(app.sent, []);
  }
  setLanguage('en');
  assert.equal(auditWhy({ reason: 'model', from: 'claude-opus-5', to: 'claude-opus-5-5' }), 'Its sessions now answer on claude-opus-5-5; the last prompt audit here was for claude-opus-5.');
  assert.equal(auditWhy({ reason: 'interval', days: 14, ranBefore: false }), 'No prompt audit seen here in the 14 days VibeSwitcher has known this project.');
});

test('C4: Remind me in a week and Not for this project send prompt-audit; Run it types the audit into the lead; each says what it did', async () => {
  const app = fakeApp({ reply: (kind, args) => (kind === 'send' ? { ok: true, result: { session: args.session } }
    : { ok: true, result: { project: 'example-site', root: args.folder, do: args.do, until: args.do === 'snooze' ? '2026-12-03T09:00:00.000Z' : null } }) });
  let changed = 0;
  const cards = promptAuditCards(app, { changed: () => { changed += 1; } });
  cards.update([AUDIT]);
  buttonNamed(cards.el, 'Remind me in a week').click();
  assert.deepEqual(app.sent.at(-1), { kind: 'prompt-audit', args: { folder: AUDIT.folder, do: 'snooze' } });
  await flush();
  assert.match(cards.el.textContent, /You’ll be reminded about example-site again on Dec 3, 2026/);
  cards.update([]);
  assert.match(cards.el.textContent, /You’ll be reminded/, 'still said once the node dropped it');
  buttonNamed(cards.el, 'OK').click();
  assert.equal(cards.el.children.length, 0);
  assert.equal(changed, 1);

  cards.update([AUDIT]);
  buttonNamed(cards.el, 'Not for this project').click();
  assert.deepEqual(app.sent.at(-1), { kind: 'prompt-audit', args: { folder: AUDIT.folder, do: 'off' } });
  await flush();
  assert.match(cards.el.textContent, /No more prompt audit reminders for example-site\./);
  buttonNamed(cards.el, 'OK').click();

  cards.update([{ ...AUDIT, days: 16 }]);
  buttonNamed(cards.el, 'Run it in the lead').click();
  assert.deepEqual(app.sent.at(-1), { kind: 'send', args: { session: AUDIT.session, text: PROMPT_AUDIT_COMMAND } });
  assert.equal(PROMPT_AUDIT_COMMAND, '/doctor prompt-audit');
  await flush();
  assert.match(cards.el.textContent, /Asked the lead of example-site to run it/);
});

test('C4: no Run it without its lead running or without send; no buttons where the page doesn’t act', () => {
  const noLead = promptAuditCards(fakeApp());
  noLead.update([{ ...AUDIT, session: null }]);
  assert.deepEqual(buttons(noLead.el), ['Remind me in a week', 'Not for this project']);
  assert.match(noLead.el.textContent, /Its lead isn’t running/);
  const noSend = promptAuditCards(fakeApp({ kinds: ['prompt-audit'] }));
  noSend.update([AUDIT]);
  assert.deepEqual(buttons(noSend.el), ['Remind me in a week', 'Not for this project']);
  const reads = promptAuditCards(fakeApp({ acts: false }));
  reads.update([AUDIT]);
  assert.equal(buttonNamed(reads.el, 'Remind me in a week'), null);
  assert.match(reads.el.textContent, /vibeswitcher prompt-audit \/home\/dev\/projects\/example-site snooze/);
});
