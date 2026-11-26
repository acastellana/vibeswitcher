// The page's components (the design review of 2026-11-25, D4 and its group B): each kind of control and label drawn
// one way everywhere. A view asks for one by its role and size; the class strings are made here and nowhere else, and
// style.css's Components section draws them (tests/components.test.mjs holds the views to it). Everything else a call
// passes (type, handlers, aria-*, a placement class in `class`) goes to the element as `h` takes it.
import { h } from './dom.js';
import { icon } from './marks.js';

// The three heights: s 24 (a small button, a tab), m 30 (a button, a field), l 36. A touch screen makes each 44.
const SIZES = { s: ' small', m: '', l: ' large' };
// A button's roles: the one main action (solid accent), a plain one (raised, a hairline), a quiet one (words in the
// accent, no surface until pointed at), and one that destroys (plain, in the danger colour).
const ROLES = { primary: '', plain: ' plain', quiet: ' quiet', danger: ' plain danger' };

const join = (...parts) => parts.filter(Boolean).join(' ');

function sized(size) {
  if (!(size in SIZES)) throw new Error(`no size ${size}`);
  return SIZES[size];
}

// The class a button of this role and size carries (a view that sets one later, as doButton's confirming does, asks here).
export function buttonClass(role = 'primary', size = 'm', extra = '') {
  if (!(role in ROLES)) throw new Error(`no button role ${role}`);
  return join(`button${ROLES[role]}${sized(size)}`, extra);
}

// A button: `button('plain', { size: 's', class: 'setting-change', onclick }, 'Change')`. `tag: 'a'` for a link drawn
// as a button (it navigates). Buttons are type="button" unless the call says otherwise.
export function button(role, { size = 'm', tag = 'button', class: extra = '', ...props } = {}, ...children) {
  return h(tag, { ...(tag === 'button' ? { type: 'button' } : {}), ...props, class: buttonClass(role, size, extra) }, ...children);
}

// A button that is only its icon (its words in aria-label and the tooltip): 30 px, or 24 with `size: 's'`. With no
// title of its own, its tooltip is its name, so a pointer finds what a screen reader hears (D25).
export function iconButton({ size = 'm', tag = 'button', class: extra = '', ...props } = {}, ...children) {
  const title = props.title ?? props['aria-label'];
  return h(tag, { ...(tag === 'button' ? { type: 'button' } : {}), ...props, ...(title ? { title } : {}), class: join(`icon-button${sized(size)}`, extra) }, ...children);
}

// A pick-one switch: its track, then each choice in it (a button that says it is chosen with aria-pressed, or a
// link with aria-current or aria-selected). `segmented({ tag: 'nav', 'aria-label': … }, segments)`.
export function segmented({ tag = 'div', class: extra = '', ...props } = {}, ...segments) {
  return h(tag, { ...props, class: join('segmented', extra) }, ...segments);
}
export function segment({ tag = 'button', class: extra = '', ...props } = {}, ...children) {
  return h(tag, { ...(tag === 'button' ? { type: 'button' } : {}), ...props, class: join('segment', extra) }, ...children);
}

// A text field (an input, or a textarea with `tag: 'textarea'`). Its kinds: plain, `search` (filled, as a list's
// search is), `code` (what is typed is a value a program reads: a path, a number, a flag).
const FIELDS = { plain: '', search: ' search', code: ' code' };
export function fieldClass(kind = 'plain', extra = '') {
  if (!(kind in FIELDS)) throw new Error(`no field kind ${kind}`);
  return join(`field${FIELDS[kind]}`, extra);
}
export function field({ tag = 'input', kind = 'plain', class: extra = '', ...props } = {}) {
  return h(tag, { ...props, class: fieldClass(kind, extra) });
}

// A dropdown: the browser's own <select> (its keyboard, its list, its screen reader), drawn as a field with the
// icons' chevron. Returns its frame, to place; the <select> itself is the frame's `control`. `wrap` is a placement
// class for the frame, `class` one for the select.
export function select({ kind = 'plain', class: extra = '', wrap = '', ...props } = {}, ...options) {
  const control = h('select', { ...props, class: fieldClass(kind, extra) }, ...options);
  const frame = h('span', { class: join('select', wrap) }, control, icon('chevron', 12));
  frame.control = control;
  return frame;
}

// A checkbox (or `type: 'radio'`): the browser's own, drawn in the field's edge and the accent.
export function checkbox({ class: extra = '', type = 'checkbox', ...props } = {}) {
  return h('input', { ...props, type, class: join('check', extra) });
}

// A badge at a row's end, or after a title: a count or a word. Its tones: neutral, asking (waits on you), working,
// done.
const TONES = { neutral: '', asking: ' asking', working: ' working', done: ' done' };
export function badgeClass(tone = 'neutral', extra = '') {
  if (!(tone in TONES)) throw new Error(`no badge tone ${tone}`);
  return join(`badge${TONES[tone]}`, extra);
}
export function badge(tone, text, { class: extra = '', ...props } = {}) {
  return h('span', { ...props, class: badgeClass(tone, extra) }, text);
}

// A number tile: the number on top, what it counts under it, a note under that; `tone: 'quiet'` greys the number,
// `'bad'` draws it in the danger colour. More parts (a meter, a day's bars) follow the words.
export function tile({ value, label, note = null, tone = '', help = '', class: extra = '' }, ...more) {
  return h('div', { class: join('tile', tone, extra), title: help || null },
    h('b', { class: 'tile-value' }, value), h('span', { class: 'tile-label' }, label), note ? h('small', { class: 'tile-note' }, note) : null, ...more);
}

// A section's title: small, strong, quiet, in sentence case. `tag` is its heading level.
export function sectionTitle(tag, { class: extra = '', ...props } = {}, ...children) {
  return h(tag, { ...props, class: join('section-title', extra) }, ...children);
}

// An empty state: what isn't here, said once. A page's or a pane's (`size: 'page'`, centred, with its title, a line
// and its button) or a list's (one line where the rows would be).
export function empty({ tag = 'div', size = 'list', class: extra = '', ...props } = {}, ...children) {
  if (size !== 'page' && size !== 'list') throw new Error(`no empty size ${size}`);
  return h(tag, { ...props, class: join('empty', size === 'page' ? 'page' : '', extra) }, ...children);
}
