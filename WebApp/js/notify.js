// Notifications (parity gap 5): while this page is open, the browser's own notification when something needs you: a
// card opens (a lead's question or approval, held config, a moved base), a session's prompt waits (its status turns
// needs you; never a worker's or a verifier's, as on the Mac, nor a lead's whose question is a card already), or a lead
// stops (its session finishes its turn or ends). Asked once, by a quiet offer the first time something needs you; then a
// toggle on This node. A notification is the first line only, as text: the browser shows it as text, and controls,
// bidirectional and other format characters are taken out first. The title bar counts what needs you: open cards and
// prompts waiting.
//
// What it decides (`summarize`, `changes`, `firstLine`, `titled`) knows nothing of the page and is tested on its own;
// `notifications(app)` puts it on the page.

import { h } from './dom.js';

const PREF = 'vibeswitcher.notifications';
const href = (id) => '#/s/' + encodeURIComponent(id);
const lastPart = (path) => String(path || '').split('/').filter(Boolean).pop() || '';

// The first line of `text`, as plain text: format and control characters (C0, C1, DEL, bidirectional overrides and
// isolates, zero-width marks, separators) left out, at most `limit` characters with an ellipsis past it.
export function firstLine(text, limit = 120) {
  const line = String(text ?? '').split(/\r\n|\r|\n|\u2028|\u2029/).map((part) => part.trim()).find(Boolean) || '';
  const clean = line.replace(/[\u0000-\u001f\u007f-\u009f\u061c\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff\ufff9-\ufffb]/g, '').trim();
  const chars = [...clean];
  return chars.length > limit ? chars.slice(0, limit - 1).join('') + '…' : clean;
}

const CARD_TITLES = { question: 'A question for you', approval: 'An approval for you', config: 'Agents’ config held', base: 'The base moved' };

function cardBody(card) {
  if (card.question) return firstLine(card.question.text || card.question.short);
  if (card.approval) return firstLine(card.approval.subject || `Merge ${String(card.approval.commit || '').slice(0, 8)}`);
  if (card.config) return firstLine((card.config.items || []).map((item) => item.name).join(', '));
  return '';
}

const working = (session) => session.status === 'working' || session.status === 'background';

// What needs you now, and each lead session's state, from the store's state:
//   asks:  key → { title, body, href }   (counted in the title bar)
//   leads: session id → { title, working, ended }
export function summarize(state) {
  const asks = new Map();
  const leads = new Map();
  const leadSession = (project) => state.leads.get(project)?.session || null;
  for (const card of state.cards.values()) {
    if (!card.open) continue;
    // A card that came back under a new id after a server restart keeps its key (store.js `cardKeys`): not told twice.
    const key = 'card:' + (state.cardKeys?.get(card.id) || card.id);
    const session = leadSession(card.project);
    asks.set(key, { title: `${CARD_TITLES[card.kind] || 'A card for you'} · ${lastPart(card.root) || 'a project'}`, body: cardBody(card), href: session ? href(session) : '#/' });
  }
  for (const session of state.sessions.values()) {
    const name = session.title || lastPart(session.cwd) || 'A session';
    if (session.role === 'lead') leads.set(session.id, { title: name, working: working(session), ended: Boolean(session.ended) });
    if (session.status !== 'needs-you' || session.paused || session.ended) continue;
    if (session.role === 'worker' || session.role === 'verifier') continue;
    if (session.role === 'lead' && session.leadAsks) continue;
    asks.set(`prompt:${session.id}:${session.since || ''}`, { title: `${name} needs you`, body: firstLine(session.detail || session.activity || 'It’s waiting for you.'), href: href(session.id) });
  }
  return { asks, leads };
}

// What to tell between two summaries: each ask that wasn't there, and each lead that was working and now isn't (done,
// idle, ended or gone). Each { key, title, body, href }.
export function changes(before, after) {
  const told = [];
  for (const [key, ask] of after.asks) if (!before.asks.has(key)) told.push({ key, ...ask });
  for (const [id, lead] of before.leads) {
    const now = after.leads.get(id);
    if (!lead.working || (now && now.working && !now.ended)) continue;
    told.push({ key: `stopped:${id}`, title: `${(now || lead).title} stopped`, body: now && !now.ended ? 'The lead finished its turn.' : 'The lead’s session ended.', href: now ? href(id) : '#/' });
  }
  return told;
}

