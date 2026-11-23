// A session's terminal over the node's socket (the wire contract's §9, the live plan's slice 4): the binary frames and
// the stream's life, apart from the emulator that draws it (views/terminal.js), so tests/terminal.test.mjs runs it on a
// fake feed and a fake emulator.
//
// - Frames: one byte of type, four of stream (big-endian), the payload. From the node: 1, the session's bytes (its
//   replay first, then live); 2, the replay is over; 4, resync (what the page shows is stale, the replay comes again);
//   5, watching only, the session's size (columns and rows, 16 bits each, big-endian), before each replay. To the node:
//   1, input; 3, a resize (the same four bytes).
// - Opening: `term.open {session, cols, rows}` replies `{stream, readOnly}`. A connection whose `hello.kinds` lacks it,
//   or that answers `unknown-kind`, has no terminal: the pane says so and no emulator is made.
// - Watching (`readOnly`, the user's own node): the screen at the session's size (type 5), and nothing goes up: no
//   key, no resize. Typing into a real session is the user's voice, `vibeswitcher send` in a terminal.
// - Calm: a replay is held until its type 2 and only then drawn, over a reset emulator, in one go. A resync or a
//   reconnect leaves the old screen up until the new one is whole: nothing empties, nothing blinks.
// - Reconnecting: the node's streams go with the connection. The screen stays, the pane is marked, and after the next
//   `hello` the same session is opened again (a new stream, the whole replay).
// - Leaving: `term.close` as the pane is left or another session shown. A session that ended has no stream left on
//   the node (the sessions stream says it ended; no frame does), so nothing is sent for it.
import { t } from './i18n.js';


export const FRAME = { bytes: 1, replayed: 2, resize: 3, resync: 4, size: 5 };
// What the node takes (TerminalRelay.cols and rows).
export const COLS = { min: 10, max: 1000 };
export const ROWS = { min: 5, max: 300 };
// Input goes in frames of at most this many bytes: the node closes a connection on a client frame over 64 KiB.
export const INPUT_CHUNK = 16 * 1024;

const encoder = new TextEncoder();

// A frame: its type, its stream, its payload (bytes).
export function frame(type, stream, payload = new Uint8Array(0)) {
  const out = new Uint8Array(5 + payload.length);
  out[0] = type;
  new DataView(out.buffer).setUint32(1, stream >>> 0, false);
  out.set(payload, 5);
  return out;
}

// A frame from the node: `{ type, stream, payload }`, or null when it is too short to be one.
export function parseFrame(data) {
  const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
  if (bytes.length < 5) return null;
  const stream = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(1, false);
  return { type: bytes[0], stream, payload: bytes.subarray(5) };
}

// A size the node takes: whole numbers inside its ranges.
export function clampSize({ cols, rows }) {
  const fit = (value, { min, max }) => Math.min(max, Math.max(min, Math.floor(Number(value) || 0)));
  return { cols: fit(cols, COLS), rows: fit(rows, ROWS) };
}

// A resize frame for `stream`.
export function resizeFrame(stream, size) {
  const { cols, rows } = clampSize(size);
  const payload = new Uint8Array(4);
  const view = new DataView(payload.buffer);
  view.setUint16(0, cols, false);
  view.setUint16(2, rows, false);
  return frame(FRAME.resize, stream, payload);
}

// Input frames for `stream`: text as UTF-8, or bytes as they are, cut to INPUT_CHUNK.
export function inputFrames(stream, input) {
  const bytes = typeof input === 'string' ? encoder.encode(input) : input;
  const frames = [];
  for (let start = 0; start < bytes.length; start += INPUT_CHUNK) frames.push(frame(FRAME.bytes, stream, bytes.subarray(start, start + INPUT_CHUNK)));
  return frames;
}

function joined(chunks) {
  const total = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const out = new Uint8Array(total);
  let at = 0;
  for (const chunk of chunks) { out.set(chunk, at); at += chunk.length; }
  return out;
}

// The size in a type 5 frame's payload, inside the node's ranges; null when it isn't four bytes.
export function parseSize(payload) {
  if (payload.length !== 4) return null;
  const view = new DataView(payload.buffer, payload.byteOffset, 4);
  return clampSize({ cols: view.getUint16(0, false), rows: view.getUint16(2, false) });
}

