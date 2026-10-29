'use strict';
// VibeSwitcher phone app. All session text is inserted with textContent, never as HTML.

const $ = id => document.getElementById(id);
const STATUS_COLORS = {
  // The AA palette in style.css, which switches with the colour scheme.
  needsInput: 'var(--st-needsInput)', working: 'var(--st-working)', background: 'var(--st-background)', done: 'var(--st-done)',
  idle: 'var(--st-idle)', unknown: 'transparent',
};
const ORDER = ['needsInput', 'working', 'background', 'done'];
// The glossary (VibeCore's StateWord), keyed by status, plus paused and ended: each state's label, and its phrase after
// a count of one and of more. GlossaryTests holds this to the Mac's words.
const WORDS = {
  needsInput: { label: 'Needs you', one: 'needs you', many: 'need you' },
  working: { label: 'Working', one: 'working', many: 'working' },
  background: { label: 'Background', one: 'in background', many: 'in background' },
  done: { label: 'Done', one: 'done', many: 'done' },
  idle: { label: 'Idle', one: 'idle', many: 'idle' },
  paused: { label: 'Paused', one: 'paused', many: 'paused' },
  ended: { label: 'Ended', one: 'ended', many: 'ended' },
  unknown: { label: 'Unknown', one: 'unknown', many: 'unknown' },
};
function counted(state, count) { return `${count} ${count === 1 ? WORDS[state].one : WORDS[state].many}`; }

let token = localStorage.getItem('vs.token');
let state = null;
let current = null;           // tty of the open session
let listTimer = null;
let screenTimer = null;
let clockOffset = 0;          // Mac clock minus phone clock, seconds

// ---------- API ----------

const UNREACHABLE = "Can't reach your Mac. Is Tailscale on here, and is the Mac awake?";

async function api(path, options = {}, authToken = token) {
  const headers = { 'Content-Type': options.contentType || 'application/json' };
  if (authToken) headers.Authorization = `Bearer ${authToken}`;
  // A dropped connection (phone off Wi-Fi, Mac asleep) must not leave requests hanging for minutes.
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), options.timeout || 10000);
  let response;
  try {
    response = await fetch(path, { ...options, headers, cache: 'no-store', credentials: 'omit', signal: controller.signal });
  } catch (error) {
    // A slow answer the caller expected (reading Chrome's tabs) isn't the Mac being unreachable.
    if (controller.signal.aborted && options.timeoutMessage) throw new Error(options.timeoutMessage);
    setOnline(false);
    throw new Error(UNREACHABLE);
  } finally {
    clearTimeout(timer);
  }
  let body = {};
  try { body = await response.json(); } catch (e) { /* empty or non-JSON body (e.g. Tailscale's 502) */ }
  // A bare 502 or 504 to a request that types something: the Mac may still be typing it, so it's unknown, not off.
  if (!response.ok && !body.error && (response.status === 502 || response.status === 504) && options.unknownOutcome) {
    throw new Error(options.unknownOutcome);
  }
  // Our server always answers errors with a JSON message; a bare error (404, 502, 504) comes from
  // Tailscale itself, meaning VibeSwitcher isn't running or Phone Access is off.
  if (!response.ok && !body.error) {
    const message = "VibeSwitcher isn't running on your Mac, or Phone Access is off.";
    setOnline(false, message);
    throw new Error(message);
  }
  setOnline(true);
  // Only a phone the Mac removed hears 401 (a restart answers 503): it forgets its token and says why.
  if (response.status === 401 && authToken === token) {
    forgetToken(body.error || "This phone isn't paired with the Mac any more.");
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

// The session the view shows, not just its tty: when another session takes over the tab, the server
// refuses requests meant for the old one (409) instead of answering for, or typing into, the new one.
let currentSid = null;

function sessionQuery(tty = current) {
  return `tty=${encodeURIComponent(tty)}&sid=${encodeURIComponent(currentSid || '')}`;
}

function shownSession() {
  // No sid: the view was opened on a tty with no session (yet). Whatever turns up there is offered, not assumed.
  if (!state || !current || !currentSid) return null;
  return state.sessions.find(s => s.tty === current && s.sid === currentSid) || null;
}

let webVersion = null;

/// Back to the pairing screen; `reason`, when the Mac unpaired this phone, shows on it.
function forgetToken(reason) {
  token = null;
  localStorage.removeItem('vs.token');
  $('pairError').textContent = reason ? `${reason} Pair it again to keep using it.` : '';
  $('pairError').hidden = !reason;
  show('pair');
}

// ---------- Views ----------

function show(view) {
  for (const id of ['pair', 'list', 'session', 'lead']) $(id).hidden = id !== view;
  $('back').hidden = view !== 'session' && view !== 'lead';
  $('prev').hidden = view !== 'session';
  $('next').hidden = view !== 'session';
  document.body.classList.toggle('in-session', view === 'session');
  $('bell').hidden = view === 'pair';
  clearInterval(listTimer);
  clearInterval(screenTimer);
  if (view !== 'lead') openLeadID = null;
  if (view === 'list') {
    current = null;
    $('title').textContent = 'VibeSwitcher';
    refreshList();
    listTimer = setInterval(() => { if (!document.hidden) refreshList(); }, 3000);
  } else if (view === 'lead') {
    current = null;
    refreshLead();
    listTimer = setInterval(() => { if (!document.hidden) refreshLead(); }, 4000);
  } else if (view === 'session') {
    refreshScreen();
    screenTimer = setInterval(() => { if (!document.hidden) { refreshScreen(); refreshList(false); } }, 1500);
  } else {
    $('title').textContent = 'VibeSwitcher';
    $('subtitle').textContent = '';
  }
}

// 45s, 12m, 3h 5m, 2d 4h: the Mac's Durations.short, which GlossaryTests holds this to.
function short(seconds) {
  const s = Math.max(0, Math.floor(seconds));
  if (s < 60) return `${s}s`;
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return s % 3600 >= 60 ? `${Math.floor(s / 3600)}h ${Math.floor(s % 3600 / 60)}m` : `${Math.floor(s / 3600)}h`;
  return `${Math.floor(s / 86400)}d ${Math.floor(s % 86400 / 3600)}h`;
}

function elapsed(since) { return since ? short(Date.now() / 1000 + clockOffset - since) : ''; }

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
  // The Mac now serves a newer app: load it (an old page would leave out what the Mac now expects).
  if (state.web) {
    if (webVersion && state.web !== webVersion) return location.reload();
    webVersion = state.web;
  }
  if (!pushChecked) { pushChecked = true; syncPushSubscription(); }
  clockOffset = state.now - Date.now() / 1000;
  $('subtitle').textContent = state.mac;
  $('notifyCard').hidden = Boolean(state.device.push) || !('PushManager' in window);
  $('bell').classList.toggle('on', Boolean(state.device.push));
  if (current) { refreshConversation(); return renderSessionMeta(); }
  if (openLeadID) return;
  renderBriefScope();
  if (render) renderList();
}

