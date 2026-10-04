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
  if (current) { refreshConversation(); return renderSessionMeta(); }
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
  refreshDevPages();
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

// ---------- Dev pages ----------

let devPagesAt = 0;
let devPagesBusy = false;

/// Chrome's localhost tabs on the Mac. Refreshed with the list, at most every 10 s.
async function refreshDevPages(force = false) {
  const box = $('devPages');
  box.hidden = !state || !state.devPagesAllowed;
  if (box.hidden || devPagesBusy || (!force && Date.now() - devPagesAt < 10000)) return;
  devPagesBusy = true;
  try {
    renderDevPages(await api('/api/devpages'));
    devPagesAt = Date.now();
  } catch (error) {
    showDevPagesError(error.message);
  } finally {
    devPagesBusy = false;
  }
}

function showDevPagesError(message) {
  $('devPagesError').textContent = message;
  $('devPagesError').hidden = !message;
}

function renderDevPages(result) {
  showDevPagesError('');
  const pages = result.pages || [];
  const hint = result.hint || (pages.length ? '' : 'No localhost pages are open in Chrome on your Mac.');
  $('devPagesHint').textContent = hint;
  $('devPagesHint').hidden = !hint;
  $('devPageRows').replaceChildren(...pages.map(page => {
    const row = el('button', 'row devPage');
    row.type = 'button';
    const text = el('div', 'text');
    const first = el('div', 'line1');
    first.append(el('b', 'name', page.title));
    if (page.open) first.append(el('span', 'when done', 'open'));
    text.append(first, el('div', 'detail', page.label));
    row.append(el('span', 'globe', '🌐'), text);
    row.addEventListener('click', () => openDevPage(page, row));
    return row;
  }));
}

