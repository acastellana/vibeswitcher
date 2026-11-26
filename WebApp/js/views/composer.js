// The one message box (the design reviews' U9 and D9): the lead's, a session's and a card's answer box are this, with
// one behaviour.
//
// - Enter sends (the way the caller's state gives: send, steer or queue, the button's word saying which); Shift+Enter
//   is a new line; ⌥Enter sends for after the turn and ⌘Enter / Ctrl+Enter now, where the agent takes those; Escape
//   leaves the box. An input method's Enter while it composes never sends. On a touch screen the soft keyboard's Enter
//   is a new line and Send is the button (a phone's keyboard has no Shift+Enter).
// - The box grows with its lines up to `MAX_HEIGHT`, then scrolls inside; a paste keeps its lines.
// - What you typed and didn't send is kept per box (a session's, a lead's, a card's: `setKey`) in this tab
//   (sessionStorage, which may refuse: then for this page only), across navigation and a reload.
// - A send the node refused says why beside the box, with Try again; the words go back in the box if it is empty.
// The caller sends (`onSend(way, text)`, returning the request's promise or nothing): only what it sends today, by its
// own path.

import { h, setText, setClass } from '../dom.js';
import { icon } from '../marks.js';
import { t } from '../i18n.js';

// The box's tallest before it scrolls inside (about nine lines at the reading size).
export const MAX_HEIGHT = 200;
const KEPT = 'vibeswitcher.composer.';

// A touch screen's soft keyboard: Enter is a new line there. Asked at each key, as a tablet's keyboard comes and goes.
export const softKeyboard = () => !!globalThis.matchMedia?.('(hover: none) and (pointer: coarse)')?.matches;

// What a key does in the box: 'send' (Enter), 'after' (⌥Enter), 'now' (⌘Enter, Ctrl+Enter), 'leave' (Escape), or null:
// the browser's own (a new line with Shift, any Enter on a soft keyboard, every key while an input method composes).
export function keyAction(event, { soft = false } = {}) {
  // Safari ends a composition with an Enter whose keyCode is 229 and isComposing already false.
  if (event.isComposing || event.keyCode === 229) return null;
  if (event.key === 'Escape') return 'leave';
  if (event.key !== 'Enter' || event.shiftKey || soft) return null;
  if (event.altKey) return 'after';
  if (event.metaKey || event.ctrlKey) return 'now';
  return 'send';
}

function kept(storage, key) {
  try { return (key && storage?.getItem(KEPT + key)) || ''; } catch { return ''; }
}
function keep(storage, key, text) {
  if (!key) return;
  try { if (text) storage?.setItem(KEPT + key, text); else storage?.removeItem(KEPT + key); } catch { /* refused: this page only */ }
}

// Returns { el, input, button, notice, key, value, setMode, setKey, grow, clear, focus, sent, refused }.
// `className`, `inputClass`: the form's and the box's (the session's `composer`, a card's `answer`); `before` and
// `after`: what sits either side of the box (the + button, push-to-talk); `button`: a caller's own submit button (a
// card's Answer), else Send with its word; `menu`: the ways menu's element (views/sendmenu.js), after Send;
// `beforeKey(event)`: the caller's keys first (`/` and `@` completion), true when it took the key.
export function composer({
  className = 'composer', inputClass = 'composer-input', label, placeholder = '', maxLength = null, before = [], after = [],
  button = null, menu = null, onSend = () => {}, beforeKey = () => false, onInput = () => {},
  storage = globalThis.sessionStorage, soft = softKeyboard, leave = null,
}) {
  const input = h('textarea', {
    class: inputClass, rows: 1, 'aria-label': label, placeholder, maxlength: maxLength, enterkeyhint: soft() ? 'enter' : 'send',
    autocomplete: 'off',
  });
  const word = h('span', { class: 'send-word' }, t('swSend'));
  const send = button || h('button', { class: 'send labelled', type: 'submit', disabled: true }, icon('send', 14), word);
  const retry = h('button', { class: 'link composer-retry', type: 'button', hidden: true }, t('cmRetry'));
  const noticeText = h('span');
  const notice = h('p', { class: 'composer-notice', role: 'status', hidden: true }, noticeText, retry);
  const el = h('form', { class: className }, before, input, after, send, menu);
  let key = null;
  let mode = { word: t('swSend'), title: '', way: 'send', disabled: false };
  let failed = null;
  let empty = () => !input.value.trim();

  function grow() {
    input.style.height = 'auto';
    input.style.height = Math.min(input.scrollHeight, MAX_HEIGHT) + 'px';
    if (!button) send.disabled = mode.disabled || empty();
  }
  function say(text, again = null) {
    notice.hidden = !text;
    setText(noticeText, text || '');
    retry.hidden = !again;
    retry.onclick = again;
    setClass(notice, 'refused', !!again);
  }
  function go(way) {
    const text = input.value.trim();
    if (mode.disabled || empty()) return;
    failed = null;
    say('');
    const asked = onSend(way === 'send' ? mode.way : way, text);
    if (asked && typeof asked.then === 'function') {
      if (!button) { send.setAttribute('aria-busy', 'true'); }
      asked.finally?.(() => { if (!button) send.removeAttribute('aria-busy'); });
    }
  }

  input.addEventListener('keydown', (event) => {
    if (beforeKey(event)) return;
    const action = keyAction(event, { soft: soft() });
    if (!action) return;
    if (action === 'leave') {
      if (leave) leave(event); else input.blur();
      return;
    }
    event.preventDefault();
    go(action);
  });
  input.addEventListener('input', () => { keep(storage, key, input.value); grow(); onInput(); });
  el.addEventListener('submit', (event) => { event.preventDefault(); go('send'); });

  const api = {
    el, input, button: send, notice,
    get key() { return key; },
    get value() { return input.value; },
    set value(text) { input.value = text; keep(storage, key, text); grow(); },
    // What Enter and the button do now: `{ word, title, way, disabled }` (the word: Send, Steer, Queue, Leave a draft).
    setMode(next) {
      mode = { ...mode, ...next };
      if (!button) {
        setText(word, mode.word);
        send.title = mode.title || mode.word;
        send.setAttribute('aria-label', mode.title || mode.word);
      }
      grow();
    },
    // Another box's words: what this one held stays kept under its key, the other's come back.
    setKey(next) {
      if (next === key) return;
      key = next;
      input.value = kept(storage, key);
      failed = null;
      say('');
      grow();
    },
    grow,
    say,
    // Sent: the box empties (and what it kept).
    clear() { input.value = ''; keep(storage, key, ''); grow(); },
    focus(options) { input.focus(options); },
    // The node refused: why, beside the box, with Try again; the words back in it if it's empty.
    refused(why, text, again) {
      failed = { text };
      if (!input.value.trim() && text) { input.value = text; keep(storage, key, text); }
      grow();
      say(why, again ? () => { say(''); again(); } : null);
    },
    get failed() { return failed; },
    setEmpty(fn) { empty = fn; grow(); },
  };
  return api;
}
