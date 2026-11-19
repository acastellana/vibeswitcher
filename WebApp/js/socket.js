// The node's live feed over its WebSocket (the wire contract, docs/superpowers/specs/2026-11-17-v2-live-wire-contract.md
// §2 to §4 and §10), in mock.js's place: the same four calls for the store (README.md, "The feed").
//
// - Pairing: the address `vibeswitcher web` prints carries a one-time code in its fragment (`#pair=…`). It is taken
//   off the address bar at once, sent in the first frame, and exchanged for a token the tab keeps (sessionStorage:
//   this origin's, this tab's) and sends on every later connection.
// - Following: one subscription per collection the page shows (node, sessions, leads, cards), each with the `seq` it
//   holds. Per subscription, the contract's four rows: a snapshot is reconciled by id; a delta whose `prev` is ours is
//   applied; one already held is dropped; anything else applies nothing and subscribes again with `since`.
// - Reconnecting: every row stays as it is, the page shows a quiet mark, and the socket is opened again at 100, 200,
//   400 ms, then every second. After the next `hello` each subscription asks to resume from its `seq`: the server
//   sends what changed, or a snapshot when it can't (a restart), which is reconciled. Nothing empties, nothing blinks.
// - Chats: one subscription per chat the page shows (`chat`, keyed by the session), its snapshot the newest items and
//   its deltas ops (the contract §6). A `text` op whose `at` isn't the length this page holds is a gap: nothing of
//   that delta is applied, and the chat is asked again for a tail from that item. Shown again after a while, or after a
//   reconnect, a chat asks to resume from its `seq` and, across a restart, for a tail from its last item (`after`):
//   nothing lost, nothing twice. Older items come with `chat.page`, as the view scrolls up to them.
// - Trust: every frame goes through the validators generated from the node's own encoders (wire/validators.js) before
//   anything reads it; a frame that fails is dropped and said in the console.
// - Actions (the contract's §8): a request with an action id is sent again after a reconnect with the same id, and
//   `reached(collection, seq)` tells the store when a subscription holds an ack's `applied`, so an overlay is dropped
//   only once the stream shows what it stood for.
//
// Everything it touches is passed in, so tests/socket.test.mjs scripts it with a fake socket and clock.

import { session as sessionValue, leadsBySession } from './wire.js';

const COLLECTIONS = ['node', 'sessions', 'leads', 'cards'];
const RETRY = [100, 200, 400];
const RETRY_AFTER = 1000;
export const TOKEN_KEY = 'vibeswitcher.token';

