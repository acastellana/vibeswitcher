// Acting from the page (the redesign's "Acting from the page"): when the node gives this connection the `act` right
// (`web_acts` on, a page on this machine's loopback), a control sends the request itself, recorded as the user's; else
// it drafts and shows the terminal line, as before. A control is shown only for a kind `hello.kinds` lists.
//
// - `doButton`: a real button that sends one request, disabled while it is out, the node's refusal said in place
//   (a card that changed since the page drew it: "look again", nothing was done).
// - What a card's request carries: the card, the `seen` the page drew it with, the usual arguments, no code.
// - Which settings a page may not set even when it acts (the node refuses them by voice): they stay terminal lines.

import { h, setText } from './dom.js';
import { t } from './i18n.js';
import { dateTime } from './words.js';

// What the node's refusal says, in the page's words where the page knows the code. `what`: the control's own label,
// for a kind the node doesn't take from a page (a page shows no button for one, so this is a node that changed).
export function refusalWords(error, what = '') {
  if (!error) return t('acRefused');
  if (error.code === 'unknown-kind') return what ? t('acUnknownKind', { what }) : t('acUnknownKindBare');
  if (error.code === 'changed') return t('acChanged');
  if (error.code === 'voice') return t('acVoice');
  if (error.code === 'acts-ended') return t('acEnded');
  if (error.code === 'passkey') return t('acPasskeyFailed') + (error.message ? ` ${error.message}` : '');
  if (error.code === 'passkey-cancelled') return t('acPasskeyCancelled');
  if (error.code === 'assertion-needed') return t('acPasskeyNeeded');
  if (error.code === 'not-yet') return t('acNotYet');
  return error.message || t('acRefused');
}

// A card's request: the card, the `seen` it was drawn with, and the kind's own arguments.
export const cardArgs = (card, args = {}) => ({ card: card.id, seen: card.seen ?? null, ...args });

// An answer to a question or an approval: its words and the version answered.
// A question's version answered; a plugin's card (a shell request's) has none, so none is sent.
export const answerArgs = (card, text) => cardArgs(card, { text, ...(card.question?.version != null ? { version: card.question.version } : {}) });

// The settings a page may set when it acts: those the node's catalog marks `.sets` (`NodeSettings`' `page`), and
// web_acts lowered. Every other one the node keeps to a terminal (`terminalOnly`: lead_mail, verifier_model,
// security_audit_model, max_workers, the policy, the floors, and every plugin's setting) and refuses from a page by
// voice; a key the page doesn't know (a newer node's, a plugin's) is the terminal's too, so nothing is offered that the
// node would refuse. The node sends no setting's page rule yet (`settings`' `Setting` has no `page`): this list is it.
export const PAGE_SETS = new Set(['projects_folder', 'node_max_sessions', 'load_threshold', 'node_heavy_slots', 'ignore_usage_limits',
  'boost', 'boost_load_threshold', 'boost_max_sessions', 'boost_max_workers', 'boost_heavy_slots', 'prompt_audit', 'prompt_audit_days',
  'ai_summaries', 'lead_model', 'lead_advisor', 'worker_advisor', 'lead_rotation']);

export function pageMaySet(key, value) {
  if (key === 'web_acts') return ['off', 'confirm'].includes(String(value).trim().toLowerCase());
  return PAGE_SETS.has(key);
}

// A button that sends `kind` with `args()` (a function, read at the click), disabled while it is out; `done(reply)` on
// success; the refusal said under it. Returns { el, button, say(text) }. `confirm`: a second click asked first, in
// place ("Click again to stop the node", with Cancel beside it), for what can't be taken back; `danger`: drawn as
// what ends something, never as the page's primary button.
// `busy`: the button's words while the request is out ("Starting…").
// `receipt(reply)`: what happened, in words, said beside the button once the node took it.
export function doButton(app, { label, kind, args, done = () => {}, quiet = false, confirm = null, danger = false, className = '', busy = null, receipt = null }) {
  const said = h('span', { class: 'act-said', role: 'status' });
  let asking = false;
  let stopAsking = () => {};
  const button = h('button', { class: (quiet || danger ? 'button quiet ' : 'button ') + (danger ? 'danger ' : '') + className, type: 'button' }, label);
  const reset = () => { asking = false; stopAsking(); button.textContent = label; button.classList.remove('confirming'); cancel.hidden = true; };
  const cancel = h('button', { class: 'button quiet', type: 'button', hidden: true, onclick: () => { reset(); button.focus?.(); } }, t('acCancel'));
  const el = h('span', { class: 'act' }, button, cancel, said);
  const later = app.later || ((fn, ms) => { const timer = setTimeout(fn, ms); return () => clearTimeout(timer); });
  button.addEventListener('click', () => {
    if (confirm && !asking) {
      asking = true;
      button.textContent = confirm;
      button.classList.add('confirming');
      cancel.hidden = false;
      stopAsking = later(() => { if (asking) reset(); }, 6000);
      return;
    }
    reset();
    button.disabled = true;
    button.setAttribute('aria-busy', 'true');
    if (busy) button.textContent = busy;
    setText(said, '');
    said.classList.remove('refused', 'receipt');
    app.store.request(kind, args()).then((reply) => {
      button.disabled = false;
      button.removeAttribute('aria-busy');
      if (busy) button.textContent = label;
      if (reply.ok) {
        const words = receipt ? receipt(reply.result || {}) : '';
        if (words) { setText(said, words); said.classList.add('receipt'); }
        done(reply);
        return;
      }
      setText(said, refusalWords(reply.error, label));
      said.classList.add('refused');
    });
  });
  return { el, button, say: (text) => setText(said, text) };
}

