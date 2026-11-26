// What the node offers you as values of its own, each a card with its buttons (the no-terminal inventory's C3 and C4,
// 2026-11-26), on This node and, the reopen offer, on Your own sessions too:
//
// - The restart's reopen offer (`node.reopenOffer`): the sessions of yours a session host restart ended, by their names
//   and projects; Reopen all, Choose (some of them) and Not now (`session.reopen` with `all`, `sessions` or `forget`).
//   Nothing reopens without the click.
// - A prompt audit due (`node.promptAudits`, one card a project): why it's due; Run it in the lead (`send`, the
//   command typed into the lead's session, only when its lead runs and the page may send), Remind me in a week and Not
//   for this project (`prompt-audit` with `snooze` or `off`).
//
// Each says what happened in place once the node took it, and stays to say so after the node's value has gone (an
// OK puts it away): nothing disappears from under the pointer. While its request is out a card stays as it was drawn
// whatever the node sends meanwhile (the node takes the sessions out of its offer before it answers, so the value
// without them may come first), then draws what happened, or the node's refusal in the card, and the list holding it
// draws again. A page that doesn't act shows the line for a terminal.

import * as kit from '../kit.js';
import { h } from '../dom.js';
import { t } from '../i18n.js';
import { dateTime } from '../words.js';
import { actsFor, doButton, refusalWords } from '../acting.js';
import { copyLine } from './cards.js';
import { icon } from '../marks.js';

// What Claude Code runs for a prompt audit (`PromptAudit.command`), typed into the lead's session by Run it.
export const PROMPT_AUDIT_COMMAND = '/doctor prompt-audit';

// A card's frame: its icon and title over its words, its parts, then its buttons and what they did.
function frame(title, ...parts) {
  return h('section', { class: 'offer-card', 'aria-label': title },
    h('div', { class: 'offer-head' }, icon('warning', 14), kit.sectionTitle('h3', { class: 'offer-title' }, title)), ...parts);
}

// A card answered: what happened, with OK to put it away (the node's value is gone or going).
function answered(title, words, tone, dismiss) {
  return frame(title, h('p', { class: `offer-said ${tone}`, role: 'status' }, words),
    h('div', { class: 'offer-actions' }, kit.button('plain', { size: 's', onclick: dismiss }, t('ofOK'))));
}

// When the host restarted: at its time today, else on its day and time.
function whenWords(iso) {
  const at = new Date(iso);
  if (Number.isNaN(at.getTime())) return '';
  const today = new Date().toDateString() === at.toDateString();
  return today ? t('roAtTime', { time: dateTime(iso, { date: null }) }) : t('roOnDay', { day: dateTime(iso, { date: 'medium' }) });
}

// What a reopen did, in words: how many reopened and, when some didn't, how many and the first reason.
export function reopenedWords(result) {
  const reopened = result.reopened?.length || 0;
  const refused = result.refused || [];
  if (typeof result.forgotten === 'number') return t('roPutAway', { n: result.forgotten });
  const done = t('roReopened', { n: reopened });
  return refused.length ? `${done} ${t('roNotReopened', { n: refused.length, why: refused[0].why || '' })}` : done;
}