function renderList() {
  // An answer being written to a lead's question: the list waits, so the box keeps its text and the keyboard.
  if (document.activeElement && document.activeElement.classList && document.activeElement.classList.contains('qInput')) return;
  // The leads' workers and verifiers fold under their lead, as on the Mac: they aren't your own sessions (nor counted
  // as yours). A team whose lead isn't listed stays where it is.
  const leadIDs = new Set(state.sessions.filter(s => s.role === 'lead').map(s => s.lead));
  const isMember = s => (s.role === 'worker' || s.role === 'verifier') && leadIDs.has(s.lead);
  const sessions = state.sessions.filter(s => !isMember(s));
  const counts = $('counts');
  counts.replaceChildren();
  for (const status of ORDER) {
    const count = sessions.filter(s => s.status === status && !s.paused).length;
    if (!count) continue;
    const chip = el('span', 'chip');
    const dot = el('i');
    dot.style.background = STATUS_COLORS[status];
    chip.append(dot, counted(status, count));
    counts.append(chip);
  }
  const paused = sessions.filter(s => s.paused).length;
  if (paused) counts.append(el('span', 'chip', `⏸ ${counted('paused', paused)}`));
  const list = $('sessions');
  list.replaceChildren(...sessions.map(session => {
    const row = sessionRow(session);
    const lead = session.role === 'lead' && (state.leads || []).find(l => l.id === session.lead);
    return lead ? leadBlock(lead, row, state.sessions.filter(s => isMember(s) && s.lead === lead.id)) : row;
  }));
  $('empty').hidden = sessions.length > 0;
  renderToday();
  refreshDevPages();
}

function sessionRow(session) {
  const row = el('button', session.paused ? 'row paused' : 'row');
  row.type = 'button';
  row.addEventListener('click', () => openSession(session.tty));
  const text = el('div', 'text');
  const first = el('div', 'line1');
  first.append(el('b', 'name', session.name), el('span', `agent ${session.agent}`, session.agent === 'claude' ? 'Claude' : 'Codex'));
  if (session.role === 'lead') first.append(el('span', 'roleTag', 'Lead'));
  if (session.paused) first.append(el('span', 'pausedTag', `⏸ ${WORDS.paused.label}`));
  const when = el('span', `when ${session.status}`, `${session.statusLabel} ${elapsed(session.since)}`.trim());
  first.append(when);
  text.append(first);
  if (session.role === 'worker' || session.role === 'verifier') {
    text.append(el('div', 'roleLine', `${session.role}${session.teamTask ? ` · ${session.teamTask}` : ''}`));
  }
  if (session.task) text.append(el('div', 'task', session.task));
  if (session.activity) text.append(el('div', 'detail', `⚙ ${session.activity} · ${elapsed(session.activitySince)}`));
  else if (session.detail) text.append(el('div', `detail ${session.status === 'needsInput' ? 'strong' : ''}`, session.detail));
  row.append(badge(session), text);
  return row;
}

function renderToday() {
  const today = state.today;
  const box = $('today');
  box.hidden = !today || (today.agentsWorking < 60 && today.waitingOnYou < 60);
  if (box.hidden) return;
  $('todayLine').textContent = `${short(today.agentsWorking)} agents working · ${short(today.waitingOnYou)} waiting on you`;
  $('todayRows').replaceChildren(...today.projects.map(p => {
    const row = el('div', 'todayRow');
    row.append(el('span', 'name', p.project),
               el('span', 'muted', `worked ${short(p.working)}`),
               el('span', p.waiting > p.working ? 'warn' : 'muted', `waited ${short(p.waiting)}`));
    return row;
  }));
}

// ---------- Project leads ----------
// A lead's row as the Mac's sidebar has it: its questions for you, its team's summary ("team: 2 working · 1 waits on
// lead") folding its workers and verifiers under it, and its page (Team ›). Its questions are answered here as on the
// Mac's answer card, through the same path on the Mac (POST /api/lead/answer); a withdrawn or decided one is a dim line.

const teamOpen = new Set();          // leads whose team is unfolded on this phone
const drafts = new Map();            // question id → the answer being written
const answering = new Set();         // question ids with an answer on its way (a second tap waits for it)
const answerNotes = new Map();       // question id → { text, error } shown under its card
const answeredHere = new Map();      // question id → { lead, text, answer, at }: answered from this phone, said for a minute
let openLeadID = null;               // the lead whose page is shown
let leadBusy = false;
let leadPage = null;

const PRIORITY = { blocking: 'Blocking', important: 'Important', whenever: 'Whenever' };

function clockText(at) {
  const date = new Date((at - clockOffset) * 1000);
  return `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`;
}

function questionCount(count) { return `${count} question${count === 1 ? '' : 's'} for you`; }

function leadBlock(lead, row, members) {
  const block = el('div', 'leadBlock');
  block.append(row);
  const bar = el('div', 'leadBar');
  if (lead.open) bar.append(el('span', lead.blocking ? 'qCount blocking' : 'qCount', `? ${questionCount(lead.open)}`));
  if (members.length) {
    const open = teamOpen.has(lead.id);
    const toggle = el('button', 'teamToggle', `${lead.summary || `team: ${members.length}`} ${open ? '▾' : '▸'}`);
    toggle.type = 'button';
    toggle.setAttribute('aria-expanded', String(open));
    toggle.addEventListener('click', () => {
      if (teamOpen.has(lead.id)) teamOpen.delete(lead.id); else teamOpen.add(lead.id);
      renderList();
    });
    bar.append(toggle);
  }
  if (lead.allDone) bar.append(el('span', 'allDoneTag', '✓ All done'));
  const page = el('button', 'teamLink', 'Team ›');
  page.type = 'button';
  page.addEventListener('click', () => openLead(lead.id));
  bar.append(page);
  block.append(bar);
  if (members.length && teamOpen.has(lead.id)) {
    const team = el('div', 'team');
    team.append(...members.map(sessionRow));
    block.append(team);
  }
  if (lead.questions.length || [...answeredHere.values()].some(done => done.lead === lead.id)) block.append(questionStack(lead));
  return block;
}

function questionStack(lead) {
  const stack = el('div', 'qStack');
  const open = lead.questions.filter(q => q.state === 'open');
  if (open.length > 1) stack.append(el('div', 'muted small qOrder', 'Answer in any order'));
  stack.append(...lead.questions.map(q => questionCard(lead, q)));
  // An answered question leaves the stack, as on the Mac: a line says it went, for a minute.
  const shown = new Set(lead.questions.map(q => q.id));
  for (const [id, done] of answeredHere) {
    if (Date.now() - done.at > 60000) { answeredHere.delete(id); continue; }
    if (done.lead !== lead.id || shown.has(id)) continue;
    const line = el('div', 'qClosed answered');
    line.append(el('div', 'status', `✓ Answered: ${done.answer}`), el('div', 'qClosedText', done.text));
    stack.append(line);
  }
  return stack;
}

