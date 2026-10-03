'use strict';
// VibeSwitcher phone app. All session text is inserted with textContent, never as HTML.

const $ = id => document.getElementById(id);
const STATUS_COLORS = {
  needsInput: '#ff453a', working: '#ff9f0a', background: '#0a84ff', done: '#30d158', idle: '#8e8e93', unknown: 'transparent',
};
const ORDER = ['needsInput', 'working', 'background', 'done'];
const LABELS = { needsInput: 'need you', working: 'working', background: 'background', done: 'done' };

let token = localStorage.getItem('vs.token');
let state = null;
let current = null;           // tty of the open session
let listTimer = null;
let screenTimer = null;
let clockOffset = 0;          // Mac clock minus phone clock, seconds

// ---------- API ----------

const UNREACHABLE = "Can't reach your Mac. Is Tailscale on here, and is the Mac awake?";

async function api(path, options = {}, authToken = token) {
  const headers = { 'Content-Type': 'application/json' };
  if (authToken) headers.Authorization = `Bearer ${authToken}`;
  // A dropped connection (phone off Wi-Fi, Mac asleep) must not leave requests hanging for minutes.
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), options.timeout || 10000);
  let response;
  try {
    response = await fetch(path, { ...options, headers, cache: 'no-store', credentials: 'omit', signal: controller.signal });
  } catch (error) {
    setOnline(false);
    throw new Error(UNREACHABLE);
  } finally {
    clearTimeout(timer);
  }
  let body = {};
  try { body = await response.json(); } catch (e) { /* empty or non-JSON body (e.g. Tailscale's 502) */ }
  // Our server always answers errors with a JSON message; a bare error (404, 502, 504) comes from
  // Tailscale itself, meaning VibeSwitcher isn't running or Phone Access is off.
  if (!response.ok && !body.error) {
    const message = "VibeSwitcher isn't running on your Mac, or Phone Access is off.";
    setOnline(false, message);
    throw new Error(message);
  }
  setOnline(true);
  if (response.status === 401 && authToken === token) {
    forgetToken();
    throw new Error(body.error || 'Not paired');
  }
  if (!response.ok) throw new Error(body.error || `Error ${response.status}`);
  return body;
}

function setOnline(online, message = UNREACHABLE) {
  const banner = $('offline');
  banner.hidden = online;
  if (!online) banner.textContent = message;
  layoutSession();
}

function forgetToken() {
  token = null;
  localStorage.removeItem('vs.token');
  show('pair');
}

// ---------- Views ----------

function show(view) {
  for (const id of ['pair', 'list', 'session']) $(id).hidden = id !== view;
  $('back').hidden = view !== 'session';
  $('prev').hidden = view !== 'session';
  $('next').hidden = view !== 'session';
  document.body.classList.toggle('in-session', view === 'session');
  $('bell').hidden = view === 'pair';
  clearInterval(listTimer);
  clearInterval(screenTimer);
  if (view === 'list') {
    current = null;
    $('title').textContent = 'VibeSwitcher';
    refreshList();
    listTimer = setInterval(() => { if (!document.hidden) refreshList(); }, 3000);
  } else if (view === 'session') {
    refreshScreen();
    screenTimer = setInterval(() => { if (!document.hidden) { refreshScreen(); refreshList(false); } }, 1500);
  } else {
    $('title').textContent = 'VibeSwitcher';
    $('subtitle').textContent = '';
  }
}

