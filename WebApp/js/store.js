// The client's state: one snapshot, then deltas (the design's "The live protocol"). Nothing here touches the page,
// and nothing here knows where the messages come from: mock.js feeds it today, the WebSocket later. The shapes are
// in WebApp/README.md.
//
//   store.apply(message)        a message from the feed: snapshot, delta, chat
//   store.subscribe(topic, fn)  topic: sessions, leads, cards, boards, node, connection, chat:<session id>
//   store.request(kind, args)   an action; resolves with the feed's reply ({ ok, result } or { ok: false, error })

// The keyed collections, and the field each entry is keyed by (a lead and its board by their project's id).
const KEYS = { sessions: 'id', cards: 'id', leads: 'project', boards: 'project' };
const COLLECTIONS = Object.keys(KEYS);

export function createStore() {
  const state = {
    // connecting: no snapshot yet. live. reconnecting: the feed dropped; what's shown is the last known.
    connection: 'connecting',
    // The server start this state is from; a snapshot with another one replaces everything (rule 8).
    epoch: null,
    // The last message applied. A delta that isn't seq + 1 is a gap: the feed is asked for a snapshot.
    seq: 0,
    // `status`'s result, less its lists (README: "The node").
    node: null,
    // Each by id, in the order the node lists them.
    sessions: new Map(),
    leads: new Map(),
    cards: new Map(),
    boards: new Map(),
    // By session id: { items: [], index: Map(id → position) }, only for the chats subscribed to.
    chats: new Map(),
    // What this client did and the server hasn't confirmed yet, by card id: { kind, answer }, or { refused: reason }.
    acting: new Map(),
  };

  const listeners = new Map();
  let feed = null;
  let nextRequest = 1;

  function subscribe(topic, fn) {
    if (!listeners.has(topic)) listeners.set(topic, new Set());
    listeners.get(topic).add(fn);
    return () => listeners.get(topic)?.delete(fn);
  }

  function emit(touched) {
    for (const [topic, changes] of touched) {
      for (const fn of listeners.get(topic) || []) fn(changes);
    }
  }

  function touch(touched, topic, change) {
    if (!touched.has(topic)) touched.set(topic, []);
    touched.get(topic).push(change);
  }

  function chatOf(session) {
    if (!state.chats.has(session)) state.chats.set(session, { items: [], index: new Map(), loaded: false });
    return state.chats.get(session);
  }

  function reindex(chat, from = 0) {
    for (let i = from; i < chat.items.length; i++) chat.index.set(chat.items[i].id, i);
  }

  // One change to a chat: a new or replaced item, more text on a streaming one, or an item gone.
  function applyChat(change, touched) {
    const chat = chatOf(change.session);
    const topic = 'chat:' + change.session;
    const at = chat.index.get(change.id);
    if (change.append) {
      if (at === undefined) return;
      const item = chat.items[at];
      for (const [field, more] of Object.entries(change.append)) item[field] = (item[field] || '') + more;
      touch(touched, topic, { type: 'append', id: change.id, item });
    } else if (change.value === null) {
      if (at === undefined) return;
      chat.items.splice(at, 1);
      chat.index.delete(change.id);
      reindex(chat, at);
      touch(touched, topic, { type: 'remove', id: change.id });
    } else if (at !== undefined) {
      chat.items[at] = change.value;
      touch(touched, topic, { type: 'put', id: change.id, item: change.value });
    } else {
      // What this client sent comes back as an item with its action id: it takes the pending row's place, so a
      // message is never shown twice.
      const pending = change.value.action ? chat.index.get('pending:' + change.value.action) : undefined;
      if (pending !== undefined) {
        const old = chat.items[pending].id;
        chat.items[pending] = change.value;
        chat.index.delete(old);
        chat.index.set(change.value.id, pending);
        touch(touched, topic, { type: 'replace', id: old, item: change.value });
      } else {
        chat.items.push(change.value);
        chat.index.set(change.value.id, chat.items.length - 1);
        touch(touched, topic, { type: 'put', id: change.id, item: change.value, fresh: true });
      }
    }
  }

  function applyChange(change, touched) {
    if (change.in === 'chat') return applyChat(change, touched);
    if (change.in === 'node') {
      state.node = change.value;
      return touch(touched, 'node', change);
    }
    if (!COLLECTIONS.includes(change.in)) return; // rule 3: a reader ignores what it doesn't know
    const map = state[change.in];
    if (change.value === null) map.delete(change.id);
    else map.set(change.id, change.value);
    if (change.in === 'cards') state.acting.delete(change.id);
    touch(touched, change.in, change);
  }

  // A message from the feed. Returns 'gap' when a delta doesn't follow the last one applied (the feed sends a new
  // snapshot), 'stale' for one already applied, else 'ok'.
  function apply(message) {
    const touched = new Map();
    if (message.kind === 'snapshot') {
      const restarted = state.epoch !== null && state.epoch !== message.epoch;
      state.epoch = message.epoch;
      state.seq = message.seq;
      state.node = message.state.node || null;
      for (const name of COLLECTIONS) {
        state[name] = new Map((message.state[name] || []).map((entry) => [entry[KEYS[name]], entry]));
        touch(touched, name, { type: 'reset' });
      }
      state.acting.clear();
      touch(touched, 'node', { type: 'reset' });
      // A chat subscription doesn't outlive the server that took it: each is asked for again.
      if (restarted) {
        for (const session of state.chats.keys()) feed?.subscribeChat(session);
      }
      setConnection('live', touched);
    } else if (message.kind === 'delta') {
      if (state.connection !== 'live' || message.seq <= state.seq) return 'stale';
      if (message.seq !== state.seq + 1) {
        feed?.resync();
        return 'gap';
      }
      state.seq = message.seq;
      for (const change of message.changes || []) applyChange(change, touched);
    } else if (message.kind === 'chat') {
      const chat = chatOf(message.session);
      chat.items = message.items.slice();
      chat.index = new Map();
      chat.loaded = true;
      reindex(chat);
      touch(touched, 'chat:' + message.session, { type: 'reset' });
    }
    emit(touched);
    return 'ok';
  }

  function setConnection(connection, touched) {
    if (state.connection === connection) return;
    state.connection = connection;
    if (touched) touch(touched, 'connection', { connection });
    else emit(new Map([['connection', [{ connection }]]]));
  }

  // A chat is subscribed to once it's shown, and stays so (its rows stay current behind the scenes).
  function openChat(session) {
    if (state.chats.has(session)) return;
    chatOf(session);
    feed?.subscribeChat(session);
  }

  // An action (the design's "Actions"): it has an id, the server answers done or refused, and the change itself
  // arrives as a delta.
  function request(kind, args = {}) {
    const message = { v: 1, id: String(nextRequest++), kind, args, action: crypto.randomUUID() };
    if (!feed) return Promise.resolve({ ok: false, error: { code: 'not-yet', message: 'Not connected to the node yet.' } });
    return feed.request(message);
  }

  // An action on a card, shown at once: the card reads as answered or held from this moment, and goes back to open,
  // saying why, if the server refuses.
  function act(card, kind, args = {}) {
    state.acting.set(card, { kind, ...args });
    emit(new Map([['cards', [{ in: 'cards', id: card, acting: true }]]]));
    return request(kind, { card, ...args }).then((reply) => {
      if (!reply.ok) {
        state.acting.set(card, { refused: reply.error?.message || 'The node refused it.' });
        emit(new Map([['cards', [{ in: 'cards', id: card, acting: true }]]]));
      }
      return reply;
    });
  }

  // A message typed into a session, shown at once as a pending row; the transcript's own row replaces it.
  function send(session, text) {
    const message = { v: 1, id: String(nextRequest++), kind: 'send', args: { session, text }, action: crypto.randomUUID() };
    const touched = new Map();
    applyChat({ session, id: 'pending:' + message.action, value: { id: 'pending:' + message.action, kind: 'prompt', text, at: new Date().toISOString(), pending: true } }, touched);
    emit(touched);
    if (!feed) return Promise.resolve({ ok: false });
    return feed.request(message);
  }

  return {
    state,
    apply,
    subscribe,
    request,
    act,
    send,
    openChat,
    setConnection: (connection) => setConnection(connection),
    connect(source) { feed = source; },
  };
}
