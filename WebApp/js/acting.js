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

// What the node's refusal says, in the page's words where the page knows the code.
export function refusalWords(error) {
  if (!error) return t('acRefused');
  if (error.code === 'changed') return t('acChanged');
  if (error.code === 'voice') return t('acVoice');
  if (error.code === 'acts-ended') return t('acEnded');
  if (error.code === 'not-yet') return t('acNotYet');
  return error.message || t('acRefused');
}

// A card's request: the card, the `seen` it was drawn with, and the kind's own arguments.
export const cardArgs = (card, args = {}) => ({ card: card.id, seen: card.seen ?? null, ...args });

// An answer to a question or an approval: its words and the version answered.
// A question's version answered; a plugin's card (a shell request's) has none, so none is sent.
export const answerArgs = (card, text) => cardArgs(card, { text, ...(card.question?.version != null ? { version: card.question.version } : {}) });

// A setting a page may not set even when it acts: web_acts raised (only off), a floor, the policy. The node refuses them
// (`voice`); the page shows their terminal line instead of a button.
export function pageMaySet(key, value) {
  if (key === 'policy' || /^floor_/.test(key)) return false;
  if (key === 'web_acts') return String(value).trim().toLowerCase() === 'off';
  return true;
}

// A button that sends `kind` with `args()` (a function, read at the click), disabled while it is out; `done(reply)` on
// success; the refusal said under it. Returns { el, button, say(text) }. `confirm`: a second click asked first
// ("Stop the node?"), for what can't be taken back.
export function doButton(app, { label, kind, args, done = () => {}, quiet = false, confirm = null, className = '' }) {
  const said = h('span', { class: 'act-said', role: 'status' });
  let asking = false;
  const button = h('button', { class: (quiet ? 'button quiet ' : 'button ') + className, type: 'button' }, label);
  const el = h('span', { class: 'act' }, button, said);
  button.addEventListener('click', () => {
    if (confirm && !asking) {
      asking = true;
      button.textContent = confirm;
      button.classList.add('confirming');
      setTimeout(() => { if (asking) { asking = false; button.textContent = label; button.classList.remove('confirming'); } }, 6000);
      return;
    }
    asking = false;
    button.classList.remove('confirming');
    button.textContent = label;
    button.disabled = true;
    setText(said, '');
    said.classList.remove('refused');
    app.store.request(kind, args()).then((reply) => {
      button.disabled = false;
      if (reply.ok) { done(reply); return; }
      setText(said, refusalWords(reply.error));
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
  // The node's level: off, confirm (a passkey per request, later), trust; `on` from a node before levels.
  const level = acts.level ?? (acts.on ? 'trust' : 'off');
  if (level === 'off') return compact ? null : h('p', { class: 'acts-line' }, t('acOffWords'), ' ', h('code', null, 'vibeswitcher set web_acts trust'), t('acOffWords2'));
  const since = acts.since ? new Date(acts.since).toLocaleString(undefined, { dateStyle: compact ? undefined : 'medium', timeStyle: 'short' }) : '';
  // A page waiting for the terminal's confirmation says so in its own banner (the phrase): nothing here meanwhile.
  if (!here && app.store.state.phrase) return null;
  // Acting is on but this page doesn't act (a reload lost its secret, or its acting ran out): pair it again.
  if (!here) return h(compact ? 'div' : 'p', { class: 'acts-line' + (compact ? ' compact' : '') }, h('span', null, t(compact ? 'acPairAgainShort' : 'acPairAgain', { since })), ' ', h('code', null, 'vibeswitcher web'));
  const words = t(compact ? 'acThisPageShort' : 'acThisPage', { since });
  const off = here && app.store.can('set') ? doButton(app, { label: t('acTurnOff'), kind: 'set', quiet: true, className: 'small', args: () => ({ key: 'web_acts', value: 'off' }) }).el : null;
  return h(compact ? 'div' : 'p', { class: 'acts-line' + (compact ? ' compact' : '') }, h('span', null, words), off);
}