function elapsed(since) {
  if (!since) return '';
  const seconds = Math.max(0, Math.floor(Date.now() / 1000 + clockOffset - since));
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ${Math.floor(seconds % 3600 / 60)}m`;
  return `${Math.floor(seconds / 86400)}d ${Math.floor(seconds % 86400 / 3600)}h`;
}

function duration(seconds) { return elapsed(Date.now() / 1000 + clockOffset - seconds); }

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined && text !== null) node.textContent = text;
  return node;
}

function badge(session) {
  const node = el('span', `badge ${session.paused ? 'paused' : session.status}`, String(session.number));
  node.style.background = session.paused ? 'var(--paused)' : (STATUS_COLORS[session.status] || 'transparent');
  if (session.viewing) node.classList.add('viewing');
  return node;
}

let listBusy = false;
let screenBusy = false;

async function refreshList(render = true) {
  if (listBusy || !token) return;   // one poll at a time: a slow network must not stack requests
  listBusy = true;
  try {
    state = await api('/api/state');
  } catch (error) {
    return;
  } finally {
    listBusy = false;
  }
  if (!pushChecked) { pushChecked = true; syncPushSubscription(); }
  clockOffset = state.now - Date.now() / 1000;
  $('subtitle').textContent = state.mac;
  $('notifyCard').hidden = Boolean(state.device.push) || !('PushManager' in window);
  $('bell').classList.toggle('on', Boolean(state.device.push));
  if (current) return renderSessionMeta();
  if (render) renderList();
}

function renderList() {
  const sessions = state.sessions;
  const counts = $('counts');
  counts.replaceChildren();
  for (const status of ORDER) {
    const count = sessions.filter(s => s.status === status && !s.paused).length;
    if (!count) continue;
    const chip = el('span', 'chip');
    const dot = el('i');
    dot.style.background = STATUS_COLORS[status];
    chip.append(dot, `${count} ${LABELS[status]}`);
    counts.append(chip);
  }
  const paused = sessions.filter(s => s.paused).length;
  if (paused) counts.append(el('span', 'chip', `⏸ ${paused} paused`));
  const list = $('sessions');
  list.replaceChildren(...sessions.map(session => {
    const row = el('button', session.paused ? 'row paused' : 'row');
    row.type = 'button';
    row.addEventListener('click', () => openSession(session.tty));
    const text = el('div', 'text');
    const first = el('div', 'line1');
    first.append(el('b', 'name', session.name), el('span', `agent ${session.agent}`, session.agent === 'claude' ? 'Claude' : 'Codex'));
    if (session.paused) first.append(el('span', 'pausedTag', '⏸ Paused'));
    const when = el('span', `when ${session.status}`, `${session.statusLabel} ${elapsed(session.since)}`.trim());
    first.append(when);
    text.append(first);
    if (session.task) text.append(el('div', 'task', session.task));
    if (session.activity) text.append(el('div', 'detail', `⚙ ${session.activity} · ${elapsed(session.activitySince)}`));
    else if (session.detail) text.append(el('div', `detail ${session.status === 'needsInput' ? 'strong' : ''}`, session.detail));
    row.append(badge(session), text);
    return row;
  }));
  $('empty').hidden = sessions.length > 0;
  renderToday();
}

function renderToday() {
  const today = state.today;
  const box = $('today');
  box.hidden = !today || (today.agentsWorking < 60 && today.waitingOnYou < 60);
  if (box.hidden) return;
  $('todayLine').textContent = `${duration(today.agentsWorking)} agents working · ${duration(today.waitingOnYou)} waiting on you`;
  $('todayRows').replaceChildren(...today.projects.map(p => {
    const row = el('div', 'todayRow');
    row.append(el('span', 'name', p.project),
               el('span', 'muted', `worked ${duration(p.working)}`),
               el('span', p.waiting > p.working ? 'warn' : 'muted', `waited ${duration(p.waiting)}`));
    return row;
  }));
}

// ---------- Session view ----------

const BOX = /^[\s─-╿]+$/;            // a line drawn only with box characters: a rule
const prefs = {
  font: Number(localStorage.getItem('vs.font')) || 12,
  wrap: localStorage.getItem('vs.wrap') !== 'off',
};
let lastScreenText = null;

function applyViewPrefs() {
  const screen = $('screen');
  screen.style.setProperty('--term-font', `${prefs.font}px`);
  screen.classList.toggle('nowrap', !prefs.wrap);
  $('wrapToggle').classList.toggle('on', prefs.wrap);
  $('wrapToggle').setAttribute('aria-pressed', String(prefs.wrap));
  localStorage.setItem('vs.font', String(prefs.font));
  localStorage.setItem('vs.wrap', prefs.wrap ? 'on' : 'off');
}

function openSession(tty) {
  current = tty;
  history.replaceState(null, '', `#s=${tty}`);
  lastScreenText = null;
  $('screen').replaceChildren();
  $('screenError').hidden = true;
  setInputStatus('');
  $('reply').value = '';
  growReply();
  renderSessionMeta();
  show('session');
  layoutSession();
}

