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
// - It stays where you are: new rows keep the view at the end only if it was there, and otherwise a small t('chLatest')
//   button counts them.
// - It opens where you were reading it in this page, else with t('chNewSinceYouLooked') at the top, else at its end (the
//   Mac's `ChatView.initialScroll`): coming back to a busy chat you start at what you haven't read.
// - Its images drawn (images.js: their bytes asked of the node, `chat.image`), a picture that opens wide when tapped.
// - A prompt's Copy, Edit in Composer and Send Again (a draft, as every message this page leaves), a reply's Copy as
//   Markdown; the whole chat copied as Markdown or exported as a .md file (the Mac's Export Chat); and find in the
//   chat (⌘F / Ctrl+F while it shows): the rows aren't all in the page, so the browser's own find can't see them all.
// - t('chNewSinceYouLooked') (the Mac's marker): a line before the first item that came after the last one you saw at the
//   chat's end, with what came since; worked out when the chat opens, kept until another opens. What you saw is this
//   browser's (`SEEN`), by session.

import * as kit from '../kit.js';
import { h, keyed, setText, setClass, framed } from '../dom.js';
import { agentMark, statusMark, setMark, icon } from '../marks.js';
import { since, short, clock, plural, tilde, stateOf, AGENTS, STATES, KEY } from '../words.js';
import { markdownNodes, diffView, codeBlock } from '../text.js';
import { copyButton } from '../copying.js';
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
import { pluginCardsOf, pluginsOn } from '../plugincard.js';
import { pluginCard } from './cards.js';
import { t } from '../i18n.js';
import { actsFor, doButton, refusalWords } from '../acting.js';
import { sendArgs, sentWords, waysFor } from '../sendways.js';
import { composer, keepFor } from './composer.js';

// How long a session's question waits for the chat's rows before it shows anyway (D14: drawn under rows still coming,
// it would jump down as they arrive; a chat the node doesn't serve never comes).
const HOLD_MS = 1500;
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

// A tool's output: the first lines, and a button for the rest; Copy takes all of it, shown or not.
function outputView(output, failed, truncated) {
  const lines = output.split('\n');
  const pre = h('pre', { class: failed ? 'output failed' : 'output', tabindex: 0 }, lines.length > 14 ? lines.slice(0, 12).join('\n') : output);
  const parts = [h('div', { class: 'output-box' }, h('div', { class: 'block-actions' }, copyButton(() => output, t('txCopyOutput'))), pre)];
  if (lines.length > 14) {
    const more = kit.button('quiet', { size: 's', onclick: () => { pre.textContent = output; more.remove(); } }, t('chShowAll', { n: lines.length }));
    parts.push(more);
  }
  if (truncated) parts.push(h('div', { class: 'path' }, t('chTheOutputWasCutShort')));
  return parts;
}

