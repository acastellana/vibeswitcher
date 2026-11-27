// The session view's Terminal pane: the session's screen in xterm.js (vendor/, at the exact version vendor/README.md
// names), fed by js/terminal.js over the node's socket. Only where the connection can open one; anywhere else the pane
// says to use the session's own terminal, and xterm.js isn't even loaded. On the user's own node the terminal is
// watched (the node's `readOnly`): drawn live at the session's own size, with no cursor and no keyboard, and a line
// saying where typing goes (`vibeswitcher send`, in a terminal: a page is never the user's voice).
//
// What the program in the session can't do from here (the live plan's Security): write the clipboard (OSC 52 is
// swallowed; xterm.js has no handler for it, and none is added), open a link (OSC 8 hyperlinks are swallowed and no link
// add-on is loaded: an address is text), set anything outside the pane (titles are swallowed; the bell only flashes the pane or
// plays a short tone, as this browser chose, throttled). What the emulator answers to a program's queries goes up as input and the node
// cuts it out (TerminalReplies): only the host's parser answers.
//
// The renderer is xterm.js's DOM one. It writes some of its CSS into <style> elements and a truecolor cell's colour into
// its style attribute, both of which the page's policy refuses (style-src 'self'): `takeXtermStyles` (js/xtermstyle.js)
// hands them to script-made CSS, which the policy doesn't govern, so the policy stays as it was and a terminal logs
// nothing. The text is xterm.js's, built from this file's options and colours the parser has already turned into
// numbers: nothing the program prints becomes CSS.
//
// Find in the terminal (P4): xterm.js's search add-on (vendor/, the same release as xterm.js) over the scrollback and the
// screen, every match highlighted and the current one stronger, next and previous, "3 of 12", Escape to close. ⌘F on a
// Mac; elsewhere Ctrl+Shift+F (Ctrl+F is the program's while you type into it), and Ctrl+F too where the page only
// watches. Only while this pane shows a terminal and the focus isn't in another field: anywhere else the key is the
// browser's own find. The highlights are decorations, xterm.js's proposed API, hence `allowProposedApi`: it widens what
// this file may call on the emulator, nothing a program in the session can do.
//
// Its look is this browser's (js/termlook.js, Settings › Terminal: the Mac's Appearance, its defaults): theme, font,
// size, cursor, colours, scrollback, Option as Meta, the bell (a flash of the pane, or a short tone, at most one a
// `BELL_GAP` ms). A change shows at once in an open terminal. Watching keeps its own cursor (an underline, still).

import * as kit from '../kit.js';
import { h, setText } from '../dom.js';
import { icon } from '../marks.js';
import { createTerminal, clampSize } from '../terminal.js';
import { takeXtermStyles } from '../xtermstyle.js';
import { look as terminalLook, onLook, xtermOptions } from '../termlook.js';
import { t } from '../i18n.js';
import { MAC } from '../words.js';

const darkQuery = globalThis.matchMedia?.('(prefers-color-scheme: dark)');
// How far apart two bells are at the most often (a program ringing in a loop rings this often).
const BELL_GAP = 400;
let lastBell = 0;
let tones = null;

function look() {
  const chosen = document.documentElement.dataset.theme;
  if (chosen === 'dark' || chosen === 'light') return chosen;
  return darkQuery?.matches ? 'dark' : 'light';
}

// xterm.js and its stylesheet, loaded once, the first time a terminal can be shown.
let loading = null;
function loadXterm() {
  if (!loading) {
    takeXtermStyles();
    document.head.append(h('link', { rel: 'stylesheet', href: new URL('../../vendor/xterm.css', import.meta.url).href }));
    loading = Promise.all([import('../../vendor/xterm.mjs'), import('../../vendor/addon-fit.mjs'), import('../../vendor/addon-search.mjs')])
      .then(([xterm, fit, search]) => ({ Terminal: xterm.Terminal, FitAddon: fit.FitAddon, SearchAddon: search.SearchAddon }));
  }
  return loading;
}

// Whether `event` asks for find in the terminal: ⌘F on a Mac; elsewhere Ctrl+Shift+F, or Ctrl+F where the keyboard
// isn't the program's (`typing`: the focus in a terminal you type into). 'next' and 'previous' for ⌘G and ⇧⌘G on a
// Mac, F3 and Shift+F3 elsewhere, once find is open. Null for any other key.
export function findKey(event, { mac = MAC, typing = false, open = false } = {}) {
  const key = (event.key || '').toLowerCase();
  if (event.altKey) return null;
  if (mac) {
    if (!event.metaKey || event.ctrlKey) return null;
    if (key === 'f' && !event.shiftKey) return 'open';
    if (key === 'g' && open) return event.shiftKey ? 'previous' : 'next';
    return null;
  }
  if (event.key === 'F3' && open && !event.ctrlKey && !event.metaKey) return event.shiftKey ? 'previous' : 'next';
  if (!event.ctrlKey || event.metaKey || key !== 'f') return null;
  return event.shiftKey || !typing ? 'open' : null;
}

