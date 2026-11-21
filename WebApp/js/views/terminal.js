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
// Its look is this browser's (js/termlook.js, Settings › Terminal: the Mac's Appearance, its defaults): theme, font,
// size, cursor, colours, scrollback, Option as Meta, the bell (a flash of the pane, or a short tone, at most one a
// `BELL_GAP` ms). A change shows at once in an open terminal. Watching keeps its own cursor (an underline, still).

import { h, setText } from '../dom.js';
import { icon } from '../marks.js';
import { createTerminal, clampSize } from '../terminal.js';
import { takeXtermStyles } from '../xtermstyle.js';
import { look as terminalLook, onLook, xtermOptions } from '../termlook.js';

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
    loading = Promise.all([import('../../vendor/xterm.mjs'), import('../../vendor/addon-fit.mjs')])
      .then(([xterm, fit]) => ({ Terminal: xterm.Terminal, FitAddon: fit.FitAddon }));
  }
  return loading;
}

export function terminalView(app) {
  const { store, ui, feed } = app;
  const control = createTerminal({ feed, can: (kind) => store.can(kind) });

  const screen = h('div', { class: 'terminal-screen' });
  const note = h('p', { class: 'terminal-note', role: 'status' });
  const watching = h('p', { class: 'terminal-watching', hidden: true },
    icon('eye', 13), h('span', null, 'Watching. To type into this session, run '), h('code', null, 'vibeswitcher send'),
    h('span', null, ' in a terminal.'));
  const says = h('p');
  const showChat = h('button', { class: 'button quiet', type: 'button', onclick: () => ui.setPane(ui.state.route.id, 'chat') }, 'Show Chat');
  const retry = h('button', { class: 'button quiet', type: 'button', hidden: true, onclick: () => { const session = shown; control.hide(); show(session); } }, 'Try Again');
  const heading = h('h2', null, 'Terminal');
  const placeholder = h('div', { class: 'placeholder' }, icon('terminal', 22), heading, says, showChat, retry);
  const el = h('div', { class: 'pane terminal-pane' }, screen, note, watching, placeholder);

  let term = null;     // the emulator, once made
  let fit = null;
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
      making = loadXterm().then(({ Terminal, FitAddon }) => {
        term = new Terminal({
          ...xtermOptions(terminalLook(), look() === 'dark'), lineHeight: 1.2,
          cursorInactiveStyle: 'outline', allowProposedApi: false, minimumContrastRatio: 1, linkHandler: null,
          drawBoldTextInBrightColors: false, rightClickSelectsWord: false,
        });
        term.onBell(() => ring());
        // The program's reach ends at the pane: no clipboard (52), no link (8), no title (0, 1, 2).
        for (const code of [0, 1, 2, 8, 52]) term.parser.registerOscHandler(code, () => true);
        fit = new FitAddon();
        term.loadAddon(fit);
        term.open(screen);
        term.onData((data) => control.input(data));
        // Bytes the emulator makes as such (an old mouse mode's reports): one byte per character.
        term.onBinary((data) => control.input(Uint8Array.from(data, (character) => character.charCodeAt(0) & 0xff)));
        // A Mac's ⌘ keys stay the page's and the browser's; elsewhere the terminal has the keyboard (app.js).
        term.attachCustomKeyEventHandler((event) => !event.metaKey);
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
      setText(heading, 'Terminal');
      words = elsewhere
        ? `This session runs in another terminal (${session.terminal || 'not the host'}): its screen is there.`
        : chatFollowed ? 'The live terminal comes to this page in a later build. Until then, the session’s conversation is in Chat.'
          : 'The live terminal comes to this page in a later build.';
    } else if (phase === 'gone') {
      setText(heading, 'No terminal for this session');
      words = control.state.message || 'The node’s host doesn’t run this session.';
    } else if (phase === 'failed') {
      setText(heading, 'The terminal didn’t open');
      words = control.state.message;
    }
    const drawn = control.drawn(shown);
    placeholder.hidden = words === null;
    if (words !== null) setText(says, words);
    showChat.hidden = !chatFollowed || (words === null);
    retry.hidden = phase !== 'failed';
    // The screen stays up while it is this session's, even stale (a reconnect, a resync): the note says so.
    screen.hidden = words !== null || !drawn;
    const noting = words === null && (ended ? 'This session ended.'
      : !drawn ? 'Opening the terminal…'
        : phase === 'reconnecting' ? 'Reconnecting…' : null);
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
      if (control.state.session !== null || control.state.phase !== 'idle') control.hide({ ended: gone || ended });
      if (gone) shown = null;
    },
    focus() { if (term && !screen.hidden && !control.state.readOnly) term.focus(); },
  };
}