/// Steps to the previous/next session in the list (same order as the Mac).
function step(delta) {
  if (!state || !current) return;
  const index = state.sessions.findIndex(s => s.tty === current);
  const next = state.sessions[index + delta];
  if (next) openSession(next.tty);
}

function renderSessionMeta() {
  const session = state && state.sessions.find(s => s.tty === current);
  const index = session ? state.sessions.indexOf(session) : -1;
  $('prev').disabled = index <= 0;
  $('next').disabled = index < 0 || index >= state.sessions.length - 1;
  if (!session) {
    $('title').textContent = 'Session ended';
    $('sessionMeta').replaceChildren();
    $('composer').hidden = true;
    $('askCard').hidden = true;
    return;
  }
  $('title').textContent = session.name;
  $('subtitle').textContent = session.task || '';
  const meta = $('sessionMeta');
  const status = el('span', `when ${session.status}`, `${session.statusLabel} ${elapsed(session.since)}`.trim());
  meta.replaceChildren(badge(session), status);
  if (session.activity) meta.append(el('span', 'activity', `⚙ ${session.activity} · ${elapsed(session.activitySince)}`));
  // What it's asking you, where you'll answer it.
  const asking = session.status === 'needsInput' && !session.paused;
  $('askCard').hidden = !asking;
  if (asking) $('askText').textContent = session.detail || 'Waiting for you';
  renderPauseControls(session);
  const canType = state.inputAllowed && session.inTerminal;
  $('composer').hidden = !canType;
  $('inputOff').hidden = state.inputAllowed || !session.inTerminal;
  $('reply').placeholder = `Message ${session.name}…`;
  layoutSession();
}

function pauseLabel(session) {
  if (!session.pausedUntil) return 'Paused';
  const until = new Date(session.pausedUntil * 1000);
  const sameDay = until.toDateString() === new Date().toDateString();
  return `Until ${until.toLocaleString([], sameDay ? { hour: '2-digit', minute: '2-digit' }
                                                    : { weekday: 'short', hour: '2-digit', minute: '2-digit' })}`;
}

function renderPauseControls(session) {
  $('pausedInfo').hidden = !session.paused;
  $('resume').hidden = !session.paused;
  $('pauseSelect').hidden = session.paused;
  if (session.paused) $('pausedInfo').textContent = `⏸ ${pauseLabel(session)}`;
}

async function setPause(duration, control) {
  if (!current || !duration) return;
  control.disabled = true;
  try {
    await api('/api/pause', { method: 'POST', body: JSON.stringify({ tty: current, duration }) });
    setTimeout(() => refreshList(false), 300);
  } catch (error) {
    setInputStatus(error.message, true);
  } finally {
    control.disabled = false;
    if (control.tagName === 'SELECT') control.value = '';
  }
}

async function refreshScreen() {
  if (!current || screenBusy) return;
  screenBusy = true;
  try { await loadScreen(); } finally { screenBusy = false; }
}

function isAtBottom() {
  const screen = $('screen');
  return screen.scrollHeight - screen.scrollTop - screen.clientHeight < 40;
}

/// Terminal text made for a phone: trailing padding trimmed (Terminal pads every line to the window
/// width, which wraps into blank lines), rules drawn as a thin line, long box-character runs shortened.
function renderScreen(text) {
  const fragment = document.createDocumentFragment();
  for (const raw of text.split('\n')) {
    const line = raw.replace(/\s+$/, '');
    const node = document.createElement('div');
    if (BOX.test(line) && line.trim().length >= 6) {
      node.className = 'rule';
    } else {
      node.className = 'ln';
      node.textContent = line.replace(/([─-╿])\1{7,}/g, (run, c) => c.repeat(6)) || ' ';
    }
    fragment.append(node);
  }
  $('screen').replaceChildren(fragment);
}