// The page's keydown handler for find in a terminal: it acts only while `shown()` (a terminal drawn in a pane that shows)
// and the focus is in the pane or in nothing (the page's body). A key typed in another field, or with no terminal
// shown, is left alone: the browser's own find stays the browser's.
export function findKeys({ pane, screen, finder, shown, readOnly, mac = MAC }) {
  return (event) => {
    const bar = finder();
    if (!bar || !shown()) return;
    const target = event.target;
    const body = globalThis.document;
    if (target && !pane.contains(target) && target !== body?.body && target !== body?.documentElement && target !== body) return;
    const wanted = findKey(event, { mac, typing: !readOnly() && screen.contains(target), open: bar.shown() });
    if (!wanted) return;
    event.preventDefault();
    if (wanted === 'open') bar.open(); else bar.step(wanted === 'next' ? 1 : -1);
  };
}

// The decorations' colours (the page's `--highlight` yellow, the current match orange), as xterm.js takes them: hex.
export const FIND_COLOURS = {
  light: { match: '#FFD60080', active: '#FF9500CC' },
  dark: { match: '#FFC80052', active: '#FF9F0AB3' },
};
export function findDecorations(dark) {
  const { match, active } = FIND_COLOURS[dark ? 'dark' : 'light'];
  return { matchBackground: match, matchOverviewRuler: match, activeMatchBackground: active, activeMatchColorOverviewRuler: active };
}

// The find bar over a terminal: `search` is xterm.js's SearchAddon (or anything with its findNext, findPrevious,
// clearDecorations and onDidChangeResults), `dark` whether the terminal is dark now, `closed` what takes the focus
// back. Returns { el, open, close, step, shown }.
export function terminalFind({ search, dark = () => false, closed = () => {} }) {
  const input = kit.field({ kind: 'search', class: 'find-input', type: 'search', placeholder: t('teFindInTerminal'), 'aria-label': t('teFindInTerminal'),
    autocomplete: 'off', spellcheck: 'false' });
  const count = h('span', { class: 'find-count', role: 'status' });
  const el = h('div', { class: 'chat-find terminal-find', role: 'search', hidden: true }, icon('search', 13), input, count,
    kit.iconButton({ title: t('chPrevious'), 'aria-label': t('chPreviousMatch'), onclick: () => step(-1) }, icon('send', 12)),
    kit.iconButton({ title: t('chNext'), 'aria-label': t('chNextMatch'), onclick: () => step(1) }, icon('down', 12)),
    kit.iconButton({ title: t('chCloseEsc'), 'aria-label': t('chCloseFind'), onclick: () => close() }, icon('close', 12)));
  const options = (incremental = false) => ({ incremental, decorations: findDecorations(dark()) });
  // What the add-on says after each search: which match is shown and how many there are (it counts up to 1000).
  let results = null;
  search.onDidChangeResults?.((event) => { results = event; say(); });
  function say() {
    const query = input.value;
    if (!query) return setText(count, '');
    if (!results || !results.resultCount) return setText(count, t('chNoMatches'));
    const of = results.resultCount >= 1000 ? '1000+' : String(results.resultCount);
    setText(count, results.resultIndex >= 0 ? t('chOf', { a: results.resultIndex + 1, b: of }) : of);
  }
  function find() {
    results = null;
    if (!input.value) { search.clearDecorations(); say(); return; }
    search.findNext(input.value, options(true));
    say();
  }
  function step(by) {
    if (!input.value) return;
    if (by < 0) search.findPrevious(input.value, options()); else search.findNext(input.value, options());
    say();
  }
  function open() {
    el.hidden = false;
    input.focus();
    input.select?.();
    if (input.value) find();
  }
  // `refocus`: the focus back where typing goes (not when the pane itself is going).
  function close({ refocus = true } = {}) {
    if (el.hidden) return;
    el.hidden = true;
    results = null;
    search.clearDecorations();
    setText(count, '');
    if (refocus) closed();
  }
  input.addEventListener('input', find);
  input.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') { event.preventDefault(); step(event.shiftKey ? -1 : 1); }
    else if (event.key === 'Escape') { event.preventDefault(); event.stopPropagation?.(); close(); }
  });
  return { el, open, close, step, input, shown: () => !el.hidden };
}

