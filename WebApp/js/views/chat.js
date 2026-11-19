// A session's chat (the Mac's ChatView): your prompts on the right, the agent's replies on the left, the tool calls
// between two messages folded into one line that opens to each command, its output and the diffs. For a lead, its
// questions for you follow the last row.
//
// It stays where you are: new rows keep the view at the end only if it was there, and otherwise a small "Latest"
// button counts them. Only the last rows are in the page (WINDOW of them, more as you scroll up), so a chat of ten
// thousand rows opens as fast as one of ten.

import { h, keyed, setText, setClass, framed } from '../dom.js';
import { agentMark, statusMark, setMark, icon } from '../marks.js';
import { since, short, clock, plural, tilde, stateOf, AGENTS, STATES } from '../words.js';
import { markdown, diffView } from '../text.js';
import { questionStack, askCard } from './cards.js';

const WINDOW = 80;
// How close to the end counts as being at the end.
const NEAR = 48;

// The rows for `items` from `start` on: each prompt, reply and note a row, each run of tool calls one row.
function rowsOf(items, start) {
  const rows = [];
  let tools = null;
  for (let i = start; i < items.length; i++) {
    const item = items[i];
    if (item.kind === 'tool') {
      if (!tools) rows.push(tools = { key: 'tools:' + item.id, kind: 'tools', tools: [] });
      tools.tools.push(item);
    } else {
      tools = null;
      // A message sent from here keeps its row when the transcript's own item takes the pending one's place.
      rows.push({ key: item.action ? 'pending:' + item.action : item.id, kind: item.kind, item });
    }
  }
  return rows;
}

// "Ran 2 commands · edited 1 file · read 3 files" (ChatTimeline's summary).
function toolSummary(tools) {
  const count = (type) => tools.filter((tool) => tool.detail?.type === type).length;
  const parts = [];
  const commands = count('command');
  const edits = count('edit') + count('write');
  const reads = count('read');
  const others = tools.length - commands - edits - reads;
  if (commands) parts.push(`ran ${plural(commands, 'command')}`);
  if (edits) parts.push(`edited ${plural(edits, 'file')}`);
  if (reads) parts.push(`read ${plural(reads, 'file')}`);
  if (others) parts.push(`used ${plural(others, 'tool')}`);
  const failed = tools.filter((tool) => tool.result?.failed).length;
  if (failed) parts.push(`${failed} failed`);
  const text = parts.join(' · ');
  return text.charAt(0).toUpperCase() + text.slice(1);
}

const seconds = (tool) => (tool.result ? (Date.parse(tool.result.at) - Date.parse(tool.at)) / 1000 : 0);
const TOOL_ICON = { command: 'terminal', edit: 'pencil', write: 'pencil', read: 'file' };

// A tool's output: the first lines, and a button for the rest.
function outputView(output, failed) {
  const lines = output.split('\n');
  const pre = h('pre', { class: failed ? 'output failed' : 'output', tabindex: 0 }, lines.length > 14 ? lines.slice(0, 12).join('\n') : output);
  if (lines.length <= 14) return pre;
  const more = h('button', { class: 'link', type: 'button', onclick: () => { pre.textContent = output; more.remove(); } }, `Show all ${lines.length} lines`);
  return [pre, more];
}

function toolView(tool, home) {
  const took = seconds(tool);
  const head = h('div', { class: 'tool-head' }, icon(TOOL_ICON[tool.detail?.type] || 'tool', 13), h('span', { class: 'tool-title' }, tool.title),
    took >= 1 ? h('span', { class: 'tool-time' }, short(took)) : null,
    tool.result ? null : h('span', { class: 'running', role: 'status', 'aria-label': 'Running' }));
  const body = [];
  const detail = tool.detail || {};
  if (detail.type === 'edit') {
    const diff = diffView(detail.changes || []);
    head.append(h('span', { class: 'counts' }, h('span', { class: 'plus' }, `+${diff.added}`), h('span', { class: 'minus' }, `−${diff.removed}`)));
    body.push(h('div', { class: 'path' }, tilde(detail.path, home)), diff.el);
  } else if (detail.type === 'read') {
    body.push(h('div', { class: 'path' }, tilde(detail.path, home)));
  }
  if (tool.result?.output) body.push(outputView(tool.result.output, tool.result.failed));
  return h('div', { class: tool.result?.failed ? 'tool failed' : 'tool' }, head, body);
}