// The restart's reopen offer as a card: { el, update(offer), shown(), count() }. `el` is empty while there is none to
// show; `changed()` once a request it sent settled, and after an OK put an answered card away (a list that holds it
// draws again).
export function reopenCard(app, { changed = () => {} } = {}) {
  const el = h('div', { class: 'offer-slot' });
  let offer = null;
  let said = null;
  let choosing = false;
  // The choice just opened: it unfolds once (drawn again while open, it is simply there).
  let opening = false;
  let chosen = new Set();
  let key = '';
  // The requests out now, the node's offer last told meanwhile (undefined: none), and the node's last refusal.
  let out = 0;
  let latest;
  let refusal = '';
  const sending = (args) => () => { out += 1; refusal = ''; return args; };
  const settled = (reply) => {
    out -= 1;
    if (!reply.ok) refusal = refusalWords(reply.error);
    // Refused, the node gives the sessions back: an offer without them told meanwhile is already over.
    if (out === 0 && latest !== undefined && (reply.ok || latest)) take(latest);
    if (out === 0) latest = undefined;
    draw();
    changed();
  };

  const draw = () => {
    if (said) { el.replaceChildren(answered(said.title, said.words, said.tone, () => { said = null; draw(); changed(); })); return; }
    if (!offer) { el.replaceChildren(); return; }
    const sessions = offer.sessions;
    const title = t('roTitle', { n: sessions.length });
    const finish = (reply) => { said = { title, words: reopenedWords(reply.result || {}), tone: 'receipt' }; choosing = false; draw(); };
    const list = h('ul', { class: 'offer-list' }, sessions.map((one) => h('li', null, h('b', null, one.name),
      one.project && one.project !== one.name ? h('span', { class: 'offer-sub' }, one.project) : null)));
    const lede = h('p', { class: 'offer-words' }, t('roWords', { n: sessions.length, when: whenWords(offer.at) }));
    if (!actsFor(app, 'session.reopen')) {
      el.replaceChildren(frame(title, lede, list, h('div', { class: 'card-command' }, h('span', { class: 'card-command-label' }, t('noInATerminal')),
        copyLine('vibeswitcher reopen all', t('roTheCommand'))), h('p', { class: 'confirm-note' }, app.store.acts() ? t('roTerminalOnly') : t('roPageReads'))));
      return;
    }
    const all = doButton(app, { label: sessions.length === 1 ? t('roReopen') : t('roReopenAll'), kind: 'session.reopen', busy: t('roReopening'),
      args: sending({ all: true }), done: finish, settled });
    const later = doButton(app, { label: t('roNotNow'), kind: 'session.reopen', plain: true, args: sending({ forget: true }),
      done: (reply) => { said = { title, words: reopenedWords(reply.result || {}), tone: 'quiet' }; choosing = false; draw(); }, settled });
    const choose = sessions.length > 1 ? kit.button('plain', { 'aria-expanded': String(choosing),
      onclick: () => { choosing = !choosing; opening = choosing; chosen = new Set(); draw(); } }, choosing ? t('acCancel') : t('roChoose')) : null;
    let picker = null;
    if (choosing && sessions.length > 1) {
      const some = doButton(app, { label: t('roReopenChosen'), kind: 'session.reopen', busy: t('roReopening'),
        args: () => sending({ sessions: [...chosen] })(), done: finish, settled });
      some.button.disabled = chosen.size === 0;
      picker = kit.unfold({ class: 'offer-choose', motion: opening ? 'opening' : null }, h('ul', { class: 'offer-picks' }, sessions.map((one) => h('li', null, h('label', { class: 'offer-pick' },
        kit.checkbox({ checked: chosen.has(one.session), onchange: (event) => {
          if (event.target.checked) chosen.add(one.session); else chosen.delete(one.session);
          some.button.disabled = chosen.size === 0;
        } }), h('span', null, one.name), one.project && one.project !== one.name ? h('span', { class: 'offer-sub' }, one.project) : null)))), some.el);
      opening = false;
    }
    el.replaceChildren(frame(title, lede, choosing ? null : list, picker,
      refusal ? h('p', { class: 'offer-said refused', role: 'status' }, refusal) : null,
      h('div', { class: 'offer-actions' }, choosing ? null : all.el, choose, later.el)));
  };

  // The node's offer taken as the one to draw (null for none).
  function take(offered) {
    offer = offered;
    // A session reopened elsewhere leaves the choice.
    const ids = new Set((offer?.sessions || []).map((one) => one.session));
    chosen = new Set([...chosen].filter((one) => ids.has(one)));
    if (!offer) choosing = false;
  }

  return {
    el,
    // Draws `next` (the node's `reopenOffer`, null for none) when it says something else than the last one drawn.
    update(next) {
      const offered = next && Array.isArray(next.sessions) && next.sessions.length ? next : null;
      const now = JSON.stringify([offered, actsFor(app, 'session.reopen'), app.store.acts()]);
      if (now === key) return;
      key = now;
      // A request out: the card stays as it is until it settles.
      if (out > 0) { latest = offered; return; }
      take(offered);
      draw();
    },
    shown: () => !!(offer || said || out > 0),
    count: () => offer?.sessions.length || 0,
  };
}

// Why a project is due a prompt audit, in the page's words.
export function auditWhy(audit) {
  if (audit.reason === 'model') return t('paWhyModel', { from: audit.from || '', to: audit.to || '' });
  return audit.ranBefore ? t('paWhyLast', { n: audit.days ?? 0 }) : t('paWhyNever', { n: audit.days ?? 0 });
}