// `title` with the count in front ("(2) VibeSwitcher"), or without one when nothing needs you.
export function titled(title, count) {
  const bare = String(title).replace(/^\(\d+\) /, '');
  return count > 0 ? `(${count}) ${bare}` : bare;
}

function stored(storage) {
  try { return storage?.getItem(PREF) ?? null; } catch { return null; }
}

function store(storage, value) {
  try { storage?.setItem(PREF, value); } catch { /* a private window: the choice lasts for this page */ }
}

// The notifier on the page. `env`: what it uses of the browser, for a test's own (Notification, storage, document).
export function notifications(app, env = {}) {
  const { store: data, ui } = app;
  const Note = 'Notification' in env ? env.Notification : globalThis.Notification;
  const storage = 'storage' in env ? env.storage : globalThis.localStorage;
  const doc = env.document || globalThis.document;
  const supported = typeof Note === 'function';
  let last = null;

  const enabled = () => supported && stored(storage) === 'on' && Note.permission === 'granted';

  // The offer, once: shown the first time something needs you while the browser hasn't been asked and you haven't
  // answered; either answer is kept.
  const offerText = h('span', null, 'Get a notification when something needs you?');
  const offer = h('div', { class: 'offline offer', role: 'status', hidden: true }, offerText,
    h('button', { class: 'offer-yes', type: 'button', onclick: () => turn(true) }, 'Turn on'),
    h('button', { class: 'offer-no', type: 'button', onclick: () => turn(false) }, 'Not now'));

  // The toggle on This node.
  const box = h('input', { type: 'checkbox', class: 'notify-toggle', onchange: () => turn(box.checked) });
  const said = h('span', { class: 'notify-said' });
  const el = h('section', { class: 'node-group notify' }, h('h2', { class: 'section-title' }, 'Notifications'),
    h('label', { class: 'notify-line' }, box, ' Tell me when something needs me, while this page is open'), said);

  function draw() {
    box.checked = enabled();
    box.disabled = !supported || Note.permission === 'denied';
    said.textContent = !supported ? 'This browser has no notifications.'
      : Note.permission === 'denied' ? 'Blocked in this browser’s settings for this page.' : '';
  }

  async function turn(on) {
    offer.hidden = true;
    if (!on || !supported) {
      store(storage, 'off');
      return draw();
    }
    const answer = Note.permission === 'default' ? await Note.requestPermission() : Note.permission;
    store(storage, answer === 'granted' ? 'on' : 'off');
    draw();
  }

  function count(summary) {
    if (doc) doc.title = titled(doc.title, summary.asks.size);
  }

  function show(note) {
    const looking = doc && doc.visibilityState === 'visible' && doc.hasFocus?.() && ui.state.route.name === 'session' && note.href === href(ui.state.route.id);
    if (looking) return;
    const shown = new Note(note.title, { body: note.body, tag: note.key });
    shown.onclick = () => {
      globalThis.focus?.();
      if (note.href) ui.go(note.href);
      shown.close?.();
    };
  }

  function look() {
    // Nothing is told for the first snapshot: only what changes while the page is open.
    if (data.state.connection !== 'live' && last === null) return;
    const now = summarize(data.state);
    count(now);
    if (last !== null) {
      const told = changes(last, now);
      if (told.length && supported && Note.permission === 'default' && stored(storage) === null) offer.hidden = false;
      if (enabled()) told.forEach(show);
    }
    last = now;
  }

  for (const topic of ['cards', 'sessions', 'leads', 'connection']) data.subscribe(topic, look);
  // The page's own title changes with the route (app.js, the board): the count goes back in front.
  if (doc?.querySelector && typeof MutationObserver === 'function') {
    const title = doc.querySelector('title');
    if (title) new MutationObserver(() => { if (last) { const next = titled(doc.title, last.asks.size); if (next !== doc.title) doc.title = next; } }).observe(title, { childList: true });
  }
  draw();
  look();
  return { el, offer, look, turn, enabled };
}
