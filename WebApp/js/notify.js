// Notifications (parity gap 5): while this page is open, the browser's own notification when something needs you: a
// card opens (a lead's question or approval, held config, a moved base), a session's prompt waits (its status turns
// needs you; never a worker's or a verifier's, as on the Mac, nor a lead's whose question is a card already), or a lead
// stops (its session finishes its turn or ends), one of your own sessions finishes its work (never a worker's or a
// verifier's: the Mac's "when a session finishes"), or the node's engine froze (a freeze its health digest keeps, told once,
// never one kept before the page looked). Asked once, by a quiet offer the first time something needs you; then a
// toggle on This node. A notification is the first line only, as text: the browser shows it as text, and controls,
// bidirectional and other format characters are taken out first. The title bar counts what needs you: open cards and
// prompts waiting.
//
// A sound too, when something new needs you (a card or a prompt; not a lead that stopped), the Mac's Settings ›
// Notifications sound (2026-11-20): its own toggle on This node, off until turned on (a page can't play before you've
// clicked on it), a short soft chime made on the page (`chime`: no file fetched), not played for the session you're
// looking at.
//
// Which kinds are told is a choice on This node, kept in this browser: something needs me, a session finishes, and a
// reminder about a session left waiting on you 10 minutes or showing no progress for 15 (the node's `reminders`, the
// Mac's "Remind me about waiting or stuck sessions": once a wait or a stall); all on by default, as the Mac's.
//
// What it decides (`summarize`, `changes`, `wanted`, `firstLine`, `titled`, `sounding`) knows nothing of the page and is tested on
// its own; `notifications(app)` puts it on the page.

import { h } from './dom.js';
import { pluginOn, pluginsOn } from './plugincard.js';

const PREF = 'vibeswitcher.notifications';
const SOUND = 'vibeswitcher.sound';
// Each kind's choice (`kindOf`): 'off' turns it off; on otherwise, as the Mac's defaults.
const KINDS = { needs: 'vibeswitcher.notify.needs', done: 'vibeswitcher.notify.done', reminders: 'vibeswitcher.notify.reminders' };
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

const CARD_TITLES = { question: 'A question for you', approval: 'An approval for you', config: 'Agents’ config held', base: 'The base moved', shell: 'A shell asked for' };

function cardBody(card) {
  if (card.question) return firstLine(card.question.text || card.question.short);
  if (card.approval) return firstLine(card.approval.subject || `Merge ${String(card.approval.commit || '').slice(0, 8)}`);
  if (card.config) return firstLine((card.config.items || []).map((item) => item.name).join(', '));
  if (card.shell) return firstLine(`${card.shell.asker}: ${card.shell.command}`);
  // A feature plugin's: who asks, and the first line of what it asks.
  if (card.plugin) return firstLine(`${card.plugin.asker}: ${(card.plugin.body?.lines || []).join('\n')}`);
  return '';
}

const working = (session) => session.status === 'working' || session.status === 'background';

// What needs you now, and each lead session's state, from the store's state:
//   asks:  key → { title, body, href }   (counted in the title bar)
//   leads: session id → { title, working, ended }
//   own:   session id → { title, working, ended }   (your own sessions: no lead's, worker's or verifier's)
export function summarize(state) {
  const asks = new Map();
  const leads = new Map();
  const own = new Map();
  const leadSession = (project) => state.leads.get(project)?.session || null;
  for (const card of state.cards.values()) {
    if (!card.open) continue;
    // A card that came back under a new id after a server restart keeps its key (store.js `cardKeys`): not told twice.
    const key = 'card:' + (state.cardKeys?.get(card.id) || card.id);
    const session = leadSession(card.project);
    // A plugin's card is told only while the node has its plugin on (`hello.plugins`; null: a node before plugins).
    if (card.plugin && !pluginOn(pluginsOn(state), card.plugin.plugin)) continue;
    const title = card.plugin?.title || CARD_TITLES[card.kind] || 'A card for you';
    asks.set(key, { title: `${title} · ${lastPart(card.root) || 'a project'}`, body: cardBody(card), href: session ? href(session) : '#/' });
  }
  for (const session of state.sessions.values()) {
    const name = session.title || lastPart(session.cwd) || 'A session';
    if (session.role === 'lead') leads.set(session.id, { title: name, working: working(session), ended: Boolean(session.ended) });
    else if (!session.role) own.set(session.id, { title: name, working: working(session), ended: Boolean(session.ended), paused: Boolean(session.paused) });
    if (session.status !== 'needs-you' || session.paused || session.ended) continue;
    if (session.role === 'worker' || session.role === 'verifier') continue;
    if (session.role === 'lead' && session.leadAsks) continue;
    asks.set(`prompt:${session.id}:${session.since || ''}`, { title: `${name} needs you`, body: firstLine(session.detail || session.activity || 'It’s waiting for you.'), href: href(session.id) });
  }
  // The node's reminders due now (`reminders`): one key a wait or a stall (its episode), so each is told once.
  const reminders = new Map();
  for (const reminder of state.node?.reminders || []) {
    const session = state.sessions.get(reminder.session);
    if (session?.paused || session?.ended) continue;
    reminders.set(`reminder:${reminder.session}:${reminder.kind}:${reminder.since}`, {
      title: firstLine(reminder.title), body: firstLine([reminder.subtitle, reminder.body].filter(Boolean).join(' · ')), href: href(reminder.session),
    });
  }
  // The engine's newest freeze (the node's health digest): '' for none yet, null while the node keeps no digest.
  const health = state.node?.health;
  const freeze = health ? (health.freezes?.[0]?.at || '') : null;
  return { asks, leads, own, reminders, freeze, freezeSeconds: health?.freezes?.[0]?.seconds || 0 };
}