function questionCard(lead, q) {
  if (q.state === 'withdrawn' || q.state === 'autoDecided') {
    const line = el('div', `qClosed ${q.state}`);
    line.append(q.state === 'withdrawn'
      ? el('div', 'qClosedWhy', `✕ Withdrawn: ${q.withdrawReason || 'no reason given'}`)
      : el('div', 'qClosedWhy', `✓ Went ahead with ${q.proposal || ''}: no answer in ${q.decideIn} min`));
    line.append(el('div', 'qClosedText', q.text));
    return line;
  }
  const card = el('div', `qCard ${q.priority}`);
  card.dataset.question = q.id;
  const head = el('div', 'qHead');
  head.append(el('span', `qPriority ${q.priority}`, PRIORITY[q.priority] || q.priority),
              el('span', 'muted small', `asked ${elapsed(q.askedAt)} ago`));
  card.append(head, el('div', 'qText', q.text));
  if (q.whyNow) card.append(el('div', 'qWhy', q.whyNow));
  if (q.revised) {
    const history = el('details', 'qRevised');
    history.append(el('summary', null, `✎ Updated ${clockText(q.revised.at)}: ${q.revised.note}`));
    for (const earlier of [...q.revised.earlier].reverse()) {
      const item = el('div', 'qEarlier');
      item.append(el('div', 'muted small', `Version ${earlier.version}, until ${clockText(earlier.until)}`),
                  el('s', null, earlier.text));
      if (earlier.options.length) item.append(el('div', 'muted small', earlier.options.join(' · ')));
      history.append(item);
    }
    card.append(history);
  }
  if (q.proposal && q.decideBy) {
    // What's left in the Mac's words, as of the last state (asked every few seconds).
    const timer = el('div', 'qTimer');
    timer.append('⏱ Going with ', el('b', null, q.proposal), q.timeLeft ? ` in ${q.timeLeft}` : ' now');
    card.append(timer);
  } else if (q.held && q.proposal) {
    const held = el('div', 'qTimer held');
    held.append('⏸ Held: the timer is off. The lead proposed ', el('b', null, q.proposal), '; it waits for your answer.');
    card.append(held);
  }
  const canAnswer = Boolean(state && state.inputAllowed);
  const busy = answering.has(q.id);
  if (q.options.length) {
    const options = el('div', 'options');
    for (const option of q.options) {
      const button = el('button', option === q.proposal ? 'option proposed' : 'option');
      button.type = 'button';
      button.append(el('span', null, option));
      if (option === q.proposal) button.append(el('span', 'proposedTag', 'Proposed'));
      button.disabled = !canAnswer || busy;
      button.addEventListener('click', () => answerQuestion(lead, q, option));
      options.append(button);
    }
    card.append(options);
  }
  const form = el('form', 'qAnswer');
  const input = el('input', 'qInput');
  input.placeholder = q.options.length ? 'Or answer in your own words' : 'Your answer';
  input.maxLength = 2000;
  input.value = drafts.get(q.id) || '';
  input.disabled = !canAnswer || busy;
  input.addEventListener('input', () => drafts.set(q.id, input.value));
  const send = el('button', 'primary', 'Answer');
  send.type = 'submit';
  send.disabled = !canAnswer || busy;
  form.append(input, send);
  form.addEventListener('submit', event => {
    event.preventDefault();
    const text = input.value.trim();
    if (text) answerQuestion(lead, q, text);
  });
  card.append(form);
  const note = answerNotes.get(q.id);
  if (note) card.append(el('div', note.error ? 'error qNote' : 'status qNote', note.text));
  if (!canAnswer) {
    card.append(el('div', 'muted small', 'Replying is off. Turn it on on the Mac: VibeSwitcher › Settings… › Phone.'));
  } else if (q.proposal && q.decideBy) {
    card.append(el('div', 'muted small', `Pick another answer, or the lead goes ahead with ${q.proposal} at ${clockText(q.decideBy)}.`));
  } else {
    card.append(el('div', 'muted small', 'It keeps working while you think; the answer reaches it at its next step.'));
  }
  return card;
}

/// Your answer, for the version of the question this phone showed. Once: a second tap waits for the first.
async function answerQuestion(lead, q, text) {
  if (answering.has(q.id)) return;
  answering.add(q.id);
  answerNotes.delete(q.id);
  redrawLeads();
  try {
    const reply = await api('/api/lead/answer', { method: 'POST', body: JSON.stringify({ lead: lead.id, question: q.id, version: q.version, text }),
                                                  unknownOutcome: "Couldn't tell whether the Mac got your answer. Check the lead before answering again." });
    drafts.delete(q.id);
    answerNotes.set(q.id, { text: reply.notice || `Answered: ${text} ✓`, error: Boolean(reply.notice) });
    answeredHere.set(q.id, { lead: lead.id, text: q.text, answer: text, at: Date.now() });
  } catch (error) {
    answerNotes.set(q.id, { text: error.message, error: true });
  } finally {
    answering.delete(q.id);
  }
  if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
  if (openLeadID) refreshLead(); else refreshList();
  redrawLeads();
}

function redrawLeads() {
  if (openLeadID) renderLead(); else if (state) renderList();
}

// ---------- A lead's page ----------

function openLead(id) {
  openLeadID = id;
  leadPage = null;
  $('leadPage').replaceChildren(el('p', 'muted center', 'Loading…'));
  show('lead');
}

async function refreshLead() {
  if (leadBusy || !openLeadID || !token) return;
  leadBusy = true;
  const id = openLeadID;
  try {
    const [page, fresh] = await Promise.all([api(`/api/lead?lead=${encodeURIComponent(id)}`), api('/api/state')]);
    if (id !== openLeadID) return;
    leadPage = page;
    state = fresh;
    clockOffset = state.now - Date.now() / 1000;
  } catch (error) {
    if (id === openLeadID) $('leadPage').replaceChildren(el('p', 'error', error.message));
    return;
  } finally {
    leadBusy = false;
  }
  renderLead();
}

const MARKS = {
  waits: '…', failed: '✕', blocked: '⊘', stalled: '⏸', ended: '■', working: '●', rework: '↻', review: '◆', merge: '◈',
  queued: '○', merged: '✓', folded: '↳', kept: '▣', abandoned: '−', reverted: '↶',
};
// The Team tab's order; only the finished ones have a title, as there ("Merged (4) · Reverted (1)").
const GROUPS = ['needsYou', 'working', 'review', 'queued', 'finished'];