async function openDevPage(page, row) {
  row.disabled = true;
  try {
    const result = await api('/api/preview', { method: 'POST', body: JSON.stringify({ id: page.id }) });
    // Opens outside the app (on Android, a Chrome tab); Back comes back here. The link works once, for a minute.
    const opened = window.open(result.open, '_blank');
    if (opened) opened.opener = null;
    else location.href = result.open;
    devPagesAt = 0;
  } catch (error) {
    showDevPagesError(error.message);
  } finally {
    row.disabled = false;
  }
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
  resetOlder();
  resetConversation();
  showTab('terminal');
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
function lineNode(raw) {
  const line = raw.replace(/\s+$/, '');
  const node = document.createElement('div');
  if (BOX.test(line) && line.trim().length >= 6) {
    node.className = 'rule';
  } else {
    node.className = 'ln';
    node.textContent = line.replace(/([─-╿])\1{7,}/g, (run, c) => c.repeat(6)) || ' ';
  }
  return node;
}

function renderScreen(text) {
  const fragment = document.createDocumentFragment();
  for (const raw of text.split('\n')) fragment.append(lineNode(raw));
  $('live').replaceChildren(fragment);
}

async function loadScreen() {
  const screen = $('screen');
  const stick = lastScreenText === null || isAtBottom();
  try {
    const result = await api(`/api/screen?tty=${encodeURIComponent(current)}`);
    if (result.tty !== current) return;   // switched sessions meanwhile
    if (result.text !== lastScreenText) {
      const first = lastScreenText === null;
      lastScreenText = result.text;
      renderScreen(result.text);
      if (stick) screen.scrollTop = screen.scrollHeight;
      // Watching the bottom while output arrives: what scrolled off is newer than the loaded scrollback.
      if (stick && !first) older.stale = true;
      if (first) loadEarlier();   // the page above the screen, so there's something to scroll back to
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

// ---------- Terminal scrollback ----------

// Named `older`, not `history`: that would shadow window.history (used for the #s= URL).
const older = { start: null, first: 0, busy: false, stale: false };

function resetOlder() {
  older.start = null;
  older.first = 0;
  older.stale = false;
  $('scrollback').replaceChildren();
  $('live').replaceChildren();
  $('earlier').hidden = true;
}

/// Near the top of the Terminal tab: fetch the page above what's shown and keep the view where it was.
/// After new output has scrolled off the live screen (`stale`), it starts again from the newest page
/// instead, so nothing between the scrollback and the screen goes missing.
async function loadEarlier() {
  const fromTail = older.start === null || older.stale;
  if (older.busy || !current || (!fromTail && older.start <= older.first)) return;
  older.busy = true;
  const tty = current;
  const screen = $('screen');
  try {
    const before = fromTail ? '' : `&before=${older.start}`;
    const page = await api(`/api/history?tty=${encodeURIComponent(tty)}${before}`);
    if (tty !== current) return;
    // A cleared terminal is shorter than what we asked about: start over from its end.
    if (!fromTail && page.total < older.start) {
      older.stale = true;
      return;
    }
    const fragment = document.createDocumentFragment();
    for (const raw of page.lines) fragment.append(lineNode(raw));
    const fromBottom = screen.scrollHeight - screen.scrollTop;
    if (fromTail) $('scrollback').replaceChildren();
    older.stale = false;
    $('scrollback').prepend(fragment);
    screen.scrollTop = screen.scrollHeight - fromBottom;
    older.start = page.start;
    older.first = page.first;
    $('earlier').hidden = false;
    $('earlier').textContent = page.start > page.first ? '↑ Scroll for earlier output' : 'Start of the scrollback';
  } catch (error) {
    $('screenError').textContent = error.message;
    $('screenError').hidden = false;
  } finally {
    older.busy = false;
  }
}

// ---------- Conversation ----------

const conversation = { cursor: null, file: null, eventAt: null, status: null, busy: false, loaded: false, retry: null };

function resetConversation() {
  conversation.cursor = null;
  conversation.file = null;
  conversation.eventAt = null;
  conversation.status = null;
  conversation.loaded = false;
  clearTimeout(conversation.retry);
  $('conversation').replaceChildren();
}

function showTab(name) {
  const terminal = name === 'terminal';
  $('screen').hidden = !terminal;
  $('conversation').hidden = terminal;
  $('toBottom').hidden = !terminal || isAtBottom();
  $('tabTerminal').classList.toggle('on', terminal);
  $('tabConversation').classList.toggle('on', !terminal);
  $('tabTerminal').setAttribute('aria-selected', String(terminal));
  $('tabConversation').setAttribute('aria-selected', String(!terminal));
  for (const id of ['wrapToggle', 'fontDown', 'fontUp']) $(id).hidden = !terminal;
  if (!terminal) refreshConversation(true);
}

function timeLabel(at) {
  return at ? new Date(at * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }) : '';
}

function entryNode(entry) {
  if (entry.kind === 'tool') {
    const box = el('details', `toolRow${entry.failed ? ' failed' : ''}`);
    box.dataset.id = entry.id;
    box.dataset.entry = JSON.stringify({ id: entry.id, tool: entry.tool, text: entry.text, at: entry.at });
    const summary = el('summary');
    const status = entry.output === undefined ? '…' : (entry.failed ? '✗' : '✓');
    const took = entry.duration >= 1 ? ` · ${duration(entry.duration)}` : '';
    summary.append(el('span', 'toolName', entry.tool || 'tool'), el('span', 'toolText', entry.text),
                   el('span', 'toolMeta', `${took} ${status}`.trim()));
    box.append(summary);
    if (entry.output !== undefined) {
      box.append(el('pre', 'toolOutput', entry.output));
      if (entry.outputTruncated) {
        const more = el('button', 'link', 'Show all');
        more.type = 'button';
        more.addEventListener('click', () => showFullTool(entry.id, box));
        box.append(more);
      }
    }
    return box;
  }
  // Not `reply`: that class already styles the reply form.
  const bubble = el('div', `bubble ${entry.kind === 'prompt' ? 'fromYou' : 'fromAgent'}`);
  bubble.append(el('div', 'bubbleText', entry.text), el('div', 'bubbleTime', timeLabel(entry.at)));
  return bubble;
}

/// A tool's result arriving in a later read: keep the row's description and time, add output and duration.
function mergeToolResult(row, result) {
  const merged = { ...row, kind: 'tool', output: result.output, outputTruncated: result.outputTruncated, failed: result.failed };
  if (row.at && result.at) merged.duration = Math.max(0, result.at - row.at);
  return merged;
}

function applyEntries(entries) {
  const box = $('conversation');
  const stick = box.scrollHeight - box.scrollTop - box.clientHeight < 60;
  for (const entry of entries) {
    if (entry.kind === 'toolResult') {
      const row = box.querySelector(`.toolRow[data-id="${CSS.escape(entry.id)}"]`);
      if (row) row.replaceWith(entryNode(mergeToolResult(JSON.parse(row.dataset.entry || '{}'), entry)));
      continue;
    }
    box.append(entryNode(entry));
  }
  if (stick) box.scrollTop = box.scrollHeight;
}

/// First open: the transcript's tail. Afterwards only what's new, and only when the session changed.
async function refreshConversation(force = false) {
  if (!current || $('conversation').hidden || conversation.busy) return;
  const session = state && state.sessions.find(s => s.tty === current);
  if (!force && conversation.loaded && session && session.eventAt === conversation.eventAt &&
      session.status === conversation.status) return;
  conversation.busy = true;
  const tty = current;
  try {
    const after = conversation.cursor === null ? '' : `&after=${conversation.cursor}&file=${encodeURIComponent(conversation.file)}`;
    const result = await api(`/api/conversation?tty=${encodeURIComponent(tty)}${after}`);
    if (tty !== current) return;
    // A fresh tail (first open, another transcript after /clear or /resume, or a big gap): start over.
    if (result.fresh) {
      $('conversation').replaceChildren();
      if (result.truncatedBefore) $('conversation').append(el('p', 'muted small center', 'Earlier messages aren’t shown.'));
    }
    applyEntries(result.entries);
    if (result.fresh && !result.entries.length) $('conversation').append(el('p', 'muted small center', 'Nothing yet.'));
    conversation.cursor = result.cursor;
    conversation.file = result.file;
    conversation.eventAt = session ? session.eventAt : null;
    conversation.status = session ? session.status : null;
    conversation.loaded = true;
    // The agent is still writing a line: ask again shortly rather than waiting for the next hook event.
    clearTimeout(conversation.retry);
    if (result.pending) conversation.retry = setTimeout(() => refreshConversation(true), 1000);
  } catch (error) {
    if (!conversation.loaded) $('conversation').replaceChildren(el('p', 'muted center', error.message));
  } finally {
    conversation.busy = false;
  }
}

async function showFullTool(id, row) {
  try {
    const result = await api(`/api/conversation/tool?tty=${encodeURIComponent(current)}&id=${encodeURIComponent(id)}`);
    const node = entryNode(result.entry);
    node.open = true;
    row.replaceWith(node);
  } catch (error) {
    row.append(el('p', 'error', error.message));
  }
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
  $('screen').addEventListener('scroll', () => {
    $('toBottom').hidden = isAtBottom();
    // Near the top: the next page up. Leaving the bottom after new output: refresh to the newest page first.
    if ($('screen').scrollTop < 300 || (older.stale && !isAtBottom())) loadEarlier();
  }, { passive: true });
  $('tabTerminal').addEventListener('click', () => showTab('terminal'));
  $('tabConversation').addEventListener('click', () => showTab('conversation'));
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