function makeRow(view, first) {
  if (first.kind === 'prompt') {
    const text = h('div', { class: 'bubble' });
    const note = h('div', { class: 'row-note' });
    const el = h('div', { class: 'chat-row prompt' }, text, note);
    return {
      el,
      update({ item }) {
        setText(text, item.text);
        setClass(el, 'pending', !!item.pending);
        setText(note, item.pending ? 'sending…' : clock(item.at));
      },
    };
  }
  if (first.kind === 'reply') {
    const body = h('div', { class: 'prose' });
    const el = h('div', { class: 'chat-row reply' }, agentMark(view.agent(), 18), body);
    let shown = null;
    return {
      el,
      update({ item }) {
        setClass(el, 'streaming', !!item.streaming);
        if (item.text === shown) return;
        shown = item.text;
        body.replaceChildren(markdown(item.text));
      },
    };
  }
  if (first.kind === 'tools') {
    const text = h('span', { class: 'fold-text' });
    const time = h('span', { class: 'fold-time' });
    const running = h('span', { class: 'running', role: 'status', 'aria-label': 'Running', hidden: true });
    const body = h('div', { class: 'fold-body', hidden: true });
    const toggle = h('button', { class: 'fold', type: 'button', 'aria-expanded': 'false' }, text, running, time, icon('chevron', 10));
    const el = h('div', { class: 'chat-row tools' }, toggle, body);
    let row = first;
    let drawn = '';
    const draw = () => {
      const open = view.open.has(row.key);
      toggle.setAttribute('aria-expanded', String(open));
      body.hidden = !open;
      if (!open) { drawn = ''; body.replaceChildren(); return; }
      const now = JSON.stringify(row.tools);
      if (now === drawn) return;
      drawn = now;
      body.replaceChildren(...row.tools.map((tool) => toolView(tool, view.home())));
    };
    toggle.addEventListener('click', () => {
      if (!view.open.delete(row.key)) view.open.add(row.key);
      draw();
    });
    return {
      el,
      update(next) {
        row = next;
        setText(text, toolSummary(row.tools));
        setClass(toggle, 'failed', row.tools.some((tool) => tool.result?.failed));
        running.hidden = row.tools.every((tool) => tool.result);
        const total = row.tools.reduce((sum, tool) => sum + seconds(tool), 0);
        setText(time, total >= 1 ? short(total) : '');
        draw();
      },
    };
  }
  if (first.kind === 'team') {
    const title = h('div', { class: 'note-title' });
    const text = h('div', { class: 'note-text' });
    const time = h('time', { class: 'note-time' });
    const el = h('div', { class: 'chat-row team' }, icon('note', 14), h('div', { class: 'note-body' }, title, text), time);
    return { el, update({ item }) { setText(title, item.title); setText(text, item.text); setText(time, clock(item.at)); } };
  }
  if (first.kind === 'ask') {
    const el = h('div', { class: 'chat-row ask-row' });
    let drawn = '';
    return {
      el,
      update({ item }) {
        const local = view.asked.get(item.id) || null;
        const now = JSON.stringify([item, local]);
        if (now === drawn) return;
        const focused = el.contains(document.activeElement);
        drawn = now;
        el.replaceChildren(askCard(view.app, view.session, item, local, view.asked, view.redraw));
        if (focused) view.composer.focus();
      },
    };
  }
  // A kind this client doesn't know yet (rule 3): its row takes no room.
  return { el: h('div', { hidden: true }), update() {} };
}