export function connectSocket(store, options) {
  const {
    url, WebSocket, storage, validate, build = Promise.resolve(null),
    setTimeout: later = globalThis.setTimeout, clearTimeout: cancel = globalThis.clearTimeout,
    location = globalThis.location, history = globalThis.history, reload = () => globalThis.location.reload(),
    log = (...args) => console.warn(...args),
  } = options;

  // Per subscription: its collection, the epoch and seq it holds (null: nothing yet), and whether it asked again. A
  // chat's also names its session (`key`) and whether the page still shows it (`open`).
  const subs = new Map(COLLECTIONS.map((collection, index) => ['s' + index, { collection, epoch: null, seq: null, asking: false }]));
  // The chats' subscriptions by session; their names are c1, c2, ….
  const chats = new Map();
  let nextChat = 1;
  // What the node sent, before the views' shapes: a session's `lead` needs the leads.
  const raw = { sessions: new Map(), leads: new Map() };
  let leadOf = new Map();
  let socket = null;
  let authed = false;
  let stopped = false;
  let attempts = 0;
  let timer = null;
  let nextId = 1;
  let mine = null;     // the page's own build (/build.json's `assets`)
  let reloading = false;
  let pair = takePair();
  store.state.follows = [...COLLECTIONS];
  // Requests in flight by id: { message, resolve }. An action's is sent again after a reconnect, with the same id.
  const pending = new Map();
  // Who waits for a collection's subscription to reach a seq: { collection, seq, epoch, resolve }.
  let waiters = [];

  // `#pair=CODE` read and taken off the address bar, so neither the history nor a bookmark keeps it.
  function takePair() {
    const match = /^#pair=([A-Za-z0-9_-]{1,64})$/.exec(location?.hash || '');
    if (!match) return null;
    history?.replaceState(null, '', location.pathname + location.search);
    return match[1];
  }

  function token() {
    try { return storage?.getItem(TOKEN_KEY) || null; } catch { return null; }
  }
  function keep(value) {
    try { if (value) storage?.setItem(TOKEN_KEY, value); else storage?.removeItem(TOKEN_KEY); } catch { /* a private window: this tab pairs again */ }
  }

  function send(message) {
    if (socket && socket.readyState === 1) socket.send(JSON.stringify(message));
  }

  function open() {
    timer = null;
    if (stopped) return;
    const credential = pair ? { pair } : token() ? { token: token() } : null;
    if (!credential) return store.setConnection('unpaired');
    authed = false;
    const ws = new WebSocket(url);
    socket = ws;
    ws.onopen = () => {
      if (socket !== ws) return;
      send({ v: 1, id: '0', kind: 'auth', args: { ...credential, client: 'webapp', ...(mine ? { assets: mine } : {}) } });
    };
    ws.onmessage = (event) => { if (socket === ws) receive(event.data); };
    ws.onclose = () => { if (socket === ws) dropped(); };
    ws.onerror = () => {};
  }

  // The socket closed: the rows stay, the mark says so, and it tries again.
  function dropped() {
    socket = null;
    authed = false;
    for (const [id, waiting] of pending) {
      if (!waiting.message.action) { pending.delete(id); waiting.resolve({ ok: false, error: { code: 'not-yet', message: 'The node isn’t answering.' } }); }
    }
    if (stopped) return;
    const held = [...subs.values()].some((sub) => sub.collection !== 'chat' && sub.seq !== null);
    if (held) store.setConnection('reconnecting');
    const wait = attempts < RETRY.length ? RETRY[attempts] : RETRY_AFTER;
    attempts += 1;
    timer = later(open, wait);
  }

  function receive(text) {
    let message;
    try { message = JSON.parse(text); } catch { return log('VibeSwitcher: a frame that isn’t JSON, dropped'); }
    const failed = validate('frame', message);
    if (failed !== null) return log('VibeSwitcher: a frame that doesn’t match the wire, dropped:', failed);
    if (message.re !== undefined) return replied(message);
    switch (message.kind) {
      case 'hello': return hello(message);
      case 'bye': return bye(message);
      case 'snapshot':
      case 'delta': return event(message);
      default:
        // Rule 3: an event this page doesn't know is skipped, unless the server says it must be understood.
        if (message.must === true) reload();
    }
  }

  function hello(message) {
    authed = true;
    attempts = 0;
    if (message.auth?.token) keep(message.auth.token);
    pair = null;
    store.setKinds(Array.isArray(message.kinds) ? message.kinds : []);
    if (mine && message.assets && message.assets !== mine) {
      reloading = true;
      idle();
    }
    // The actions that had no answer go again first, with their own ids (the server answers a repeat as before).
    for (const waiting of [...pending.values()]) send(waiting.message);
    for (const [name, sub] of subs) if (sub.open !== false) subscribe(name, sub);
    settle();
  }

  function bye(message) {
    if (message.code === 'auth' || message.code === 'revoked') {
      stopped = true;
      keep(null);
      store.setConnection(message.code === 'auth' ? 'unpaired' : 'revoked');
    } else if (message.code === 'version') {
      stopped = true;
      reload();
    }
    // Any other: the close follows, and the page connects again.
  }

  function subscribe(name, sub, { tailFrom = null } = {}) {
    const args = { sub: name, collection: sub.collection };
    if (sub.collection === 'chat') {
      args.key = sub.key;
      const held = store.state.chats.get(sub.key)?.items.filter((item) => !item.pending) || [];
      const after = tailFrom || held[held.length - 1]?.id || null;
      if (after) args.after = after;
      if (sub.seq !== null && !tailFrom) args.since = { epoch: sub.epoch, seq: sub.seq };
    } else if (sub.seq !== null) {
      args.since = { epoch: sub.epoch, seq: sub.seq };
    }
    sub.asking = true;
    // Its own ids (`sub-N`, for subscribe, unsubscribe and chat.page), apart from the store's (`1`, `2`…): a reply is
    // matched to its request by id alone.
    request({ v: 1, id: 'sub-' + nextId++, kind: 'subscribe', args }).then((reply) => {
      if (!reply.ok) log('VibeSwitcher: the node refused a subscription:', reply.error?.message);
    });
  }

  function event(message) {
    const sub = subs.get(message.sub);
    if (!sub || sub.open === false) return; // a subscription this page doesn't hold (one it replaced or left): dropped
    if (message.kind === 'snapshot') {
      if (message.collection !== sub.collection) return;
      const failed = validate('snapshot', message);
      if (failed !== null) return log('VibeSwitcher: a snapshot that doesn’t match the wire, dropped:', failed);
      sub.epoch = message.epoch;
      sub.seq = message.seq;
      sub.asking = false;
      if (sub.collection === 'chat') return store.chatSnapshot(sub.key, { items: message.items || [], after: message.after ?? null, more: !!message.more });
      take(sub.collection, message.entries || [], true);
      wake();
      return settle();
    }
    if (sub.seq === null) return;
    const failed = validate('delta.' + sub.collection, message);
    if (failed !== null) return log('VibeSwitcher: a delta that doesn’t match the wire, dropped:', failed);
    if (message.seq <= sub.seq) return;                       // held already
    if (message.prev !== sub.seq) {                            // a gap, or one that overlaps: ask again from ours
      if (!sub.asking) subscribe(message.sub, sub);
      return;
    }
    if (sub.collection === 'chat') {
      if (store.chatOps(sub.key, message.ops || []) === 'gap') {
        // What this page holds of an item isn't the node's: nothing of the delta is applied, and the item and what
        // follows it are asked for again.
        const op = (message.ops || []).find((each) => each.op === 'text' || each.op === 'set');
        if (!sub.asking) subscribe(message.sub, sub, { tailFrom: op?.id || op?.item?.id || null });
        return;
      }
      sub.seq = message.seq;
      sub.asking = false;
      return;
    }
    sub.seq = message.seq;
    sub.asking = false;
    take(sub.collection, message.changes || [], false);
    wake();
  }

  // The subscription that follows `collection`.
  const following = (collection) => [...subs.values()].find((sub) => sub.collection === collection);

  // Waiters whose subscription now holds their seq are told; so is one whose server restarted since (a new epoch's
  // snapshot is the whole truth: there is nothing left to wait for).
  function wake() {
    waiters = waiters.filter((waiter) => {
      const sub = following(waiter.collection);
      const done = !sub || (sub.seq !== null && (sub.epoch !== waiter.epoch || sub.seq >= waiter.seq));
      if (done) waiter.resolve();
      return !done;
    });
  }

  // Resolves once `collection`'s subscription holds `seq` of the epoch it holds now.
  function reached(collection, seq) {
    return new Promise((resolve) => {
      const sub = following(collection);
      waiters.push({ collection, seq, epoch: sub?.epoch ?? null, resolve });
      wake();
    });
  }

  // Entries ({id, value}) of one collection into the store, in the views' shapes.
  function take(collection, entries, whole) {
    if (collection === 'sessions' || collection === 'leads') {
      const map = raw[collection];
      if (whole) map.clear();
      for (const entry of entries) {
        if (entry.value === null) map.delete(entry.id); else map.set(entry.id, entry.value);
      }
    }
    if (collection === 'sessions') {
      const shaped = (entry) => (entry.value === null ? entry : { id: entry.id, value: sessionValue(entry.value, leadOf) });
      if (whole) store.reconcile('sessions', entries.map(shaped).map((entry) => entry.value));
      else store.change('sessions', entries.map(shaped));
      return;
    }
    if (whole) store.reconcile(collection, entries.map((entry) => entry.value));
    else store.change(collection, entries);
    if (collection === 'leads') {
      // A lead session's `lead` comes from here: the sessions whose lead changed are given again.
      const next = leadsBySession(raw.leads);
      const moved = [...raw.sessions.keys()].filter((id) => leadOf.get(id) !== next.get(id));
      leadOf = next;
      if (moved.length) store.change('sessions', moved.map((id) => ({ id, value: sessionValue(raw.sessions.get(id), leadOf) })));
    }
  }

  // Live once every subscription holds something: the first load shows its lists whole, not one at a time.
  function settle() {
    if (authed && [...subs.values()].every((sub) => sub.collection === 'chat' || sub.seq !== null)) store.setConnection('live');
  }

  function replied(message) {
    const waiting = pending.get(message.re);
    if (!waiting) return;
    pending.delete(message.re);
    waiting.resolve(message);
    idle();
  }

  // A newer build of the page is on the node: it reloads once nothing it sent waits for an answer.
  function idle() {
    if (reloading && ![...pending.values()].some((waiting) => waiting.message.action)) {
      reloading = false;
      stopped = true;
      reload();
    }
  }

  function request(message) {
    return new Promise((resolve) => {
      if (!authed && !message.action) return resolve({ ok: false, error: { code: 'not-yet', message: 'Not connected to the node yet.' } });
      pending.set(message.id, { message, resolve });
      if (authed) send(message);
    });
  }

  return {
    start() {
      return Promise.resolve(build).then((assets) => { mine = assets || null; }, () => {}).then(open);
    },
    // The store's own gap check is the mock's; here each subscription keeps its own.
    resync() {},
    reached,
    // A chat the page shows: followed (again, from what it holds, when it was before).
    subscribeChat(session) {
      let name = chats.get(session);
      if (!name) {
        name = 'c' + nextChat++;
        chats.set(session, name);
        subs.set(name, { collection: 'chat', key: session, epoch: null, seq: null, asking: false, open: true });
      }
      const sub = subs.get(name);
      sub.open = true;
      if (authed) subscribe(name, sub);
    },
    // A chat the page no longer shows: no longer followed; what it holds stays, with its seq, to resume from.
    unsubscribeChat(session) {
      const name = chats.get(session);
      const sub = name && subs.get(name);
      if (!sub || !sub.open) return;
      sub.open = false;
      if (authed) request({ v: 1, id: 'sub-' + nextId++, kind: 'unsubscribe', args: { sub: name } });
    },
    // The items before `before` (`chat.page`): a promise of the reply.
    pageChat(session, before) {
      return request({ v: 1, id: 'sub-' + nextId++, kind: 'chat.page', args: { session, before, limit: 200 } });
    },
    request(message) {
      if (!store.can(message.kind)) {
        return Promise.resolve({ ok: false, error: { code: 'unknown-kind', message: 'This page can’t do that yet: use `vibeswitcher` in a terminal.' } });
      }
      return request(message);
    },
    stop() {
      stopped = true;
      if (timer !== null) cancel(timer);
      socket?.close();
      socket = null;
    },
  };
}
