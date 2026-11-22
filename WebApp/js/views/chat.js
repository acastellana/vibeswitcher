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
// - It opens where you were reading it in this page, else with "New since you looked" at the top, else at its end (the
//   Mac's `ChatView.initialScroll`): coming back to a busy chat you start at what you haven't read.
// - Its images drawn (images.js: their bytes asked of the node, `chat.image`), a picture that opens wide when tapped.
// - A prompt's Copy, Edit in Composer and Send Again (a draft, as every message this page leaves), a reply's Copy as
//   Markdown; the whole chat copied as Markdown or exported as a .md file (the Mac's Export Chat); and find in the
//   chat (⌘F / Ctrl+F while it shows): the rows aren't all in the page, so the browser's own find can't see them all.
// - "New since you looked" (the Mac's marker): a line before the first item that came after the last one you saw at the
//   chat's end, with what came since; worked out when the chat opens, kept until another opens. What you saw is this
//   browser's (`SEEN`), by session.

import { h, keyed, setText, setClass, framed } from '../dom.js';
import { agentMark, statusMark, setMark, icon } from '../marks.js';
import { since, short, clock, plural, tilde, stateOf, AGENTS, STATES, KEY } from '../words.js';
import { markdown, diffView, codeBlock } from '../text.js';
import { runnable } from '../runnable.js';
import { summaryOf, newSince, sinceSummary, chatMarkdown, exportName, findIn, fold, openingPlace } from '../chatops.js';
import { imageLoader } from '../images.js';
import { questionStack, askCard } from './cards.js';
import { draftBox, promptCard, queuedStrip, drivable } from './drive.js';
import { copyLine } from './cards.js';
import { imageSendLine } from '../actions.js';
import { tokenAt, accept, IMAGE_TYPES, MAX_IMAGE } from '../composing.js';
import { allDoneView } from './alldone.js';
import { talkButton } from '../dictate.js';
import { shellCardsOf } from '../shellcard.js';
import { shellCard } from './cards.js';

// How close to the end counts as being at the end.
const NEAR = 48;
// How far beyond what you see rows are drawn, in viewports, above and below.
const OVERSCAN = 1.5;
// Rows drawn at least, from the end, when the chat opens.
const FIRST_ROWS = 30;
// A row's height until it is measured, by type.
const ESTIMATE = { prompt: 62, reply: 96, tools: 30, team: 70, ask: 160, allDone: 140 };

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