async function loadScreen() {
  const screen = $('screen');
  const stick = lastScreenText === null || isAtBottom();
  try {
    const result = await api(`/api/screen?tty=${encodeURIComponent(current)}`);
    if (result.tty !== current) return;   // switched sessions meanwhile
    if (result.text !== lastScreenText) {
      lastScreenText = result.text;
      renderScreen(result.text);
      if (stick) screen.scrollTop = screen.scrollHeight;
    }
    $('screenError').hidden = true;
  } catch (error) {
    $('screenError').textContent = error.message;
    $('screenError').hidden = false;
  }
  $('toBottom').hidden = isAtBottom();
}

/// Session view fills the screen between the header and the composer (which stays above the keyboard).
function layoutSession() {
  if ($('session').hidden) return;
  const top = document.querySelector('header').offsetHeight + ($('offline').hidden ? 0 : $('offline').offsetHeight);
  document.documentElement.style.setProperty('--top', `${top}px`);
}

function growReply() {
  const reply = $('reply');
  reply.style.height = 'auto';
  reply.style.height = `${Math.min(reply.scrollHeight, 132)}px`;
  $('clearReply').hidden = !reply.value;
}

// ---------- Quick replies ----------

const DEFAULT_QUICK_REPLIES = ['Yes, go ahead', 'Continue', 'Show me the diff', 'Run the tests', 'Explain briefly'];

function quickReplies() {
  try {
    const saved = JSON.parse(localStorage.getItem('vs.quickReplies'));
    if (Array.isArray(saved)) return saved.filter(t => typeof t === 'string' && t.trim());
  } catch (e) { /* fall back to defaults */ }
  return DEFAULT_QUICK_REPLIES;
}

function renderQuickReplies() {
  const box = $('quickReplies');
  const chips = quickReplies().map(text => {
    const chip = el('button', 'quickChip', text);
    chip.type = 'button';
    chip.addEventListener('click', () => {
      const session = state && state.sessions.find(s => s.tty === current);
      // A question or menu is open: text doesn't answer it (1–3 / arrows do) and gets taken as
      // "let's discuss the question" instead. Put the reply in the box rather than sending it.
      if (session && session.status === 'needsInput') {
        $('reply').value = text;
        growReply();
        $('reply').focus();
        setInputStatus('A question is open: answer it with 1–3 / ↑↓ ⏎, or tap Send to send this text.', true);
        return;
      }
      // Otherwise it's sent right away, like typing it and pressing Enter.
      send({ text, submit: true }, chip);
    });
    return chip;
  });
  const editButton = el('button', 'quickChip edit', '✎');
  editButton.type = 'button';
  editButton.setAttribute('aria-label', 'Edit quick replies');
  editButton.addEventListener('click', openQuickEditor);
  box.replaceChildren(...chips, editButton);
}

function openQuickEditor() {
  $('quickText').value = quickReplies().join('\n');
  $('quickEditor').hidden = false;
  $('quickReplies').hidden = true;
  $('quickText').focus();
}

function closeQuickEditor() {
  $('quickEditor').hidden = true;
  $('quickReplies').hidden = false;
}

function saveQuickReplies(list) {
  const clean = list.map(t => t.trim().slice(0, 200)).filter(Boolean).slice(0, 12);
  localStorage.setItem('vs.quickReplies', JSON.stringify(clean));
  renderQuickReplies();
  closeQuickEditor();
}

let statusTimer = null;
function setInputStatus(message, isError = false) {
  const status = $('inputStatus');
  status.textContent = message;
  status.classList.toggle('error', isError);
  status.hidden = !message;
  clearTimeout(statusTimer);
  if (message && !isError) statusTimer = setTimeout(() => { status.hidden = true; }, 2000);
}