// Whether the page acts for `kind` now: the node gave it `act` and lists the kind.
export const actsFor = (app, kind) => app.store.acts() && app.store.can(kind);

// Whether pages may act on this node and since when, in words, with the switch that turns it off from here (`set
// web_acts off`, the one value a page may set); null for a node from before acting. `compact`: the left column's
// one line.
export function actsLine(app, { compact = false } = {}) {
  const acts = app.store.state.node?.web?.acts;
  if (!acts) return null;
  const here = app.store.acts();
  // The node's level: off, confirm (a passkey per request), trust; `on` from a node before levels.
  const level = acts.level ?? (acts.on ? 'trust' : 'off');
  if (level === 'off') return compact ? null : h('p', { class: 'acts-line' }, t('acOffWords'), ' ', h('code', null, 'vibeswitcher set web_acts trust'), t('acOffWords2'));
  const since = acts.since ? dateTime(acts.since, { date: compact ? null : 'medium' }) : '';
  // A page waiting for the terminal's confirmation says so in its own banner (the phrase): nothing here meanwhile.
  if (!here && app.store.state.phrase) return null;
  // At confirm on another origin than the passkeys' (127.0.0.1): acting needs the localhost address.
  const elsewhere = level === 'confirm' && acts.passkeyOrigin && globalThis.location?.origin !== acts.passkeyOrigin;
  if (!here && elsewhere) {
    return h(compact ? 'div' : 'p', { class: 'acts-line' + (compact ? ' compact' : '') }, h('span', null, t('acPasskeyOrigin')), ' ',
      h('a', { class: 'link', href: acts.passkeyOrigin }, acts.passkeyOrigin), compact ? null : h('span', null, ' ', t('acPasskeyOriginRun'), ' '), compact ? null : h('code', null, 'vibeswitcher web --localhost'));
  }
  // Acting is on but this page doesn't act: the banner at the top of the centre says it (the footer says nothing).
  if (!here && compact) return null;
  // Acting is on but this page doesn't act (a reload lost its secret, or its acting ran out): pair it again.
  if (!here) return h(compact ? 'div' : 'p', { class: 'acts-line' + (compact ? ' compact' : '') }, h('span', null, t(compact ? 'acPairAgainShort' : 'acPairAgain', { since })), ' ', h('code', null, 'vibeswitcher web'));
  const words = level === 'confirm' ? t(compact ? 'acConfirmShort' : 'acConfirm', { since }) : t(compact ? 'acThisPageShort' : 'acThisPage', { since });
  const off = here && app.store.can('set') ? doButton(app, { label: t('acTurnOff'), kind: 'set', quiet: true, className: 'small', args: () => ({ key: 'web_acts', value: 'off' }) }).el : null;
  // From trust a page may lower acting to a passkey per action (never raise it).
  const lower = !compact && here && level === 'trust' && acts.passkeyOrigin && app.store.can('set')
    ? doButton(app, { label: t('acAskPasskey'), kind: 'set', quiet: true, className: 'small', args: () => ({ key: 'web_acts', value: 'confirm' }) }).el : null;
  // This page's words (its name, by which the terminal names it), on This node.
  const named = !compact && app.store.state.pageWords ? h('span', { class: 'page-words' }, ' ', t('pkThisPage'), ' ', h('strong', null, app.store.state.pageWords)) : null;
  return h(compact ? 'div' : 'p', { class: 'acts-line' + (compact ? ' compact' : '') }, h('span', null, words), named, lower, off);
}