// The stream's life for one pane. `feed`: the socket's (`request`, `sendBinary`, `onBinary`, `onLink`); `can(kind)`:
// the store's; `emulator`: `{ reset(), write(bytes), resize?(cols, rows) }`, made by the view only once the terminal
// can be shown. `state.readOnly`: the node's last open said the stream is watched; `state.size`, the session's size
// it drew at then (null otherwise).
//
// Phases: idle (nothing shown), unavailable (this connection has no terminal), opening, replaying, live,
// reconnecting (the connection dropped; the screen stays), gone (the node has no such session to show), failed.
export function createTerminal({ feed, can, log = (...args) => console.warn(...args) }) {
  const state = { phase: 'idle', session: null, stream: null, message: null, readOnly: false, size: null };
  const listeners = new Set();
  let emulator = null;
  let size = { cols: 80, rows: 24 };
  let replay = [];
  let watchedSize = null;   // the session's size from the replay under way (type 5), drawn at with it
  let drawnSession = null;   // the session whose screen the emulator shows (its last replay drawn), even stale
  let attempt = 0;       // the open in flight: a reply to an older one is late
  let nextId = 1;
  const offs = [];

  const usable = () => !!feed && typeof feed.sendBinary === 'function' && typeof feed.onBinary === 'function' && can('term.open');

  function set(phase, message = null) {
    const changed = state.phase !== phase || state.message !== message;
    state.phase = phase;
    state.message = message;
    if (changed) for (const fn of listeners) fn(state);
  }

  function request(kind, args) {
    return feed.request({ v: 1, id: 'term-' + nextId++, kind, args });
  }

  function open() {
    const mine = ++attempt;
    const session = state.session;
    replay = [];
    set('opening');
    request('term.open', { session, ...size }).then((reply) => {
      const late = mine !== attempt || state.session !== session;
      const stream = reply?.ok ? reply.result?.stream : null;
      if (late) {
        // Opened for a pane that moved on meanwhile: closed at once.
        if (Number.isInteger(stream)) request('term.close', { stream });
        return;
      }
      if (Number.isInteger(stream)) {
        state.stream = stream;
        state.readOnly = reply.result.readOnly === true;
        replay = [];
        // Watching: the session's size as the open found it (each replay's type 5 says it again).
        const { cols, rows } = reply.result;
        watchedSize = state.readOnly && Number.isInteger(cols) && Number.isInteger(rows) ? clampSize({ cols, rows }) : null;
        set('replaying');
        return;
      }
      const code = reply?.error?.code;
      if (code === 'unknown-kind') return set('unavailable');
      if (code === 'not-yet') return set('reconnecting');   // opened again after the next hello
      if (code === 'gone') return set('gone', reply.error.message || null);
      log('VibeSwitcher: the node refused a terminal:', reply?.error?.message);
      set('failed', reply?.error?.message || t('tmTheNodeDidnTOpen'));
    });
  }

  function received(data) {
    const parsed = parseFrame(data);
    if (!parsed || state.stream === null || parsed.stream !== state.stream) return;
    switch (parsed.type) {
      case FRAME.bytes:
        if (state.phase === 'replaying') replay.push(parsed.payload.slice());
        else if (state.phase === 'live') emulator?.write(parsed.payload);
        return;
      case FRAME.size:
        if (state.readOnly && state.phase === 'replaying') watchedSize = parseSize(parsed.payload);
        return;
      case FRAME.replayed:
        if (state.phase !== 'replaying') return;
        if (state.readOnly && watchedSize) {
          state.size = watchedSize;
          emulator?.resize?.(watchedSize.cols, watchedSize.rows);
        }
        emulator?.reset();
        emulator?.write(joined(replay));
        replay = [];
        drawnSession = state.session;
        return set('live');
      case FRAME.resync:
        // The screen stays until the new replay is whole.
        replay = [];
        watchedSize = null;
        return set('replaying');
      default:
    }
  }

  function linked(how) {
    if (how === 'down') {
      attempt += 1;
      state.stream = null;
      replay = [];
      if (state.session !== null && state.phase !== 'unavailable' && state.phase !== 'gone') set('reconnecting');
    } else if (how === 'up' && state.session !== null && (state.phase === 'reconnecting' || state.phase === 'opening')) {
      if (usable()) open(); else set('unavailable');
    }
  }

  if (feed && typeof feed.onBinary === 'function') offs.push(feed.onBinary(received));
  if (feed && typeof feed.onLink === 'function') offs.push(feed.onLink(linked));

  function leave({ ended = false } = {}) {
    attempt += 1;
    if (state.stream !== null && !ended) request('term.close', { stream: state.stream });
    state.stream = null;
    replay = [];
  }

  return {
    state,
    // Whether this connection can show a terminal at all (the view makes no emulator otherwise).
    available: usable,
    onChange(fn) { listeners.add(fn); return () => listeners.delete(fn); },
    // The emulator to draw into, once the view made one.
    attach(target) { emulator = target; },
    // Shows `session` at `cols` × `rows`: its stream opened (another session's closed first).
    show(session, at) {
      if (at) size = clampSize(at);
      if (state.session === session && state.phase !== 'idle' && state.phase !== 'failed') return;
      if (state.session !== session) leave();
      state.session = session;
      if (!usable()) return set('unavailable');
      open();
    },
    // The pane no longer shows it. `ended`: the session ended, and its stream with it on the node.
    hide({ ended = false } = {}) {
      leave({ ended });
      state.session = null;
      set('idle');
    },
    // The pane's new size, sent to the node when a stream is open that isn't watched.
    resize(at) {
      const next = clampSize(at);
      if (next.cols === size.cols && next.rows === size.rows) return;
      size = next;
      if (state.stream !== null && !state.readOnly) feed.sendBinary(resizeFrame(state.stream, size));
    },
    // Keys typed, as text (UTF-8) or bytes; dropped while no stream is open, and always while it is watched.
    input(data) {
      if (state.stream === null || state.readOnly || !data.length) return false;
      for (const each of inputFrames(state.stream, data)) if (!feed.sendBinary(each)) return false;
      return true;
    },
    // Whether the emulator shows `session`'s screen, if stale (a reconnect, a resync on its way, the pane shown again).
    drawn: (session) => session !== null && drawnSession === session,
    dispose() {
      leave();
      for (const off of offs) off?.();
      listeners.clear();
    },
  };
}