function renderLead() {
  if (!leadPage || document.activeElement && document.activeElement.classList && document.activeElement.classList.contains('qInput')) return;
  const page = leadPage;
  $('title').textContent = page.project;
  $('subtitle').textContent = page.summary || 'Project lead';
  const parts = [];
  const lead = (state && state.leads || []).find(l => l.id === page.id);
  if (lead && lead.questions.length) {
    parts.push(el('h3', 'sectionTitle', lead.open ? questionCount(lead.open) : 'No questions waiting'), questionStack(lead));
  }
  if (page.allDone) parts.push(allDoneCard(page.allDone));
  if (page.updates.length) {
    parts.push(el('h3', 'sectionTitle', 'Latest updates'));
    for (const update of page.updates) {
      const card = el('div', 'card update');
      const head = el('div', 'updateHead');
      head.append(el('b', null, update.title), el('span', 'muted small', clockText(update.at)));
      card.append(head, el('div', 'updateBody', update.body));
      if (update.images) card.append(el('div', 'muted small', `${update.images} image${update.images === 1 ? '' : 's'} on the Mac`));
      parts.push(card);
    }
  }
  parts.push(el('h3', 'sectionTitle', 'Tasks'));
  const tasks = el('div', 'card tasks');
  for (const group of GROUPS) {
    const rows = page.tasks.filter(t => t.group === group);
    if (!rows.length) continue;
    if (group === 'finished') tasks.append(el('div', 'taskGroup', page.finished.title));
    for (const task of rows) {
      const row = el('div', 'taskRow');
      const mark = el('span', `mark ${task.mark}`, MARKS[task.mark] || '•');
      mark.setAttribute('aria-hidden', 'true');
      const text = el('div', 'text');
      const first = el('div', 'line1');
      first.append(el('span', 'taskTitle', task.title), el('span', `taskState ${task.mark}`, task.stateText));
      text.append(first);
      if (task.line) text.append(el('div', 'detail', task.line));
      row.append(mark, text);
      tasks.append(row);
    }
    if (group === 'finished' && page.finished.count > page.finished.shown) {
      tasks.append(el('div', 'muted small', `and ${page.finished.count - page.finished.shown} earlier`));
    }
  }
  if (!page.tasks.length) tasks.append(el('div', 'muted small', 'No tasks on the board.'));
  parts.push(tasks);
  if (page.scorecard || page.cost) {
    const score = el('div', 'card scorecard');
    if (page.scorecard) score.append(el('div', null, page.scorecard));
    if (page.cost) score.append(el('div', 'muted small', page.cost));
    parts.push(score);
  }
  $('leadPage').replaceChildren(...parts);
}

function allDoneCard(mark) {
  const card = el('div', 'allDone');
  const head = el('div', 'allDoneHead');
  head.append(el('b', null, '✓ All tasks finished'), el('span', 'muted small', clockText(mark.at)));
  card.append(head);
  if (mark.headline) {
    card.append(el('div', 'allDoneHeadline', mark.headline));
    const bullets = el('ul', 'allDoneBullets');
    bullets.append(...(mark.bullets || []).map(b => el('li', null, b)));
    card.append(bullets);
  } else {
    card.append(el('div', 'muted small', 'Writing a short summary of what was done…'));
  }
  if (mark.cost) card.append(el('div', 'muted small allDoneCost', mark.cost));
  const list = el('details', 'allDoneTasks');
  list.append(el('summary', null, mark.count));
  list.append(...mark.tasks.map(t => el('div', `small outcome ${t.outcome}`, `${t.outcome === 'merged' ? '✓' : t.outcome === 'reverted' ? '↶' : '−'} ${t.title}`)));
  card.append(list);
  return card;
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
    renderDevPages(await api('/api/devpages', { timeout: 20000, timeoutMessage: CHROME_SLOW }));
    devPagesAt = Date.now();
  } catch (error) {
    showDevPagesError(error.message);
  } finally {
    devPagesBusy = false;
  }
}

const CHROME_SLOW = "Chrome on your Mac didn't answer in time. Try again.";

// A tap on a real link always opens a new tab, where window.open after a wait can be blocked.
let devPageLinkUntil = 0;

function showDevPageLink(url) {
  devPageLinkUntil = Date.now() + 60000;
  const link = el('a', 'devPageLink', 'Open the page');
  link.href = url;
  link.target = '_blank';
  link.rel = 'noopener noreferrer';
  link.addEventListener('click', () => { devPageLinkUntil = 0; $('devPagesHint').hidden = true; });
  $('devPagesHint').replaceChildren(link, ' (works once, for a minute)');
  $('devPagesHint').hidden = false;
}

function showDevPagesError(message) {
  $('devPagesError').textContent = message;
  $('devPagesError').hidden = !message;
}

function renderDevPages(result) {
  showDevPagesError('');
  const pages = result.pages || [];
  const hint = result.hint || (pages.length ? '' : 'No localhost pages are open in Chrome on your Mac.');
  if (Date.now() >= devPageLinkUntil) {   // keep a link waiting for its tap
    $('devPagesHint').textContent = hint;
    $('devPagesHint').hidden = !hint;
  }
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
    const result = await api('/api/preview', { method: 'POST', body: JSON.stringify({ id: page.id }),
                                               timeout: 20000, timeoutMessage: CHROME_SLOW });
    // Opens outside the app (on Android, a Chrome tab); Back comes back here. The link works once, for a minute.
    const opened = window.open(result.open, '_blank');
    if (opened) {
      opened.opener = null;
      devPageLinkUntil = 0;   // an older link waiting for a tap is superseded
      $('devPagesHint').hidden = true;
    } else {
      showDevPageLink(result.open);
    }   // blocked (the tap was before the wait): never navigate the app itself away
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
  const opened = state && state.sessions.find(s => s.tty === tty);
  currentSid = opened ? opened.sid : null;
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
  const session = shownSession();
  const index = session ? state.sessions.indexOf(session) : -1;
  $('prev').disabled = index <= 0;
  $('next').disabled = index < 0 || index >= state.sessions.length - 1;
  if (!session) {
    $('title').textContent = 'Session ended';
    $('sessionMeta').replaceChildren();
    $('composer').hidden = true;
    $('askCard').hidden = true;
    // Another session in the same tab: offer it, never carry on as if it were this one.
    const successor = state && state.sessions.find(s => s.tty === current);
    $('subtitle').textContent = successor ? 'Another session is running in this tab now.' : '';
    if (successor) {
      const open = el('button', 'chip-btn', `Open ${successor.name}`);
      open.type = 'button';
      open.addEventListener('click', () => openSession(successor.tty));
      $('sessionMeta').append(open);
    }
    return;
  }
  $('title').textContent = session.name;
  $('subtitle').textContent = session.task || '';
  const meta = $('sessionMeta');
  const status = el('span', `when ${session.status}`, `${session.statusLabel} ${elapsed(session.since)}`.trim());
  meta.replaceChildren(badge(session), status);
  if (session.activity) meta.append(el('span', 'activity', `⚙ ${session.activity} · ${elapsed(session.activitySince)}`));
  // What it's asking you, where you'll answer it: with its options as buttons once the Mac has read them off the screen.
  const menu = session.paused ? null : session.menu || null;
  const asking = (session.status === 'needsInput' && !session.paused) || Boolean(menu);
  $('askCard').hidden = !asking;
  if (asking) $('askText').textContent = (menu && menu.question) || session.detail || 'Waiting for you';
  const canType = state.inputAllowed && session.inTerminal;
  renderMenu(session, menu, canType);
  renderPauseControls(session);
  $('composer').hidden = !canType;
  $('inputOff').hidden = state.inputAllowed || !session.inTerminal;
  $('reply').placeholder = `Message ${session.name}…`;
  renderMic();
  layoutSession();
}