export function terminalView(app) {
  const { store, ui, feed } = app;
  const control = createTerminal({ feed, can: (kind) => store.can(kind) });

  const screen = h('div', { class: 'terminal-screen' });
  const note = h('p', { class: 'terminal-note', role: 'status' });
  const watching = h('p', { class: 'terminal-watching', hidden: true },
    icon('eye', 13), h('span', null, t('teWatchingToTypeIntoThis')), h('code', null, 'vibeswitcher send'),
    h('span', null, t('teInATerminal')));
  const says = h('p');
  const showChat = kit.button('plain', { onclick: () => ui.setPane(ui.state.route.id, 'chat') }, t('teShowChat'));
  const retry = kit.button('plain', { hidden: true, onclick: () => { const session = shown; control.hide(); show(session); } }, t('teTryAgain'));
  const heading = h('h2', null, t('teTerminal'));
  const placeholder = kit.empty({ size: 'page', class: 'placeholder' }, icon('terminal', 22), heading, says, showChat, retry);
  // Find (P4): its bar over the screen once the emulator is made; until then nothing to find in.
  const findSlot = h('div', { class: 'terminal-find-slot' });
  const el = h('div', { class: 'pane terminal-pane' }, findSlot, screen, note, watching, placeholder);

  let term = null;     // the emulator, once made
  let fit = null;
  let finder = null;
  let making = null;
  let shown = null;    // the session the pane shows
  let visible = false;
  let ended = false;

  function sizeNow() {
    const proposed = fit?.proposeDimensions();
    return proposed && Number.isFinite(proposed.cols) && Number.isFinite(proposed.rows) ? proposed : { cols: 80, rows: 24 };
  }

  function make() {
    if (!making) {
      making = loadXterm().then(({ Terminal, FitAddon, SearchAddon }) => {
        term = new Terminal({
          ...xtermOptions(terminalLook(), look() === 'dark'), lineHeight: 1.2,
          // Proposed API for the search add-on's highlights (decorations) only: the page's code, never the program's.
          cursorInactiveStyle: 'outline', allowProposedApi: true, minimumContrastRatio: 1, linkHandler: null,
          drawBoldTextInBrightColors: false, rightClickSelectsWord: false,
        });
        term.onBell(() => ring());
        // The program's reach ends at the pane: no clipboard (52), no link (8), no title (0, 1, 2).
        for (const code of [0, 1, 2, 8, 52]) term.parser.registerOscHandler(code, () => true);
        fit = new FitAddon();
        term.loadAddon(fit);
        const search = new SearchAddon();
        term.loadAddon(search);
        finder = terminalFind({ search, dark: () => look() === 'dark', closed: () => { if (!control.state.readOnly) term.focus(); } });
        findSlot.replaceChildren(finder.el);
        term.open(screen);
        term.onData((data) => control.input(data));
        // Bytes the emulator makes as such (an old mouse mode's reports): one byte per character.
        term.onBinary((data) => control.input(Uint8Array.from(data, (character) => character.charCodeAt(0) & 0xff)));
        // A Mac's ⌘ keys stay the page's and the browser's; elsewhere the terminal has the keyboard (app.js), but for
        // find's Ctrl+Shift+F (and F3 while find is open).
        term.attachCustomKeyEventHandler((event) => !event.metaKey && !findKey(event, { typing: true, open: !!finder?.shown() }));
        control.attach({
          reset: () => term.reset(), write: (bytes) => term.write(bytes),
          // Watching: the session's own size, whatever the pane's (the pane scrolls when it is wider).
          resize: (cols, rows) => { if (cols !== term.cols || rows !== term.rows) term.resize(cols, rows); },
        });
        new ResizeObserver(() => refit()).observe(screen);
        return term;
      });
    }
    return making;
  }

  let refitting = false;
  function refit() {
    if (!term || refitting || !visible) return;
    refitting = true;
    requestAnimationFrame(() => {
      refitting = false;
      if (!term || !visible || screen.clientWidth === 0 || control.state.readOnly) return;
      const next = clampSize(sizeNow());
      if (next.cols !== term.cols || next.rows !== term.rows) term.resize(next.cols, next.rows);
      control.resize(next);
    });
  }

  // The look, applied again: the page's light or dark changed, or this browser's preferences did.
  function restyle() {
    if (!term) return;
    const options = xtermOptions(terminalLook(), look() === 'dark');
    const watched = !!term.options.disableStdin;
    for (const [name, value] of Object.entries(options)) {
      if (watched && (name === 'cursorStyle' || name === 'cursorBlink')) continue;
      term.options[name] = value;
    }
    refit();
  }
  darkQuery?.addEventListener?.('change', restyle);
  new MutationObserver(restyle).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
  onLook(restyle);

  // The bell, as this browser's look says: a flash of the pane, a short tone, or nothing; one a `BELL_GAP` at most.
  function ring() {
    const bell = terminalLook().bell;
    const now = Date.now();
    if (bell === 'none' || now - lastBell < BELL_GAP) return;
    lastBell = now;
    if (bell === 'visual') {
      el.classList.remove('is-bell');
      void el.offsetWidth;
      el.classList.add('is-bell');
      setTimeout(() => el.classList.remove('is-bell'), 300);
      return;
    }
    try {
      tones ??= new AudioContext();
      const tone = tones.createOscillator();
      const gain = tones.createGain();
      gain.gain.setValueAtTime(0.08, tones.currentTime);
      gain.gain.exponentialRampToValueAtTime(0.0001, tones.currentTime + 0.12);
      tone.frequency.value = 880;
      tone.connect(gain).connect(tones.destination);
      tone.start();
      tone.stop(tones.currentTime + 0.12);
    } catch { /* no sound here */ }
  }

  function draw() {
    const phase = control.state.phase;
    const chatFollowed = store.can('chat.page');
    const session = shown ? store.state.sessions.get(shown) : null;
    const elsewhere = session && session.hosted === false;
    const unavailable = phase === 'unavailable' || (!control.available() && !term);
    let words = null;
    if (unavailable || elsewhere) {
      setText(heading, t('teTerminal'));
      words = elsewhere
        ? t('teOtherTerminal', { terminal: session.terminal || t('teNotHost') })
        : !store.watches() ? t('teNeedsWatch')
        : chatFollowed ? t('teTheLiveTerminalComesTo')
          : t('teTheLiveTerminalComesTo2');
    } else if (phase === 'gone') {
      setText(heading, t('teNoTerminalForThisSession'));
      words = control.state.message || t('teTheNodeSHostDoesn');
    } else if (phase === 'failed') {
      setText(heading, t('teTheTerminalDidnTOpen'));
      words = control.state.message;
    }
    const drawn = control.drawn(shown);
    placeholder.hidden = words === null;
    if (words !== null) setText(says, words);
    showChat.hidden = !chatFollowed || (words === null);
    retry.hidden = phase !== 'failed';
    // The screen stays up while it is this session's, even stale (a reconnect, a resync): the note says so.
    screen.hidden = words !== null || !drawn;
    const noting = words === null && (ended ? t('teThisSessionEnded')
      : !drawn ? t('teOpeningTheTerminal')
        : phase === 'reconnecting' ? t('teReconnecting') : null);
    note.hidden = !noting;
    if (noting) setText(note, noting);
    el.classList.toggle('is-stale', words === null && drawn && (phase === 'reconnecting' || ended));
    el.classList.toggle('is-waiting', words === null && !drawn);
    const watched = words === null && control.state.readOnly;
    el.classList.toggle('is-watching', watched);
    watching.hidden = !(watched && drawn && !ended);
    if (term) {
      term.options.disableStdin = watched;
      term.options.cursorStyle = watched ? 'underline' : terminalLook().cursorShape;
      term.options.cursorBlink = watched ? false : terminalLook().cursorBlink;
      term.options.cursorInactiveStyle = watched ? 'none' : 'outline';
      if (watched && screen.contains(document.activeElement)) term.blur();
    }
  }
  control.onChange(() => { draw(); if (control.state.phase === 'live') refit(); });

  // Find's keys, while this pane shows a terminal (the screen up, the pane in the page and not hidden).
  document.addEventListener('keydown', findKeys({ pane: el, screen, finder: () => finder, readOnly: () => control.state.readOnly,
    shown: () => visible && !screen.hidden && el.isConnected && !el.hidden && !el.closest('[hidden]') }));

  function show(session) {
    const value = store.state.sessions.get(session);
    if (shown !== session) ended = false;
    shown = session;
    visible = true;
    if (value?.ended) {
      if (!ended) { ended = true; control.hide({ ended: true }); }
      return draw();
    }
    if (value?.hosted === false || !control.available()) {
      control.hide();
      return draw();
    }
    make().then(() => {
      if (shown !== session || !visible) return;
      if (!control.drawn(session)) term.reset();
      const size = clampSize(sizeNow());
      if (!control.state.readOnly && (size.cols !== term.cols || size.rows !== term.rows)) term.resize(size.cols, size.rows);
      control.show(session, size);
      draw();
    });
    draw();
  }

  return {
    el,
    // The pane shows `session` (an id the store holds).
    show,
    // The pane is hidden, or its session is gone: the stream closed (`ended`: the node closed it already).
    hide({ gone = false } = {}) {
      visible = false;
      finder?.close({ refocus: false });
      if (control.state.session !== null || control.state.phase !== 'idle') control.hide({ ended: gone || ended });
      if (gone) shown = null;
    },
    focus() { if (term && !screen.hidden && !control.state.readOnly) term.focus(); },
  };
}