// An image the agent saw, in words: its type and size.
function imageWords(image) {
  const type = (image.mediaType || 'image').replace(/^image\//, '').toUpperCase();
  const size = image.bytes >= 1048576 ? `${(image.bytes / 1048576).toFixed(1)} MB` : `${Math.max(1, Math.round(image.bytes / 1024))} KB`;
  return `Image · ${type} · ${size}`;
}

// An image the agent saw: its picture, where the node serves its bytes (`chat.image`), else its line of words. The
// words stand in while the bytes come, and stay when they can't be had.
function imageView(view, image) {
  const words = imageWords(image);
  const note = h('span', { class: 'image-note' }, icon('file', 12), words);
  if (!view.images) return note;
  const holder = h('span', { class: 'image-holder' }, note);
  const show = (url) => {
    if (!url) return;
    const picture = h('img', { class: 'chat-image', src: url, alt: words, decoding: 'async' });
    const button = h('button', { class: 'chat-image-button', type: 'button', title: `${words} · tap to see it wide`, 'aria-expanded': 'false',
      onclick: () => {
        const wide = !button.classList.contains('wide');
        button.classList.toggle('wide', wide);
        button.setAttribute('aria-expanded', String(wide));
        view.redraw();
      } }, picture);
    picture.addEventListener('load', () => view.redraw(), { once: true });
    holder.replaceChildren(button);
  };
  const known = view.images.known(view.session, image);
  if (known) show(known);
  else view.images.url(view.session, image).then((url) => { if (holder.isConnected || !holder.parentNode) show(url); });
  return holder;
}

// A row's own actions (the Mac's row menu): small buttons over its corner, shown on hover and on focus.
function rowActions(...buttons) {
  return h('div', { class: 'row-actions' }, buttons);
}
function rowButton(label, glyph, onclick) {
  return h('button', { class: 'icon-button row-action', type: 'button', title: label, 'aria-label': label, onclick }, icon(glyph, 12));
}

// A shell code block's Run (the app's `RunButton`): the command as the message that runs it in the agent's shell
// (`! command`, js/runnable.js), left as the session's draft over the box, where `vibeswitcher send SESSION` in a
// terminal shows it whole and asks for the code. Nothing runs from the page. None for a block that isn't plainly one
// command line, or where the page can't draft.
function runButton(view, code, language) {
  const run = runnable(code, language);
  if (!run || !view.canRun()) return null;
  return h('button', { class: 'code-run', type: 'button', title: `Leaves “${run.prompt}” as a draft for this session: vibeswitcher send runs it after you type its code`,
    onclick: () => view.runCode(run.prompt) }, icon('terminal', 11), 'Run');
}

function toolView(tool, home, view) {
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
  for (const image of tool.result?.images || []) body.push(imageView(view, image));
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
    let row = first;
    const again = rowButton('Send Again (leaves it as a draft)', 'send', () => view.again(row.text || ''));
    const edit = rowButton('Edit in Composer', 'pencil', () => view.edit(row.text || ''));
    const copy = rowButton('Copy Message', 'copy', (event) => view.copy(row.text || '', event.currentTarget));
    const actions = rowActions(copy, edit, again);
    const el = h('div', { class: 'chat-row prompt' }, actions, text, images, note);
    // What it may do is asked as you reach it: the session's state moves without its row being drawn again.
    const look = () => {
      edit.hidden = !view.canEdit();
      again.hidden = !view.canDraft();
    };
    el.addEventListener('pointerenter', look);
    el.addEventListener('focusin', look);
    let drawnImages = '';
    return {
      el,
      update(item) {
        row = item;
        setText(text, item.text);
        text.hidden = !item.text;
        actions.hidden = !item.text || !!item.pending;
        look();
        const ids = (item.images || []).map((image) => image.id).join(' ');
        if (ids !== drawnImages) {
          drawnImages = ids;
          images.replaceChildren(...(item.images || []).map((image) => imageView(view, image)));
        }
        images.hidden = !(item.images || []).length;
        setClass(el, 'pending', !!item.pending);
        setClass(el, 'steered', !!item.steered);
        setText(note, item.pending ? 'sending…' : [item.steered ? (item.fromLead ? 'From the lead, while it worked' : 'Sent while it worked') : '', clock(item.at)].filter(Boolean).join(' · '));
      },
    };
  }
  if (first.type === 'reply') {
    const body = h('div', { class: 'prose' });
    let shown = null;
    const actions = rowActions(rowButton('Copy as Markdown', 'copy', (event) => view.copy(shown || '', event.currentTarget)));
    const el = h('div', { class: 'chat-row reply' }, actions, agentMark(view.agent(), 18), body);
    return {
      el,
      update(item) {
        setClass(el, 'streaming', !!item.streaming);
        if (item.text === shown) return;
        const grew = shown !== null && item.text.startsWith(shown);
        shown = item.text;
        const next = h('div', null, markdown(item.text, { codeAction: (code, language) => runButton(view, code, language) }));
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
      body.replaceChildren(...row.tools.map((tool) => toolView(tool, view.home(), view)));
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
    // A long message's TL;DR, once the node wrote one (its AI summaries).
    const gist = h('div', { class: 'note-gist', hidden: true });
    const time = h('time', { class: 'note-time' });
    const el = h('div', { class: 'chat-row team' }, icon('note', 14), h('div', { class: 'note-body' }, title, gist, text), time);
    return {
      el,
      update(item) {
        setText(title, item.title || 'VibeSwitcher');
        setText(gist, item.summary ? `TL;DR: ${item.summary}` : '');
        gist.hidden = !item.summary;
        setText(text, item.text);
        setText(time, clock(item.at));
      },
    };
  }
  // Where the lead's board cleared (the node places it in the lead's chat by its time).
  if (first.type === 'allDone') {
    const el = h('div', { class: 'chat-row all-done-row' });
    let drawn = '';
    return {
      el,
      update(item) {
        const now = JSON.stringify(item);
        if (now === drawn) return;
        drawn = now;
        el.replaceChildren(allDoneView(item, { className: 'all-done' }));
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
  // This session's shell requests (js/shellcard.js).
  const shellSlot = h('div', { class: 'stack-cards shell-cards' });
  let shellDrawn = '';
  // The question open on the session's own screen, under its conversation, where the Mac's answer card sits.
  const asking = promptCard(app);
  const column = h('div', { class: 'chat-column' }, earlier, skeleton, empty, later, above, rowsEl, below, live, stackSlot, shellSlot, asking.el);
  const scroller = h('div', { class: 'chat-scroll' }, column);
  // The "New since you looked" line, placed before its row while that row is drawn.
  const markSummary = h('span', { class: 'new-mark-summary' });
  const mark = h('div', { class: 'new-mark', role: 'separator' }, h('span', { class: 'new-mark-text' }, h('span', null, 'New since you looked'), markSummary));
  const latestCount = h('span', { class: 'latest-count' });
  const latest = h('button', { class: 'latest', type: 'button', hidden: true, onclick: () => toEnd(true) }, icon('down', 12), 'Latest', latestCount);

  const input = h('textarea', { class: 'composer-input', rows: 1, 'aria-label': 'Message' });
  const sendButton = h('button', { class: 'send', type: 'submit', title: 'Send (↩)', 'aria-label': 'Send', disabled: true }, icon('send', 15));
  // Images into the message: one from this device (as a paste, `session.attach`), or one that is a file on the node,
  // which the page can't read: for that, the line that sends the message with it (`send … --image PATH`).
  const pick = h('input', { type: 'file', accept: 'image/*', multiple: true, hidden: true, 'aria-hidden': 'true' });
  const attachButton = h('button', { class: 'icon-button composer-attach', type: 'button', title: 'Add an image', 'aria-label': 'Add an image',
    'aria-expanded': 'false', 'aria-controls': 'attach-menu' }, icon('plus', 15));
  const fromDevice = h('button', { class: 'attach-choice', type: 'button' }, 'An image from this device…');
  const fromNode = h('button', { class: 'attach-choice', type: 'button' }, 'An image on the node, by its path…');
  const attachMenu = h('div', { class: 'attach-menu', id: 'attach-menu', role: 'group', 'aria-label': 'Add an image', hidden: true }, fromDevice, fromNode);
  const nodePath = h('input', { class: 'find-input node-image-path', type: 'text', placeholder: '/path/on/the/node/screenshot.png', 'aria-label': 'Image path on the node',
    autocomplete: 'off', spellcheck: 'false' });
  const nodeLine = h('div', { class: 'node-image-line' });
  const nodeImage = h('div', { class: 'node-image', hidden: true },
    h('div', { class: 'node-image-head' }, nodePath,
      h('button', { class: 'icon-button', type: 'button', title: 'Close', 'aria-label': 'Close', onclick: () => { nodeImage.hidden = true; input.focus(); } }, icon('close', 12))),
    nodeLine,
    h('p', { class: 'confirm-note' }, 'Run it in a terminal on the node: it shows the message with the image and asks for a code. The page can’t read a file on the node itself.'));
  // Push-to-talk dictation into the box (js/dictate.js): only where the browser recognises speech and you turned it on.
  const talk = talkButton(input);
  const form = h('form', { class: 'composer' }, attachButton, input, talk, sendButton, pick);
  const hint = h('p', { class: 'composer-hint', hidden: true });
  // The message this page left for the session, over the box, with the line that sends it; Edit puts it and its images
  // back in the box.
  const drafted = draftBox(app, { edit: (text, images = []) => {
    input.value = text;
    attached = images.map((path) => ({ key: path, name: path.split('/').pop(), path, failed: null, thumb: null }));
    drawAttached();
    grow();
    input.focus();
  } });
  // What `vibeswitcher send` sent while a question was open: the node types it in once that closes.
  const queuedMessages = queuedStrip();
  // What `/` and `@` complete to (`session.complete`), over the box.
  const suggestions = h('ul', { class: 'suggestions', role: 'listbox', 'aria-label': 'Completions', hidden: true });
  // The images pasted or dropped into the box (`session.attach`), as small pictures over it.
  const attachedEl = h('div', { class: 'attached', hidden: true });
  const notice = h('p', { class: 'composer-notice', role: 'status', hidden: true });
  // Find in the chat: over it, opened by ⌘F / Ctrl+F (or the palette's Find in Chat) while the chat shows.
  const findInput = h('input', { class: 'find-input', type: 'search', placeholder: 'Find in chat', 'aria-label': 'Find in chat',
    autocomplete: 'off', spellcheck: 'false' });
  const findCount = h('span', { class: 'find-count', role: 'status' });
  const findBar = h('div', { class: 'chat-find', role: 'search', hidden: true }, icon('search', 13), findInput, findCount,
    h('button', { class: 'icon-button', type: 'button', title: 'Previous (⇧↩)', 'aria-label': 'Previous match', onclick: () => step(-1) }, icon('send', 12)),
    h('button', { class: 'icon-button', type: 'button', title: 'Next (↩)', 'aria-label': 'Next match', onclick: () => step(1) }, icon('down', 12)),
    h('button', { class: 'icon-button', type: 'button', title: 'Close (Esc)', 'aria-label': 'Close find', onclick: () => closeFind() }, icon('close', 12)));
  const el = h('div', { class: 'chat' }, findBar, scroller, latest, queuedMessages.el, drafted.el, suggestions, attachedEl, notice, attachMenu, nodeImage, form, hint);

  const loader = imageLoader((kind, args) => store.read(kind, args));
  const view = {
    app,
    session: null,
    open: new Set(),          // the tool folds opened, by item id
    asked: new Map(),         // answers to an agent's prompt, not confirmed yet
    agent: () => store.state.sessions.get(view.session)?.agent || 'claude',
    home: () => store.state.node?.home,
    composer: input,
    // Its pictures' bytes, asked of the node where it serves them (`chat.image`).
    get images() { return store.can('chat.image') ? loader : null; },
    redraw: () => { structural = true; schedule(); },
    // A row's Copy: the text to the clipboard, and the button says so for a moment.
    copy: (text, button) => copyText(text, button),
    // Edit in Composer (the box holds the text, nothing is sent) and Send Again (a draft, as every message here).
    canEdit: () => !form.hidden,
    canDraft: () => !form.hidden && drafting(),
    edit: (text) => {
      if (form.hidden) return;
      input.value = text;
      grow();
      input.focus();
      input.setSelectionRange(text.length, text.length);
    },
    again: (text) => {
      if (form.hidden || !drafting() || !text) return;
      store.sessionDraft(view.session, text, [], false);
      say('Left as a draft, over the box.');
    },
    // A code block's Run: only in an agent's session the page drafts for (a shell takes no `send`).
    canRun: () => view.canDraft() && ['claude', 'codex'].includes(store.state.sessions.get(view.session)?.agent),
    runCode: (prompt) => {
      if (!view.canRun()) return;
      store.sessionDraft(view.session, prompt, [], false);
      say('Left as a draft, over the box: `vibeswitcher send` runs it in the agent’s shell after you type its code.');
    },
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
  // Where each chat was left, by session: its top row's key and how far it was above the view's top (this page only).
  const readAt = new Map();
  // This chat's first view placed yet (where it opens: `openingPlace`).
  let opened = false;
  // A chat just shown, this turn: the session view's `reveal` after it leaves where it opens alone.
  let shownJustNow = false;
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
    drawShells();
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
    if (loaded && !opened && jump) {
      // Its first view: where it was left, else at what's new, else at the end.
      opened = true;
      const placed = placeOpening(list);
      if (!placed) toEnd(false);
      else {
        latest.hidden = false;
        setText(latestCount, '');
      }
      noteLooked(list);
    } else if (loaded && pinned) {
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

  // The chat's first view at a row: the one it was left at (its offset kept), or the marker's (the marker at the top).
  // False when it opens at the end.
  function placeOpening(list) {
    const place = openingPlace({ saved: readAt.get(view.session), markKey, keys: list.map(keyOf) });
    if (place.kind === 'end') return false;
    draw(list, Math.max(0, place.index - 8), Math.min(list.length, place.index + Math.max(FIRST_ROWS, 12)));
    measure();
    const row = rows.get(keyOf(list[place.index]));
    if (!row) return false;
    const top = place.kind === 'marker' && mark.parentNode === rowsEl ? mark.offsetTop : row.el.offsetTop;
    // A marker a little below the top, so it reads as a line across; a row left at exactly where it was.
    scroller.scrollTop = Math.max(0, top + place.offset - (place.kind === 'marker' ? 8 : 0));
    // At the end anyway (a short chat): nothing to point at below.
    if (atEnd()) return false;
    follow();
    return true;
  }

  // The row at the view's top, and how far above it is, for where the chat opens next time in this page.
  function leftAt() {
    const top = scroller.scrollTop;
    for (const [key, row] of rows) {
      if (row.el.hidden || row.el.parentNode !== rowsEl) continue;
      if (row.el.offsetTop + row.el.offsetHeight > top) return { key, offset: Math.max(0, top - row.el.offsetTop) };
    }
    return null;
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
    if (!typed) { closeAttach(); nodeImage.hidden = true; }
    hint.hidden = typed;
    asking.update(session);
    drafted.update(session);
    queuedMessages.update(session);
    attachedEl.hidden = !typed || !attached.length;
    if (!typed) {
      closeSuggestions();
      setText(hint, !session ? '' : session.ended ? 'This session has ended.'
        : !session.hosted ? 'Runs in another terminal. It can be read here, not typed into.'
        : 'This page follows the node; to type into a session, use its terminal.');
      return;
    }
    const agent = AGENTS[session.agent] || AGENTS.claude;
    const working = stateOf(session) === 'working';
    if (drafting()) {
      // While it works, as the app's ↩ steers and ⌥↩ queues: ↩ leaves a draft that steers it now, ⌥↩ one for after.
      const steers = working && session.agent === 'claude';
      // On a phone the words that fit one line; the keys are a keyboard's (the send button's title says what it does).
      input.placeholder = narrow() ? (steers ? `Steer ${agent}…` : `Message ${agent}…`)
        : steers ? `Steer ${agent} while it works… (↩ leaves a send-now draft, ⌥↩ one for after its turn)`
          : `Message ${agent}… (↩ leaves a draft)`;
      sendButton.title = steers ? 'Leave as a send-now draft: it steers the agent at its next step (↩)' : 'Leave as a draft (↩)';
      sendButton.setAttribute('aria-label', steers ? 'Leave as a send-now draft' : 'Leave as a draft');
    } else {
      input.placeholder = working ? (narrow() ? `Steer ${agent}…` : `Steer ${agent} while it works — ↩ sends it to its next step`) : `Message ${agent}…`;
    }
  }
  // A phone's width (style.css's own breakpoint): the composer's words kept to one line. Drawn again as it changes.
  const narrowQuery = globalThis.matchMedia?.('(max-width: 760px)');
  const narrow = () => !!narrowQuery?.matches;
  narrowQuery?.addEventListener?.('change', () => { if (view.session) schedule(); });

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
  function drawShells() {
    const open = shellCardsOf(store.state.cards.values(), view.session);
    const key = JSON.stringify(open.map((card) => [card.id, card.shell?.state, card.notice]));
    if (key === shellDrawn) return;
    shellDrawn = key;
    shellSlot.replaceChildren(...open.map(shellCard));
  }

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
    sendButton.disabled = uploading() || (!input.value.trim() && !attached.some((item) => item.path));
  }
  input.addEventListener('input', () => { grow(); lookToken(); });
  input.addEventListener('keyup', (event) => { if (['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) lookToken(); });
  input.addEventListener('click', lookToken);
  input.addEventListener('blur', () => setTimeout(closeSuggestions, 120));
  // ⌥↩: the next submit is for after the turn.
  let queueNext = false;
  input.addEventListener('keydown', (event) => {
    if (completion && !event.isComposing) {
      if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
        event.preventDefault();
        completion.index = (completion.index + (event.key === 'ArrowDown' ? 1 : -1) + completion.items.length) % completion.items.length;
        drawSuggestions();
        return;
      }
      if ((event.key === 'Enter' && !event.shiftKey) || event.key === 'Tab') {
        event.preventDefault();
        take(completion.index);
        return;
      }
      if (event.key === 'Escape') {
        event.preventDefault();
        closeSuggestions();
        return;
      }
    }
    if (event.key === 'Enter' && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      queueNext = event.altKey;
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
    const images = attached.filter((item) => item.path).map((item) => item.path);
    if (uploading() || (!text && !images.length)) return;
    input.value = '';
    attached = [];
    drawAttached();
    closeSuggestions();
    grow();
    // A draft left while a Claude agent works steers it (`now`), unless ⌥↩ asked for after its turn.
    const session = store.state.sessions.get(view.session);
    const now = !queueNext && stateOf(session) === 'working' && session?.agent === 'claude';
    queueNext = false;
    if (drafting()) store.sessionDraft(view.session, text, images, now); else store.send(view.session, text);
  });

  // ---- `/` and `@`: what the app's composer completes, asked of the node as you type ----

  let completion = null;     // { token, items, index } while the list shows
  let completing = 0;        // the newest ask: an older answer is dropped
  let completeTimer = null;
  function lookToken() {
    const session = store.state.sessions.get(view.session);
    const caret = input.selectionStart;
    const token = drivable(session) && store.can('session.complete') && caret === input.selectionEnd ? tokenAt(input.value, caret) : null;
    if (!token) return closeSuggestions();
    const ask = ++completing;
    const id = view.session;
    clearTimeout(completeTimer);
    completeTimer = setTimeout(() => {
      store.read('session.complete', { session: id, kind: token.kind, query: token.query }).then((reply) => {
        if (ask !== completing || id !== view.session) return;
        const items = reply?.ok ? reply.result.items : [];
        if (!items.length) return closeSuggestions();
        completion = { token, items, index: 0 };
        drawSuggestions();
      });
    }, 80);
  }
  function drawSuggestions() {
    suggestions.hidden = !completion;
    if (!completion) return suggestions.replaceChildren();
    suggestions.replaceChildren(...completion.items.map((item, index) => h('li', {
      class: 'suggestion' + (index === completion.index ? ' chosen' : ''), role: 'option', 'aria-selected': String(index === completion.index),
      onmousedown: (event) => { event.preventDefault(); take(index); },
    }, h('span', { class: 'suggestion-title' }, item.title), h('span', { class: 'suggestion-note' }, item.subtitle))));
    suggestions.querySelector('.chosen')?.scrollIntoView({ block: 'nearest' });
  }
  function take(index) {
    const item = completion?.items[index];
    if (!item) return;
    const done = accept(input.value, completion.token, item.insert);
    input.value = done.text;
    input.setSelectionRange(done.caret, done.caret);
    closeSuggestions();
    grow();
    input.focus();
  }
  function closeSuggestions() {
    completing += 1;
    clearTimeout(completeTimer);
    if (!completion && suggestions.hidden) return;
    completion = null;
    drawSuggestions();
  }

  // ---- Images pasted or dropped into the box: sent to the node in parts, named by the draft ----

  let attached = [];         // { key, name, path, failed, thumb }
  const uploading = () => attached.some((item) => !item.path && !item.failed);
  const canAttach = () => drafting() && store.can('session.attach') && drivable(store.state.sessions.get(view.session));
  function say(text) {
    notice.hidden = !text;
    setText(notice, text || '');
  }
  function drawAttached() {
    attachedEl.hidden = !attached.length;
    attachedEl.replaceChildren(...attached.map((item) => h('div', {
      class: 'attached-item' + (item.path ? '' : item.failed ? ' failed' : ' sending'), title: item.failed || item.name,
    }, item.thumb || h('span', { class: 'attached-name' }, item.name),
    h('button', { class: 'attached-remove', type: 'button', 'aria-label': `Remove ${item.name}`, title: 'Remove this image',
      onclick: () => { attached = attached.filter((one) => one !== item); drawAttached(); grow(); } }, icon('close', 10)))));
    const failed = attached.find((item) => item.failed);
    say(failed ? `${failed.name}: ${failed.failed}` : '');
  }
  // A small picture of `file`, drawn on a canvas (the page's policy loads no image but its own files).
  async function thumbnail(file) {
    const bitmap = await createImageBitmap(file);
    const canvas = h('canvas', { class: 'attached-thumb', width: 112, height: 112, 'aria-hidden': 'true' });
    const side = Math.min(bitmap.width, bitmap.height);
    canvas.getContext('2d').drawImage(bitmap, (bitmap.width - side) / 2, (bitmap.height - side) / 2, side, side, 0, 0, 112, 112);
    bitmap.close?.();
    return canvas;
  }
  // The bytes the node is sent: the file as it is when the node takes its type and size, else drawn again (at most
  // 2048 pixels a side) as a PNG, or a JPEG when that is still too large.
  async function prepared(file) {
    if (IMAGE_TYPES.includes(file.type) && file.size <= MAX_IMAGE) return { bytes: new Uint8Array(await file.arrayBuffer()), type: file.type };
    const bitmap = await createImageBitmap(file);
    const scale = Math.min(1, 2048 / Math.max(bitmap.width, bitmap.height));
    const canvas = h('canvas', { width: Math.round(bitmap.width * scale), height: Math.round(bitmap.height * scale) });
    canvas.getContext('2d').drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    const encode = (type, quality) => new Promise((resolve) => canvas.toBlob(resolve, type, quality));
    let blob = await encode('image/png');
    if (!blob || blob.size > MAX_IMAGE) blob = await encode('image/jpeg', 0.85);
    if (!blob || blob.size > MAX_IMAGE) throw new Error('too large');
    return { bytes: new Uint8Array(await blob.arrayBuffer()), type: blob.type };
  }
  async function addImage(file) {
    const item = { key: crypto.randomUUID(), name: file.name || 'pasted image', path: null, failed: null, thumb: null };
    attached.push(item);
    drawAttached();
    grow();
    const session = view.session;
    try {
      item.thumb = await thumbnail(file);
      drawAttached();
      const { bytes, type } = await prepared(file);
      const reply = await store.attach(session, bytes, type);
      if (reply.ok && reply.result?.path) item.path = reply.result.path;
      else item.failed = reply.error?.message || 'The node didn’t keep it.';
    } catch {
      item.failed = 'It couldn’t be read as an image, or it is too large.';
    }
    if (view.session !== session) return;
    drawAttached();
    grow();
  }
  function images(list) { return [...(list || [])].filter((file) => file && file.type.startsWith('image/')); }
  input.addEventListener('paste', (event) => {
    const files = images([...(event.clipboardData?.items || [])].filter((entry) => entry.kind === 'file').map((entry) => entry.getAsFile()));
    if (!files.length) return;
    event.preventDefault();
    if (!canAttach()) return say('This page can’t attach images to this session.');
    files.forEach(addImage);
  });
  form.addEventListener('dragover', (event) => {
    if ([...(event.dataTransfer?.types || [])].includes('Files')) event.preventDefault();
  });
  form.addEventListener('drop', (event) => {
    const dropped = [...(event.dataTransfer?.files || [])];
    if (!dropped.length) return;
    event.preventDefault();
    const files = images(dropped);
    if (!canAttach()) return say('This page can’t attach images to this session.');
    if (files.length < dropped.length) say('Only images go in from here: a file on this computer isn’t on the node.');
    files.forEach(addImage);
  });

  for (const topic of ['sessions', 'cards', 'leads', 'connection']) store.subscribe(topic, () => { if (view.session && el.isConnected) schedule(); });

  // ---- Images from the + button: this device's (as a paste), the node's (the line that sends them) ----

  function closeAttach() {
    attachMenu.hidden = true;
    attachButton.setAttribute('aria-expanded', 'false');
  }
  attachButton.addEventListener('click', () => {
    const opening = attachMenu.hidden;
    attachMenu.hidden = !opening;
    attachButton.setAttribute('aria-expanded', String(opening));
    fromDevice.disabled = !canAttach();
    fromDevice.title = canAttach() ? '' : 'This page can’t attach images to this session.';
    if (opening) (canAttach() ? fromDevice : fromNode).focus();
  });
  attachMenu.addEventListener('keydown', (event) => { if (event.key === 'Escape') { closeAttach(); attachButton.focus(); } });
  fromDevice.addEventListener('click', () => { closeAttach(); pick.click(); });
  pick.addEventListener('change', () => {
    const files = images(pick.files);
    pick.value = '';
    if (!canAttach()) return say('This page can’t attach images to this session.');
    files.forEach(addImage);
  });
  fromNode.addEventListener('click', () => {
    closeAttach();
    nodeImage.hidden = false;
    drawNodeLine();
    nodePath.focus();
  });
  // The line for the path typed, with what the box holds as its text (several paths: separated by commas).
  function drawNodeLine() {
    if (nodeImage.hidden) return;
    const session = store.state.sessions.get(view.session);
    const paths = nodePath.value.split(',').map((path) => path.trim()).filter(Boolean);
    const now = stateOf(session) === 'working' && session?.agent === 'claude';
    const line = session ? imageSendLine(session, input.value, paths, now) : null;
    nodeLine.replaceChildren(line ? copyLine(line, 'the command that sends the message with the image') : h('p', { class: 'confirm-note' }, 'Type the image’s path on the node.'));
  }
  nodePath.addEventListener('input', drawNodeLine);
  input.addEventListener('input', drawNodeLine);

  // ---- Copy, export, find ----

  async function copyText(text, button) {
    let done = false;
    try {
      await navigator.clipboard.writeText(text);
      done = true;
    } catch { /* no clipboard here (an insecure origin, a refusal) */ }
    if (button) {
      button.classList.toggle('copied', done);
      button.title = done ? 'Copied' : 'This browser didn’t let the page copy';
      setTimeout(() => { button.classList.remove('copied'); button.title = button.getAttribute('aria-label'); }, 1500);
    } else {
      say(done ? 'Copied.' : 'This browser didn’t let the page copy.');
    }
    return done;
  }

  // The whole chat as the Mac's Export Chat writes it, of what this page holds (older items it hasn't paged in aren't).
  function markdownNow() {
    const session = store.state.sessions.get(view.session);
    return chatMarkdown(items(), AGENTS[session?.agent] || 'Agent');
  }
  function exportChat() {
    if (!items().length) return say('Nothing in this chat to export yet.');
    const session = store.state.sessions.get(view.session);
    const url = URL.createObjectURL(new Blob([markdownNow()], { type: 'text/markdown' }));
    const link = h('a', { href: url, download: exportName(session?.title || (session && session.project)) , hidden: true });
    document.body.append(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 10_000);
    if (chat()?.more) say('Exported what this page holds: scroll up for earlier messages first to take them too.');
  }

  let found = [];            // the positions of the items that match
  let foundAt = -1;          // which of them is shown
  let foundKey = null;       // its row's key
  function openFind() {
    findBar.hidden = false;
    findInput.focus();
    findInput.select();
    search();
  }
  function closeFind() {
    if (findBar.hidden) return;
    findBar.hidden = true;
    found = [];
    foundAt = -1;
    markFound(null);
    input.focus({ preventScroll: true });
  }
  function search() {
    const list = items();
    found = findIn(list, findInput.value);
    // From the newest match: what you look for is most often what just happened.
    foundAt = found.length ? found.length - 1 : -1;
    show();
  }
  function step(by) {
    if (!found.length) return;
    foundAt = (foundAt + by + found.length) % found.length;
    show();
  }
  function show() {
    const query = findInput.value.trim();
    const more = chat()?.more ? ' · earlier messages not loaded' : '';
    setText(findCount, !query ? '' : found.length ? `${foundAt + 1} of ${found.length}${more}` : `No matches${more}`);
    if (foundAt < 0) return markFound(null);
    const list = items();
    const index = found[foundAt];
    const item = list[index];
    // A run of tools opens, so what matched in it shows.
    if (item.type === 'tools') view.open.add(item.id);
    draw(list, Math.max(0, index - 8), Math.min(list.length, index + 12));
    measure();
    const row = rows.get(keyOf(item));
    row?.update(item);
    markFound(keyOf(item), query);
    row?.el.scrollIntoView({ block: 'center' });
  }
  // The found row marked, and the query in it highlighted where the browser can (CSS Custom Highlights).
  function markFound(key, query = '') {
    if (foundKey && rows.get(foundKey)) rows.get(foundKey).el.classList.remove('found');
    foundKey = key;
    const row = key ? rows.get(key) : null;
    row?.el.classList.add('found');
    if (!globalThis.CSS?.highlights || typeof Highlight === 'undefined') return;
    CSS.highlights.delete('chat-find');
    if (!row || !query) return;
    const wanted = fold(query);
    const ranges = [];
    const walker = document.createTreeWalker(row.el, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const text = fold(node.nodeValue);
      for (let at = text.indexOf(wanted); at >= 0; at = text.indexOf(wanted, at + wanted.length)) {
        const range = new Range();
        range.setStart(node, at);
        range.setEnd(node, at + wanted.length);
        ranges.push(range);
      }
    }
    if (ranges.length) CSS.highlights.set('chat-find', new Highlight(...ranges));
  }
  findInput.addEventListener('input', search);
  findInput.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') { event.preventDefault(); step(event.shiftKey ? -1 : 1); }
    else if (event.key === 'Escape') { event.preventDefault(); closeFind(); }
  });
  // ⌘F / Ctrl+F while the chat shows: this find, since the browser's sees only the rows drawn. ⌘G / Ctrl+G: the next.
  document.addEventListener('keydown', (event) => {
    if (!view.session || el.hidden || !el.isConnected || el.closest('[hidden]')) return;
    const mod = KEY.mod === '⌘' ? event.metaKey && !event.ctrlKey : event.ctrlKey && !event.metaKey;
    if (!mod || event.altKey) return;
    const key = event.key.toLowerCase();
    if (key === 'f') { event.preventDefault(); openFind(); }
    else if (key === 'g' && !findBar.hidden) { event.preventDefault(); step(event.shiftKey ? -1 : 1); }
  });

  let unsubscribe = null;
  return {
    el,
    // Shows `id`'s chat: at once from what's held, or a skeleton until its items arrive.
    show(id) {
      if (view.session === id) return;
      unsubscribe?.();
      // Where this one was left, for when it opens again; at its end, it opens at its end again.
      if (view.session && chat()?.loaded) {
        const here = atEnd() ? null : leftAt();
        if (here) readAt.set(view.session, here); else readAt.delete(view.session);
      }
      opened = false;
      shownJustNow = true;
      queueMicrotask(() => { shownJustNow = false; });
      if (view.session) store.closeChat(view.session);
      view.session = id;
      view.open = new Set();
      findBar.hidden = true;
      found = [];
      foundAt = -1;
      foundKey = null;
      // What the box held for the last session stays with it: nothing typed here goes to another.
      attached = [];
      drawAttached();
      closeSuggestions();
      closeAttach();
      nodeImage.hidden = true;
      nodePath.value = '';
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
      shellDrawn = '';
      placeStack(store.state.sessions.get(id));
      drawShells();
      unsubscribe = store.subscribe('chat:' + id, onChat);
      store.openChat(id);
      render();
    },
    // Shown again after another pane had its place: back at the end. Not as it opens (the session view reveals the
    // chat it has just shown): then it opens where `openingPlace` says.
    reveal() {
      if (shownJustNow) return;
      jump = true;
      structural = true;
      render();
    },
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
    // The chat's own commands (the palette's): find in it, copy it as Markdown, export it as a .md file.
    find: () => openFind(),
    copyMarkdown: () => (items().length ? copyText(markdownNow()) : say('Nothing in this chat to copy yet.')),
    exportChat: () => exportChat(),
  };
}