// ---------- Menu (a question, permission prompt or picker) ----------

let drawnMenu = '';   // what the option buttons were drawn from: redrawn only when that changes

/// One full-width button per option (and a multi-select's Submit row); a tap answers it. Text only, via textContent.
function renderMenu(session, menu, canAnswer) {
  const box = $('askOptions');
  const key = menu ? JSON.stringify([session.sid, menu.fingerprint, menu.selected, menu.checked || null, canAnswer]) : '';
  if (key !== drawnMenu) {
    drawnMenu = key;
    box.hidden = !menu;
    const options = menu ? menu.options.map((label, index) => optionButton(menu, index, label,
                                                                           (menu.descriptions || [])[index], canAnswer)) : [];
    if (menu && menu.submit) options.push(optionButton(menu, menu.options.length, menu.submit, null, canAnswer));
    box.replaceChildren(...options);
  }
  // A menu is answered with its buttons: typed text would be taken as "let's discuss the question".
  syncQuickReplies();
}

function optionButton(menu, index, label, description, canAnswer) {
  const button = el('button', index === menu.selected ? 'option selected' : 'option');
  button.type = 'button';
  const box = menu.checked && index < menu.checked.length ? (menu.checked[index] ? '☑ ' : '☐ ') : '';
  button.append(el('span', 'optionLabel', `${box}${label}`));
  if (description) button.append(el('span', 'optionDetail', description));
  button.disabled = !canAnswer;
  button.addEventListener('click', () => chooseOption(index, menu.fingerprint, label));
  return button;
}

/// Sends the tap with the fingerprint of the menu it was drawn from: the Mac types it only if that menu is still up.
async function chooseOption(index, fingerprint, label) {
  for (const button of $('askOptions').children) button.disabled = true;
  await send({ choose: index, fingerprint }, null, `“${label}” ✓`);
  drawnMenu = '';   // redrawn from the next state: the answered menu, the next one, or a changed one after a 409
  refreshList(false);
}

/// A key button. While a menu is shown, its keys carry its fingerprint, as a tap does: a bare key would answer whatever
/// question is up by the time it arrives. 1, 2 and 3 are taps on its options, ⏎ a tap on the highlighted one, and ↑ ↓
/// move only while that menu is still up.
function pressKey(button) {
  const session = shownSession();
  const menu = session && !session.paused ? session.menu : null;
  const key = button.dataset.key;
  if (menu && key === 'enter') {
    const index = menu.selected;
    const label = index < menu.options.length ? menu.options[index] : menu.submit;
    if (!Number.isInteger(index) || label === undefined) return setInputStatus('Tap an option.', true);
    return chooseOption(index, menu.fingerprint, label);
  }
  if (menu && (key === 'up' || key === 'down')) return send({ key, fingerprint: menu.fingerprint }, button);
  if (key) return send({ key }, button);
  if (menu && /^[1-9]$/.test(button.dataset.text)) {
    const index = Number(button.dataset.text) - 1;
    if (index >= menu.options.length) return setInputStatus(`There's no option ${index + 1}.`, true);
    return chooseOption(index, menu.fingerprint, menu.options[index]);
  }
  return send({ text: button.dataset.text, submit: false }, button);
}

function syncQuickReplies() {
  $('quickReplies').hidden = !$('askOptions').hidden || !$('quickEditor').hidden;
}

