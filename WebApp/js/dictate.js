// Push-to-talk dictation on the page (the parity table's row; the Mac's Dictation/): a hold-to-talk button beside the
// composer and the answer boxes. Held, the browser's own speech recognition (`SpeechRecognition`, Chrome's and
// Safari's) turns what you say into text in the box; let go, it stops. It fills the box only: nothing is sent, as
// nothing this page writes is ever sent but by you. Off until you turn it on on This node (kept in this browser): the
// browser sends your voice to its own speech service to recognise it (Chrome: Google's), which the page can't change.
// Where the browser has no speech recognition (Firefox) the button isn't there, and This node says so.

import { h } from './dom.js';
import { icon } from './marks.js';

const PREF = 'vibeswitcher.dictation';
const CHANGED = 'vibeswitcher-dictation';

// The browser's speech recognition, or null where it has none.
export function recognizer(env = globalThis) {
  return env.SpeechRecognition || env.webkitSpeechRecognition || null;
}

// Whether you turned dictation on in this browser.
export function dictationOn(storage = globalThis.localStorage) {
  try { return storage?.getItem(PREF) === 'on'; } catch { return false; }
}

export function setDictation(on, storage = globalThis.localStorage, target = globalThis) {
  try { storage?.setItem(PREF, on ? 'on' : 'off'); } catch { /* a private window: for this page only */ }
  target.dispatchEvent?.(new Event(CHANGED));
}

// `spoken` put into `value` where the selection was (`start` to `end`), a space between it and the words either side
// when they'd run together; the new value and where the caret goes.
export function insertSpoken(value, start, end, spoken) {
  const words = String(spoken || '').trim();
  if (!words) return { value, caret: end };
  const before = value.slice(0, start), after = value.slice(end);
  const left = before && !/\s$/.test(before) ? ' ' : '';
  const right = after && !/^\s/.test(after) ? ' ' : '';
  const next = before + left + words + right + after;
  return { value: next, caret: (before + left + words).length };
}

// The final words a recognition event carries from `from` on (interim ones are left for the next event).
export function finalWords(event) {
  const said = [];
  for (let index = event.resultIndex ?? 0; index < event.results.length; index++) {
    const result = event.results[index];
    if (result.isFinal) said.push(result[0].transcript);
  }
  return said.join(' ');
}

// The hold-to-talk button for `input` (a textarea or a text input), or null where the browser has no recognition.
// Hidden while dictation is off. Each final phrase goes into the box at the caret, with an `input` event so the box's
// own handlers (its height, its Draft button) see it. Never submits.
export function talkButton(input, env = {}) {
  const Recognition = recognizer(env.window || globalThis);
  if (!Recognition) return null;
  const storage = 'storage' in env ? env.storage : globalThis.localStorage;
  const target = env.window || globalThis;
  let listening = null;
  const button = h('button', { class: 'icon-button talk-button', type: 'button', title: 'Hold to dictate into this box (it sends nothing)',
    'aria-label': 'Hold to dictate', 'aria-pressed': 'false' }, icon('mic', 15));
  const show = () => { button.hidden = !dictationOn(storage); };
  show();
  target.addEventListener?.(CHANGED, show);

  function start(event) {
    event?.preventDefault?.();
    if (listening) return;
    const recognition = new Recognition();
    recognition.continuous = true;
    recognition.interimResults = true;
    recognition.lang = (env.window || globalThis).navigator?.language || 'en';
    recognition.onresult = (heard) => {
      const words = finalWords(heard);
      if (!words) return;
      const at = input.selectionStart ?? input.value.length, to = input.selectionEnd ?? at;
      const next = insertSpoken(input.value, at, to, words);
      input.value = next.value;
      input.setSelectionRange?.(next.caret, next.caret);
      input.dispatchEvent(new Event('input', { bubbles: true }));
    };
    recognition.onend = () => { if (listening === recognition) stop(); };
    recognition.onerror = () => stop();
    listening = recognition;
    button.classList.add('listening');
    button.setAttribute('aria-pressed', 'true');
    try { recognition.start(); } catch { stop(); }
  }

  function stop() {
    const recognition = listening;
    listening = null;
    button.classList.remove('listening');
    button.setAttribute('aria-pressed', 'false');
    try { recognition?.stop(); } catch { /* already stopped */ }
  }

  button.addEventListener('pointerdown', start);
  for (const name of ['pointerup', 'pointercancel', 'pointerleave', 'blur']) button.addEventListener(name, stop);
  button.addEventListener('keydown', (event) => { if ((event.key === ' ' || event.key === 'Enter') && !event.repeat) start(event); });
  button.addEventListener('keyup', (event) => { if (event.key === ' ' || event.key === 'Enter') stop(); });
  return button;
}

// This node's Dictation group: the toggle, what it sends where, or why there's none in this browser.
export function dictationGroup(env = {}) {
  const storage = 'storage' in env ? env.storage : globalThis.localStorage;
  const supported = Boolean(recognizer(env.window || globalThis));
  const box = h('input', { type: 'checkbox', class: 'dictation-toggle', disabled: !supported, onchange: () => setDictation(box.checked, storage, env.window || globalThis) });
  box.checked = supported && dictationOn(storage);
  return h('section', { class: 'node-group dictation' }, h('h2', { class: 'section-title' }, 'Dictation'),
    h('label', { class: 'notify-line' }, box, ' Hold the mic beside a message or an answer to dictate into it'),
    h('p', { class: 'node-says' }, supported
      ? 'Your browser turns your voice into text with its own speech service (Chrome sends it to Google). What you say only fills the box: nothing is sent.'
      : 'This browser has no speech recognition (Firefox hasn’t), so dictation is hidden here. Chrome, Edge and Safari have it.'));
}