// What to tell between two summaries: each ask that wasn't there, and each lead that was working and now isn't (done,
// idle, ended or gone). Each { key, title, body, href }.
export function changes(before, after) {
  const told = [];
  for (const [key, ask] of after.asks) if (!before.asks.has(key)) told.push({ key, ...ask });
  for (const [key, reminder] of after.reminders || []) if (!(before.reminders || new Map()).has(key)) told.push({ key, ...reminder });
  // A freeze kept since the last look (never one from before this page looked: `before.freeze` null).
  if (before.freeze != null && after.freeze && after.freeze !== before.freeze) {
    told.push({ key: `freeze:${after.freeze}`, title: 'The node froze', body: `Its engine didn’t answer for ${after.freezeSeconds} s. This node shows its health.`, href: '#/node' });
  }
  for (const [id, lead] of before.leads) {
    const now = after.leads.get(id);
    if (!lead.working || (now && now.working && !now.ended)) continue;
    told.push({ key: `stopped:${id}`, title: `${(now || lead).title} stopped`, body: now && !now.ended ? 'The lead finished its turn.' : 'The lead’s session ended.', href: now ? href(id) : '#/' });
  }
  // One of your own sessions finished its work (the Mac's "Notify when a session finishes": never a worker's or a
  // verifier's, nor one you paused): it was working and now isn't, or it ended.
  for (const [id, session] of before.own || []) {
    const now = (after.own || new Map()).get(id);
    if (!session.working || session.paused || (now && now.working && !now.ended)) continue;
    told.push({ key: `finished:${id}`, title: `${(now || session).title} finished`, body: now && !now.ended ? 'It finished its work.' : 'Its session ended.', href: now ? href(id) : '#/' });
  }
  return told;
}

// The kind a note is of, for Settings › Notifications' choices: `needs` (a card, a prompt waiting, the node frozen),
// `done` (a lead stopped, a session of yours finished) or `reminders` (left waiting, or no progress).
export const kindOf = (note) => (/^(stopped|finished):/.test(note.key) ? 'done' : /^reminder:/.test(note.key) ? 'reminders' : 'needs');

// The kinds told by the choices kept: each on unless turned off.
export function wanted(told, choices) {
  return told.filter((note) => choices[kindOf(note)] !== false);
}

// `title` with the count in front ("(2) VibeSwitcher"), or without one when nothing needs you.
export function titled(title, count) {
  const bare = String(title).replace(/^\(\d+\) /, '');
  return count > 0 ? `(${count}) ${bare}` : bare;
}

// Whether what's told calls for the sound: something new that needs you (a card, a prompt), not a lead that stopped.
export function sounding(told) {
  return told.some((note) => /^(card|prompt):/.test(note.key));
}

// A short soft chime on `context` (an AudioContext): two sine notes, a fifth apart, each fading out within 0.4 s.
export function chime(context) {
  const start = context.currentTime;
  [[660, 0], [990, 0.12]].forEach(([frequency, after]) => {
    const tone = context.createOscillator();
    const level = context.createGain();
    tone.type = 'sine';
    tone.frequency.value = frequency;
    level.gain.setValueAtTime(0.0001, start + after);
    level.gain.exponentialRampToValueAtTime(0.12, start + after + 0.02);
    level.gain.exponentialRampToValueAtTime(0.0001, start + after + 0.4);
    tone.connect(level);
    level.connect(context.destination);
    tone.start(start + after);
    tone.stop(start + after + 0.42);
  });
}