async function send(payload, button) {
  if (!current) return false;
  if (button) button.disabled = true;
  try {
    await api('/api/input', { method: 'POST', body: JSON.stringify({ tty: current, ...payload }) });
    const label = button && button.classList.contains('quickChip') ? `“${payload.text}” sent ✓` : 'Sent ✓';
    setInputStatus(payload.text && payload.submit ? label : `${button ? button.textContent : 'Key'} ✓`);
    setTimeout(refreshScreen, 250);
    setTimeout(refreshScreen, 1200);
    return true;
  } catch (error) {
    setInputStatus(error.message, true);
    return false;
  } finally {
    if (button) button.disabled = false;
  }
}

// ---------- Pairing ----------

async function pair(event) {
  event.preventDefault();
  $('pairError').hidden = true;
  try {
    const result = await api('/api/pair', {
      method: 'POST',
      body: JSON.stringify({ code: $('code').value, name: $('deviceName').value || defaultName() }),
    });
    // Pairing again from a phone that was already paired: retire the old entry on the Mac.
    const previous = localStorage.getItem('vs.previousToken');
    if (previous) api('/api/unpair', { method: 'POST', body: '{}' }, previous).catch(() => {});
    localStorage.removeItem('vs.previousToken');
    token = result.token;
    localStorage.setItem('vs.token', token);
    history.replaceState(null, '', '/');
    show('list');
  } catch (error) {
    $('pairError').textContent = error.message;
    $('pairError').hidden = false;
  }
}

function defaultName() {
  const ua = navigator.userAgent;
  const model = (ua.match(/Android [\d.]+; ([^;)]+)/) || [])[1];
  return model && model !== 'K' ? model : (/Android/.test(ua) ? 'Android phone' : 'Phone');
}

// ---------- Notifications ----------

function keyBytes(base64url) {
  const base64 = base64url.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - base64url.length % 4) % 4);
  return Uint8Array.from(atob(base64), c => c.charCodeAt(0));
}

/// A subscription made for this Mac's current key (a new key needs a new subscription).
async function currentSubscription() {
  const registration = await navigator.serviceWorker.ready;
  const wanted = keyBytes(state.vapidPublicKey);
  let subscription = await registration.pushManager.getSubscription();
  const key = subscription && subscription.options && subscription.options.applicationServerKey;
  if (subscription && key && !sameBytes(new Uint8Array(key), wanted)) {
    await subscription.unsubscribe();
    subscription = null;
  }
  return subscription || registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: wanted });
}

function sameBytes(a, b) {
  return a.length === b.length && a.every((value, index) => value === b[index]);
}

let pushChecked = false;

/// Once per app start: if notifications were allowed, make sure the Mac has this browser's current
/// subscription (browsers rotate them; the Mac drops ones the push service rejects).
async function syncPushSubscription() {
  if (!('serviceWorker' in navigator) || !('PushManager' in window) || Notification.permission !== 'granted') return;
  try {
    const subscription = await currentSubscription();
    await api('/api/push', { method: 'POST', body: JSON.stringify(subscription.toJSON()) });
  } catch (error) { /* shown via the card if it matters */ }
}

async function enableNotifications() {
  $('notifyError').hidden = true;
  try {
    if (!('serviceWorker' in navigator) || !('PushManager' in window)) throw new Error('This browser has no web push.');
    const permission = await Notification.requestPermission();
    if (permission !== 'granted') throw new Error('Notifications are blocked for this site in the browser settings.');
    const subscription = await currentSubscription();
    await api('/api/push', { method: 'POST', body: JSON.stringify(subscription.toJSON()) });
    await api('/api/push/test', { method: 'POST', body: '{}' });
    refreshList();
  } catch (error) {
    $('notifyError').textContent = error.message;
    $('notifyError').hidden = false;
    $('notifyCard').hidden = false;
  }
}

// ---------- Startup ----------