function pauseLabel(session) {
  if (!session.pausedUntil) return WORDS.paused.label;
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
    await api('/api/pause', { method: 'POST', body: JSON.stringify({ tty: current, sid: currentSid, duration }) });
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
    const result = await api(`/api/screen?${sessionQuery()}`);
    if (result.tty !== current) return;   // switched sessions meanwhile
    if (result.text !== lastScreenText) {
      const first = lastScreenText === null;
      lastScreenText = result.text;
      renderScreen(result.text);
      if (stick) screen.scrollTop = screen.scrollHeight;
      // Watching the bottom while output arrives: what scrolled off is newer than the loaded scrollback.
      if (stick && !first) older.stale = true;
      if (first) loadEarlier();   // the page above the screen, so there's something to scroll back to
      else checkCleared();
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
// `gen` changes with every reset (another session): an answer for the previous one is dropped, even
// after going A → B → A while it was on its way.
const older = { start: null, first: 0, total: 0, busy: false, stale: false, gen: 0, checkedAt: 0 };

function resetOlder() {
  older.gen += 1;
  older.busy = false;
  older.start = null;
  older.first = 0;
  older.total = 0;
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
  const gen = older.gen;
  const tty = current;
  const screen = $('screen');
  try {
    const before = fromTail ? '' : `&before=${older.start}`;
    const page = await api(`/api/history?${sessionQuery(tty)}${before}`);
    if (gen !== older.gen || tty !== current) return;
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
    older.total = page.total;
    $('earlier').hidden = false;
    $('earlier').textContent = page.start > page.first ? '↑ Scroll for earlier output' : 'Start of the scrollback';
  } catch (error) {
    if (gen !== older.gen) return;
    $('screenError').textContent = error.message;
    $('screenError').hidden = false;
  } finally {
    if (gen === older.gen) older.busy = false;
  }
}

/// While output changes, now and then: if the tab's history got shorter (⌘K, `clear`), the scrollback
/// shown above the screen is gone on the Mac too, so it's reloaded from the new end.
async function checkCleared() {
  if (older.busy || older.start === null || Date.now() - older.checkedAt < 10000) return;
  older.checkedAt = Date.now();
  const gen = older.gen;
  try {
    const page = await api(`/api/history?${sessionQuery()}&limit=1`);
    if (gen !== older.gen || page.total >= older.total) return;
    older.stale = true;
    loadEarlier();
  } catch (error) { /* the next check will tell */ }
}

// ---------- Conversation ----------

const conversation = { cursor: null, file: null, eventAt: null, status: null, hasTranscript: null, busy: false,
                       loaded: false, retry: null, gen: 0, errorAt: 0 };

function resetConversation() {
  conversation.gen += 1;
  conversation.busy = false;
  conversation.errorAt = 0;
  conversation.hasTranscript = null;
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

// `full`: the output from "Show all" (still cut past 64 KB: say so instead of offering it again).
function entryNode(entry, full = false) {
  if (entry.kind === 'tool') {
    const box = el('details', `toolRow${entry.failed ? ' failed' : ''}`);
    box.dataset.id = entry.id;
    box.dataset.entry = JSON.stringify({ id: entry.id, tool: entry.tool, text: entry.text, at: entry.at });
    const summary = el('summary');
    const status = entry.output === undefined ? '…' : (entry.failed ? '✗' : '✓');
    const took = entry.duration >= 1 ? ` · ${short(entry.duration)}` : '';
    summary.append(el('span', 'toolName', entry.tool || 'tool'), el('span', 'toolText', entry.text),
                   el('span', 'toolMeta', `${took} ${status}`.trim()));
    box.append(summary);
    if (entry.output !== undefined) {
      box.append(el('pre', 'toolOutput', entry.output));
      if (entry.outputTruncated && full) {
        box.append(el('p', 'muted small', 'Output cut at 64 KB. See the Terminal tab for the rest.'));
      } else if (entry.outputTruncated) {
        const more = el('button', 'link', 'Show all');
        more.type = 'button';
        more.addEventListener('click', () => showFullTool(entry.id, box));
        box.append(more);
      }
    }
    return box;
  }
  // What VibeSwitcher handed the agent (a report, a wake-up, your words relayed): its sender above it, never your blue.
  if (entry.kind === 'notice') {
    const notice = el('div', 'bubble fromVibe');
    notice.append(el('div', 'bubbleFrom', entry.from || 'VibeSwitcher'), el('div', 'bubbleText', entry.text),
                  el('div', 'bubbleTime', timeLabel(entry.at)));
    return notice;
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
  if (entries.length) box.querySelectorAll('.emptyNote').forEach(node => node.remove());
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
  const session = shownSession();
  if (state && !session) return;   // that session ended: nothing more to read for it
  // A transcript can appear without a new hook event (Claude creates the file a moment after the session starts).
  const unchanged = session && session.eventAt === conversation.eventAt && session.status === conversation.status &&
    session.hasTranscript === conversation.hasTranscript;
  if (!force && conversation.loaded && unchanged) return;
  if (!force && Date.now() - conversation.errorAt < 10000) return;   // after a failure, not on every poll
  // No transcript (no hooks, or an agent that doesn't write one): say so without asking the Mac.
  if (session && session.hasTranscript === false) {
    if (!(conversation.loaded && unchanged && conversation.cursor === null)) {
      $('conversation').replaceChildren(el('p', 'muted center', 'No transcript for this session. See the Terminal tab.'));
    }
    conversation.cursor = null;
    conversation.eventAt = session.eventAt;
    conversation.status = session.status;
    conversation.hasTranscript = false;
    conversation.loaded = true;
    return;
  }
  conversation.busy = true;
  const gen = conversation.gen;
  const tty = current;
  try {
    const after = conversation.cursor === null ? '' : `&after=${conversation.cursor}&file=${encodeURIComponent(conversation.file)}`;
    const result = await api(`/api/conversation?${sessionQuery(tty)}${after}`);
    if (gen !== conversation.gen || tty !== current) return;
    // A fresh tail (first open, another transcript after /clear or /resume, or a big gap): start over.
    if (result.fresh) {
      $('conversation').replaceChildren();
      if (result.truncatedBefore) $('conversation').append(el('p', 'muted small center', 'Earlier messages aren’t shown.'));
    }
    applyEntries(result.entries);
    if (result.fresh && !result.entries.length) $('conversation').append(el('p', 'muted small center emptyNote', 'Nothing yet.'));
    conversation.cursor = result.cursor;
    conversation.file = result.file;
    conversation.eventAt = session ? session.eventAt : null;
    conversation.status = session ? session.status : null;
    conversation.hasTranscript = session ? session.hasTranscript : null;
    conversation.loaded = true;
    conversation.errorAt = 0;
    // The agent is still writing a line: ask again shortly rather than waiting for the next hook event.
    clearTimeout(conversation.retry);
    if (result.pending) conversation.retry = setTimeout(() => refreshConversation(true), 1000);
  } catch (error) {
    if (gen !== conversation.gen) return;
    conversation.errorAt = Date.now();
    if (!conversation.loaded) $('conversation').replaceChildren(el('p', 'muted center', error.message));
  } finally {
    if (gen === conversation.gen) conversation.busy = false;
  }
}

async function showFullTool(id, row) {
  const gen = conversation.gen;
  try {
    const result = await api(`/api/conversation/tool?${sessionQuery()}&id=${encodeURIComponent(id)}`);
    if (gen !== conversation.gen) return;
    const node = entryNode(result.entry, true);
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
      const session = shownSession();
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
  syncQuickReplies();
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

let replying = false;      // a reply (text with Enter) is being sent: a second Enter or Send waits for it
let unconfirmed = null;   // the last reply the Mac didn't confirm (text, request id): sent again, it keeps its id

async function send(payload, button, doneLabel) {
  if (!current) return false;
  // A reply is sent once: a second Enter while it's on its way does nothing, and sending the same text again after an
  // unknown outcome carries the same id, so the Mac types it at most once.
  const reply = payload.text !== undefined && payload.submit;
  if (reply) {
    if (replying) return false;
    replying = true;
    if (!unconfirmed || unconfirmed.text !== payload.text) {
      unconfirmed = { text: payload.text, id: `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}` };
    }
    payload = { ...payload, request: unconfirmed.id };
  }
  if (button) button.disabled = true;
  try {
    // Typing waits for a jump in progress on the Mac and takes a moment for long text: allow for it, and on a
    // timeout say what's unknown rather than "unreachable" (a retry could type it twice).
    const unknown = "The Mac didn't confirm in time. Check the screen before sending again.";
    await api('/api/input', { method: 'POST', body: JSON.stringify({ tty: current, sid: currentSid, ...payload }),
                              timeout: 30000, timeoutMessage: unknown, unknownOutcome: unknown });
    if (reply) unconfirmed = null;
    const label = button && button.classList.contains('quickChip') ? `“${payload.text}” sent ✓` : 'Sent ✓';
    setInputStatus(doneLabel || (payload.text && payload.submit ? label : `${button ? button.textContent : 'Key'} ✓`));
    setTimeout(refreshScreen, 250);
    setTimeout(refreshScreen, 1200);
    return true;
  } catch (error) {
    setInputStatus(error.message, true);
    return false;
  } finally {
    if (reply) replying = false;
    if (button) button.disabled = false;
  }
}

// ---------- Dictation ----------

// Hold the mic to record; let go and the recording goes to the Mac (`/api/dictation`), which has OpenAI transcribe it
// with the Mac's key (the key never comes here). The text lands in the reply box at the cursor; it's never sent by
// itself. The first press on this phone shows a note about OpenAI instead of recording. Nothing is kept: the recording
// is in memory until it's posted.
const DICTATION_MAX_MS = 120000;
const DICTATION_MAX_BYTES = 4 * 1024 * 1024;
const DICTATION_TYPES = ['audio/webm;codecs=opus', 'audio/mp4', 'audio/webm', 'audio/ogg;codecs=opus'];
const DICTATION_NO_KEY = 'Dictation needs an OpenAI API key on the Mac: VibeSwitcher › Settings… › General › Dictation.';
let dictation = null;        // the recording under way: { recorder, stream, chunks, started, sid, timer, limit }
let dictationHeld = false;   // the mic is held down now
let transcribing = false;

function dictationSupported() {
  return Boolean(window.MediaRecorder && navigator.mediaDevices && navigator.mediaDevices.getUserMedia);
}

function dictationNoted() {
  try { return localStorage.getItem('vs.dictationNoted') === '1'; } catch (e) { return false; }
}

function renderMic() {
  const mic = $('micButton');
  const mode = state && state.dictation;
  mic.hidden = !dictationSupported() || !mode || mode === 'off';
  mic.classList.toggle('needsKey', mode === 'needsKey');
  mic.classList.toggle('recording', Boolean(dictation));
  mic.classList.toggle('busy', transcribing);
  const label = mode === 'needsKey' ? DICTATION_NO_KEY : dictation ? 'Recording: let go to transcribe' : transcribing ? 'Transcribing' : 'Hold to dictate';
  mic.setAttribute('aria-label', label);
  mic.setAttribute('title', label);
}

function setDictationStatus(message, isError = false) {
  const status = $('dictationStatus');
  status.textContent = message || '';
  status.hidden = !message;
  status.classList.toggle('error', isError);
}

async function startDictation() {
  setDictationStatus('');
  if (state && state.dictation === 'needsKey') return setDictationStatus(DICTATION_NO_KEY, true);
  if (!dictationNoted()) {
    $('dictationNote').hidden = false;
    layoutSession();
    return;
  }
  if (dictation || transcribing || !current) return;
  dictationHeld = true;
  let stream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  } catch (error) {
    dictationHeld = false;
    return setDictationStatus("This page may not use the microphone: allow it in your browser's settings for this site.", true);
  }
  // Let go while the browser asked: nothing to record.
  if (!dictationHeld || dictation) {
    stream.getTracks().forEach(track => track.stop());
    return;
  }
  const type = DICTATION_TYPES.find(t => MediaRecorder.isTypeSupported && MediaRecorder.isTypeSupported(t));
  let recorder;
  try {
    recorder = new MediaRecorder(stream, type ? { mimeType: type, audioBitsPerSecond: 32000 } : { audioBitsPerSecond: 32000 });
  } catch (error) {
    stream.getTracks().forEach(track => track.stop());
    return setDictationStatus("The microphone couldn't be started.", true);
  }
  const recording = { recorder, stream, chunks: [], started: Date.now(), sid: currentSid, limit: false };
  recording.timer = setTimeout(() => stopDictation(true), DICTATION_MAX_MS);
  recorder.addEventListener('dataavailable', event => { if (event.data && event.data.size) recording.chunks.push(event.data); });
  recorder.addEventListener('stop', () => finishDictation(recording));
  dictation = recording;
  recorder.start();
  setDictationStatus('Recording… let go to transcribe (2 minutes at most).');
  renderMic();
}

function stopDictation(limit = false) {
  dictationHeld = false;
  const recording = dictation;
  if (!recording) return;
  dictation = null;
  clearTimeout(recording.timer);
  recording.limit = limit;
  recording.duration = (Date.now() - recording.started) / 1000;
  recording.stream.getTracks().forEach(track => track.stop());
  if (recording.recorder.state !== 'inactive') recording.recorder.stop();
  renderMic();
}

async function finishDictation(recording) {
  const duration = Math.min(recording.duration || 0, DICTATION_MAX_MS / 1000);
  const blob = new Blob(recording.chunks, { type: recording.recorder.mimeType || 'audio/webm' });
  recording.chunks = [];
  if (duration < 0.3 || !blob.size) return setDictationStatus('Nothing was recorded: hold the mic while you speak.', true);
  if (blob.size > DICTATION_MAX_BYTES) return setDictationStatus('That recording is too big: keep it under 2 minutes.', true);
  transcribing = true;
  renderMic();
  setDictationStatus('Transcribing on your Mac…');
  try {
    const sid = recording.sid ? `&sid=${encodeURIComponent(recording.sid)}` : '';
    const result = await api(`/api/dictation?duration=${duration.toFixed(1)}${sid}`,
                             { method: 'POST', body: blob, contentType: blob.type || 'audio/webm', timeout: 75000 });
    // Another session opened meanwhile: its box isn't where this was meant to go.
    if (recording.sid !== currentSid) return setDictationStatus('The session changed, so the dictation was dropped.', true);
    insertDictation(result.text || '');
    setDictationStatus(recording.limit ? 'Stopped at 2 minutes, the most one dictation takes.' : '');
  } catch (error) {
    setDictationStatus(error.message, true);
  } finally {
    transcribing = false;
    renderMic();
  }
}

/// The text at the reply box's cursor (in place of a selection), a space on a side that touches a word; never sent.
function insertDictation(text) {
  if (!text) return;
  const reply = $('reply');
  const value = reply.value;
  const start = typeof reply.selectionStart === 'number' ? reply.selectionStart : value.length;
  const end = typeof reply.selectionEnd === 'number' ? reply.selectionEnd : start;
  const before = value.slice(0, start);
  const after = value.slice(end);
  let piece = text;
  if (before && !/\s$/.test(before)) piece = ` ${piece}`;
  if (after && !/^[\s.,;:!?]/.test(after)) piece = `${piece} `;
  const room = 2000 - before.length - after.length;
  piece = piece.slice(0, Math.max(0, room));
  reply.value = before + piece + after;
  const caret = before.length + piece.length;
  if (typeof reply.setSelectionRange === 'function') reply.setSelectionRange(caret, caret);
  growReply();
}

// ---------- Pairing ----------

async function pair(event) {
  event.preventDefault();
  $('pairError').hidden = true;
  try {
    const result = await api('/api/pair', {
      method: 'POST',
      // Pairing again from a phone that was already paired: the Mac retires the old token in the same step.
      body: JSON.stringify({ code: $('code').value, name: $('deviceName').value || defaultName(),
                             previous: localStorage.getItem('vs.previousToken') || undefined }),
    });
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

// ---------- Brief me ----------
// The Mac writes a briefing of what happened lately and makes its audio (ElevenLabs' voice when it has a key, else its
// own); the phone gets it with its token and plays it from a blob. A briefing takes longer than a request may stay
// open, so the press starts one and the phone asks until it's written.

const brief = { gen: 0, url: null, writing: false, ready: false, projects: '' };
const BRIEF_PROJECT = 'vs.briefProject';   // the picker's choice on this phone: a led project's name, or '' for all
const BRIEF_POLL = 1000;      // ms between asks
const BRIEF_WAIT = 150;       // asks: Claude may take a minute, ElevenLabs half of one more

function wait(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }

// A tenth of a second of silence as a WAV. Started from the tap itself, it lets the briefing play when it arrives:
// phones only let a page start audio from a tap.
function silence() {
  const samples = 800;   // 8 kHz, 8-bit mono
  const bytes = new Uint8Array(44 + samples);
  const view = new DataView(bytes.buffer);
  const ascii = (at, text) => { for (let i = 0; i < text.length; i++) bytes[at + i] = text.charCodeAt(i); };
  ascii(0, 'RIFF'); view.setUint32(4, 36 + samples, true); ascii(8, 'WAVE'); ascii(12, 'fmt ');
  view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
  view.setUint32(24, 8000, true); view.setUint32(28, 8000, true); view.setUint16(32, 1, true); view.setUint16(34, 8, true);
  ascii(36, 'data'); view.setUint32(40, samples, true);
  bytes.fill(128, 44);
  return new Blob([bytes], { type: 'audio/wav' });
}

function setBriefAudio(blob) {
  if (brief.url) URL.revokeObjectURL(brief.url);
  brief.url = URL.createObjectURL(blob);
  $('briefAudio').src = brief.url;
}

// The picker's choice: kept on this phone (storage may be unavailable: then it's All projects each time).
function savedBriefProject() {
  try { return localStorage.getItem(BRIEF_PROJECT) || ''; } catch (error) { return ''; }
}

function saveBriefProject(name) {
  try { if (name) localStorage.setItem(BRIEF_PROJECT, name); else localStorage.removeItem(BRIEF_PROJECT); } catch (error) { /* not kept */ }
}

// The project Brief me is about: one the Mac leads now, or '' for all of them.
function briefProject() {
  const name = $('briefScope').value || '';
  return (state?.briefingProjects || []).includes(name) ? name : '';
}

// "On [All projects ▾]": All projects and each project the Mac leads (from /api/state), drawn again only when they change.
function renderBriefScope() {
  const projects = state?.briefingProjects || [];
  $('briefScopeRow').hidden = projects.length === 0;
  const key = JSON.stringify(projects);
  if (key === brief.projects) return;
  brief.projects = key;
  const select = $('briefScope');
  const all = el('option', '', 'All projects');
  all.value = '';
  select.replaceChildren(all, ...projects.map(name => {
    const option = el('option', '', name);
    option.value = name;
    return option;
  }));
  const saved = savedBriefProject();
  select.value = projects.includes(saved) ? saved : '';
  renderBrief();
}

function renderBrief() {
  const audio = $('briefAudio');
  const playing = brief.ready && !audio.paused && !audio.ended;
  const project = briefProject();
  $('briefMe').disabled = brief.writing;
  $('briefSpinner').hidden = !brief.writing;
  $('briefLabel').textContent = brief.writing ? 'Writing your briefing…' : project ? `Brief me on ${project}` : 'Brief me';
  const play = $('briefPlay');
  play.hidden = !brief.writing && !brief.ready;
  play.textContent = brief.writing || playing ? '■ Stop' : '▶ Play';
}

function showBriefError(message) {
  $('briefError').textContent = message;
  $('briefError').hidden = !message;
}

async function briefMe() {
  if (brief.writing) return;
  const gen = ++brief.gen;
  const audio = $('briefAudio');
  audio.pause();
  brief.ready = false;
  brief.writing = true;
  showBriefError('');
  try { setBriefAudio(silence()); audio.play().catch(() => {}); } catch (error) { /* no audio here: the text still shows */ }
  renderBrief();
  try {
    const project = briefProject();
    let result = await api('/api/briefing', { method: 'POST', body: JSON.stringify(project ? { project } : {}) });
    for (let asked = 0; result.writing && asked < BRIEF_WAIT; asked++) {
      await wait(BRIEF_POLL);
      if (gen !== brief.gen) return;
      result = await api('/api/briefing');
    }
    if (gen !== brief.gen) return;
    if (result.writing) throw new Error('The Mac is taking too long to write it. Try again in a minute.');
    showBriefing(result);
  } catch (error) {
    if (gen === brief.gen) showBriefError(error.message);
  } finally {
    if (gen === brief.gen) { brief.writing = false; renderBrief(); }
  }
}

function showBriefing(result) {
  const text = $('briefText');
  text.textContent = result.text || '';
  text.lang = result.language || '';
  text.hidden = !result.text;
  $('briefNotice').textContent = result.notice || '';
  $('briefNotice').hidden = !result.notice;
  if (!result.audio) return;
  const bytes = Uint8Array.from(atob(result.audio), c => c.charCodeAt(0));
  setBriefAudio(new Blob([bytes], { type: result.audioType || 'audio/mpeg' }));
  brief.ready = true;
  // A phone that won't start it on its own: ▶ Play does.
  $('briefAudio').play().catch(() => renderBrief());
}

// Stop while it's written (it isn't played when it arrives), stop what's playing, or play it again.
function toggleBriefAudio() {
  const audio = $('briefAudio');
  if (brief.writing) {
    brief.gen++;
    brief.writing = false;
    audio.pause();
  } else if (!audio.paused && !audio.ended) {
    audio.pause();
    audio.currentTime = 0;
  } else {
    audio.play().catch(error => showBriefError(`Couldn't play it here (${error.message}).`));
  }
  renderBrief();
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
    // Unpaired meanwhile (a 401): the pairing screen stays, with its reason, not an empty list over it.
    api('/api/state').then(result => { state = result; openSession(tty); }).catch(() => { if (token) show('list'); });
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
    // Forget the token only once the Mac has removed this phone: otherwise a copy of it would keep working
    // while this screen says it's unpaired. (A 401 means it's already gone: api() forgets it then.)
    const note = $('unpairNote');
    try {
      await api('/api/unpair', { method: 'POST', body: '{}' });
      note.hidden = true;
      forgetToken();
    } catch (error) {
      if (!token) { note.hidden = true; return; }   // 401: the Mac had already removed it (and api() forgot it)
      note.replaceChildren(`Couldn't reach the Mac, so this phone is still paired (${error.message}). Try again, or remove it on the Mac in VibeSwitcher › Settings… › Phone. `);
      const anyway = el('button', 'link', 'Forget it on this phone only');
      anyway.type = 'button';
      anyway.addEventListener('click', () => {
        // Kept so that pairing this phone again retires the old token on the Mac.
        localStorage.setItem('vs.previousToken', token);
        note.hidden = true;
        forgetToken();
      });
      note.append(anyway);
      note.hidden = false;
    }
  });
  for (const button of document.querySelectorAll('.keys button')) button.addEventListener('click', () => pressKey(button));
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
  // Hold to dictate: down records, up (or the finger sliding off) sends it to the Mac. The press keeps the keyboard
  // where it is.
  const mic = $('micButton');
  mic.addEventListener('pointerdown', event => {
    event.preventDefault();
    if (mic.setPointerCapture && event.pointerId !== undefined) { try { mic.setPointerCapture(event.pointerId); } catch (e) { /* gone */ } }
    startDictation();
  });
  for (const type of ['pointerup', 'pointercancel']) mic.addEventListener(type, () => stopDictation());
  mic.addEventListener('contextmenu', event => event.preventDefault());
  // A keyboard or switch press: once starts, once stops.
  mic.addEventListener('keydown', event => {
    if ((event.key === 'Enter' || event.key === ' ') && !event.repeat) {
      event.preventDefault();
      if (dictation) stopDictation(); else startDictation();
    }
  });
  $('dictationOk').addEventListener('click', () => {
    try { localStorage.setItem('vs.dictationNoted', '1'); } catch (e) { /* private mode: it shows again */ }
    $('dictationNote').hidden = true;
    layoutSession();
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
  $('briefMe').addEventListener('click', () => briefMe());
  $('briefScope').addEventListener('change', () => { saveBriefProject($('briefScope').value); renderBrief(); });
  $('briefPlay').addEventListener('click', toggleBriefAudio);
  for (const type of ['play', 'pause', 'ended']) $('briefAudio').addEventListener(type, renderBrief);
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
