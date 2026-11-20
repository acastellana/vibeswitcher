// A session's chat (the Mac's ChatView): your prompts on the right, the agent's replies on the left, the tool calls
// between two messages folded into one line that opens to each command, its output and the diffs. For a lead, its
// questions for you follow the last row.
//
// The items are the node's (the wire contract §6), drawn to nodes by text.js: nothing an agent wrote is markup.
//
// - A windowed list: only the rows near what you see are in the page, the rest stand in as two spacers whose heights
//   are the rows' measured heights (an estimate until a row was drawn once). A chat of ten thousand rows opens and
//   scrolls as one of ten.
// - Older items come as you scroll up to them (`chat.page`), and the row under your eyes stays where it is.
// - A reply that grows is drawn again in its own row only, keeping the blocks that didn't change.
// - It stays where you are: new rows keep the view at the end only if it was there, and otherwise a small "Latest"
//   button counts them.
// - "New since you looked" (the Mac's marker): a line before the first item that came after the last one you saw at the
//   chat's end, with what came since; worked out when the chat opens, kept until another opens. What you saw is this
//   browser's (`SEEN`), by session.

import { h, keyed, setText, setClass, framed } from '../dom.js';
import { agentMark, statusMark, setMark, icon } from '../marks.js';
import { since, short, clock, plural, tilde, stateOf, AGENTS, STATES } from '../words.js';
import { markdown, diffView, codeBlock } from '../text.js';
import { summaryOf, newSince, sinceSummary } from '../chatops.js';
import { questionStack, askCard } from './cards.js';
import { draftBox, promptCard, drivable } from './drive.js';

// How close to the end counts as being at the end.
const NEAR = 48;
// How far beyond what you see rows are drawn, in viewports, above and below.
const OVERSCAN = 1.5;
// Rows drawn at least, from the end, when the chat opens.
const FIRST_ROWS = 30;
// A row's height until it is measured, by type.
const ESTIMATE = { prompt: 62, reply: 96, tools: 30, team: 70, ask: 160 };

// The last item seen at each chat's end, by session id, in this browser: the newest `SEEN_KEPT` sessions.
const SEEN = 'vibeswitcher.seen';
const SEEN_KEPT = 300;

function seenRecord() {
  try { return JSON.parse(globalThis.localStorage?.getItem(SEEN) || '{}') || {}; } catch { return {}; }
}

function noteSeen(session, id) {
  const record = seenRecord();
  if (record[session] === id) return;
  delete record[session];
  record[session] = id;
  const kept = Object.entries(record).slice(-SEEN_KEPT);
  try { globalThis.localStorage?.setItem(SEEN, JSON.stringify(Object.fromEntries(kept))); } catch { /* a private window: not kept */ }
}

// A row's key: its id, but a message sent from here keeps its row when the transcript's own item takes its place.
const keyOf = (item) => (item.action ? 'pending:' + item.action : item.id);

const seconds = (tool) => (tool.result?.at && tool.at ? Math.max(0, (Date.parse(tool.result.at) - Date.parse(tool.at)) / 1000) : 0);
const TOOL_ICON = { command: 'terminal', edit: 'pencil', write: 'pencil', read: 'file', thought: 'note', todos: 'check', plan: 'note' };

// A tool's output: the first lines, and a button for the rest.
function outputView(output, failed, truncated) {
  const lines = output.split('\n');
  const pre = h('pre', { class: failed ? 'output failed' : 'output', tabindex: 0 }, lines.length > 14 ? lines.slice(0, 12).join('\n') : output);
  const parts = [pre];
  if (lines.length > 14) {
    const more = h('button', { class: 'link', type: 'button', onclick: () => { pre.textContent = output; more.remove(); } }, `Show all ${lines.length} lines`);
    parts.push(more);
  }
  if (truncated) parts.push(h('div', { class: 'path' }, 'The output was cut short in the transcript.'));
  return parts;
}

