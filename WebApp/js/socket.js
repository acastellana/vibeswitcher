// The node's live feed over its WebSocket (the wire contract, docs/superpowers/specs/2026-11-17-v2-live-wire-contract.md
// §2 to §4 and §10), in mock.js's place: the same four calls for the store (README.md, "The feed").
//
// - Pairing: the address `vibeswitcher web` prints carries a one-time code in its fragment (`#pair=…`). It is taken
//   off the address bar at once, sent in the first frame, and exchanged for a token the tab keeps (sessionStorage:
//   this origin's, this tab's) and sends on every later connection.
// - Following: one subscription per collection the page shows (node, sessions, leads, cards, boards), each with the `seq` it
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
// - Terminals (the contract's §9): binary frames are handed to `onBinary`'s listeners as they come, once the socket is
//   authenticated, and `sendBinary` sends one; `onLink` tells them when the connection is up (after each `hello`) and
//   when it dropped, since a terminal's stream goes with its connection (js/terminal.js opens it again).
// - Actions (the contract's §8): a request with an action id is sent again after a reconnect with the same id, and
//   `reached(collection, seq)` tells the store when a subscription holds an ack's `applied`, so an overlay is dropped
//   only once the stream shows what it stood for.
//
// Everything it touches is passed in, so tests/socket.test.mjs scripts it with a fake socket and clock.

import { session as sessionValue, leadsBySession, replacedBySession } from './wire.js';

const COLLECTIONS = ['node', 'sessions', 'leads', 'cards', 'boards'];
const RETRY = [100, 200, 400];
const RETRY_AFTER = 1000;
export const TOKEN_KEY = 'vibeswitcher.token';
// That this tab acted (a pairing confirmed in it), and that it reloaded before its pairing was confirmed: flags the
// tab keeps across a reload (sessionStorage), never the secret, so a reloaded tab can say why it no longer acts.
export const ACTED_KEY = 'vibeswitcher.acted';
export const UNCONFIRMED_KEY = 'vibeswitcher.unconfirmed';