function route() {
  const hash = location.hash.slice(1);
  const params = new URLSearchParams(hash);
  if (params.get('pair')) {
    $('code').value = params.get('pair');
    $('deviceName').value = defaultName();
    if (token) localStorage.setItem('vs.previousToken', token);
    forgetToken();
    return;
  }
  if (!token) { $('deviceName').value = defaultName(); return show('pair'); }
  const tty = params.get('s');
  if (tty && /^ttys\d{1,4}$/.test(tty)) {
    api('/api/state').then(result => { state = result; openSession(tty); }).catch(() => show('list'));
  } else {
    show('list');
  }
}

document.addEventListener('DOMContentLoaded', () => {
  $('pairForm').addEventListener('submit', pair);
  $('back').addEventListener('click', () => { history.replaceState(null, '', '/'); show('list'); });
  $('bell').addEventListener('click', enableNotifications);
  $('notifyOn').addEventListener('click', enableNotifications);
  $('unpair').addEventListener('click', async () => {
    try { await api('/api/unpair', { method: 'POST', body: '{}' }); } catch (e) { /* already gone */ }
    forgetToken();
  });
  for (const button of document.querySelectorAll('.keys button')) {
    button.addEventListener('click', () => button.dataset.key
      ? send({ key: button.dataset.key }, button)
      : send({ text: button.dataset.text, submit: false }, button));
  }
  const reply = $('reply');
  reply.addEventListener('input', growReply);
  reply.addEventListener('keydown', event => {
    // Enter sends (the phone keyboard's send key too); the agent's box is single-line anyway.
    if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      $('replyForm').requestSubmit();
    }
  });
  // Clear only empties the phone's box; nothing is sent. Keeping the press from taking focus keeps
  // the keyboard up, so you can start retyping straight away.
  $('clearReply').addEventListener('pointerdown', event => event.preventDefault());
  $('clearReply').addEventListener('click', () => {
    reply.value = '';
    growReply();
    reply.focus();
  });
  $('replyForm').addEventListener('submit', async event => {
    event.preventDefault();
    if (!reply.value.trim()) return reply.focus();
    if (await send({ text: reply.value.replace(/\s*\n\s*/g, ' '), submit: true }, $('sendButton'))) {
      reply.value = '';
      growReply();
    }
  });
  $('screen').addEventListener('scroll', () => { $('toBottom').hidden = isAtBottom(); }, { passive: true });
  $('toBottom').addEventListener('click', () => {
    const screen = $('screen');
    screen.scrollTop = screen.scrollHeight;
    $('toBottom').hidden = true;
  });
  $('wrapToggle').addEventListener('click', () => { prefs.wrap = !prefs.wrap; applyViewPrefs(); });
  $('fontDown').addEventListener('click', () => { prefs.font = Math.max(8, prefs.font - 1); applyViewPrefs(); });
  $('fontUp').addEventListener('click', () => { prefs.font = Math.min(20, prefs.font + 1); applyViewPrefs(); });
  $('pauseSelect').addEventListener('change', event => setPause(event.target.value, event.target));
  $('resume').addEventListener('click', event => setPause('resume', event.target));
  $('quickSave').addEventListener('click', () => saveQuickReplies($('quickText').value.split('\n')));
  $('quickCancel').addEventListener('click', closeQuickEditor);
  $('quickReset').addEventListener('click', () => saveQuickReplies(DEFAULT_QUICK_REPLIES));
  renderQuickReplies();
  $('prev').addEventListener('click', () => step(-1));
  $('next').addEventListener('click', () => step(1));
  window.addEventListener('resize', layoutSession);
  applyViewPrefs();
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) return;
    if (current) refreshScreen(); else if (token) refreshList();
  });
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.register('/sw.js').catch(() => {});
    navigator.serviceWorker.addEventListener('message', event => {
      const tty = event.data && event.data.open;
      if (tty && /^ttys\d{1,4}$/.test(tty) && token) api('/api/state').then(r => { state = r; openSession(tty); });
    });
  }
  route();
});