// An image the agent saw, in words: its type and size.
function imageWords(image) {
  const type = (image.mediaType || 'image').replace(/^image\//, '').toUpperCase();
  const size = image.bytes >= 1048576 ? `${(image.bytes / 1048576).toFixed(1)} MB` : `${Math.max(1, Math.round(image.bytes / 1024))} KB`;
  return t('chImageWords', { type, size });
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
    const button = h('button', { class: 'chat-image-button', type: 'button', title: t('chTapWide', { words }), 'aria-expanded': 'false',
      onclick: () => {
        const wide = !button.classList.contains('wide');
        button.classList.toggle('wide', wide);
        button.setAttribute('aria-expanded', String(wide));
        view.redraw();
      } }, picture);
    // Placed only once it has loaded, and the chat drawn again in the same task: a picture laid out at its size before
    // that would move what is under it for a frame (D14). Its words stand in meanwhile, and stay if it can't be read.
    picture.addEventListener('load', () => { holder.replaceChildren(button); view.settle(); }, { once: true });
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
  return kit.iconButton({ size: 's', class: 'row-action', title: label, 'aria-label': label, onclick }, icon(glyph, 12));
}

// A shell code block's Run (the app's `RunButton`): the command as the message that runs it in the agent's shell
// (`! command`, js/runnable.js), left as the session's draft over the box, where `vibeswitcher send SESSION` in a
// terminal shows it whole and asks for the code. Nothing runs from the page. None for a block that isn't plainly one
// command line, or where the page can't draft.
function runButton(view, code, language) {
  const run = runnable(code, language);
  if (!run || !view.canRun()) return null;
  return h('button', { class: 'code-run', type: 'button', title: t('chRunTitle', { prompt: run.prompt }),
    onclick: () => view.runCode(run.prompt) }, icon('terminal', 11), t('chRun'));
}

function toolView(tool, home, view) {
  const took = seconds(tool);
  const detail = tool.detail || {};
  // A command's or a file's title is code; a thought's, a plan's or a to-do list's is words (D27).
  const words = !['command', 'edit', 'write', 'read', 'patch'].includes(detail.type);
  const head = h('div', { class: 'tool-head' }, icon(TOOL_ICON[detail.type] || 'tool', 13), h('span', { class: words ? 'tool-title words' : 'tool-title' }, tool.title),
    took >= 1 ? h('span', { class: 'tool-time' }, short(took)) : null,
    tool.result ? null : h('span', { class: 'running', role: 'status', 'aria-label': t('chRunning') }));
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
    body.push(h('div', { class: 'prose quiet' }, markdownNodes(detail.text || '', { links: true })));
  } else if (detail.type === 'todos') {
    body.push(h('ul', { class: 'todos' }, (detail.todos || []).map((todo) => h('li', { class: 'todo ' + todo.status }, todo.text))));
  } else if (detail.type === 'patch') {
    body.push(codeBlock(detail.text || ''));
  } else if (detail.type === 'agent') {
    body.push(h('div', { class: 'prose quiet' }, markdownNodes(detail.prompt || '', { links: true })));
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
    // Your words as you typed them (their lines kept), with the same marks a reply has.
    const text = h('div', { class: 'bubble prose' });
    let drawnText = null;
    const images = h('div', { class: 'row-images' });
    const note = h('div', { class: 'row-note' });
    let row = first;
    const again = rowButton(t('chSendAgainLeavesItAs'), 'send', () => view.again(row.text || ''));
    const edit = rowButton(t('chEditInComposer'), 'pencil', () => view.edit(row.text || ''));
    const copy = rowButton(t('chCopyMessage'), 'copy', (event) => view.copy(row.text || '', event.currentTarget));
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
        if (item.text !== drawnText) {
          drawnText = item.text;
          text.replaceChildren(...markdownNodes(item.text || '', { links: true, breaks: true }));
        }
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
        setText(note, item.pending ? t('chSending') : [item.steered ? (item.fromLead ? t('chFromTheLeadWhileIt') : t('chSentWhileItWorked')) : '', clock(item.at)].filter(Boolean).join(' · '));
      },
    };
  }
  if (first.type === 'reply') {
    const body = h('div', { class: 'prose' });
    // When it was said, quiet: on hover with a pointer, beside it on a touch screen; the whole date as its title (D23).
    const time = h('time', { class: 'row-note reply-time' });
    let shown = null;
    let wasStreaming = null;
    const actions = rowActions(rowButton(t('chCopyAsMarkdown'), 'copy', (event) => view.copy(shown || '', event.currentTarget)));
    const el = h('div', { class: 'chat-row reply' }, actions, agentMark(view.agent(), 18), h('div', { class: 'reply-body' }, body, time));
    return {
      el,
      update(item) {
        setClass(el, 'streaming', !!item.streaming);
        setText(time, item.streaming ? '' : clock(item.at));
        if (item.at) time.setAttribute('datetime', item.at);
        time.title = item.at && !item.streaming ? new Date(item.at).toLocaleString() : '';
        if (item.text === shown && !!item.streaming === wasStreaming) return;
        const grew = shown !== null && item.text.startsWith(shown);
        shown = item.text;
        wasStreaming = !!item.streaming;
        // Still arriving, a marker waits for its other half (text.js), so nothing flickers between typed and drawn.
        const next = h('div', null, markdownNodes(item.text, { links: true, streaming: !!item.streaming, codeAction: (code, language) => runButton(view, code, language) }));
        if (grew) patchChildren(body, next); else body.replaceChildren(...next.childNodes);
      },
    };
  }
  if (first.type === 'tools') {
    const text = h('span', { class: 'fold-text' });
    // How many failed, alone in the failure's colour: the rest of the line stays quiet (D13).
    const failedText = h('span', { class: 'fold-failed' });
    const time = h('span', { class: 'fold-time' });
    const running = h('span', { class: 'running', role: 'status', 'aria-label': t('chRunning'), hidden: true });
    const body = h('div', { class: 'fold-body', hidden: true });
    const toggle = h('button', { class: 'fold', type: 'button', 'aria-expanded': 'false' }, text, failedText, running, time, icon('chevron', 10));
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
        setText(text, row.summary || summaryOf(tools));
        setText(failedText, failed ? t('chFailed', { n: failed }) : '');
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
        setText(gist, item.summary ? t('chTldr', { x: item.summary }) : '');
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
  const rowsEl = h('div', { class: 'chat-rows', role: 'log', 'aria-label': t('chConversation') });
  const above = h('div', { class: 'chat-spacer', 'aria-hidden': 'true' });
  const below = h('div', { class: 'chat-spacer', 'aria-hidden': 'true' });
  const earlier = h('div', { class: 'earlier', hidden: true }, t('chEarlierMessages'));
  const liveMark = statusMark('working', 10);
  const liveText = h('span');
  const live = h('div', { class: 'chat-live' }, liveMark, liveText);
  const skeleton = h('div', { class: 'chat-skeleton', 'aria-hidden': 'true' },
    h('span', { class: 'bone right' }), h('span', { class: 'bone wide' }), h('span', { class: 'bone' }), h('span', { class: 'bone short' }));
  // An empty chat says what to do (the words under it only where the box is there to write in).
  const emptyWhat = h('span', { class: 'pane-empty-what' }, t('cmEmptyWhat'));
  const empty = kit.empty({ tag: 'p', size: 'page', class: 'pane-empty', hidden: true }, t('chNoConversationForThisSession'), ' ', emptyWhat);
  // A node whose page can't follow a chat (`chat.page` isn't among what this connection may send): said once, calmly,
  // in the conversation's place. A lead's questions still follow below it.
  const later = kit.empty({ tag: 'p', size: 'page', class: 'pane-empty', hidden: true }, t('chThisNodeDoesnTSend'));
  const stackSlot = h('div');
  // This session's plugin cards (js/plugincard.js): its shell requests among them.
  const pluginSlot = h('div', { class: 'stack-cards plugin-cards' });
  let pluginDrawn = '';
  // The question open on the session's own screen, under its conversation, where the Mac's answer card sits.
  const asking = promptCard(app);
  const column = h('div', { class: 'chat-column' }, earlier, skeleton, empty, later, above, rowsEl, below, live, stackSlot, pluginSlot, asking.el);
  const scroller = h('div', { class: 'chat-scroll' }, column);
  // The t('chNewSinceYouLooked') line, placed before its row while that row is drawn.
  const markSummary = h('span', { class: 'new-mark-summary' });
  const mark = h('div', { class: 'new-mark', role: 'separator' }, h('span', { class: 'new-mark-text' }, h('span', null, t('chNewSinceYouLooked')), markSummary));
  const latestCount = h('span', { class: 'latest-count' });
  const latest = h('button', { class: 'latest', type: 'button', hidden: true, onclick: () => toEnd(true) }, icon('down', 12), t('chLatest'), latestCount);

  // Images into the message: one from this device (as a paste, `session.attach`), or one that is a file on the node,
  // which the page can't read: for that, the line that sends the message with it (`send … --image PATH`).
  const pick = h('input', { class: 'file-pick', type: 'file', accept: 'image/*', multiple: true, hidden: true, 'aria-hidden': 'true' });
  const attachButton = kit.iconButton({ class: 'composer-attach', title: t('chAddAnImage'), 'aria-label': t('chAddAnImage'),
    'aria-expanded': 'false', 'aria-controls': 'attach-menu' }, icon('plus', 15));
  const fromDevice = h('button', { class: 'attach-choice', type: 'button' }, t('chAnImageFromThisDevice'));
  const fromNode = h('button', { class: 'attach-choice', type: 'button' }, t('chAnImageOnTheNode'));
  const attachMenu = h('div', { class: 'attach-menu', id: 'attach-menu', role: 'group', 'aria-label': t('chAddAnImage'), hidden: true }, fromDevice, fromNode);
  const nodePath = kit.field({ kind: 'code', class: 'node-image-path', type: 'text', placeholder: '/path/on/the/node/screenshot.png', 'aria-label': t('chImagePathOnTheNode'),
    autocomplete: 'off', spellcheck: 'false' });
  const nodeLine = h('div', { class: 'node-image-line' });
  const nodeNote = h('p', { class: 'confirm-note' }, t('chRunItInATerminal'));
  const nodeImage = h('div', { class: 'node-image', hidden: true },
    h('div', { class: 'node-image-head' }, nodePath,
      kit.iconButton({ size: 's', title: t('chClose'), 'aria-label': t('chClose'), onclick: () => { nodeImage.hidden = true; input.focus(); } }, icon('close', 12))),
    nodeLine,
    nodeNote);
  // The one message box (views/composer.js): Enter sends, steers or queues where the page acts (`send`), else leaves
  // a draft (`session.draft`); Shift+Enter a new line; what you typed kept per session.
  const box = composer({
    label: t('chMessage'), before: [attachButton],
    beforeKey: (event) => composerKeys(event),
    onInput: () => lookToken(),
    onSend: (way, text) => sendFromBox(way, text),
  });
  const input = box.input;
  const sendButton = box.button;
  // Push-to-talk dictation into the box (js/dictate.js): only where the browser recognises speech and you turned it on.
  const talk = talkButton(input);
  const form = box.el;
  if (talk) form.insertBefore(talk, sendButton);
  form.append(pick);
  const hint = h('p', { class: 'composer-hint', hidden: true });
  // The message this page left for the session, over the box, with the line that sends it; Edit puts it and its images
  // back in the box.
  const drafted = draftBox(app, { edit: (text, images = []) => {
    box.value = text;
    attached = images.map((path) => ({ key: path, name: path.split('/').pop(), path, failed: null, thumb: null }));
    drawAttached();
    grow();
    input.focus();
  } });
  // What `vibeswitcher send` sent while a question was open: the node types it in once that closes.
  const queuedMessages = queuedStrip();
  // What `/` and `@` complete to (`session.complete`), over the box.
  const suggestions = h('ul', { class: 'suggestions', role: 'listbox', 'aria-label': t('chCompletions'), hidden: true });
  // The images pasted or dropped into the box (`session.attach`), as small pictures over it.
  const attachedEl = h('div', { class: 'attached', hidden: true });
  const notice = box.notice;
  // Find in the chat: over it, opened by ⌘F / Ctrl+F (or the palette's Find in Chat) while the chat shows.
  const findInput = kit.field({ kind: 'search', class: 'find-input', type: 'search', placeholder: t('chFindInChat'), 'aria-label': t('chFindInChat'),
    autocomplete: 'off', spellcheck: 'false' });
  const findCount = h('span', { class: 'find-count', role: 'status' });
  const findBar = h('div', { class: 'chat-find', role: 'search', hidden: true }, icon('search', 13), findInput, findCount,
    kit.iconButton({ size: 's', title: t('chPrevious'), 'aria-label': t('chPreviousMatch'), onclick: () => step(-1) }, icon('send', 12)),
    kit.iconButton({ size: 's', title: t('chNext'), 'aria-label': t('chNextMatch'), onclick: () => step(1) }, icon('down', 12)),
    kit.iconButton({ size: 's', title: t('chCloseEsc'), 'aria-label': t('chCloseFind'), onclick: () => closeFind() }, icon('close', 12)));
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
    settle: () => { structural = true; if (view.session) render(); },
    // A row's Copy: the text to the clipboard, and the button says so for a moment.
    copy: (text, button) => copyText(text, button),
    // Edit in Composer (the box holds the text, nothing is sent) and Send Again (a draft, as every message here).
    canEdit: () => !form.hidden,
    canDraft: () => !form.hidden && drafting(),
    edit: (text) => {
      if (form.hidden) return;
      box.value = text;
      grow();
      input.focus();
      input.setSelectionRange(text.length, text.length);
    },
    again: (text) => {
      if (form.hidden || !drafting() || !text) return;
      store.sessionDraft(view.session, text, [], false);
      say(t('chLeftAsADraftOver'));
    },
    // A code block's Run: only in an agent's session the page drafts for (a shell takes no `send`).
    canRun: () => view.canDraft() && ['claude', 'codex'].includes(store.state.sessions.get(view.session)?.agent),
    runCode: (prompt) => {
      if (!view.canRun()) return;
      store.sessionDraft(view.session, prompt, [], false);
      say(t('chLeftAsADraftOver2'));
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
  // What follows the rows waits for them at most `HOLD_MS` (a chat the node refuses never loads): `app.later` is the
  // tests' clock.
  let heldOut = false;
  let stopHold = null;
  const afterMs = app.later || ((fn, ms) => { const timer = setTimeout(fn, ms); return () => clearTimeout(timer); });
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
    drawPluginCards();
    const held = chat();
    const pinned = jump || atEnd();
    const following = store.can('chat.page');
    const loaded = !!held?.loaded;
    skeleton.hidden = loaded || !following;
    later.hidden = following;
    const list = items();
    empty.hidden = !following || !loaded || list.length > 0 || !!stack;
    // What follows the rows (a session's question, a lead's cards, a plugin's) waits for the rows: drawn before them it
    // would jump down as they arrive (D14, 213 px measured); the skeleton holds the place meanwhile.
    // Held a moment at most: a chat the node doesn't serve never loads, and its question must still be answerable.
    const placed = loaded || !following || heldOut;
    stackSlot.hidden = !placed;
    pluginSlot.hidden = !placed;
    asking.el.classList.toggle('waiting-rows', !placed);
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
    liveText.replaceChildren(state === 'background' ? t('chTurnDone', { x: session.detail || t('chBackgroundWork') }) : `${session.detail || STATES.working.label} · `,
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
    emptyWhat.hidden = !typed;
    drafted.update(session);
    queuedMessages.update(session);
    attachedEl.hidden = !typed || !attached.length;
    if (!typed) {
      closeSuggestions();
      setText(hint, !session ? '' : session.ended ? t('chThisSessionHasEnded')
        : !session.hosted ? t('chRunsInAnotherTerminalIt')
        : t('chThisPageFollowsTheNode'));
      return;
    }
    const agent = AGENTS[session.agent] || AGENTS.claude;
    const way = primaryWay(session);
    // The button's word says what Enter does: Send, Steer (a working Claude), Queue (behind its open question), or
    // Draft where the page doesn't act; the placeholder names whom, the title the keys.
    input.placeholder = way === 'now' ? t('chSteerShort', { agent }) : t('chMessageShort', { agent });
    if (sends()) {
      box.setMode(session.prompt ? { word: t('cmQueue'), title: t('cmQueueTitle', { agent }), way }
        : way === 'now' ? { word: t('cmSteer'), title: t('cmSteerTitle', { agent }), way }
          : { word: t('swSend'), title: t('cmSendTitle', { agent }), way });
    } else {
      box.setMode({ word: t('cmDraft'), title: t('cmDraftTitle'), way });
    }
    // Where the page drafts, why, once, under the box.
    hint.hidden = sends() || !drafting();
    if (!hint.hidden) setText(hint, t('cmDraftsWhy'));
  }
  // The page sends for you (`send` where it acts): else Enter leaves a draft.
  const sends = () => actsFor(app, 'send') && drivable(store.state.sessions.get(view.session));
  // Enter's way: now for a working Claude (it steers), else at its next step.
  function primaryWay(session) {
    const ways = waysFor(session);
    return stateOf(session) === 'working' && session?.agent === 'claude' && ways.includes('now') ? 'now' : 'step';
  }
  // ⌥↩ and ⌘↩ where the agent takes them; else the next step.
  function wayFor(session, way) {
    if (way === 'step' || way === 'now' || way === 'after') return waysFor(session).includes(way) ? way : 'step';
    return primaryWay(session);
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
  function drawPluginCards() {
    // The feature plugins' cards of this session (a shell request's among them), of the plugins the node has on.
    const open = pluginCardsOf(store.state.cards.values(), view.session, pluginsOn(store.state));
    const key = JSON.stringify([open.map((card) => [card.id, card.seen, card.plugin?.state, card.notice]), store.acts()]);
    if (key === pluginDrawn) return;
    pluginDrawn = key;
    pluginSlot.replaceChildren(...open.map((one) => pluginCard(one, app)));
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
  // On a touch screen a message's actions wait for a tap on it, over its corner; a tap elsewhere puts them away (D15).
  let touchedRow = null;
  const putAway = () => { touchedRow?.classList.remove('touched'); touchedRow = null; };
  rowsEl.addEventListener('click', (event) => {
    if (!globalThis.matchMedia?.('(hover: none)')?.matches) return;
    const row = event.target?.closest?.('.chat-row.prompt, .chat-row.reply');
    if (!row || event.target.closest('a, button, pre, .table, .diff')) return;
    const again = row === touchedRow;
    putAway();
    if (!again) { touchedRow = row; row.classList.add('touched'); }
  });
  globalThis.document?.addEventListener?.('pointerdown', (event) => {
    if (touchedRow && !touchedRow.contains(event.target)) putAway();
  }, { passive: true });

  const grow = () => box.grow();
  input.addEventListener('keyup', (event) => { if (['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) lookToken(); });
  input.addEventListener('click', lookToken);
  input.addEventListener('blur', () => setTimeout(closeSuggestions, 120));
  // The box's own keys, before Enter's: `/` and `@` completion takes ↑ ↓ ↩ Tab and Esc while its list shows, and ↑ in
  // an empty box steps into what waits for an answer. True when taken.
  function composerKeys(event) {
    if (event.isComposing || event.keyCode === 229) return false;
    if (completion) {
      if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
        event.preventDefault();
        completion.index = (completion.index + (event.key === 'ArrowDown' ? 1 : -1) + completion.items.length) % completion.items.length;
        drawSuggestions();
        return true;
      }
      if ((event.key === 'Enter' && !event.shiftKey) || event.key === 'Tab') {
        event.preventDefault();
        take(completion.index);
        return true;
      }
      if (event.key === 'Escape') {
        event.preventDefault();
        closeSuggestions();
        return true;
      }
    }
    if (event.key === 'ArrowUp' && input.value === '') {
      // ↑ from an empty box steps into what's waiting for an answer (the Mac's "↑ ↓ and ↩ with the message box empty").
      const cards = el.querySelectorAll('.card:not(.closed)');
      const target = cards[cards.length - 1]?.querySelector('.option, .answer-input');
      if (target) { event.preventDefault(); target.focus(); return true; }
    }
    return false;
  }
  // Enter, or the button: where the page acts, `send` the way it says (now steers a working Claude, after for after its
  // turn), the box emptied at once and its words back with Try again if the node refuses; else a draft over the box
  // (`session.draft`, a send-now one while a Claude works), or, for a feed that types without drafts, `send` as typed.
  // Sends refused after the box moved to another session, by session: shown when it comes back.
  const refusals = new Map();
  function sendFromBox(way, typed) {
    const text = typed ?? input.value.trim();
    const images = attached.filter((item) => item.path).map((item) => item.path);
    if (uploading() || (!text && !images.length)) return null;
    const id = view.session;
    const session = store.state.sessions.get(id);
    const held = attached;
    box.clear();
    attached = [];
    drawAttached();
    closeSuggestions();
    if (sends()) {
      const chosen = wayFor(session, way);
      return store.request('send', sendArgs(session, text, chosen, images)).then((reply) => {
        if (view.session !== id) {
          // Moved to another session meanwhile: a refusal waits for this one, its words and images back in its box.
          if (!reply?.ok) {
            keepFor('session:' + id, text);
            refusals.set(id, { why: t('cmRefused', { why: refusalWords(reply?.error) }), text, held, way });
          }
          return;
        }
        if (reply?.ok) {
          // The node's own words where it says something the chat won't show (held behind a question, sent otherwise).
          const words = reply.result?.said || reply.result?.queued ? sentWords(chosen, reply.result) : '';
          say(words);
          return;
        }
        if (!attached.length) { attached = held; drawAttached(); }
        box.refused(t('cmRefused', { why: refusalWords(reply?.error) }), text, () => sendFromBox(way, input.value.trim()));
      });
    }
    const now = way === 'now' || (way !== 'after' && primaryWay(session) === 'now');
    if (drafting()) return store.sessionDraft(id, text, images, now);
    return store.send(id, text);
  }

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
  // Nothing to send: no words and no image the node holds, or an image still on its way.
  box.setEmpty(() => uploading() || (!input.value.trim() && !attached.some((item) => item.path)));
  const canAttach = () => drafting() && store.can('session.attach') && drivable(store.state.sessions.get(view.session));
  function say(text) {
    box.say(text || '');
  }
  function drawAttached() {
    attachedEl.hidden = !attached.length;
    attachedEl.replaceChildren(...attached.map((item) => h('div', {
      class: 'attached-item' + (item.path ? '' : item.failed ? ' failed' : ' sending'), title: item.failed || item.name,
    }, item.thumb || h('span', { class: 'attached-name' }, item.name),
    h('button', { class: 'attached-remove', type: 'button', 'aria-label': t('chRemoveName', { name: item.name }), title: t('chRemoveThisImage'),
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
      else item.failed = reply.error?.message || t('chTheNodeDidnTKeep');
    } catch {
      item.failed = t('chItCouldnTBeRead');
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
    if (!canAttach()) return say(t('chThisPageCanTAttach'));
    files.forEach(addImage);
  });
  form.addEventListener('dragover', (event) => {
    if ([...(event.dataTransfer?.types || [])].includes(t('chFiles'))) event.preventDefault();
  });
  form.addEventListener('drop', (event) => {
    const dropped = [...(event.dataTransfer?.files || [])];
    if (!dropped.length) return;
    event.preventDefault();
    const files = images(dropped);
    if (!canAttach()) return say(t('chThisPageCanTAttach'));
    if (files.length < dropped.length) say(t('chOnlyImagesGoInFrom'));
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
    fromDevice.title = canAttach() ? '' : t('chThisPageCanTAttach');
    if (opening) (canAttach() ? fromDevice : fromNode).focus();
  });
  attachMenu.addEventListener('keydown', (event) => { if (event.key === 'Escape') { closeAttach(); attachButton.focus(); } });
  fromDevice.addEventListener('click', () => { closeAttach(); pick.click(); });
  pick.addEventListener('change', () => {
    const files = images(pick.files);
    pick.value = '';
    if (!canAttach()) return say(t('chThisPageCanTAttach'));
    files.forEach(addImage);
  });
  fromNode.addEventListener('click', () => {
    closeAttach();
    nodeImage.hidden = false;
    drawNodeLine();
    nodePath.focus();
  });
  // The line for the path typed, with what the box holds as its text (several paths: separated by commas). Where the
  // page acts and the node lists `send`, Send sends them from here instead (`send` with `images`, `~/` the node's home;
  // the node checks each is an image file there), the way the line would (now to a working Claude, else at its next
  // step), and says what became of it; the box and the path empty once it went.
  function drawNodeLine() {
    if (nodeImage.hidden) return;
    const session = store.state.sessions.get(view.session);
    const paths = nodePath.value.split(',').map((path) => path.trim()).filter(Boolean);
    const now = stateOf(session) === 'working' && session?.agent === 'claude';
    const acts = !!session && drivable(session) && actsFor(app, 'send');
    nodeNote.hidden = acts;
    if (acts && paths.length) {
      const home = store.state.node?.home;
      const images = paths.map((path) => (home && (path === '~' || path.startsWith('~/')) ? home + path.slice(1) : path));
      const way = now ? 'now' : 'step';
      const send = doButton(app, { label: t('acSend'), kind: 'send', busy: t('chSendingImage'), args: () => sendArgs(session, input.value.trim(), way, images),
        receipt: (result) => sentWords(way, result), done: () => { box.clear(); nodePath.value = ''; send.button.disabled = true; } });
      nodeLine.replaceChildren(send.el);
      return;
    }
    const line = session ? imageSendLine(session, input.value, paths, now) : null;
    nodeLine.replaceChildren(line ? copyLine(line, 'the command that sends the message with the image') : h('p', { class: 'confirm-note' }, t('chTypeTheImageSPath')));
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
      button.title = done ? t('chCopied') : t('chThisBrowserDidnTLet');
      setTimeout(() => { button.classList.remove('copied'); button.title = button.getAttribute('aria-label'); }, 1500);
    } else {
      say(done ? t('chCopied2') : t('chThisBrowserDidnTLet2'));
    }
    return done;
  }

  // The whole chat as the Mac's Export Chat writes it, of what this page holds (older items it hasn't paged in aren't).
  function markdownNow() {
    const session = store.state.sessions.get(view.session);
    return chatMarkdown(items(), AGENTS[session?.agent] || t('chAgent'));
  }
  function exportChat() {
    if (!items().length) return say(t('chNothingInThisChatTo'));
    const session = store.state.sessions.get(view.session);
    const url = URL.createObjectURL(new Blob([markdownNow()], { type: 'text/markdown' }));
    const link = h('a', { href: url, download: exportName(session?.title || (session && session.project)) , hidden: true });
    document.body.append(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 10_000);
    if (chat()?.more) say(t('chExportedWhatThisPageHolds'));
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
    const more = chat()?.more ? t('chEarlierNotLoaded') : '';
    setText(findCount, !query ? '' : found.length ? t('chOf', { a: foundAt + 1, b: found.length }) + more : t('chNoMatches') + more);
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
      // What the box held for the last session stays with it (kept under its key): nothing typed here goes to another.
      box.setKey('session:' + id);
      attached = [];
      drawAttached();
      closeSuggestions();
      const refusal = refusals.get(id);
      if (refusal) {
        refusals.delete(id);
        attached = refusal.held;
        drawAttached();
        box.refused(refusal.why, refusal.text, () => sendFromBox(refusal.way, input.value.trim()));
      }
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
      pluginDrawn = '';
      placeStack(store.state.sessions.get(id));
      drawPluginCards();
      heldOut = false;
      stopHold?.();
      stopHold = afterMs(() => { heldOut = true; if (view.session === id) { structural = true; render(); } }, HOLD_MS);
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
    copyMarkdown: () => (items().length ? copyText(markdownNow()) : say(t('chNothingInThisChatTo2'))),
    exportChat: () => exportChat(),
  };
}