export function connectSocket(store, options) {
  const {
    url, WebSocket, storage, validate, build = Promise.resolve(null), rebuild = null,
    setTimeout: later = globalThis.setTimeout, clearTimeout: cancel = globalThis.clearTimeout,
    location = globalThis.location, history = globalThis.history, reload = () => globalThis.location.reload(),
    log = (...args) => console.warn(...args),
  } = options;

  // Per subscription: its collection, the epoch and seq it holds (null: nothing yet), and whether it asked again. A
  // chat's also names its session (`key`), whether the page still shows it (`open`), and whether it waits for the
  // session's first transcript (`waiting`: the node refused it, the session having none yet).
  const subs = new Map(COLLECTIONS.map((collection, index) => ['s' + index, { collection, epoch: null, seq: null, asking: false }]));
  // The chats' subscriptions by session; their names are c1, c2, ….
  const chats = new Map();
  let nextChat = 1;
  // What the node sent, before the views' shapes: a session's `lead` needs the leads.
  const raw = { sessions: new Map(), leads: new Map() };
  let leadOf = new Map();
  let replacedOf = new Map();
  let socket = null;
  let authed = false;
  // The second secret a pairing confirmed in the terminal gets (`paired.act`): kept in this variable only, never in
  // storage, the address or a log; sent with the token on a reconnect without a reload. It brings "watch" (terminals),
  // and "act" while the node's level lets pages act. A reload loses it: the page then reads and drafts until it is
  // paired again.
  let actSecret = null;
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
  // The terminals' listeners: binary frames, and the connection going up or down.
  const binaryListeners = new Set();
  const linkListeners = new Set();
  const linked = (how) => { for (const fn of [...linkListeners]) fn(how); };

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
  function flag(key, on) {
    try { if (on) storage?.setItem(key, '1'); else storage?.removeItem(key); } catch { /* a private window */ }
  }
  function flagged(key) {
    try { return storage?.getItem(key) === '1'; } catch { return false; }
  }
  // Said once the first hello is in: this tab acted before its reload, or reloaded before the terminal confirmed it.
  let acted = flagged(ACTED_KEY);
  let unconfirmed = flagged(UNCONFIRMED_KEY);
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
    ws.binaryType = 'arraybuffer';
    ws.onopen = () => {
      if (socket !== ws) return;
      send({ v: 1, id: '0', kind: 'auth', args: { ...credential, ...(actSecret && credential.token ? { act: actSecret } : {}), client: 'webapp', ...(mine ? { assets: mine } : {}) } });
    };
    ws.onmessage = (event) => {
      if (socket !== ws) return;
      if (typeof event.data === 'string') return receive(event.data);
      if (authed) for (const fn of [...binaryListeners]) fn(event.data);
    };
    ws.onclose = () => { if (socket === ws) dropped(); };
    ws.onerror = () => {};
  }

  // The socket closed: the rows stay, the mark says so, and it tries again.
  function dropped() {
    socket = null;
    const wasUp = authed;
    authed = false;
    if (wasUp) linked('down');
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
      case 'paired': return paired(message);
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
    if (typeof message.auth?.act === 'string') actSecret = message.auth.act;
    const rights = message.auth?.rights || [];
    // A hello without "watch": this connection's pairing isn't a confirmed one (any more): the secret goes, and the
    // tab says it no longer acts (its pairing ended: run out, ended in the terminal, acting lowered).
    if (!rights.includes('watch') && actSecret) {
      actSecret = null;
      store.setActsLost('ended');
    }
    const phrase = typeof message.auth?.phrase === 'string' ? message.auth.phrase : null;
    const newer = !!(mine && message.assets && message.assets !== mine);
    pair = null;
    // A code just redeemed by a page older than the node's build: reloaded before any phrase shows (the confirmation
    // is this connection's, so the reloaded page says to fetch a new address); never after a pairing is confirmed.
    if (newer && phrase) {
      flag(UNCONFIRMED_KEY, true);
      stopped = true;
      return reload();
    }
    // A page that just redeemed a code: the words `vibeswitcher web` asks the user to type, until they're confirmed.
    store.setPhrase(phrase);
    if (unconfirmed && !phrase && !actSecret) store.setActsLost('unconfirmed');
    else if (acted && !actSecret && !rights.includes('act')) store.setActsLost('reloaded');
    unconfirmed = false;
    acted = false;
    flag(UNCONFIRMED_KEY, false);
    store.setKinds(Array.isArray(message.kinds) ? message.kinds : [], message.plugins, rights);
    // The page's own build unknown (/build.json failed at its load): asked again, so the next switch is seen.
    if (!mine && message.assets && rebuild) Promise.resolve(rebuild()).then((assets) => { if (assets && !mine) mine = assets; }, () => {});
    if (newer && actSecret) {
      // A tab that acts isn't reloaded behind the user's back (its pairing lives in this tab's memory): it says the
      // node has a newer page, and reloading is theirs.
      store.setNewerBuild(true);
    } else if (newer) {
      reloading = true;
      idle();
      // Held off (an action of its own waits for its reply): it says so meanwhile, and reloads once that settles.
      if (reloading) store.setNewerBuild(true);
    }
    // The actions that had no answer go again first, with their own ids (the server answers a repeat as before).
    for (const waiting of [...pending.values()]) send(waiting.message);
    // A node restarted on a newer build may stream what the last one didn't: each collection is asked for again.
    store.state.follows = [...COLLECTIONS];
    for (const [name, sub] of subs) {
      sub.missing = false;
      if (sub.open !== false) subscribe(name, sub);
    }
    settle();
    linked('up');
  }

  // The user confirmed this page in the terminal: on this same connection, its secret and its new rights. Without the
  // kinds those rights bring, the page connects again (token and secret) for a hello that lists them.
  function paired(message) {
    if (typeof message.act !== 'string' || !Array.isArray(message.rights)) return;
    actSecret = message.act;
    store.setPhrase(null);
    store.setActsLost(null);
    flag(ACTED_KEY, true);
    if (Array.isArray(message.kinds)) return store.setKinds(message.kinds, message.plugins ?? store.state.plugins, message.rights);
    store.setKinds(store.state.kinds, store.state.plugins, message.rights);
    socket?.close();
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
    // Any other (`acts-off` too: the user turned web_acts off, so the page connects again, now without `act`): the
    // close follows, and the page connects again.
  }

  function subscribe(name, sub, { tailFrom = null } = {}) {
    const args = { sub: name, collection: sub.collection };
    if (sub.collection === 'chat') {
      args.key = sub.key;
      const held = store.state.chats.get(sub.key)?.items.filter((item) => !item.pending) || [];
      const after = tailFrom || held[held.length - 1]?.id || null;
      if (after) args.after = after;
      if (sub.seq !== null && !tailFrom) args.since = { epoch: sub.epoch, seq: sub.seq };
    } else {
      // Snapshots in parts (the contract's §4, "Snapshots in parts"): each part a message of at most 256 KiB.
      args.parts = true;
      if (sub.seq !== null) args.since = { epoch: sub.epoch, seq: sub.seq };
    }
    sub.parting = null;
    sub.asking = true;
    sub.waiting = false;
    // Its own ids (`sub-N`, for subscribe, unsubscribe and chat.page), apart from the store's (`1`, `2`…): a reply is
    // matched to its request by id alone.
    request({ v: 1, id: 'sub-' + nextId++, kind: 'subscribe', args }).then((reply) => {
      if (reply.ok) return;
      // A node from before the boards: the page goes live without them, and says where a board would be that it has none.
      if (sub.collection === 'boards' && reply.error?.code === 'bad-args') {
        sub.missing = true;
        store.state.follows = store.state.follows.filter((collection) => collection !== 'boards');
        return settle();
      }
      // A new session's chat before its transcript is written (acceptance run, 2026-11-20: the page logged this and
      // showed nothing): no conversation yet, shown as such, and asked for again once the session has a transcript.
      if (sub.collection === 'chat' && reply.error?.code === 'gone' && raw.sessions.get(sub.key)?.hasTranscript === false) {
        sub.asking = false;
        sub.waiting = true;
        if (!store.state.chats.get(sub.key)?.loaded) store.chatSnapshot(sub.key, { items: [] });
        return;
      }
      log('VibeSwitcher: the node refused a subscription:', reply.error?.message);
    });
  }

  // The chats waiting for their session's first transcript whose session has one now: asked for again.
  function transcriptsCame() {
    for (const [name, sub] of subs) {
      if (sub.waiting && sub.open && authed && raw.sessions.get(sub.key)?.hasTranscript) subscribe(name, sub);
    }
  }

  function event(message) {
    const sub = subs.get(message.sub);
    if (!sub || sub.open === false) return; // a subscription this page doesn't hold (one it replaced or left): dropped
    if (message.kind === 'snapshot') {
      if (message.collection !== sub.collection) return;
      const failed = validate('snapshot', message);
      if (failed !== null) return log('VibeSwitcher: a snapshot that doesn’t match the wire, dropped:', failed);
      let entries = message.entries || [];
      if (typeof message.part === 'number') {
        // A snapshot in parts: held until its last part, then taken whole, as one snapshot. A part out of its place (it
        // can't be, on one ordered socket) drops what was held, and the subscription is asked for again.
        if (message.part === 0) sub.parting = { epoch: message.epoch, seq: message.seq, next: 0, entries: [], withheld: [] };
        const held = sub.parting;
        if (!held || held.next !== message.part || held.epoch !== message.epoch || held.seq !== message.seq) {
          sub.parting = null;
          log('VibeSwitcher: a snapshot part out of its place, asked for again');
          return subscribe(message.sub, sub);
        }
        held.entries.push(...entries);
        held.withheld.push(...(message.withheld || []));
        held.next += 1;
        if (message.final !== true) return;
        sub.parting = null;
        entries = held.entries;
        // An entry too large for a part, withheld whole (never cut): its stub, when its collection gives one, takes its
        // place (a card drawn as too large to show here, with the command that shows it); any other is said and left out.
        const stubs = held.withheld.filter((item) => item.stub && typeof item.stub === 'object');
        entries = entries.concat(stubs.map((item) => ({ id: item.id, value: item.stub })));
        const unshown = held.withheld.filter((item) => !stubs.includes(item));
        if (unshown.length) log(`VibeSwitcher: ${unshown.length} ${sub.collection} too large to send, not shown:`, unshown.map((item) => item.id).join(', '));
      }
      sub.epoch = message.epoch;
      sub.seq = message.seq;
      sub.asking = false;
      if (sub.collection === 'chat') return store.chatSnapshot(sub.key, { items: message.items || [], after: message.after ?? null, more: !!message.more });
      take(sub.collection, entries, true);
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
      const shaped = (entry) => (entry.value === null ? entry : { id: entry.id, value: sessionValue(entry.value, leadOf, replacedOf) });
      if (whole) store.reconcile('sessions', entries.map(shaped).map((entry) => entry.value));
      else store.change('sessions', entries.map(shaped));
      transcriptsCame();
      return;
    }
    if (whole) store.reconcile(collection, entries.map((entry) => entry.value));
    else store.change(collection, entries);
    if (collection === 'leads') {
      // A lead session's `lead` comes from here: the sessions whose lead changed are given again.
      const next = leadsBySession(raw.leads), nextReplaced = replacedBySession(raw.leads);
      const moved = [...raw.sessions.keys()].filter((id) => leadOf.get(id) !== next.get(id) || replacedOf.get(id) !== nextReplaced.get(id));
      leadOf = next;
      replacedOf = nextReplaced;
      if (moved.length) store.change('sessions', moved.map((id) => ({ id, value: sessionValue(raw.sessions.get(id), leadOf, replacedOf) })));
    }
  }

  // Live once every subscription holds something: the first load shows its lists whole, not one at a time.
  function settle() {
    if (authed && [...subs.values()].every((sub) => sub.collection === 'chat' || sub.missing || sub.seq !== null)) store.setConnection('live');
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
    // This page no longer acts (the node's `acts-ended`: the pairing ended, the level was lowered, it was revoked).
    dropAct() { actSecret = null; },
    // The user dismissed "this tab no longer acts": it isn't said again after a reload either.
    forgetActed() { flag(ACTED_KEY, false); },
    // The user's own reload, for a newer build: the tab then says it no longer acts.
    reloadNow() { stopped = true; reload(); },
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
    // A terminal's binary frame (an ArrayBuffer or a typed array), sent if the socket is up: whether it was.
    sendBinary(bytes) {
      if (!authed || !socket || socket.readyState !== 1) return false;
      socket.send(bytes);
      return true;
    },
    // Binary frames from the node, as ArrayBuffers: a function that stops them.
    onBinary(fn) { binaryListeners.add(fn); return () => binaryListeners.delete(fn); },
    // 'up' after each hello, 'down' when an authenticated connection dropped: a function that stops them.
    onLink(fn) { linkListeners.add(fn); return () => linkListeners.delete(fn); },
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