// What a prompt-audit change did, in words (`prompt-audit`'s reply: the project, what was done, until when).
export function auditChangedWords(result) {
  if (result.do === 'snooze') return t('paSnoozed', { project: result.project || '', until: result.until ? dateTime(result.until, { date: 'medium' }) : '' });
  if (result.do === 'off') return t('paTurnedOff', { project: result.project || '' });
  return t('paTurnedOn', { project: result.project || '' });
}

// The prompt audits due as cards, one a project: { el, update(audits), shown(), count() }.
export function promptAuditCards(app, { changed = () => {} } = {}) {
  const el = h('div', { class: 'offer-slot' });
  let audits = [];
  // What was done for each project's card, by its folder, kept until its OK; the node's refusal of a card's last click.
  const said = new Map();
  const refused = new Map();
  let key = '';
  // The requests out now, and the node's list last told meanwhile (undefined: none).
  let out = 0;
  let latest;
  // Each card drawn while a request is out, by its folder: kept (its button busy) until it settles.
  const kept = new Map();
  const sending = (audit, args) => () => { out += 1; refused.delete(audit.folder); kept.set(audit.folder, audit); return args; };
  const settledFor = (audit) => (reply) => {
    out -= 1;
    if (!reply.ok) refused.set(audit.folder, refusalWords(reply.error));
    if (out === 0) {
      if (latest !== undefined) audits = latest;
      latest = undefined;
      kept.clear();
    }
    draw();
    changed();
  };

  const card = (audit) => {
    const title = t('paTitle', { project: audit.project });
    const done = said.get(audit.folder);
    if (done) return answered(title, done.words, done.tone, () => { said.delete(audit.folder); draw(); changed(); });
    const words = [h('p', { class: 'offer-words' }, auditWhy(audit)), h('p', { class: 'confirm-note' }, t('paWhat'))];
    const answer = (tone) => (reply) => { said.set(audit.folder, { audit, words: tone === 'run' ? t('paAsked', { project: audit.project }) : auditChangedWords(reply.result || {}), tone: tone === 'run' ? 'receipt' : 'quiet' }); draw(); };
    if (!actsFor(app, 'prompt-audit')) {
      return frame(title, ...words, h('div', { class: 'card-command' }, h('span', { class: 'card-command-label' }, t('noInATerminal')),
        copyLine(`vibeswitcher prompt-audit ${audit.folder} snooze`, t('paTheCommand'))), h('p', { class: 'confirm-note' }, app.store.acts() ? t('paTerminalOnly') : t('paPageReads')));
    }
    const settled = settledFor(audit);
    const run = audit.session && actsFor(app, 'send')
      ? doButton(app, { label: t('paRun'), kind: 'send', busy: t('paRunning'), args: sending(audit, { session: audit.session, text: PROMPT_AUDIT_COMMAND }), done: answer('run'), settled }).el : null;
    const snooze = doButton(app, { label: t('paSnooze'), kind: 'prompt-audit', plain: !!run, args: sending(audit, { folder: audit.folder, do: 'snooze' }), done: answer('snooze'), settled }).el;
    const off = doButton(app, { label: t('paOff'), kind: 'prompt-audit', plain: true, args: sending(audit, { folder: audit.folder, do: 'off' }), done: answer('off'), settled }).el;
    const why = refused.get(audit.folder);
    return frame(title, ...words, run ? null : h('p', { class: 'confirm-note' }, t('paRunInLead')),
      why ? h('p', { class: 'offer-said refused', role: 'status' }, why) : null, h('div', { class: 'offer-actions' }, run, snooze, off));
  };

  function draw() {
    const shown = [...audits];
    // A card answered stays (its words) after the node's list dropped it; so does one whose request is out.
    for (const [folder, done] of said) if (!shown.some((one) => one.folder === folder)) shown.push(done.audit);
    for (const [folder, audit] of kept) if (!shown.some((one) => one.folder === folder)) shown.push(audit);
    el.replaceChildren(...shown.map(card));
  }

  return {
    el,
    update(next) {
      const list = Array.isArray(next) ? next.filter((one) => one && one.folder) : [];
      const now = JSON.stringify([list, actsFor(app, 'prompt-audit'), actsFor(app, 'send'), app.store.acts()]);
      if (now === key) return;
      key = now;
      // A request out: the cards stay as they are until it settles.
      if (out > 0) { latest = list; return; }
      audits = list;
      draw();
    },
    shown: () => audits.length > 0 || said.size > 0 || out > 0,
    count: () => audits.length,
  };
}