// An image the agent saw: its type and size only (the node serves no bytes yet).
function imageNote(image) {
  const type = (image.mediaType || 'image').replace(/^image\//, '').toUpperCase();
  const size = image.bytes >= 1048576 ? `${(image.bytes / 1048576).toFixed(1)} MB` : `${Math.max(1, Math.round(image.bytes / 1024))} KB`;
  return h('span', { class: 'image-note' }, icon('file', 12), `Image · ${type} · ${size}`);
}

function toolView(tool, home) {
  const took = seconds(tool);
  const detail = tool.detail || {};
  const head = h('div', { class: 'tool-head' }, icon(TOOL_ICON[detail.type] || 'tool', 13), h('span', { class: 'tool-title' }, tool.title),
    took >= 1 ? h('span', { class: 'tool-time' }, short(took)) : null,
    tool.result ? null : h('span', { class: 'running', role: 'status', 'aria-label': 'Running' }));
  const body = [];
  if (detail.type === 'edit') {
    const diff = diffView(detail.changes || []);
    head.append(h('span', { class: 'counts' }, h('span', { class: 'plus' }, `+${diff.added}`), h('span', { class: 'minus' }, `−${diff.removed}`)));
    body.push(h('div', { class: 'path' }, tilde(detail.path, home)), diff.el);
  } else if (detail.type === 'write') {
    const diff = diffView([{ old: '', new: detail.content || '' }]);
    head.append(h('span', { class: 'counts' }, h('span', { class: 'plus' }, `+${diff.added}`)));
    body.push(h('div', { class: 'path' }, tilde(detail.path, home)), diff.el);
  } else if (detail.type === 'read') {
    body.push(h('div', { class: 'path' }, tilde(detail.path, home)));
  } else if (detail.type === 'command' && detail.command !== tool.title) {
    body.push(codeBlock(detail.command));
  } else if (detail.type === 'thought' || detail.type === 'plan') {
    body.push(h('div', { class: 'prose quiet' }, markdown(detail.text || '')));
  } else if (detail.type === 'todos') {
    body.push(h('ul', { class: 'todos' }, (detail.todos || []).map((todo) => h('li', { class: 'todo ' + todo.status }, todo.text))));
  } else if (detail.type === 'patch') {
    body.push(codeBlock(detail.text || ''));
  } else if (detail.type === 'agent') {
    body.push(h('div', { class: 'prose quiet' }, markdown(detail.prompt || '')));
  } else if (detail.type === 'questions') {
    for (const question of detail.questions || []) body.push(h('div', { class: 'prose quiet' }, question.question, h('ul', null, (question.options || []).map((option) => h('li', null, option)))));
  } else if (detail.type === 'fields') {
    body.push(h('dl', { class: 'fields' }, (detail.fields || []).map((field) => [h('dt', null, field.name), h('dd', null, field.value)])));
  }
  if (tool.result?.output) body.push(outputView(tool.result.output, tool.result.failed, tool.result.truncated));
  for (const image of tool.result?.images || []) body.push(imageNote(image));
  return h('div', { class: tool.result?.failed ? 'tool failed' : 'tool' }, head, body);
}

// `next`'s blocks into `el`: a block that reads the same keeps its node (a growing reply moves nothing above its end).
function patchChildren(el, next) {
  const fresh = [...next.childNodes];
  const old = [...el.childNodes];
  let same = 0;
  while (same < old.length && same < fresh.length && old[same].isEqualNode(fresh[same])) same++;
  for (const node of old.slice(same)) node.remove();
  el.append(...fresh.slice(same));
}

function makeRow(view, first) {
  if (first.type === 'prompt') {
    const text = h('div', { class: 'bubble' });
    const images = h('div', { class: 'row-images' });
    const note = h('div', { class: 'row-note' });
    const el = h('div', { class: 'chat-row prompt' }, text, images, note);
    return {
      el,
      update(item) {
        setText(text, item.text);
        text.hidden = !item.text;
        images.replaceChildren(...(item.images || []).map(imageNote));
        images.hidden = !(item.images || []).length;
        setClass(el, 'pending', !!item.pending);
        setClass(el, 'steered', !!item.steered);
        setText(note, item.pending ? 'sending…' : [item.steered ? (item.fromLead ? 'From the lead, while it worked' : 'Sent while it worked') : '', clock(item.at)].filter(Boolean).join(' · '));
      },
    };
  }
  if (first.type === 'reply') {
    const body = h('div', { class: 'prose' });
    const el = h('div', { class: 'chat-row reply' }, agentMark(view.agent(), 18), body);
    let shown = null;
    return {
      el,
      update(item) {
        setClass(el, 'streaming', !!item.streaming);
        if (item.text === shown) return;
        const grew = shown !== null && item.text.startsWith(shown);
        shown = item.text;
        const next = h('div', null, markdown(item.text));
        if (grew) patchChildren(body, next); else body.replaceChildren(...next.childNodes);
      },
    };
  }
  if (first.type === 'tools') {
    const text = h('span', { class: 'fold-text' });
    const time = h('span', { class: 'fold-time' });
    const running = h('span', { class: 'running', role: 'status', 'aria-label': 'Running', hidden: true });
    const body = h('div', { class: 'fold-body', hidden: true });
    const toggle = h('button', { class: 'fold', type: 'button', 'aria-expanded': 'false' }, text, running, time, icon('chevron', 10));
    const el = h('div', { class: 'chat-row tools' }, toggle, body);
    let row = first;
    let drawn = '';
    const draw = () => {
      const open = view.open.has(row.id);
      toggle.setAttribute('aria-expanded', String(open));
      body.hidden = !open;
      if (!open) { drawn = ''; body.replaceChildren(); return; }
      const now = JSON.stringify(row.tools);
      if (now === drawn) return;
      drawn = now;
      body.replaceChildren(...row.tools.map((tool) => toolView(tool, view.home())));
    };
    toggle.addEventListener('click', () => {
      if (!view.open.delete(row.id)) view.open.add(row.id);
      view.held(draw);
    });
    return {
      el,
      update(next) {
        row = next;
        const tools = row.tools || [];
        const failed = tools.filter((tool) => tool.result?.failed).length;
        setText(text, (row.summary || summaryOf(tools)) + (failed ? ` · ${failed} failed` : ''));
        setClass(toggle, 'failed', failed > 0);
        running.hidden = tools.every((tool) => tool.result);
        const total = tools.reduce((sum, tool) => sum + seconds(tool), 0);
        setText(time, total >= 1 ? short(total) : '');
        draw();
      },
    };
  }
  if (first.type === 'team') {
    const title = h('div', { class: 'note-title' });
    const text = h('div', { class: 'note-text' });
    const time = h('time', { class: 'note-time' });
    const el = h('div', { class: 'chat-row team' }, icon('note', 14), h('div', { class: 'note-body' }, title, text), time);
    return {
      el,
      update(item) {
        setText(title, item.title || 'VibeSwitcher');
        setText(text, item.text);
        setText(time, clock(item.at));
      },
    };
  }
  if (first.type === 'ask') {
    const el = h('div', { class: 'chat-row ask-row' });
    let drawn = '';
    return {
      el,
      update(item) {
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
  // A type this client doesn't know yet (rule 3): its row takes no room.
  return { el: h('div', { class: 'chat-row unknown', hidden: true }), update() {} };
}

export function chatView(app) {
  const { store } = app;
  const rowsEl = h('div', { class: 'chat-rows', role: 'log', 'aria-label': 'Conversation' });
  const above = h('div', { class: 'chat-spacer', 'aria-hidden': 'true' });
  const below = h('div', { class: 'chat-spacer', 'aria-hidden': 'true' });
  const earlier = h('div', { class: 'earlier', hidden: true }, 'Earlier messages…');
  const liveMark = statusMark('working', 10);
  const liveText = h('span');
  const live = h('div', { class: 'chat-live' }, liveMark, liveText);
  const skeleton = h('div', { class: 'chat-skeleton', 'aria-hidden': 'true' },
    h('span', { class: 'bone right' }), h('span', { class: 'bone wide' }), h('span', { class: 'bone' }), h('span', { class: 'bone short' }));
  const empty = h('p', { class: 'pane-empty', hidden: true }, 'No conversation for this session yet.');
  // A node whose page can't follow a chat (`chat.page` isn't among what this connection may send): said once, calmly,
  // in the conversation's place. A lead's questions still follow below it.
  const later = h('p', { class: 'pane-empty', hidden: true }, 'This node doesn’t send this session’s conversation to the page.');
  const stackSlot = h('div');
  // The question open on the session's own screen, under its conversation, where the Mac's answer card sits.
  const asking = promptCard(app);
  const column = h('div', { class: 'chat-column' }, earlier, skeleton, empty, later, above, rowsEl, below, live, stackSlot, asking.el);
  const scroller = h('div', { class: 'chat-scroll' }, column);
  // The "New since you looked" line, placed before its row while that row is drawn.
  const markSummary = h('span', { class: 'new-mark-summary' });
  const mark = h('div', { class: 'new-mark', role: 'separator' }, h('span', { class: 'new-mark-text' }, h('span', null, 'New since you looked'), markSummary));
  const latestCount = h('span', { class: 'latest-count' });
  const latest = h('button', { class: 'latest', type: 'button', hidden: true, onclick: () => toEnd(true) }, icon('down', 12), 'Latest', latestCount);

  const input = h('textarea', { class: 'composer-input', rows: 1, 'aria-label': 'Message' });
  const sendButton = h('button', { class: 'send', type: 'submit', title: 'Send (↩)', 'aria-label': 'Send', disabled: true }, icon('send', 15));
  const form = h('form', { class: 'composer' }, input, sendButton);
  const hint = h('p', { class: 'composer-hint', hidden: true });
  // The message this page left for the session, over the box, with the line that sends it.
  const drafted = draftBox(app, { edit: (text) => { input.value = text; grow(); input.focus(); } });
  const el = h('div', { class: 'chat' }, scroller, latest, drafted.el, form, hint);

  const view = {
    app,
    session: null,
    open: new Set(),          // the tool folds opened, by item id
    asked: new Map(),         // answers to an agent's prompt, not confirmed yet
    agent: () => store.state.sessions.get(view.session)?.agent || 'claude',
    home: () => store.state.node?.home,
    composer: input,
    redraw: () => schedule(),
    // A change inside a row that moves what follows it (a fold opened): the row under your eyes stays put.
    held: (work) => { anchored(work); measure(); },
  };
  const rows = new Map();     // drawn rows by key: { el, update }
  const heights = new Map();  // measured heights by key, each with the gap above the next row
  let start = 0;              // the drawn range of the chat's items: [start, end)
  let end = 0;
  let unseen = 0;
  let stack = null;
  let stackProject = null;
  let jump = true;
  let shownQuestions = 0;
  let structural = true;
  // The marker's row (its key) once the chat's items came; `marking`: not worked out yet for this chat.
  let markKey = null;
  let marking = true;
  const touched = new Set();

  const chat = () => store.state.chats.get(view.session);
  const items = () => chat()?.items || [];
  const atEnd = () => scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < NEAR;
  const heightOf = (item) => heights.get(keyOf(item)) ?? ESTIMATE[item.type] ?? 60;
  const sum = (list, from, to) => { let total = 0; for (let i = from; i < to; i++) total += heightOf(list[i]); return total; };

  function toEnd(focus) {
    pin();
    unseen = 0;
    latest.hidden = true;
    setText(latestCount, '');
    if (focus) input.focus({ preventScroll: true });
  }

  // The view at the end: the last rows drawn, enough to fill it and more, and the scroll at the bottom.
  function pin() {
    const list = items();
    const want = Math.max(scroller.clientHeight * (1 + OVERSCAN), 1);
    let from = list.length;
    let filled = 0;
    while (from > 0 && (filled < want || list.length - from < FIRST_ROWS)) filled += heightOf(list[--from]);
    draw(list, from, list.length);
    measure();
    scroller.scrollTop = scroller.scrollHeight;
  }

  // Draws items [from, to) between the spacers.
  function draw(list, from, to) {
    start = Math.max(0, Math.min(from, list.length));
    end = Math.max(start, Math.min(to, list.length));
    keyed(rowsEl, rows, list.slice(start, end), keyOf, (item) => makeRow(view, item), { enter: !jump && structural && to === list.length });
    placeMark();
    above.style.height = sum(list, 0, start) + 'px';
    below.style.height = sum(list, end, list.length) + 'px';
    earlier.hidden = !(start === 0 && chat()?.more);
  }

  // The marker before its row, while that row is drawn (`keyed` moves rows only: the marker is put back after it).
  function placeMark() {
    const row = markKey ? rows.get(markKey) : null;
    if (row?.el.parentNode === rowsEl) {
      if (mark.nextSibling !== row.el) rowsEl.insertBefore(mark, row.el);
    } else {
      mark.remove();
    }
  }

  // At the chat's first items: where the marker goes (from what this browser saw last), then what's seen now.
  function noteLooked(list) {
    if (marking) {
      marking = false;
      const at = newSince(list, seenRecord()[view.session]);
      markKey = at >= 0 ? keyOf(list[at]) : null;
      setText(markSummary, at >= 0 ? sinceSummary(list.slice(at)) : '');
    }
    const last = [...list].reverse().find((item) => item.id && !item.pending);
    if (last) noteSeen(view.session, last.id);
  }

  // Each drawn row's height, with the gap above the next: the spacers then stand in for them exactly.
  function measure() {
    const list = items();
    for (let i = start; i < end; i++) {
      const row = rows.get(keyOf(list[i]));
      if (!row || row.el.hidden) continue;
      const next = i + 1 < end ? rows.get(keyOf(list[i + 1]))?.el : null;
      const height = next && !next.hidden ? next.offsetTop - row.el.offsetTop : row.el.offsetHeight + 16;
      if (height > 0) heights.set(keyOf(list[i]), height);
    }
    above.style.height = sum(list, 0, start) + 'px';
    below.style.height = sum(list, end, list.length) + 'px';
  }

  // Runs `work` (which may draw, measure or move rows) with the first row in view kept where it is on the screen.
  function anchored(work) {
    const top = scroller.scrollTop;
    let anchor = null;
    let offset = 0;
    for (const row of rows.values()) {
      if (row.el.hidden) continue;
      if (row.el.offsetTop + row.el.offsetHeight > top) { anchor = row.el; offset = row.el.offsetTop - top; break; }
    }
    work();
    if (anchor?.isConnected) scroller.scrollTop = anchor.offsetTop - offset;
  }

  // The range the scroll position wants drawn, with what lies beyond the view on both sides.
  function wanted(list) {
    const base = above.offsetTop;
    const top = scroller.scrollTop - base - scroller.clientHeight * OVERSCAN;
    const bottom = scroller.scrollTop - base + scroller.clientHeight * (1 + OVERSCAN);
    let y = 0;
    let from = 0;
    while (from < list.length && y + heightOf(list[from]) < top) y += heightOf(list[from++]);
    let to = from;
    while (to < list.length && y < bottom) y += heightOf(list[to++]);
    return [from, Math.max(to, Math.min(list.length, from + 1))];
  }

  // After a scroll: rows drawn where you look, those far away let go, and older items asked for near the top.
  function follow() {
    const list = items();
    if (!list.length || !chat()?.loaded) return;
    const [from, to] = wanted(list);
    if (from < start || to > end || from - start > 40 || end - to > 40) {
      anchored(() => { draw(list, from, to); measure(); });
    }
    if (start === 0 && scroller.scrollTop < scroller.clientHeight && chat()?.more) store.pageChat(view.session);
  }

  function render() {
    const session = store.state.sessions.get(view.session);
    placeStack(session);
    const held = chat();
    const pinned = jump || atEnd();
    const following = store.can('chat.page');
    const loaded = !!held?.loaded;
    skeleton.hidden = loaded || !following;
    later.hidden = following;
    const list = items();
    empty.hidden = !following || !loaded || list.length > 0 || !!stack;
    if (loaded && marking) noteLooked(list);
    if (loaded) {
      if (structural) {
        // At the end, `toEnd` below draws the last rows.
        if (!pinned) {
          // Rows came or went off screen: the drawn range follows its items, the view keeps its place.
          const first = rowsEl.firstElementChild && [...rows.entries()].find(([, row]) => row.el === rowsEl.firstElementChild)?.[0];
          const at = first ? list.findIndex((item) => keyOf(item) === first) : -1;
          const from = at >= 0 ? at : Math.min(start, list.length);
          anchored(() => { draw(list, from, Math.min(list.length, from + Math.max(end - start, 1))); measure(); });
        }
      } else {
        // Only text grew: the rows it grew in are drawn again, nothing else is touched.
        anchored(() => {
          for (let i = start; i < end; i++) {
            const item = list[i];
            if (touched.has(item.id)) rows.get(keyOf(item))?.update(item);
          }
          measure();
        });
      }
    }
    touched.clear();
    structural = false;
    const fresh = stack ? stack.update() : 0;
    renderLive(session);
    renderComposer(session);
    if (loaded && pinned) {
      toEnd(false);
      noteLooked(list);
    }
    else if (unseen > 0 || fresh > shownQuestions) {
      latest.hidden = false;
      setText(latestCount, unseen > 0 ? String(unseen) : '');
    }
    shownQuestions = fresh;
    if (loaded) jump = false;
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

  // On the node's page the box leaves a draft (`session.draft`): `vibeswitcher send` in a terminal types it. Only a
  // feed that may send (`send` in what it may send, and no drafts) types at once.
  const drafting = () => store.can('session.draft');
  function renderComposer(session) {
    const typed = drivable(session) && (drafting() || store.can('send'));
    form.hidden = !typed;
    hint.hidden = typed;
    asking.update(session);
    drafted.update(session);
    if (!typed) {
      setText(hint, !session ? '' : session.ended ? 'This session has ended.'
        : !session.hosted ? 'Runs in another terminal. It can be read here, not typed into.'
        : 'This page follows the node; to type into a session, use its terminal.');
      return;
    }
    const agent = AGENTS[session.agent] || AGENTS.claude;
    const working = stateOf(session) === 'working';
    if (drafting()) {
      input.placeholder = `Message ${agent}… (↩ leaves a draft)`;
      sendButton.title = 'Leave as a draft (↩)';
      sendButton.setAttribute('aria-label', 'Leave as a draft');
    } else {
      input.placeholder = working ? `Steer ${agent} while it works — ↩ sends it to its next step` : `Message ${agent}…`;
    }
  }

  const schedule = framed(render);
  const scrolled = framed(() => {
    if (atEnd()) {
      unseen = 0;
      latest.hidden = true;
      if (chat()?.loaded) noteLooked(items());
    }
    follow();
  });

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
      if (change.type === 'text') touched.add(change.id);
      else structural = true;
      if (change.type === 'reset' && change.first) jump = true;
      if (change.fresh && !atEnd()) unseen += 1;
      // What you sent yourself always brings the view to it.
      if (change.pending) jump = true;
      if (change.type === 'page') {
        // Older items came in above: the drawn range moves with its items, and the view doesn't move.
        start += change.count;
        end += change.count;
      }
    }
    schedule();
  }

  scroller.addEventListener('scroll', scrolled, { passive: true });

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
    if (drafting()) store.sessionDraft(view.session, text); else store.send(view.session, text);
  });

  for (const topic of ['sessions', 'cards', 'leads', 'connection']) store.subscribe(topic, () => { if (view.session && el.isConnected) schedule(); });

  let unsubscribe = null;
  return {
    el,
    // Shows `id`'s chat: at once from what's held, or a skeleton until its items arrive.
    show(id) {
      if (view.session === id) return;
      unsubscribe?.();
      if (view.session) store.closeChat(view.session);
      view.session = id;
      view.open = new Set();
      rows.clear();
      heights.clear();
      rowsEl.replaceChildren();
      start = 0;
      end = 0;
      unseen = 0;
      latest.hidden = true;
      structural = true;
      jump = true;
      shownQuestions = 0;
      markKey = null;
      marking = true;
      mark.remove();
      stack = null;
      stackProject = null;
      // The last session's questions leave with it (placeStack only draws when the project changes).
      stackSlot.replaceChildren();
      placeStack(store.state.sessions.get(id));
      unsubscribe = store.subscribe('chat:' + id, onChat);
      store.openChat(id);
      render();
    },
    // Shown again after another pane had its place: back at the end.
    reveal() { jump = true; structural = true; render(); },
    // Runs `work`, which changes the chat's width (its lines wrap again): at the end before, at the end after.
    hold(work) {
      const pinned = atEnd();
      work();
      heights.clear();
      if (pinned) toEnd(false);
      else anchored(() => measure());
    },
    // The message box, for the keys that go to it.
    focus() { input.focus(); },
  };
}
