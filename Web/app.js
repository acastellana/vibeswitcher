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

async function api(path, options = {}) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  const response = await fetch(path, { ...options, headers, cache: 'no-store', credentials: 'omit' });
  let body = {};
  try { body = await response.json(); } catch (e) { /* empty body */ }
  if (response.status === 401) {
    forgetToken();
    throw new Error(body.error || 'Not paired');
  }
  if (!response.ok) throw new Error(body.error || `Error ${response.status}`);
  return body;
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
  const node = el('span', `badge ${session.status}`, String(session.number));
  node.style.background = STATUS_COLORS[session.status] || 'transparent';
  if (session.viewing) node.classList.add('viewing');
  return node;
}

async function refreshList(render = true) {
  try {
    state = await api('/api/state');
  } catch (error) {
    if (token) $('subtitle').textContent = error.message;
    return;
  }
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
    const count = sessions.filter(s => s.status === status).length;
    if (!count) continue;
    const chip = el('span', 'chip');
    const dot = el('i');
    dot.style.background = STATUS_COLORS[status];
    chip.append(dot, `${count} ${LABELS[status]}`);
    counts.append(chip);
  }
  const list = $('sessions');
  list.replaceChildren(...sessions.map(session => {
    const row = el('button', 'row');
    row.type = 'button';
    row.addEventListener('click', () => openSession(session.tty));
    const text = el('div', 'text');
    const first = el('div', 'line1');
    first.append(el('b', 'name', session.name), el('span', `agent ${session.agent}`, session.agent === 'claude' ? 'Claude' : 'Codex'));
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

function openSession(tty) {
  current = tty;
  history.replaceState(null, '', `#s=${tty}`);
  $('screen').textContent = '';
  $('screenError').hidden = true;
  $('inputError').hidden = true;
  renderSessionMeta();
  show('session');
}

function renderSessionMeta() {
  const session = state && state.sessions.find(s => s.tty === current);
  if (!session) {
    $('title').textContent = 'Session ended';
    $('sessionMeta').replaceChildren();
    return;
  }
  $('title').textContent = session.name;
  $('subtitle').textContent = session.task || '';
  const meta = $('sessionMeta');
  const status = el('span', `when ${session.status}`, `${session.statusLabel} ${elapsed(session.since)}`.trim());
  meta.replaceChildren(badge(session), status);
  if (session.detail && !session.activity) meta.append(el('div', 'detail', session.detail));
  if (session.activity) meta.append(el('div', 'detail', `⚙ ${session.activity} · ${elapsed(session.activitySince)}`));
  $('controls').hidden = !state.inputAllowed || !session.inTerminal;
  $('inputOff').hidden = state.inputAllowed || !session.inTerminal;
}

async function refreshScreen() {
  if (!current) return;
  const screen = $('screen');
  const atBottom = screen.scrollHeight - screen.scrollTop - screen.clientHeight < 40;
  try {
    const result = await api(`/api/screen?tty=${encodeURIComponent(current)}`);
    if (screen.textContent !== result.text) {
      screen.textContent = result.text;
      if (atBottom) screen.scrollTop = screen.scrollHeight;
    }
    $('screenError').hidden = true;
  } catch (error) {
    $('screenError').textContent = error.message;
    $('screenError').hidden = false;
  }
}

async function send(payload, button) {
  if (!current) return;
  $('inputError').hidden = true;
  if (button) button.disabled = true;
  try {
    await api('/api/input', { method: 'POST', body: JSON.stringify({ tty: current, ...payload }) });
    setTimeout(refreshScreen, 250);
    return true;
  } catch (error) {
    $('inputError').textContent = error.message;
    $('inputError').hidden = false;
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

async function enableNotifications() {
  $('notifyError').hidden = true;
  try {
    if (!('serviceWorker' in navigator) || !('PushManager' in window)) throw new Error('This browser has no web push.');
    const permission = await Notification.requestPermission();
    if (permission !== 'granted') throw new Error('Notifications are blocked for this site in the browser settings.');
    const registration = await navigator.serviceWorker.ready;
    let subscription = await registration.pushManager.getSubscription();
    if (!subscription) {
      subscription = await registration.pushManager.subscribe({
        userVisibleOnly: true, applicationServerKey: keyBytes(state.vapidPublicKey),
      });
    }
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
  $('replyForm').addEventListener('submit', async event => {
    event.preventDefault();
    const input = $('reply');
    if (!input.value.trim()) return;
    if (await send({ text: input.value, submit: true }, event.submitter)) input.value = '';
  });
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
