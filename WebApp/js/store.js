// The client's state: one snapshot, then deltas (the design's "The live protocol"). Nothing here touches the page,
// and nothing here knows where the messages come from: mock.js feeds it today, the WebSocket later. The shapes are
// in WebApp/README.md.
//
//   store.apply(message)        a message from the feed: snapshot, delta (the mock's whole-state form)
//   store.subscribe(topic, fn)  topic: sessions, leads, cards, boards, node, connection, chat:<session id>
//   store.request(kind, args)   an action; resolves with the feed's reply ({ ok, result } or { ok: false, error })
//   store.reconcile(name, list)  a live feed's snapshot of one collection, by id (socket.js)
//   store.change(name, changes)  a live feed's delta of one collection: [{ id, value }], value null for gone
//   store.can(kind)              whether this connection may send `kind` (`hello.kinds`; the mock may send anything)
//   store.acts()                 whether it acts for the user (`hello.auth.rights` holds `act`; the mock does)
//   store.chatSnapshot(id, s)    a chat's snapshot ({ items, after, more }): the newest items, or a tail from `after` on
//   store.chatOps(id, ops)       a chat delta's ops; 'gap' when they don't fit what it holds (nothing applied)
//   store.chatPage(id, items, more)  older items, before the first held
//   store.openChat(id), closeChat(id), pageChat(id)   what the chat view asks of the feed
//   store.draft(card, text)      leaves an answer drafted on a card, shown at once (the contract's §8); null clears it
//   store.draftOf(card)          the draft a card shows: this page's overlay over the node's, or null
//   store.sessionDraft(id, text, images, now) leaves a message drafted for a session (`session.draft`), with the paths
//                                of images attached to it, shown at once; null clears it. `now`: to steer a working
//                                agent mid-turn (`vibeswitcher send` then steers it, as `--now` does)
//   store.sessionDraftOf(id)     the message a session shows drafted: this page's overlay over the node's, or null
//   store.read(kind, args)       a read (no action id): resolves with the feed's reply
//   store.attach(id, bytes, type) an image for a session's composer, sent in parts (`session.attach`): the last reply,
//                                whose result has the `path` the node wrote it to

// The keyed collections, and the field each entry is keyed by (a lead and its board by their project's id).
import { applyOps, reindex } from './chatops.js';
import { parts as imageParts } from './composing.js';
import { assert as passkeyAssert } from './passkey.js';

const KEYS = { sessions: 'id', cards: 'id', leads: 'project', boards: 'project' };
const COLLECTIONS = Object.keys(KEYS);