export function chatView(app) {
  const { store } = app;
  const rowsEl = h('div', { class: 'chat-rows', role: 'log', 'aria-label': 'Conversation' });
  const earlier = h('div', { class: 'earlier', hidden: true }, 'Earlier messages load as you scroll');
  const liveMark = statusMark('working', 10);
  const liveText = h('span');
  const live = h('div', { class: 'chat-live' }, liveMark, liveText);
  const skeleton = h('div', { class: 'chat-skeleton', 'aria-hidden': 'true' },
    h('span', { class: 'bone right' }), h('span', { class: 'bone wide' }), h('span', { class: 'bone' }), h('span', { class: 'bone short' }));
  const empty = h('p', { class: 'pane-empty', hidden: true }, 'No conversation for this session yet.');
  // A node whose page can't follow a chat yet (`chat` isn't in what this connection may send): said once, calmly, in
  // the conversation's place. A lead's questions still follow below it.
  const later = h('p', { class: 'pane-empty', hidden: true }, 'This session’s conversation comes to this page in a later build.');
  const stackSlot = h('div');
  const column = h('div', { class: 'chat-column' }, earlier, skeleton, empty, later, rowsEl, live, stackSlot);
  const scroller = h('div', { class: 'chat-scroll' }, column);
  const latestCount = h('span', { class: 'latest-count' });
  const latest = h('button', { class: 'latest', type: 'button', hidden: true, onclick: () => toEnd(true) }, icon('down', 12), 'Latest', latestCount);

  const input = h('textarea', { class: 'composer-input', rows: 1, 'aria-label': 'Message' });
  const sendButton = h('button', { class: 'send', type: 'submit', title: 'Send (↩)', 'aria-label': 'Send', disabled: true }, icon('send', 15));
  const form = h('form', { class: 'composer' }, input, sendButton);
  const hint = h('p', { class: 'composer-hint', hidden: true });
  const el = h('div', { class: 'chat' }, scroller, latest, form, hint);

  const view = {
    app,
    session: null,
    open: new Set(),          // the tool folds opened
    asked: new Map(),         // answers to an agent's prompt, not confirmed yet
    agent: () => store.state.sessions.get(view.session)?.agent || 'claude',
    home: () => store.state.node?.home,
    composer: input,
    redraw: () => schedule(),
  };
  const rows = new Map();
  let start = 0;
  let unseen = 0;
  let stack = null;
  let stackProject = null;
  let unsubscribe = null;
  let structural = true;
  let jump = true;
  let shownQuestions = 0;
  const touched = new Set();

  const atEnd = () => scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < NEAR;
  function toEnd(focus) {
    scroller.scrollTop = scroller.scrollHeight;
    unseen = 0;
    latest.hidden = true;
    setText(latestCount, '');
    if (focus) input.focus({ preventScroll: true });
  }

  function render() {
    const session = store.state.sessions.get(view.session);
    placeStack(session);
    const chat = store.state.chats.get(view.session);
    const pinned = jump || atEnd();
    const following = store.can('chat');
    const loaded = !!chat?.loaded;
    skeleton.hidden = loaded || !following;
    later.hidden = following;
    empty.hidden = !following || !loaded || chat.items.length > 0 || !!stack;
    if (loaded && structural) {
      const items = chat.items;
      if (jump || (pinned && items.length - start > WINDOW * 3)) start = Math.max(0, items.length - WINDOW);
      const before = rows.size;
      keyed(rowsEl, rows, rowsOf(items, start), (row) => row.key, (row) => makeRow(view, row), { enter: !jump && before > 0 });
      earlier.hidden = start === 0;
    } else if (loaded) {
      // Only text grew: the rows it grew in are drawn again, nothing else is touched.
      for (const row of rowsOf(chat.items, start)) {
        if (touched.has(row.key)) rows.get(row.key)?.update(row);
      }
    }
    touched.clear();
    structural = false;
    const fresh = stack ? stack.update() : 0;
    renderLive(session);
    renderComposer(session);
    if (pinned) toEnd(false);
    else if (unseen > 0 || fresh > shownQuestions) {
      latest.hidden = false;
      setText(latestCount, unseen > 0 ? String(unseen) : '');
    }
    shownQuestions = fresh;
    jump = false;
  }

  function renderLive(session) {
    const state = session ? stateOf(session) : 'idle';
    const shown = state === 'working' || state === 'background';
    setClass(live, 'on', shown);
    if (!shown) return;
    setMark(liveMark, state);
    liveText.replaceChildren(state === 'background' ? `Turn done · still running: ${session.detail || 'background work'}` : `${session.detail || STATES.working.label} · `,
      state === 'background' ? '' : h('time', { data: { since: session.since } }, since(session.since)));
  }

  function renderComposer(session) {
    const typed = !!session?.hosted && !session.ended && store.can('send');
    form.hidden = !typed;
    hint.hidden = typed;
    if (!typed) {
      setText(hint, !session ? '' : session.ended ? 'This session has ended.'
        : !store.can('send') ? 'This page follows the node; to type into a session, use its terminal.'
        : 'Runs in another terminal. It can be read here, not typed into.');
      return;
    }
    const agent = AGENTS[session.agent] || AGENTS.claude;
    const working = stateOf(session) === 'working';
    input.placeholder = working ? `Steer ${agent} while it works — ↩ sends it to its next step` : `Message ${agent}…`;
  }

  const schedule = framed(render);

  // A lead's questions, under its chat. Its project can arrive after the session does (the node sends the leads in
  // their own collection), so the stack follows it.
  function placeStack(session) {
    const project = session?.role === 'lead' ? session.lead || null : null;
    if (project === stackProject) return;
    stackProject = project;
    stack = project ? questionStack(app, project) : null;
    stackSlot.replaceChildren(...(stack ? [stack.el] : []));
    shownQuestions = 0;
  }

  function onChat(changes) {
    for (const change of changes) {
      if (change.type === 'append') touched.add(change.id);
      else structural = true;
      if (change.type === 'reset') jump = true;
      if (change.fresh && !atEnd()) unseen += 1;
      // What you sent yourself always brings the view to it.
      if (change.item?.pending) jump = true;
    }
    // A streaming reply's text lives in a row keyed by its id; a tool's in its fold, which `structural` redraws.
    schedule();
  }

  scroller.addEventListener('scroll', () => {
    if (atEnd()) {
      unseen = 0;
      latest.hidden = true;
    }
    if (scroller.scrollTop < 600 && start > 0) {
      // Earlier rows come in above; the row under your eyes stays where it is.
      const height = scroller.scrollHeight;
      const chat = store.state.chats.get(view.session);
      start = Math.max(0, start - WINDOW);
      keyed(rowsEl, rows, rowsOf(chat.items, start), (row) => row.key, (row) => makeRow(view, row));
      earlier.hidden = start === 0;
      scroller.scrollTop += scroller.scrollHeight - height;
    }
  }, { passive: true });

  function grow() {
    input.style.height = 'auto';
    input.style.height = Math.min(input.scrollHeight, 200) + 'px';
    sendButton.disabled = !input.value.trim();
  }
  input.addEventListener('input', grow);
  input.addEventListener('keydown', (event) => {
    if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      form.requestSubmit();
    } else if (event.key === 'ArrowUp' && input.value === '') {
      // ↑ from an empty box steps into what's waiting for an answer (the Mac's "↑ ↓ and ↩ with the message box empty").
      const cards = el.querySelectorAll('.card:not(.closed)');
      const target = cards[cards.length - 1]?.querySelector('.option, .answer-input');
      if (target) { event.preventDefault(); target.focus(); }
    }
  });
  form.addEventListener('submit', (event) => {
    event.preventDefault();
    const text = input.value.trim();
    if (!text) return;
    input.value = '';
    grow();
    store.send(view.session, text);
  });

  for (const topic of ['sessions', 'cards', 'leads', 'connection']) store.subscribe(topic, () => { if (view.session && el.isConnected) schedule(); });

  return {
    el,
    // Shows `id`'s chat: at once from what's known, or a skeleton until its rows arrive.
    show(id) {
      if (view.session === id) return;
      unsubscribe?.();
      view.session = id;
      view.open = new Set();
      rows.clear();
      rowsEl.replaceChildren();
      unseen = 0;
      latest.hidden = true;
      structural = true;
      jump = true;
      shownQuestions = 0;
      stack = null;
      stackProject = null;
      // The last session's questions leave with it (placeStack only draws when the project changes).
      stackSlot.replaceChildren();
      placeStack(store.state.sessions.get(id));
      store.openChat(id);
      unsubscribe = store.subscribe('chat:' + id, onChat);
      render();
    },
    // Shown again after another pane had its place: back at the end.
    reveal() { jump = true; structural = true; render(); },
    // Runs `work`, which changes the chat's width (its lines wrap again): at the end before, at the end after.
    hold(work) {
      const pinned = atEnd();
      work();
      if (pinned) toEnd(false);
    },
    focus() { input.focus(); },
  };
}