function stored(storage, key = PREF) {
  try { return storage?.getItem(key) ?? null; } catch { return null; }
}

function store(storage, value, key = PREF) {
  try { storage?.setItem(key, value); } catch { /* a private window: the choice lasts for this page */ }
}

// The notifier on the page. `env`: what it uses of the browser, for a test's own (Notification, storage, document).
export function notifications(app, env = {}) {
  const { store: data, ui } = app;
  const Note = 'Notification' in env ? env.Notification : globalThis.Notification;
  const storage = 'storage' in env ? env.storage : globalThis.localStorage;
  const doc = env.document || globalThis.document;
  const supported = typeof Note === 'function';
  const Audio = 'AudioContext' in env ? env.AudioContext : globalThis.AudioContext;
  let last = null;
  let audio = null;

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
  // The sound's toggle beside it.
  const ring = h('input', { type: 'checkbox', class: 'sound-toggle', onchange: () => sound(ring.checked) });
  // Each kind's choice (the Mac's Settings › Notifications): something needs me; a session finishes.
  const kindBoxes = {
    needs: h('input', { type: 'checkbox', class: 'notify-kind', onchange: () => choose('needs', kindBoxes.needs.checked) }),
    done: h('input', { type: 'checkbox', class: 'notify-kind', onchange: () => choose('done', kindBoxes.done.checked) }),
    reminders: h('input', { type: 'checkbox', class: 'notify-kind', onchange: () => choose('reminders', kindBoxes.reminders.checked) }),
  };
  const el = h('section', { class: 'node-group notify' }, h('h2', { class: 'section-title' }, 'Notifications'),
    h('label', { class: 'notify-line' }, box, ' Tell me when something happens, while this page is open'), said,
    h('label', { class: 'notify-line notify-sub' }, kindBoxes.needs, ' When a session or a lead needs me (a question, an approval, a prompt waiting)'),
    h('label', { class: 'notify-line notify-sub' }, kindBoxes.done, ' When a lead stops or a session of mine finishes'),
    h('label', { class: 'notify-line notify-sub' }, kindBoxes.reminders, ' Remind me about waiting or stuck sessions (waiting on me 10 minutes, no progress for 15)'),
    h('label', { class: 'notify-line' }, ring, ' Play a sound when something needs me'));

  const choices = () => ({ needs: stored(storage, KINDS.needs) !== 'off', done: stored(storage, KINDS.done) !== 'off',
    reminders: stored(storage, KINDS.reminders) !== 'off' });
  function choose(kind, on) {
    store(storage, on ? 'on' : 'off', KINDS[kind]);
    draw();
  }

  const soundOn = () => typeof Audio === 'function' && stored(storage, SOUND) === 'on';

  function draw() {
    box.checked = enabled();
    box.disabled = !supported || Note.permission === 'denied';
    said.textContent = !supported ? 'This browser has no notifications.'
      : Note.permission === 'denied' ? 'Blocked in this browser’s settings for this page.' : '';
    const chosen = choices();
    for (const kind of Object.keys(kindBoxes)) {
      kindBoxes[kind].checked = chosen[kind];
      kindBoxes[kind].disabled = !enabled();
    }
    ring.checked = soundOn();
    ring.disabled = typeof Audio !== 'function';
  }

  // Plays the chime; the context made (or woken) on the toggle's click, which is what lets a page play at all.
  function play() {
    try {
      audio = audio || new Audio();
      if (audio.state === 'suspended') audio.resume?.();
      chime(audio);
    } catch { /* no sound here: nothing else depends on it */ }
  }

  function sound(on) {
    store(storage, on ? 'on' : 'off', SOUND);
    if (on) play();
    draw();
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

  const lookingAt = (note) => doc && doc.visibilityState === 'visible' && doc.hasFocus?.() && ui.state.route.name === 'session' && note.href === href(ui.state.route.id);

  function show(note) {
    if (lookingAt(note)) return;
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
      const chosen = wanted(told, choices());
      if (enabled()) chosen.forEach(show);
      if (soundOn() && sounding(chosen.filter((note) => !lookingAt(note)))) play();
    }
    last = now;
  }

  for (const topic of ['cards', 'sessions', 'leads', 'connection', 'node']) data.subscribe(topic, look);
  // The page's own title changes with the route (app.js, the board): the count goes back in front.
  if (doc?.querySelector && typeof MutationObserver === 'function') {
    const title = doc.querySelector('title');
    if (title) new MutationObserver(() => { if (last) { const next = titled(doc.title, last.asks.size); if (next !== doc.title) doc.title = next; } }).observe(title, { childList: true });
  }
  draw();
  look();
  return { el, offer, look, turn, enabled, sound };
}