// `options.credentials`: the browser's WebAuthn (navigator.credentials), asked for a passkey at the `confirm` level.
export function createStore(options = {}) {
  const credentials = () => ('credentials' in options ? options.credentials : globalThis.navigator?.credentials);
  const state = {
    // connecting: no snapshot yet. live. reconnecting: the feed dropped; what's shown is the last known.
    // unpaired: the node doesn't know this page (no code or token, or it refused them), revoked: its access was
    // dropped. Neither retries: the user runs `vibeswitcher web` again.
    connection: 'connecting',
    // What this connection may send (`hello.kinds`); null: anything (the mock).
    kinds: null,
    // This connection's rights (`hello.auth.rights`): read, draft, and act once the node lets a page act (`web_acts`);
    // null: the mock's, which may do anything.
    rights: null,
    // The feature plugins the node has on (`hello.plugins`: [{ id, title }]); null: a node before plugins (or the mock).
    plugins: null,
    // The words a page that just redeemed a pairing code shows until the user confirms it in the terminal.
    phrase: null,
    // Why this tab no longer acts for the user, once it did: 'reloaded' (a pairing lives in the tab's memory only),
    // 'ended' (its pairing ended: 12 hours, ended in the terminal, acting lowered or turned off), 'unconfirmed' (it
    // reloaded to the node's newer page before the terminal confirmed it). Null: nothing to say.
    actsLost: null,
    // The node serves a newer page than this tab runs, and this tab acts, so it isn't reloaded for the user.
    newerBuild: false,
    // At `confirm`: what the passkey now asked for approves ({ line }), and the vault's line for the last one done.
    confirming: null,
    recorded: null,
    // The terminal's offer to add a passkey (`vibeswitcher web --passkey`), while it holds: the node's message, and
    // what became of it here ({ state: 'adding' | 'added' | 'cancelled' | 'refused', id, why }).
    passkeyOffer: null,
    passkeyAdding: null,
    // The collections the feed follows; null: all of them (the mock). The node sends no lead's board yet.
    follows: null,
    // A card's place across a server restart: card ids are the server's memory and change, so a card that comes back
    // under a new id with the same project and question keeps the key (and the row) it had. By card id.
    cardKeys: new Map(),
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
    // By session id, for the chats shown: { items: [], index: Map(id → position), loaded, more, open, paging }. The items
    // are the wire's (the contract §6), oldest first; `more`: older ones can be paged in.
    chats: new Map(),
    // What this client did and the server hasn't confirmed yet, by card id: { kind, answer }, or { refused: reason }.
    acting: new Map(),
    // A draft this page sent that the stream doesn't show yet (the contract's "Optimistic actions"), by card id:
    // { text (null: cleared), action, sent: false until the node acked it }. Shown over the card's own `draft` until
    // the cards stream reaches the ack's `applied`, so nothing flickers between the click, the ack and the delta.
    drafts: new Map(),
    // Why the node refused a card's last draft, by card id, until the next one.
    draftRefused: new Map(),
    // The same for a message drafted for a session (`session.draft`), by session id: the overlay, and why the node
    // refused the last one.
    sessionDrafts: new Map(),
    sessionDraftRefused: new Map(),
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
    if (!state.chats.has(session)) state.chats.set(session, { items: [], index: new Map(), loaded: false, more: false, open: false, paging: false });
    return state.chats.get(session);
  }

  // What this client sent and the node hasn't written back yet: kept across a snapshot.
  const pendingOf = (items) => items.filter((item) => item.pending);

  // A chat's snapshot (the contract §4, §6). `after` null: the newest items, reconciled by id (a row that stays keeps its
  // node). `after` an item this chat holds (a tail, after a restart): every item before it is kept, and it and what
  // followed are replaced. One notification either way, so the list never shows empty in between.
  function chatSnapshot(session, { items, after = null, more = false }) {
    const chat = chatOf(session);
    const cut = after === null ? undefined : chat.index.get(after);
    const incoming = new Set(items.map((item) => item.action).filter(Boolean));
    const pending = pendingOf(chat.items).filter((item) => !incoming.has(item.id.slice('pending:'.length)));
    if (cut === undefined) {
      chat.items = [...items, ...pending];
      chat.more = !!more;
    } else {
      chat.items = [...chat.items.slice(0, cut).filter((item) => !item.pending), ...items, ...pending];
    }
    chat.index = new Map();
    reindex(chat);
    const first = !chat.loaded;
    chat.loaded = true;
    emit(new Map([['chat:' + session, [{ type: cut === undefined ? 'reset' : 'tail', first }]]]));
  }

  // A chat delta's ops, all or none: 'gap' when one doesn't fit (the feed asks again), else 'ok'.
  function chatOps(session, ops) {
    const chat = chatOf(session);
    const done = applyOps(chat, ops);
    if (done.gap !== undefined) return 'gap';
    if (done.touched.length) emit(new Map([['chat:' + session, done.touched]]));
    return 'ok';
  }

  // Older items, just before the first held (`chat.page`).
  function chatPage(session, items, more) {
    const chat = chatOf(session);
    const older = items.filter((item) => !chat.index.has(item.id));
    chat.items = [...older, ...chat.items];
    chat.more = !!more;
    chat.index = new Map();
    reindex(chat);
    emit(new Map([['chat:' + session, [{ type: 'page', count: older.length }]]]));
  }

  function applyChange(change, touched) {
    if (change.in === 'node') {
      state.node = change.value;
      return touch(touched, 'node', change);
    }
    if (!COLLECTIONS.includes(change.in)) return; // rule 3: a reader ignores what it doesn't know
    const map = state[change.in];
    if (change.value === null) map.delete(change.id);
    else map.set(change.id, change.value);
    if (change.in === 'cards') {
      state.acting.delete(change.id);
      if (change.value === null) state.cardKeys.delete(change.id);
      // A card that closed (or went) has nothing left to draft: what this page had pending on it is moot.
      if (change.value === null || change.value.open === false) {
        state.drafts.delete(change.id);
        state.draftRefused.delete(change.id);
      }
    }
    touch(touched, change.in, change);
  }

  // The same question on the same project: a card the server made again after it restarted.
  const sameQuestion = (a, b) => a.project === b.project && !!a.question && a.question.id === b.question?.id;

  // A snapshot of one collection from a live feed: each row whose id is still there is updated in place, new ones are
  // added and the rest removed, in one notification, so the list never shows empty in between. The order is the
  // server's, except that a card back under a new id takes the place of the one it replaces.
  function reconcile(name, list) {
    const touched = new Map();
    if (name === 'node') {
      state.node = list[0] ?? null;
      touch(touched, 'node', { type: 'reset' });
    } else if (COLLECTIONS.includes(name)) {
      const key = KEYS[name];
      const before = state[name];
      const next = new Map();
      if (name === 'cards') {
        const incoming = new Map(list.map((entry) => [entry[key], entry]));
        const gone = [...before.values()].filter((card) => !incoming.has(card.id));
        const placed = new Set();
        // Where the old card was, its successor goes; then everything else in the server's order.
        for (const old of before.values()) {
          let card = incoming.get(old.id);
          if (!card && gone.includes(old)) {
            card = list.find((entry) => !before.has(entry.id) && !placed.has(entry.id) && sameQuestion(old, entry));
            if (card) {
              state.cardKeys.set(card.id, state.cardKeys.get(old.id) || old.id);
              const acting = state.acting.get(old.id);
              if (acting) state.acting.set(card.id, acting);
              const drafted = state.drafts.get(old.id);
              if (drafted) state.drafts.set(card.id, drafted);
            }
          }
          if (card && !placed.has(card.id)) { next.set(card.id, card); placed.add(card.id); }
        }
        for (const card of list) if (!placed.has(card.id)) next.set(card.id, card);
        for (const id of state.cardKeys.keys()) if (!next.has(id)) state.cardKeys.delete(id);
        for (const id of state.acting.keys()) if (!next.has(id)) state.acting.delete(id);
        for (const id of state.drafts.keys()) if (!next.get(id)?.open) state.drafts.delete(id);
        for (const id of state.draftRefused.keys()) if (!next.has(id)) state.draftRefused.delete(id);
      } else {
        for (const entry of list) next.set(entry[key], entry);
      }
      state[name] = next;
      touch(touched, name, { type: 'reset' });
    }
    emit(touched);
  }

  // A delta of one collection from a live feed (its order and gaps are socket.js's to judge).
  function change(name, changes) {
    const touched = new Map();
    for (const entry of changes) applyChange({ in: name, id: entry.id, value: entry.value }, touched);
    emit(touched);
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
        for (const [session, chat] of state.chats) if (chat.open) feed?.subscribeChat(session);
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

  // A chat is followed while it's shown. Left, its items stay, and shown again it resumes from what it holds: the
  // node sends what changed meanwhile, so it opens at once and current.
  function openChat(session) {
    const chat = chatOf(session);
    if (chat.open) return;
    chat.open = true;
    feed?.subscribeChat(session);
  }

  function closeChat(session) {
    const chat = state.chats.get(session);
    if (!chat?.open) return;
    chat.open = false;
    feed?.unsubscribeChat?.(session);
  }

  // The items before the first held, asked of the feed once at a time, while there are more.
  function pageChat(session) {
    const chat = state.chats.get(session);
    const first = chat?.items.find((item) => !item.pending);
    if (!chat || chat.paging || !chat.more || !first || !feed?.pageChat) return;
    chat.paging = true;
    feed.pageChat(session, first.id).then((reply) => {
      chat.paging = false;
      if (reply?.ok) chatPage(session, reply.result.items || [], reply.result.more);
      else emit(new Map([['chat:' + session, [{ type: 'paged' }]]]));
    });
  }

  // An action (the design's "Actions"): it has an id, the server answers done or refused, and the change itself
  // arrives as a delta.
  function request(kind, args = {}, action = crypto.randomUUID()) {
    const message = { v: 1, id: String(nextRequest++), kind, args, action };
    if (!feed) return Promise.resolve({ ok: false, error: { code: 'not-yet', message: 'Not connected to the node yet.' } });
    return feed.request(message).then((reply) => confirmed(message, reply)).then((reply) => {
      // This page no longer acts (`acts-ended`: its pairing ended, the level was lowered, it was revoked): the secret
      // goes, and the page reads and drafts until it is paired again. A `voice` refusal (the terminal's kind or
      // setting) changes nothing.
      if (reply?.error?.code === 'acts-ended' && state.rights) {
        state.rights = state.rights.filter((right) => right !== 'act' && right !== 'watch');
        state.actsLost = 'ended';
        feed.dropAct?.();
        emit(new Map([['connection', [{ connection: state.connection }]]]));
      }
      return reply;
    });
  }

  // A read: no action id, so nothing is sent again after a reconnect (asked again by whoever wants it).
  // At the `confirm` level an acting request without a passkey's assertion is refused `assertion-needed`: the node is
  // asked for a challenge over exactly this request, the line it approves is shown while the browser asks for the
  // passkey, and the request goes again (its action the same) with the assertion. Once; the user's cancel sends
  // nothing. The vault's line for it (`recorded`) is said after.
  async function confirmed(message, reply) {
    if (reply?.error?.code !== 'assertion-needed' || message.assertion) return reply;
    const challenge = await read('act.challenge', { kind: message.kind, args: message.args, action: message.action });
    if (!challenge.ok) return challenge;
    const changed = () => emit(new Map([['connection', [{ connection: state.connection }]]]));
    state.confirming = { line: challenge.result?.line || '', kind: message.kind };
    changed();
    let assertion;
    try {
      assertion = await passkeyAssert(challenge.result, credentials());
    } catch (error) {
      state.confirming = null;
      changed();
      return { ok: false, error: { code: 'passkey-cancelled', message: error?.message || 'The passkey wasn’t given.' } };
    }
    state.confirming = null;
    changed();
    const again = await feed.request({ ...message, id: String(nextRequest++), assertion });
    if (again?.ok && again.recorded) {
      state.recorded = { line: again.recorded, at: Date.now() };
      changed();
    }
    return again;
  }

  function read(kind, args = {}) {
    if (!feed) return Promise.resolve({ ok: false, error: { code: 'not-yet', message: 'Not connected to the node yet.' } });
    return feed.request({ v: 1, id: String(nextRequest++), kind, args });
  }

  // An image for session `id`'s composer, in the parts the node takes, one after another (each an action: a part is
  // sent again after a reconnect, and the node answers a repeat as before). The last reply carries the file's `path`.
  async function attach(id, bytes, type) {
    const upload = crypto.randomUUID();
    let reply = { ok: false, error: { code: 'bad-args', message: 'No image.' } };
    for (const part of imageParts(bytes)) {
      reply = await request('session.attach', { session: id, upload, type, ...part });
      if (!reply.ok) return reply;
    }
    return reply;
  }

  // An action on a card, shown at once: the card reads as answered or held from this moment, and goes back to open,
  // saying why, if the server refuses.
  function act(card, kind, args = {}) {
    state.acting.set(card, { kind, ...args });
    emit(new Map([['cards', [{ in: 'cards', id: card, acting: true }]]]));
    return request(kind, { card, ...args }).then((reply) => {
      if (!reply.ok) {
        state.acting.set(card, { refused: reply.error?.message || 'The node refused it.', code: reply.error?.code || null });
        emit(new Map([['cards', [{ in: 'cards', id: card, acting: true }]]]));
      }
      return reply;
    });
  }

  const cardsTouched = (card) => emit(new Map([['cards', [{ in: 'cards', id: card, acting: true }]]]));

  // An answer drafted on a card (the contract's §8): shown at once as an overlay keyed by its action id, sent as
  // `draft` (or `draft.clear` for null), and kept over the card until the cards stream holds what the node acked
  // (`applied`), so the card never shows the old draft in between. A refusal takes the overlay back and says why.
  // Nothing is answered: the user confirms it with `vibeswitcher answer` in a terminal, the card's code typed.
  function draft(card, text) {
    const value = state.cards.get(card);
    if (!value?.open || !value.question) return Promise.resolve({ ok: false, error: { code: 'gone', message: 'This card is closed.' } });
    const action = crypto.randomUUID();
    const clearing = text === null;
    state.drafts.set(card, { text: clearing ? null : text, action, sent: false });
    state.draftRefused.delete(card);
    cardsTouched(card);
    const args = clearing ? { card } : { card, text, version: value.question.version };
    const mine = () => state.drafts.get(card)?.action === action;
    return request(clearing ? 'draft.clear' : 'draft', args, action).then((reply) => {
      if (!mine()) return reply;
      if (!reply.ok) {
        state.drafts.delete(card);
        state.draftRefused.set(card, reply.error?.message || 'The node refused it.');
        cardsTouched(card);
        return reply;
      }
      state.drafts.get(card).sent = true;
      cardsTouched(card);
      const applied = reply.result?.applied?.cards;
      const reached = typeof applied === 'number' && feed?.reached ? feed.reached('cards', applied) : Promise.resolve();
      return reached.then(() => {
        if (mine()) { state.drafts.delete(card); cardsTouched(card); }
        return reply;
      });
    });
  }

  // The draft card `id` shows, `{ text, sending, mine }`, or null: this page's overlay while it has one (a cleared one
  // shows none), else the node's own (left here, in another tab, on another device).
  function draftOf(id) {
    const overlay = state.drafts.get(id);
    if (overlay) return overlay.text === null ? null : { text: overlay.text, sending: !overlay.sent, mine: true };
    const card = state.cards.get(id);
    return card?.open && card.draft ? { text: card.draft.text, sending: false, mine: false } : null;
  }

  // A message for a session, drafted on the node beside it (`session.draft`, or `session.draft.clear` for null): shown
  // at once as an overlay keyed by its action id, and kept until the sessions stream reaches what the node acked
  // (`applied`), as a card's draft. Nothing is typed: the user sends it with `vibeswitcher send` in a terminal.
  const sessionTouched = (id) => emit(new Map([['sessions', [{ in: 'sessions', id, drafting: true }]]]));
  function sessionDraft(id, text, images = [], now = false) {
    if (!state.sessions.get(id)?.hosted) return Promise.resolve({ ok: false, error: { code: 'gone', message: 'This session can’t be typed into.' } });
    const action = crypto.randomUUID();
    const clearing = text === null;
    state.sessionDrafts.set(id, { text: clearing ? null : text, images: clearing ? [] : images, now: !clearing && now, action, sent: false });
    state.sessionDraftRefused.delete(id);
    sessionTouched(id);
    const mine = () => state.sessionDrafts.get(id)?.action === action;
    const args = clearing ? { session: id } : { session: id, text, ...(images.length ? { images } : {}), ...(now ? { now: true } : {}) };
    return request(clearing ? 'session.draft.clear' : 'session.draft', args, action).then((reply) => {
      if (!mine()) return reply;
      if (!reply.ok) {
        state.sessionDrafts.delete(id);
        state.sessionDraftRefused.set(id, reply.error?.message || 'The node refused it.');
        sessionTouched(id);
        return reply;
      }
      state.sessionDrafts.get(id).sent = true;
      sessionTouched(id);
      const applied = reply.result?.applied?.sessions;
      const reached = typeof applied === 'number' && feed?.reached ? feed.reached('sessions', applied) : Promise.resolve();
      return reached.then(() => {
        if (mine()) { state.sessionDrafts.delete(id); sessionTouched(id); }
        return reply;
      });
    });
  }

  // The message session `id` shows drafted, `{ text, images, now, sending, mine }`, or null: this page's overlay while
  // it has one, else the node's (left here, in another tab, on another device).
  function sessionDraftOf(id) {
    const overlay = state.sessionDrafts.get(id);
    if (overlay) return overlay.text === null ? null : { text: overlay.text, images: overlay.images || [], now: !!overlay.now, sending: !overlay.sent, mine: true };
    const draft = state.sessions.get(id)?.draft;
    return draft?.text || draft?.images?.length ? { text: draft.text || '', images: draft.images || [], now: draft.now === true, sending: false, mine: false } : null;
  }

  // A message typed into a session, shown at once as a pending row; the transcript's own row replaces it.
  function send(session, text) {
    const message = { v: 1, id: String(nextRequest++), kind: 'send', args: { session, text }, action: crypto.randomUUID() };
    const touched = new Map();
    const chat = chatOf(session);
    const id = 'pending:' + message.action;
    chat.items.push({ id, type: 'prompt', at: new Date().toISOString(), text, steered: false, fromLead: false, images: [], pending: true });
    chat.index.set(id, chat.items.length - 1);
    touch(touched, 'chat:' + session, { type: 'add', id, fresh: true, pending: true });
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
    draft,
    draftOf,
    sessionDraft,
    sessionDraftOf,
    read,
    attach,
    send,
    openChat,
    closeChat,
    pageChat,
    chatSnapshot,
    chatOps,
    chatPage,
    reconcile,
    change,
    can: (kind) => state.kinds === null || state.kinds.includes(kind),
    follows: (collection) => state.follows === null || state.follows.includes(collection),
    // A card's stable key (its first id, across a server restart's new ones).
    cardKey: (id) => state.cardKeys.get(id) || id,
    // Whether this page acts for the user (the node's `act` right): its buttons send, else they draft and show the line.
    acts: () => state.rights === null || state.rights.includes('act'),
    // Whether it may watch terminals (`watch`: a pairing confirmed in the terminal).
    watches: () => state.rights === null || state.rights.includes('watch'),
    // The terminal's offer to add a passkey, or its end (`op: ended`).
    setPasskeyOffer(offer) {
      state.passkeyOffer = offer;
      if (!offer) state.passkeyAdding = null;
      emit(new Map([['connection', [{ connection: state.connection }]]]));
    },
    // Adds a passkey for the offer: the browser asks, the node is told; then the terminal confirms it.
    async addPasskey(register) {
      const offer = state.passkeyOffer;
      if (!offer) return;
      const said = (adding) => { state.passkeyAdding = adding; emit(new Map([['connection', [{ connection: state.connection }]]])); };
      said({ state: 'adding' });
      let args;
      try {
        args = await register(offer, credentials());
      } catch (error) {
        return said({ state: 'cancelled', why: error?.message || '' });
      }
      const reply = await request('passkey.registered', args);
      said(reply.ok ? { state: 'added', id: reply.result?.id || '' } : { state: 'refused', why: reply.error?.message || '' });
    },
    clearRecorded() { state.recorded = null; emit(new Map([['connection', [{ connection: state.connection }]]])); },
    setActsLost(why) {
      if (state.actsLost === why) return;
      state.actsLost = why;
      emit(new Map([['connection', [{ connection: state.connection }]]]));
    },
    setNewerBuild(on) {
      if (state.newerBuild === on) return;
      state.newerBuild = on;
      emit(new Map([['connection', [{ connection: state.connection }]]]));
    },
    // "This tab no longer acts" dismissed; a reload asked for by the user.
    forgetActsLost() { state.actsLost = null; feed?.forgetActed?.(); emit(new Map([['connection', [{ connection: state.connection }]]])); },
    reloadNow() { feed?.reloadNow?.(); },
    setPhrase(phrase) {
      if (state.phrase === phrase) return;
      state.phrase = phrase;
      emit(new Map([['connection', [{ connection: state.connection }]]]));
    },
    setKinds(kinds, plugins = null, rights = undefined) {
      state.kinds = kinds;
      if (rights !== undefined) state.rights = Array.isArray(rights) ? rights : [];
      state.plugins = Array.isArray(plugins) ? plugins : null;
      emit(new Map([['connection', [{ connection: state.connection }]]]));
    },
    setConnection: (connection) => setConnection(connection),
    connect(source) { feed = source; },
  };
}
