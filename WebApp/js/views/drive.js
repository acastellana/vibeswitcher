// Driving an ordinary session from the page (the parity table's gaps 1, 3 and 6): a message for it, its own question,
// starting one and ending one. No click is the user's voice (the plan's LW-D6): a message is left as a draft beside
// the session (`session.draft`), and everything else is the one line that does it in a terminal, a click to copy. The
// node shows that line's effect when it happens; the terminal asks for the typed code first.

import * as kit from '../kit.js';
import { h, setText, setClass } from '../dom.js';
import { icon } from '../marks.js';
import { AGENTS, tilde, lastPart } from '../words.js';
import { copyLine, UNDO_MS } from './cards.js';
import {
  sessionShort, shellWord, renameLine, PAUSES, pauseLine, endable, endLine, closeShellsLine, resumeLine, endedEntry, newLine,
  PRESET_VARIABLES, presetProblem, presetLine, presetArgs, leadLine, newProjectLine, projectFolderName,
} from '../actions.js';
import { t } from '../i18n.js';
import { actsFor, doButton, refusalWords } from '../acting.js';
import { waysFor, sendArgs } from '../sendways.js';
import { sendMenu } from './sendmenu.js';
import { sessionHref, projectHref } from '../ui.js';

// The command line's words for a session and for what the user typed (js/actions.js, where the page's lines are made).
export { sessionShort, shellWord };

// Whether the page may drive `session` at all: one the node's host started, still running.
export const drivable = (session) => !!session?.hosted && !session.ended;

// Whether `drafted` (a session's draft) goes in as the free-text answer of `prompt` (the question open on its screen)
// when `vibeswitcher send` types it: a single choice with an option that takes words, and words that aren't a `/`
// command, with no images (the node's `send`, as the app's composer does).
export function answersQuestion(prompt, drafted) {
  return !!prompt && !prompt.multiSelect && (prompt.text || []).length > 0 && !!drafted?.text?.trim()
    && !drafted.text.trim().startsWith('/') && !(drafted.images || []).length;
}

// The `session.pause` arguments for a choice of PAUSES (the command line's flags as the node takes them).
export function pauseArgs(choice) {
  return { indefinitely: { for: 'indefinitely' }, hour: { for: 'hours', hours: 1 }, morning: { for: 'morning' }, week: { for: 'hours', hours: 168 }, off: { for: 'off' } }[choice] || { for: 'indefinitely' };
}

// The message drafted for a session, over its composer: the text as it will be typed, the line that sends it, and
// Edit (back into the box) and Discard. Returns { el, update(session) }.
export function draftBox(app, { edit }) {
  const label = h('span', { class: 'confirm-label' });
  const text = h('p', { class: 'confirm-text' });
  const pictures = h('p', { class: 'confirm-note draft-images', hidden: true });
  const lineSlot = h('div');
  const refused = h('p', { class: 'card-notice', role: 'alert', hidden: true });
  let id = null;
  let drawn = '';
  const editButton = kit.button('quiet', { size: 's', title: t('drPutTheMessageBackIn'), onclick: () => {
    const drafted = app.store.sessionDraftOf(id);
    if (drafted) edit(drafted.text, drafted.images || []);
  } }, t('drEdit'));
  const discard = kit.button('quiet', { size: 's', title: t('drTakeTheDraftOffThe'), onclick: () => app.store.sessionDraft(id, null) }, t('drDiscard'));
  const note = h('p', { class: 'confirm-note' }, t('drRunItInATerminal'));
  const el = h('div', { class: 'confirm composer-draft', role: 'group', 'aria-label': t('drSendYourMessageFromA'), hidden: true },
    h('div', { class: 'confirm-head' }, label, h('span', { class: 'confirm-actions' }, editButton, discard)), text, pictures, lineSlot, note, refused);

  return {
    el,
    update(session) {
      id = session?.id || null;
      const drafted = id ? app.store.sessionDraftOf(id) : null;
      const why = id ? app.store.state.sessionDraftRefused.get(id) : null;
      el.hidden = !drafted && !why;
      refused.hidden = !why;
      if (why) setText(refused, why);
      if (!drafted) return;
      setClass(el, 'sending', drafted.sending);
      setClass(el, 'now', !!drafted.now);
      // A question open that takes typed words: the message goes in as its answer (the node's `send`, as the app's
      // composer does), so the box says so.
      const prompt = drivable(session) ? session.prompt : null;
      const answers = answersQuestion(prompt, drafted);
      setClass(el, 'answers', answers);
      setText(label, drafted.sending ? t('drSavingYourMessage')
        : drafted.now ? t('drSteer', { agent: AGENTS[session.agent] || t('drTheAgentLow') })
          : answers ? t('drAnswerAbove', { option: prompt.options[prompt.text[0]] })
            : t('drMessageFor', { agent: AGENTS[session.agent] || t('drTheAgentLow') }));
      setText(text, drafted.text);
      text.hidden = !drafted.text;
      const images = drafted.images || [];
      pictures.hidden = !images.length;
      setText(pictures, images.length ? t('drWithImages', { n: images.length, names: images.map((path) => path.split('/').pop()).join(', ') }) : '');
      // With the `act` right, Send sends it from here (`send`, as the command line would), and the draft goes.
      const acts = actsFor(app, 'send');
      const line = `vibeswitcher send ${sessionShort(id)}`;
      const key = JSON.stringify([line, acts, drafted.text, drafted.now, images, session?.sendWays || null]);
      if (key !== drawn) {
        drawn = key;
        note.hidden = acts;
        lineSlot.replaceChildren(acts ? sessionSender(app, session, drafted, images) : copyLine(line, 'the command that sends it'));
      }
    },
  };
}

// The draft's Send with the menu of the ways the session's agent takes a message (js/sendways.js): the button sends it
// the way it was left (now, for a draft left to steer a working agent; else at its next step); the draft goes once sent,
// and a refusal is said beside it.
function sessionSender(app, session, drafted, images) {
  const said = h('span', { class: 'act-said refused', role: 'status' });
  const menu = sendMenu({
    primary: drafted.now ? 'now' : 'step',
    send: (way) => {
      menu.el.querySelectorAll('button').forEach((button) => { button.disabled = true; });
      app.store.request('send', sendArgs(session, drafted.text, way, images)).then((reply) => {
        menu.el.querySelectorAll('button').forEach((button) => { button.disabled = false; });
        if (reply.ok) app.store.sessionDraft(session.id, null);
        else setText(said, refusalWords(reply.error));
      });
    },
  });
  menu.update(waysFor(session));
  return h('span', { class: 'session-send' }, menu.el, said);
}

// The messages `vibeswitcher send` sent while a question or picker was open on the session's screen, which the node
// holds and types in once it closes (`queued`, as the app's composer holds them). Returns { el, update(session) }.
export function queuedStrip() {
  const head = h('span', { class: 'confirm-label' });
  const list = h('ol', { class: 'queued-list' });
  const el = h('div', { class: 'confirm composer-draft queued', role: 'status', hidden: true }, head, list,
    h('p', { class: 'confirm-note' }, t('drTypedInInThisOrder')));
  let drawn = '';
  return {
    el,
    update(session) {
      const queued = drivable(session) ? session.queued || [] : [];
      el.hidden = !queued.length;
      const now = JSON.stringify(queued.map((item) => [item.action, item.text, item.images]));
      if (now === drawn) return;
      drawn = now;
      setText(head, queued.length === 1 ? t('drAMessageWaitsToGo') : t('drQueuedMany', { n: queued.length }));
      list.replaceChildren(...queued.map((item) => h('li', null, item.text || '', item.images ? h('span', { class: 'queued-images' }, t('drPlusImages', { n: item.images })) : null)));
    },
  };
}

// The question open on a session's screen (a permission prompt, its own question, a plan to approve), as the node read
// it: the options numbered as the screen numbers them. Where the page acts and the node lists `session.reply`, a click
// answers it: "Sending … · Undo" for as long as a Blocking card's answer waits (`UNDO_MS`, on `app.later`, the tests'
// clock), then the request, with the question and options the click was made on (the node types nothing unless its
// screen still shows them), then "You answered …" on the card; a refusal stays on the card in words, the choices back.
// The answer waiting to go is dropped if the question changes or closes meanwhile. Elsewhere a pick shows the line that
// answers it, `vibeswitcher reply`, and the card says why; an option that takes words opens a field, and the line or
// the answer carries them. Returns { el, update(session) }.
export const promptKey = (prompt) => JSON.stringify([prompt.question, prompt.options, prompt.at ?? null]);

export function promptCard(app) {
  const el = h('article', { class: 'card ask session-prompt', tabindex: -1, hidden: true });
  const later = app.later || ((fn, ms) => { const timer = setTimeout(fn, ms); return () => clearTimeout(timer); });
  let key = '';
  let chosen = null;
  let words = '';
  let shown = null;
  // This page's answer, for the session it was given on: { phase: 'waiting' (Undo still possible) | 'sending' |
  // 'answered' | 'refused' | 'dropped', session, prompt (the click's identity), choice, option, text, cancel, why }.
  let mine = null;
  let lastSession = null;

  const acting = () => actsFor(app, 'session.reply');

  // The click: what it answers is taken now, and checked again when it goes.
  function answer(session, index, text = null) {
    const prompt = session.prompt;
    if (!prompt || mine?.phase === 'waiting' || mine?.phase === 'sending') return;
    const waiting = { phase: 'waiting', session: session.id, key: promptKey(prompt), question: prompt.question, options: [...prompt.options], choice: index + 1,
      option: prompt.options[index], text };
    mine = waiting;
    waiting.cancel = later(() => go(waiting), UNDO_MS);
    draw(session);
  }

  function undo() {
    if (mine?.phase !== 'waiting') return;
    mine.cancel?.();
    mine = null;
    if (shown) draw(shown);
    el.focus?.();
  }

  // The seconds are over: it goes only if the session still shows that question and the page still acts.
  function go(waiting) {
    if (mine !== waiting) return;
    const now = app.store.state.sessions.get(waiting.session);
    if (!drivable(now) || !now.prompt || promptKey(now.prompt) !== waiting.key || !acting()) {
      mine = { ...waiting, phase: 'dropped', key: now?.prompt ? promptKey(now.prompt) : null };
      if (shown) draw(shown);
      return;
    }
    mine = { ...waiting, phase: 'sending' };
    draw(now);
    const args = { session: waiting.session, choice: waiting.choice, question: waiting.question, options: waiting.options, ...(waiting.text ? { text: waiting.text } : {}) };
    app.store.request('session.reply', args).then((reply) => {
      // It no longer needs you: until the node reads its screen again, the answered question counts no more.
      if (reply?.ok) app.store.sessionReplied?.(waiting.session, waiting.key);
      if (mine?.session !== waiting.session || mine.phase !== 'sending') return;
      if (reply?.ok) {
        mine = { ...mine, phase: 'answered' };
      } else {
        mine = { ...mine, phase: 'refused', why: refusalWords(reply?.error) };
      }
      if (shown) draw(app.store.state.sessions.get(waiting.session) || shown);
    });
  }

  function closedCard(session, ...lines) {
    el.replaceChildren(h('header', { class: 'card-head' }, h('span', { class: 'priority blocking' }, t('drIsAsking', { agent: AGENTS[session.agent] || t('drTheAgent') }))),
      h('div', { class: 'card-closed', role: 'status' }, ...lines));
  }

  // Why this card shows a line to paste instead of answering: the page doesn't act here, or the node doesn't take it.
  const whyLine = () => h('p', { class: 'confirm-note prompt-why' }, app.store.acts() ? t('drReplyTerminalOnly') : t('drReplyPageReads'));

  function draw(session) {
    const prompt = session.prompt;
    const said = (option, text) => h('strong', null, text ? `${option}: ${text}` : option);
    if (mine?.phase === 'waiting') {
      el.classList.add('closed', 'sending');
      return closedCard(session, icon('send', 13), h('div', null, h('p', null, t('cSending', { x: mine.text ? `${mine.option}: ${mine.text}` : mine.option }), ' · ',
        kit.button('quiet', { size: 's', class: 'card-undo', onclick: undo }, t('cUndo'))), h('p', { class: 'card-about' }, mine.question.split('\n').at(-1))));
    }
    if (mine?.phase === 'sending') {
      el.classList.add('closed', 'sending');
      return closedCard(session, icon('send', 13), h('div', null, h('p', null, t('cSending', { x: mine.text ? `${mine.option}: ${mine.text}` : mine.option })),
        h('p', { class: 'card-about' }, mine.question.split('\n').at(-1))));
    }
    if (mine?.phase === 'answered' && !prompt) {
      el.classList.add('closed');
      el.classList.remove('sending');
      return closedCard(session, icon('check', 13), h('div', null, h('p', null, t('cYouAnswered'), said(mine.option, mine.text)),
        h('p', { class: 'card-about' }, mine.question.split('\n').at(-1))));
    }
    el.classList.remove('closed', 'sending');
    if (!prompt) return;
    const agent = AGENTS[session.agent] || t('drTheAgent');
    const takes = new Set(prompt.text || []);
    const short = sessionShort(session.id);
    const acts = acting();
    const buttons = prompt.options.map((option, index) => h('button', {
      class: 'option' + (chosen === index ? ' chosen' : ''), type: 'button', 'aria-pressed': String(chosen === index),
      onclick: () => {
        // Acting, an option that takes no words is the answer; one that does opens its field first.
        if (acts && !takes.has(index)) { chosen = null; answer(session, index); return; }
        chosen = index;
        draw(session);
        el.querySelector(takes.has(index) ? '.answer-input' : '.copy-button')?.focus();
      },
    }, h('span', { class: 'option-key', 'aria-hidden': 'true' }, String(index + 1)), h('span', { class: 'option-text' }, option),
    prompt.descriptions?.[index] ? h('span', { class: 'option-note' }, prompt.descriptions[index]) : null));
    const parts = [
      h('header', { class: 'card-head' }, h('span', { class: 'priority blocking' }, t('drIsAsking', { agent }))),
      h('pre', { class: 'ask-text' }, prompt.question),
    ];
    if (prompt.multiSelect) {
      parts.push(h('ol', { class: 'options read-only' }, prompt.options.map((option) => h('li', { class: 'option' }, h('span', { class: 'option-text' }, option)))),
        h('p', { class: 'confirm-note' }, t('drItTakesSeveralTicksAnswer')));
    } else if (acts) {
      parts.push(h('div', { class: 'options' }, buttons));
      if (chosen !== null && takes.has(chosen)) {
        const index = chosen;
        const input = kit.field({ class: 'answer-input', type: 'text', value: words, placeholder: t('drYourWords'), 'aria-label': t('drYourWordsForThisOption'), autocomplete: 'off' });
        const send = kit.button('primary', { type: 'submit', disabled: !words.trim() }, t('drReplySend'));
        input.addEventListener('input', () => { words = input.value; send.disabled = !words.trim(); });
        parts.push(h('form', { class: 'answer', onsubmit: (event) => { event.preventDefault(); if (words.trim()) { const text = words.trim(); words = ''; chosen = null; answer(session, index, text); } } }, input, send));
      }
      if (mine?.phase === 'refused' && mine.key === promptKey(prompt)) parts.push(h('p', { class: 'card-notice', role: 'alert' }, t('drReplyRefused', { why: mine.why })));
      if (mine?.phase === 'dropped') parts.push(h('p', { class: 'card-notice', role: 'status' }, t('drReplyChanged')));
      if (mine?.phase === 'still' && mine.key === promptKey(prompt)) parts.push(h('p', { class: 'card-notice', role: 'alert' }, t('drReplyStillOpen')));
    } else {
      parts.push(h('div', { class: 'options' }, buttons));
      if (chosen !== null && takes.has(chosen)) {
        const input = kit.field({ class: 'answer-input', type: 'text', value: words, placeholder: t('drYourWords'), 'aria-label': t('drYourWordsForThisOption'),
          oninput: () => { words = input.value; line.replaceChildren(command()); } });
        parts.push(input);
      }
      const command = () => {
        if (chosen === null) return h('p', { class: 'confirm-note' }, t('drPickAnAnswerTheLine'));
        const typed = takes.has(chosen) && words.trim() ? ` ${shellWord(words.trim())}` : '';
        return copyLine(`vibeswitcher reply ${short} ${chosen + 1}${typed}`, t('drTheCommandThatAnswersIt'));
      };
      const line = h('div', { class: 'prompt-line' }, command());
      parts.push(line, whyLine(), h('p', { class: 'confirm-note' }, t('drRunItInATerminal2')));
    }
    el.replaceChildren(...parts);
  }

  return {
    el,
    update(session) {
      // Another session: nothing of this one's answer is kept (one waiting to go is dropped).
      if (session?.id !== lastSession) {
        if (mine?.phase === 'waiting') mine.cancel?.();
        mine = null;
        key = '';
        lastSession = session?.id ?? null;
      }
      shown = session;
      const prompt = drivable(session) ? session.prompt : null;
      // Waiting to go, and the question changed or closed: it doesn't go.
      if (mine?.phase === 'waiting' && (!prompt || promptKey(prompt) !== mine.key)) {
        mine.cancel?.();
        mine = { ...mine, phase: 'dropped', key: prompt ? promptKey(prompt) : null };
      }
      // Answered, and the node still shows that question once the store stopped hiding it: it is still open; say so.
      if (prompt && mine?.phase === 'answered' && promptKey(prompt) === mine.key) mine = { ...mine, phase: 'still' };
      // A new question: what was said of the last one goes.
      if (prompt && mine && mine.phase !== 'waiting' && mine.phase !== 'sending' && promptKey(prompt) !== mine.key) mine = null;
      const keeps = mine?.phase === 'sending' || mine?.phase === 'answered';
      el.hidden = !prompt && !keeps;
      if (!prompt && !keeps) { key = ''; if (mine?.phase === 'dropped' || mine?.phase === 'refused') mine = null; return; }
      const now = JSON.stringify([session.id, prompt?.question, prompt?.options, prompt?.at, mine?.phase ?? null, acting()]);
      if (now === key) return;
      // Another question (or the same one asked again): nothing picked for it yet.
      if (!prompt || !key.startsWith(JSON.stringify([session.id, prompt.question]).slice(0, -1))) { chosen = null; words = ''; }
      key = now;
      draw(session);
    },
  };
}

// What the Mac's row menu does to a session (Rename…, Pause, Resume Notifications, End Session…, Close Finished
// Shells…), under its header: pick one, and the line that does it shows, a click to copy. A lead and a lead's team
// aren't ended from here (their lead and `vibeswitcher stop` are). A session that ended has its Resume line, where the
// node knows its conversation. Returns { el, open(tab), toggle(), update(session, node) → whether it offers anything }.
export function actionsStrip(app = null) {
  const TABS = [
    { id: 'rename', label: t('drRename') },
    { id: 'pause', label: t('drPause') },
    { id: 'end', label: t('drEnd') },
    { id: 'shells', label: t('drCloseShells') },
    { id: 'resume', label: t('drResume') },
  ];
  const tabs = kit.segmented({ role: 'group', 'aria-label': t('drDo') });
  const panel = h('div', { class: 'action-panel' });
  const close = kit.iconButton({ 'aria-label': t('drClose'), title: t('drClose') }, icon('close', 13));
  const el = h('div', { class: 'end-strip action-strip', role: 'group', 'aria-label': t('drRenamePauseOrEndThis'), hidden: true }, tabs, panel, close);
  let opened = false;
  let tab = 'rename';
  let id = null;
  let session = null;
  let node = null;
  let typed = null;
  let pause = 'indefinitely';
  let drawn = '';
  close.addEventListener('click', () => { opened = false; el.hidden = true; });

  // What can be done to it now: renamed and paused while the node lists it (any session, one in your own terminal
  // too: a name types nothing), ended when the page may end it, its folder's shells closed, resumed once ended.
  function offered() {
    if (!session) return [];
    const ended = endedEntry(node, session.id);
    if (session.ended) return ended ? ['resume'] : [];
    return ['rename', 'pause', ...(endable(session) ? ['end'] : []), ...(session.hosted && session.cwd ? ['shells'] : [])];
  }

  // With the `act` right, the button that does it from here (`kind` with `args`), named for what it does (D12); else
  // the line that does it in a terminal. Never both. What it does, said under it.
  function line(text, label, note, kind = null, args = null, doing = null) {
    const acts = app && kind && text && actsFor(app, kind);
    return [acts ? doButton(app, { label: doing || t('acDoIt'), kind, args: () => args, done: () => { opened = false; el.hidden = true; } }).el : null,
      text && !acts ? copyLine(text, label) : null, note ? h('p', { class: 'confirm-note' }, note) : null].filter(Boolean);
  }

  function body() {
    if (tab === 'rename') {
      if (typed === null) typed = session.name || '';
      const input = kit.field({ class: 'answer-input', type: 'text', value: typed, placeholder: session.task || t('drItsOwnName'), 'aria-label': t('drName'), spellcheck: 'false', autocomplete: 'off' });
      const slot = h('div');
      const fill = () => {
        const text = renameLine(session, typed);
        slot.replaceChildren(...line(text, t('drTheCommandThatRenamesIt'),
          text ? (typed.trim() ? t('drKeptAcrossAResumeThe') : t('drGivesItItsOwnName'))
            : typed.trim() ? t('drThatSItsNameNow') : t('drTypeAName'), 'session.rename', { session: session.id, ...(typed.trim() ? { name: typed.trim() } : {}) }, t('drRename')));
      };
      input.addEventListener('input', () => { typed = input.value; fill(); });
      fill();
      return [input, slot];
    }
    if (tab === 'pause') {
      if (session.paused) {
        return line(pauseLine(session, 'off'), t('drTheCommandThatResumesIts'),
          t('drPausedGreyedOutNeverReminded'), 'session.pause', { session: session.id, for: 'off' }, t('drResumeNotifications'));
      }
      const choices = kit.segmented({ class: 'presets', role: 'group', 'aria-label': t('drForHowLong') }, PAUSES.map((one) => kit.segment({
        'aria-pressed': String(one.id === pause), onclick: () => { pause = one.id; draw(true); },
      }, one.label)));
      return [choices, ...line(pauseLine(session, pause), t('drTheCommandThatPausesIt'), t('drGreyedOutAndNothingReminds'), 'session.pause', { session: session.id, ...pauseArgs(pause) }, t('drPause'))];
    }
    if (tab === 'end') return line(endLine(session), t('drTheCommandThatEndsIt'), t('drItsAgentStopsWithEverything'), 'session.end', { session: session.id }, t('drEnd'));
    if (tab === 'shells') {
      // Where the page acts and the node lists `shells` and `session.close-shells`: the folder's shells listed first,
      // then Close N finished shells for those the node says are finished (a second click asks first).
      if (app && actsFor(app, 'shells') && actsFor(app, 'session.close-shells')) return [shellsPanel(app, session.cwd)];
      return line(closeShellsLine(session.cwd), t('drTheCommandThatClosesThe'),
        t('drEndsThisNodeSShells'));
    }
    const ended = endedEntry(node, session.id);
    const resume = resumeLine(ended);
    // Its conversation's id is the terminal's (claude --resume): shown only where the page can't resume it.
    return [...line(resume, t('drTheCommandThatResumesIt'), resume ? t('drStartsItAgainInIts') : t('drItsConversationIdWasnT'), 'session.resume', { session: session.id }, t('drResume')),
      ended?.conversation && !(app && actsFor(app, 'session.resume')) ? copyLine(ended.conversation, t('drItsConversationId')) : null];
  }

  function draw(force = false) {
    const can = offered();
    if (!can.includes(tab)) tab = can[0] || 'rename';
    const key = JSON.stringify([session?.id, session?.name, session?.paused, session?.cwd, can, tab, pause, endedEntry(node, session?.id), app?.store.acts()]);
    if (!force && key === drawn) return;
    drawn = key;
    tabs.replaceChildren(...TABS.filter((one) => can.includes(one.id)).map((one) => kit.segment({
      'aria-pressed': String(one.id === tab), onclick: () => { tab = one.id; draw(true); el.querySelector('.action-panel input, .action-panel .copy-button')?.focus(); },
    }, one.id === 'pause' && session?.paused ? t('drResumeNotifications') : one.label)));
    tabs.hidden = can.length < 2;
    panel.replaceChildren(...(session && can.length ? body() : []).filter(Boolean));
  }

  return {
    el,
    open(which) {
      if (which) tab = which;
      opened = true;
      draw(true);
      el.hidden = !offered().length;
      el.querySelector('.action-panel input, .action-panel .copy-button')?.focus();
    },
    toggle() { opened ? (opened = false, el.hidden = true) : this.open(); },
    update(next, nodeValue) {
      if (next?.id !== id) { opened = false; id = next?.id || null; typed = null; pause = 'indefinitely'; }
      session = next || null;
      node = nodeValue || null;
      const can = offered().length > 0;
      if (!can) opened = false;
      el.hidden = !opened;
      if (opened) draw();
      return can;
    },
  };
}

// The node's shells in `folder` (the `shells` read: each with its terminal and whether it is finished, back at its
// prompt with nothing running), and Close N finished shells (`session.close-shells` with the ids listed: the node ends
// only those still finished then, and says which it left). Returns the panel.
export function shellsPanel(app, folder) {
  const list = h('ul', { class: 'shell-list' });
  const slot = h('div', { class: 'shell-acts' });
  const said = h('p', { class: 'confirm-note', role: 'status' }, t('drShellsLooking'));
  const el = h('div', { class: 'shells-panel' }, said, list, slot);
  const home = app.store.state.node?.home;
  const where = (path) => (home && path?.startsWith(home + '/') ? '~' + path.slice(home.length) : path || '');
  function draw(shells) {
    const finished = shells.filter((shell) => shell.finished === true && typeof shell.session === 'string');
    list.replaceChildren(...shells.map((shell) => h('li', { class: shell.finished ? 'shell finished' : 'shell' },
      h('span', { class: 'shell-where' }, where(shell.folder)), ' · ', h('span', null, shell.terminal || ''), ' · ',
      h('span', { class: shell.finished ? 'tone-text-done' : 'tone-text-working' }, shell.finished ? t('drShellFinished') : t('drShellRunning')))));
    setText(said, !shells.length ? t('drNoShellsHere') : finished.length ? t('drShellsListed', { n: finished.length }) : t('drNoFinishedShells'));
    if (!finished.length) { slot.replaceChildren(); return; }
    const ids = finished.map((shell) => shell.session);
    const close = doButton(app, { label: t('drCloseNShells', { n: ids.length }), kind: 'session.close-shells', danger: true, confirm: t('drCloseShellsSure', { n: ids.length }),
      busy: t('drClosing'), args: () => ({ sessions: ids }),
      receipt: (result) => [t('drShellsClosed', { n: (result.ended || []).length }), (result.left || []).length ? t('drShellsLeft', { n: result.left.length }) : ''].filter(Boolean).join(' '),
      done: () => { close.button.disabled = true; } });
    slot.replaceChildren(close.el);
  }
  app.store.read('shells', { folder }).then((reply) => {
    if (reply?.ok && Array.isArray(reply.result?.shells)) { draw(reply.result.shells); return; }
    // An odd answer or a refusal: the node's words, and the line that does it from a terminal.
    setText(said, refusalWords(reply?.error, t('drCloseShells')));
    slot.replaceChildren(copyLine(closeShellsLine(folder), t('drTheCommandThatClosesThe')));
  });
  return el;
}

// Starting a session or a project's lead from the page, where it acts and the node lists the kind: the primary button
// ("Starting…" while the request is out), and once the node said what it started, the page goes there as soon as the
// store lists it (the reply can come before the stream's delta); the node's refusal said under the button. Elsewhere
// the line to run, and why it is a line. `target(result)`: { session } for a session, { lead } for a lead's session;
// `note(result)` what to say instead of going (a lead that waits for its host). `busy`: the button's words while it
// is out; `orLine`: the terminal's line beside the button too (false: the button alone, the line only where there is
// none). Returns the slot's nodes.
export function startOrLine(app, { kind, label, args, line, lineLabel, terminalOnly, target, note = () => null, busy = null, orLine = true, plain = false, after = null, confirm = null }) {
  if (!actsFor(app, kind)) {
    return [line ? copyLine(line, lineLabel) : null, h('p', { class: 'confirm-note start-why' }, app.store.acts() ? t(terminalOnly) : t('drStartPageReads'))].filter(Boolean);
  }
  let stop = () => {};
  // Where the user was when it started: the page goes to what started only while they are still there.
  const here = () => JSON.stringify(app.ui.state?.route ?? null);
  let from = null;
  const button = doButton(app, { label, kind, args, plain, confirm, className: 'start-button', busy: busy || t('drStarting'), done: (reply) => {
    stop();
    after?.(reply.result || {}, button);
    // Started: the button doesn't start a second one (the form drawn again for another folder or preset gives a new one).
    button.button.disabled = true;
    from = here();
    const said = note(reply.result || {});
    if (said) { button.say(said); return; }
    const wanted = target(reply.result || {});
    const place = () => {
      if (wanted.session && app.store.state.sessions.has(wanted.session)) return sessionHref(wanted.session);
      if (wanted.lead) {
        const lead = [...app.store.state.leads.values()].find((one) => one.session === wanted.lead);
        if (lead) return projectHref(lead.project);
      }
      return null;
    };
    if (!wanted.session && !wanted.lead) { button.say(t('drStartedNoName')); return; }
    const now = place();
    if (now) { app.ui.go(now); return; }
    button.say(t(wanted.lead ? 'drLeadStartedWaiting' : 'drStartedWaiting'));
    const topic = wanted.lead ? 'leads' : 'sessions';
    const off = app.store.subscribe(topic, () => {
      // The user went elsewhere meanwhile: nothing pulls them away; it stops listening.
      if (here() !== from) { stop(); return; }
      const found = place();
      if (!found) return;
      stop();
      app.ui.go(found);
    });
    stop = () => { off?.(); stop = () => {}; };
  } });
  return [button.el, line && orLine ? h('p', { class: 'confirm-note or-terminal' }, t('drOrInATerminal')) : null, line && orLine ? copyLine(line, lineLabel) : null].filter(Boolean);
}

// What a lead's start answered that asks the user for a choice (`lead`'s notes, the engine's `LeadStart` words; the
// reply has no field for it yet): 'replace' when the lead there runs without its role and nothing started (`--replace`
// starts a new one), else null. Only those exact words: anything else is said as the node said it.
export function leadNeeds(result) {
  const notes = (result?.notes || []).join('\n');
  if (result?.happened === 'shown' && /without its role/.test(notes) && /--replace\b/.test(notes)) return 'replace';
  return null;
}

// The open base-move card of the project in `folder` (its base moved since its lead last left it, outside its merges),
// or null.
export function baseMoveOf(app, folder) {
  return [...app.store.state.cards.values()].find((card) => card.open !== false && card.kind === 'base' && card.base && card.root === folder) || null;
}

// Starting a project's lead from the page (`lead`, the folder and `extra`: a goal, `resume`), where it acts and the
// node lists `lead`; the line and why elsewhere. Two choices the node takes as `lead`'s own flags, each said in a line
// before it is made: where the base moved since its lead last left it (its card open), Take the base as it is
// (`takeHead`: the lead starts on the branch as it is now, the move not asked again); where the lead runs without its
// role and nothing started (the node's answer), Replace it (`replace`: a new lead takes the role, a second click in
// place). Returns the slot's nodes.
export function leadStartOrLine(app, { folder, extra = () => ({}), label, plain = false, line, lineLabel, orLine = false, baseChoice = true }) {
  const choices = h('div', { class: 'lead-choices', hidden: true });
  const go = (result) => ({ lead: typeof result.session === 'string' ? result.session : null });
  const words = (result) => (result.happened === 'waiting' ? t('drLeadWaiting') : leadNeeds(result) === 'replace' ? t('drLeadNoRole') : null);
  const offerReplace = (result) => {
    if (leadNeeds(result) !== 'replace' || !actsFor(app, 'lead')) return;
    choices.hidden = false;
    choices.replaceChildren(h('p', { class: 'confirm-note choice-what' }, t('drReplaceWhat')),
      ...startOrLine(app, { kind: 'lead', label: t('drReplaceLead'), busy: t('drReplacing'), confirm: t('drReplaceSure'), orLine: false,
        args: () => ({ folder, ...extra(), replace: true }), terminalOnly: 'drLeadTerminalOnly', target: go, note: words }));
  };
  const start = startOrLine(app, { kind: 'lead', label, plain, orLine, args: () => ({ folder, ...extra() }), line, lineLabel, terminalOnly: 'drLeadTerminalOnly',
    target: go, note: words, after: offerReplace });
  const base = baseChoice && actsFor(app, 'lead') ? baseMoveOf(app, folder) : null;
  if (!base) return [...start, choices];
  const moved = base.base;
  return [...start, h('div', { class: 'lead-choices base-choice' },
    h('p', { class: 'confirm-note choice-what' }, t('drTakeBaseWhat', { branch: moved.branch || '', to: String(moved.to || '').slice(0, 8) })),
    ...startOrLine(app, { kind: 'lead', label: t('drTakeBase'), plain: true, orLine: false, args: () => ({ folder, ...extra(), takeHead: true }),
      terminalOnly: 'drLeadTerminalOnly', target: go, note: words, after: offerReplace })), choices];
}

// Resume for an ended session of yours (`session.resume`): started again in its conversation, the page goes to it once
// the node lists it; what the node refused (no conversation recorded) said beside it. Elsewhere its line and why.
export function resumeOrLine(app, entry, { plain = false } = {}) {
  return startOrLine(app, { kind: 'session.resume', label: t('acResume'), busy: t('drResuming'), plain, orLine: false,
    args: () => ({ session: entry.session }), line: resumeLine(entry), lineLabel: t('drTheCommandThatResumesIt'), terminalOnly: 'drResumeTerminalOnly',
    target: (result) => ({ session: typeof result.reopened?.[0]?.session === 'string' ? result.reopened[0].session : null }),
    note: (result) => (!result.reopened?.length && result.refused?.length ? t('drResumeRefused', { why: result.refused[0].why || '' }) : null) });
}

// The start forms (New session, New project; the design review's D12): a short form each, in the page's components.
// A row is its words over its control: what to start, where (the folder field, the recent folders offered beside
// it), what is optional; then one primary button that says what it will start, which opens what started. Where the
// page can't act, the same form ends in the line to copy and one sentence why. A folder is shown as ~/… (`~` is the
// node's home, as a shell reads it).
function startRow(label, ...controls) {
  return h('div', { class: 'start-row' }, h('span', { class: 'start-label' }, label), h('div', { class: 'start-control' }, ...controls));
}

// The folder field's text as the folder the node takes: `~/` is the node's home.
function folderOf(app, typed) {
  const home = app.store.state.node?.home;
  const text = String(typed || '').trim();
  return home && (text === '~' || text.startsWith('~/')) ? home + text.slice(1) : text;
}

// The recent folders beside a folder field, each a quiet button with its folder's name (~/… on hover): a press puts it
// in the field. Returns { el, update(folders) }.
function recentChoices(app, pick) {
  const list = h('span', { class: 'start-recent-list' });
  const el = h('div', { class: 'start-recent', hidden: true }, h('span', { class: 'start-recent-label' }, t('drRecent')), list);
  let drawn = '';
  return {
    el,
    update(folders) {
      const home = app.store.state.node?.home;
      const key = JSON.stringify([folders, home]);
      if (key === drawn) return;
      drawn = key;
      el.hidden = !folders.length;
      list.replaceChildren(...folders.map((folder) => kit.button('quiet', { size: 's', title: tilde(folder, home), onclick: () => pick(folder) }, lastPart(folder) || folder)));
    },
  };
}

// A preset in a person's words: what it starts (Claude with its model, Codex, a shell), and what else it does, counted.
// Its whole command stays in the tooltip (presetNote).
export function presetWords(preset) {
  if (!preset) return '';
  const parts = [];
  if (preset.kind === 'shell') parts.push(t('drPwShell'));
  else {
    const agent = preset.kind === 'codex' ? 'Codex' : 'Claude';
    const model = /(?:^|\s)--model[= ](\S+)/.exec(preset.command || '')?.[1];
    parts.push(model ? t('drPwModel', { agent, model: model.charAt(0).toUpperCase() + model.slice(1) }) : agent);
  }
  if (preset.env?.length) parts.push(t('drPwSettings', { n: preset.env.length }));
  if (preset.keepShell) parts.push(t('drShellStays'));
  if (preset.default) parts.push(t('drFolderDefault'));
  return parts.join(' · ');
}

// Starting a project lead in a folder that exists (the Mac's Start Project Lead…, and the palette's "Start Project
// Lead in …"): the folder, the goal, and Start the lead in <folder>; a folder whose lead runs offers Open it instead.
// Returns { el, choose(folder), update(recent) }.
export function newLeadForm(app) {
  const path = kit.field({ class: 'answer-input', type: 'text', placeholder: t('drPathPlaceholder'), 'aria-label': t('drProjectFolder'), spellcheck: 'false', autocomplete: 'off' });
  const goal = kit.field({ tag: 'textarea', class: 'answer-input lead-goal', rows: 2, placeholder: t('drGoalPlaceholder'), 'aria-label': t('drGoal') });
  const recent = recentChoices(app, (folder) => { path.value = tilde(folder, app.store.state.node?.home); draw(); goal.focus?.(); });
  const lineSlot = h('div', { class: 'prompt-line start-actions' });
  const el = h('section', { class: 'start-form new-lead', 'aria-label': t('drStartAProjectLead') },
    startRow(t('drWhereFolder'), path, recent.el),
    startRow(t('drGoalOptional'), goal),
    lineSlot);
  let drawn = '';
  function draw() {
    const folder = folderOf(app, path.value);
    const running = folder ? [...app.store.state.leads.values()].find((one) => one.root === folder && one.session) : null;
    const key = JSON.stringify([folder, goal.value.trim(), running?.project || null, app.store.acts(), app.store.can('lead')]);
    if (key === drawn) return;
    drawn = key;
    if (!folder) { lineSlot.replaceChildren(kit.button('primary', { class: 'start-button', disabled: true }, t('acStartLead'))); return; }
    const name = lastPart(folder) || folder;
    if (running) {
      lineSlot.replaceChildren(kit.button('primary', { tag: 'a', class: 'start-button', href: projectHref(running.project) }, t('drOpenProject', { name })),
        h('p', { class: 'confirm-note' }, t('drItsLeadRuns')));
      return;
    }
    // With the `act` right and `lead` listed, it starts the lead (the folder and the goal; never `--init`, which stays
    // the terminal's), then opens its project; Take the base as it is and Replace it where the node's state asks
    // for them (leadStartOrLine). Elsewhere the line and why.
    lineSlot.replaceChildren(...leadStartOrLine(app, { folder, label: t('drStartLeadIn', { name }), orLine: false,
      extra: () => (goal.value.trim() ? { goal: goal.value.trim() } : {}),
      line: leadLine(folder, goal.value), lineLabel: t('drTheCommandThatStartsThe') }));
  }
  path.addEventListener('input', draw);
  goal.addEventListener('input', () => { if (!actsFor(app, 'lead')) draw(); });
  draw();
  return {
    el,
    // The palette's "Start Project Lead in …": that folder in the form, the goal to write.
    choose(folder) {
      path.value = tilde(folder, app.store.state.node?.home);
      draw();
      goal.focus?.();
      el.scrollIntoView?.({ block: 'nearest' });
    },
    update(folders = []) { recent.update(folders); draw(); },
  };
}

// A brand-new project (the Mac's New Project…): a name, where (the node's projects folder when empty) and a goal. No
// node request makes a project's folder from a page yet (`vibeswitcher new-project` makes it, its repository and first
// commit, in the terminal's own process): the form says so plainly and ends in that line. Returns { el, update() }.
export function newProjectForm(app) {
  const name = kit.field({ class: 'answer-input', type: 'text', placeholder: t('drProjectNamePlaceholder'), 'aria-label': t('drProjectName'), spellcheck: 'false', autocomplete: 'off' });
  const location = kit.field({ class: 'answer-input', type: 'text', placeholder: t('drWhereOptionalTheNodeS'), 'aria-label': t('drWhere'), spellcheck: 'false', autocomplete: 'off' });
  const goal = kit.field({ tag: 'textarea', class: 'answer-input lead-goal', rows: 2, placeholder: t('drGoalPlaceholder'), 'aria-label': t('drGoal') });
  const folderNote = h('p', { class: 'confirm-note', hidden: true });
  const lineSlot = h('div', { class: 'prompt-line start-actions' });
  const el = h('section', { class: 'start-form new-project', 'aria-label': t('drNewProject') },
    startRow(t('drProjectName'), name, folderNote),
    startRow(t('drWhere'), location, h('p', { class: 'confirm-note where-hint' }, t('drWhereHint'))),
    startRow(t('drGoalOptional'), goal),
    lineSlot);
  function draw() {
    const folder = projectFolderName(name.value);
    folderNote.hidden = !folder;
    folderNote.textContent = folder ? t('drItsFolder', { folder }) : '';
    lineSlot.replaceChildren(h('p', { class: 'confirm-note start-why' }, t('drProjectTerminalOnly')),
      folder ? copyLine(newProjectLine(name.value, location.value, goal.value), t('drTheCommandThatMakesThe')) : h('p', { class: 'confirm-note' }, t('drGiveItANameThe')));
  }
  for (const field of [name, location, goal]) field.addEventListener('input', draw);
  draw();
  return { el, update: draw };
}

// Starting a session: what (one of the launch presets the node keeps for the folder, `session.presets`: the folder's
// own and its default first, as the app's New Session lists them; Claude, Codex and Shell when the node lists none),
// where (`folder()` offered first, the recent folders beside it), Claude's model if you want another; then Start
// <preset> in <folder>. Returns { el, update(), choose(folder, preset) }.
export function newSessionForm(app, { folder, recent = () => [] }) {
  const BUILT_IN = [{ name: 'Claude', kind: 'claude', builtIn: true }, { name: 'Codex', kind: 'codex', builtIn: true }, { name: 'Shell', kind: 'shell', builtIn: true }];
  let presets = BUILT_IN;
  let chosen = 'Claude';
  // Whether you picked one: until then the folder's default (the first listed) is.
  let picked = false;
  let asked = null;
  let timer = null;
  const path = kit.field({ class: 'answer-input', type: 'text', placeholder: t('drPathPlaceholder'), 'aria-label': t('drFolder'), spellcheck: 'false', autocomplete: 'off' });
  const model = kit.field({ class: 'answer-input model-input', type: 'text', placeholder: t('drModelPlaceholder'), 'aria-label': t('drModel'), spellcheck: 'false', autocomplete: 'off' });
  const kinds = kit.segmented({ class: 'presets', role: 'group', 'aria-label': t('drPreset') });
  const about = h('p', { class: 'confirm-note preset-about', hidden: true });
  const lineSlot = h('div', { class: 'prompt-line start-actions' });
  const choices = recentChoices(app, (one) => { path.value = tilde(one, app.store.state.node?.home); offered = true; draw(); ask(); });
  // Adding, changing and removing the folder's presets: the `vibeswitcher preset` line for each, or Save where it acts.
  const editor = presetEditor({ folder: () => where(), app, saved: () => { asked = null; ask(); } });
  const editing = kit.button('quiet', { size: 's', class: 'preset-edit-toggle', 'aria-expanded': 'false', onclick: () => {
    const open = editor.el.hidden;
    editor.el.hidden = !open;
    editing.setAttribute('aria-expanded', String(open));
    if (open) editor.update(presets, true);
  } }, t('drEditPresets'));
  const modelRow = startRow(t('drModelOptional'), model);
  const el = h('section', { class: 'start-form start-card new-session', 'aria-label': t('drStartASession') },
    startRow(t('drWhat'), h('div', { class: 'start-what' }, kinds, editing), about),
    startRow(t('drWhereFolder'), path, choices.el),
    modelRow,
    lineSlot,
    editor.el);
  let offered = false;
  let lineDrawn = '';

  const where = () => folderOf(app, path.value);

  // The node's presets for the folder, asked a moment after it changes (an absolute path only).
  function ask() {
    const folder = where();
    if (!app.store.can('session.presets') || folder === asked) return;
    asked = folder;
    clearTimeout(timer);
    timer = setTimeout(() => {
      app.store.read('session.presets', folder.startsWith('/') ? { folder } : {}).then((reply) => {
        if (asked !== folder || !reply?.ok) return;
        presets = reply.result.presets.length ? reply.result.presets : BUILT_IN;
        chosen = presetChosen(presets, chosen, picked);
        draw();
      });
    }, 250);
  }

  function draw() {
    const preset = presets.find((one) => one.name === chosen && !one.refused) || presets.find((one) => one.name === chosen) || presets[0];
    kinds.replaceChildren(...presets.map((one) => kit.segment({
      'aria-pressed': String(one === preset), disabled: !!one.refused, title: one.refused ? t('drCantStartHere', { why: one.refused }) : presetNote(one) || null,
      onclick: () => { chosen = one.name; picked = true; draw(); },
    }, one.name)));
    modelRow.hidden = preset.kind === 'shell' || !!preset.command?.includes('--model');
    const words = preset.builtIn ? '' : presetWords(preset);
    about.hidden = !words;
    setText(about, words);
    about.title = preset.builtIn ? '' : presetNote(preset);
    const folder = where();
    const what = preset.name;
    if (!folder) {
      lineDrawn = '';
      lineSlot.replaceChildren(kit.button('primary', { class: 'start-button', disabled: true }, t('acStart')));
      if (!editor.el.hidden) editor.update(presets);
      return;
    }
    // With the `act` right, Start starts it from here (`session.new`: the folder, a built-in's agent or a preset by
    // name, the model); elsewhere the line and why.
    // A preset the node listed goes by its name with the digest it was listed with (the node starts it only while it is
    // as shown); the page's own Claude, Codex or Shell (the node listed none) by its agent.
    // Drawn again only when what it starts changed: a store update while a start is out keeps its "Starting…".
    const drawnNow = JSON.stringify([folder, preset.name, preset.digest ?? null, preset.kind, model.value, actsFor(app, 'session.new'), app.store.acts()]);
    if (drawnNow === lineDrawn) { if (!editor.el.hidden) editor.update(presets); return; }
    lineDrawn = drawnNow;
    const withModel = !modelRow.hidden && model.value.trim();
    const startArgs = () => ({ folder, ...(preset.digest ? { preset: preset.name, digest: preset.digest } : { agent: preset.kind || 'claude' }),
      ...(withModel ? { model: model.value.trim() } : {}) });
    lineSlot.replaceChildren(...startOrLine(app, { kind: 'session.new', label: t('drStartIn', { what, name: lastPart(folder) || folder }), terminalOnly: 'drStartTerminalOnly', args: startArgs,
      orLine: false, line: newLine(folder, preset, withModel ? model.value : ''), lineLabel: 'the command that starts it',
      target: (result) => ({ session: typeof result.session === 'string' ? result.session : null }) }));
    if (!editor.el.hidden) editor.update(presets);
  }
  path.addEventListener('input', () => { draw(); ask(); });
  model.addEventListener('input', draw);

  return {
    el,
    // The palette's "New … in …": that folder and preset in the form, its Start (or its line) ready.
    choose(given, name) {
      path.value = tilde(given, app.store.state.node?.home);
      offered = true;
      chosen = name;
      picked = true;
      ask();
      draw();
      (lineSlot.querySelector('.start-button') || lineSlot.querySelector('.copy-button'))?.focus();
      el.scrollIntoView?.({ block: 'nearest' });
    },
    update() {
      if (!offered && !path.value) {
        const given = folder();
        if (given) { path.value = tilde(given, app.store.state.node?.home); offered = true; }
      }
      choices.update(recent());
      ask();
      draw();
    },
  };
}

// The presets of yours for a folder (not the built-ins, which come from VibeSwitcher itself), and a form that adds one or
// changes one: the `vibeswitcher preset` line it makes, after the checks the node makes too (`presetProblem`). The page
// never sees a variable's value (the node sends their names only), so a change names only what it sets or takes off.
// Returns { el, update(presets, force) }.
// The `presets.edit` arguments for the form's change: what `presetLine` puts on the command line, as the node takes it
// (an edit or a remove with the digest of the preset as listed, so the node changes it only while it is as shown).
export function presetEditArgs(op, state, { folder = null, original = null } = {}) {
  const name = String(state.name || '').trim();
  const words = String(state.args || '').split(/\s+/).filter(Boolean).join(' ');
  const env = Object.fromEntries((state.env || []).filter(([variable, value]) => variable && value));
  const args = { op, name: original?.name || name, ...(folder ? { folder } : {}), ...(original ? { digest: original.digest } : {}) };
  if (op === 'remove') return args;
  if (op === 'add') {
    Object.assign(args, { kind: state.kind === 'shell' ? 'shell' : 'claude' });
    if (state.kind !== 'shell' && words) args.args = words;
    if (state.keepShell) args.keepShell = true;
  } else {
    const kind = state.kind === 'shell' ? 'shell' : 'claude';
    if (name && name !== original.name) args.rename = name;
    if (kind !== original.kind) args.kind = kind;
    if (kind === 'claude' && (words !== presetArgs(original) || kind !== original.kind)) args.args = words;
    if (!!state.keepShell !== !!original.keepShell) args.keepShell = !!state.keepShell;
    if ((state.unset || []).length) args.unset = [...state.unset];
  }
  if (Object.keys(env).length) args.env = env;
  if (state.isDefault && folder) args.default = true;
  return args;
}

// Where the page acts and the node lists `presets.edit`, Save and Remove do it from here (Remove asked twice); what the
// node did is said under the list once the form closes, its refusal beside the button. `saved()`: the list asked again.
export function presetEditor({ folder, app = null, saved = () => {} }) {
  const list = h('div', { class: 'preset-list' });
  const formSlot = h('div', { class: 'preset-form-slot' });
  const said = h('p', { class: 'act-said receipt preset-said', role: 'status', hidden: true });
  const acts = () => !!app && actsFor(app, 'presets.edit');
  const note = h('p', { class: 'confirm-note' }, t('drAChangedPresetsFileWaits'));
  const el = h('div', { class: 'preset-editor', hidden: true },
    h('p', { class: 'new-title' }, t('drYourPresets')), list, said, formSlot, note);
  // The button that saves or removes it from here; once the node did it, the form closes and what it did is said.
  const doneWith = (op, label, args, confirm = null) => doButton(app, { label, kind: 'presets.edit', args, busy: op === 'remove' ? t('drRemoving') : t('drSaving'),
    danger: op === 'remove', confirm, done: (reply) => {
      const result = reply.result || {};
      said.hidden = false;
      setText(said, t(op === 'remove' ? 'drPresetRemoved' : op === 'add' ? 'drPresetAdded' : 'drPresetSaved', { name: result.name || args().name })
        + (result.held ? ' ' + t('drPresetHeld') : ''));
      open = null;
      formSlot.replaceChildren();
      saved();
    } }).el;
  let drawn = '';
  // What the form edits: null (closed), { op: 'add' }, { op: 'edit', original } or { op: 'remove', original }.
  let open = null;

  function form() {
    const where = folder();
    if (open.op === 'remove') {
      const scoped = open.original.project ? where : null;
      const original = open.original;
      return h('div', { class: 'preset-form' }, h('p', { class: 'confirm-note' }, t(scoped ? 'drRemovesHere' : 'drRemovesAll', { name: original.name })),
        acts() ? doneWith('remove', t('drRemovePreset', { name: original.name }), () => presetEditArgs('remove', { name: original.name }, { folder: scoped, original }), t('drRemovePresetSure'))
          : copyLine(presetLine('remove', { name: original.name }, { folder: scoped, original }), t('drTheCommandThatRemovesIt')));
    }
    const original = open.original || null;
    const state = {
      name: original?.name || '', kind: original?.kind === 'shell' ? 'shell' : 'claude', args: original ? presetArgs(original) : '',
      keepShell: !!original?.keepShell, isDefault: false, env: [], unset: [], scoped: original ? !!original.project : !!where,
    };
    const name = kit.field({ class: 'answer-input', type: 'text', value: state.name, placeholder: t('drName'), 'aria-label': t('drPresetName'), spellcheck: 'false', autocomplete: 'off' });
    const args = kit.field({ class: 'answer-input', type: 'text', value: state.args, placeholder: t('drClaudeSArgumentsEG'), 'aria-label': t('drClaudeSArguments'), spellcheck: 'false', autocomplete: 'off' });
    const kinds = kit.segmented({ role: 'group', 'aria-label': t('drRuns') });
    const tick = (label, key, disabled = false) => {
      const box = kit.checkbox({ disabled });
      box.checked = state[key];
      box.addEventListener('change', () => { state[key] = box.checked; fill(); });
      return h('label', { class: 'preset-tick' }, box, ' ', label);
    };
    const variables = h('div', { class: 'preset-vars' });
    const lineSlot = h('div', { class: 'prompt-line' });
    const listId = 'preset-variables';
    const names = h('datalist', { id: listId }, PRESET_VARIABLES.map((variable) => h('option', { value: variable })));
    const addVariable = kit.button('quiet', { size: 's', onclick: () => { state.env.push(['', '']); drawVariables(); variables.querySelector('.preset-var:last-child input')?.focus(); } }, t('drAddAVariable'));

    function drawVariables() {
      const kept = (original?.env || []).map((variable) => {
        const off = state.unset.includes(variable);
        return h('span', { class: 'preset-chip' + (off ? ' off' : '') }, variable, kit.iconButton({
          'aria-label': t(off ? 'drKeepVar' : 'drTakeVar', { variable }), title: off ? t('drKeepIt') : t('drTakeItOff'),
          onclick: () => { state.unset = off ? state.unset.filter((one) => one !== variable) : [...state.unset, variable]; drawVariables(); fill(); },
        }, icon(off ? 'plus' : 'close', 11)));
      });
      const rows = state.env.map((pair, index) => {
        const key = kit.field({ class: 'answer-input', type: 'text', value: pair[0], placeholder: 'VARIABLE', list: listId, 'aria-label': t('drVariable'), spellcheck: 'false', autocomplete: 'off' });
        const value = kit.field({ class: 'answer-input', type: 'text', value: pair[1], placeholder: t('drValue'), 'aria-label': t('drValue'), spellcheck: 'false', autocomplete: 'off' });
        key.addEventListener('input', () => { state.env[index][0] = key.value.trim(); fill(); });
        value.addEventListener('input', () => { state.env[index][1] = value.value; fill(); });
        return h('div', { class: 'preset-var' }, key, value);
      });
      variables.replaceChildren(...(kept.length ? [h('div', { class: 'preset-chips' }, kept)] : []), ...rows);
    }

    function fill() {
      args.hidden = state.kind === 'shell';
      [...kinds.children].forEach((button) => button.setAttribute('aria-pressed', String(button.dataset.kind === state.kind)));
      const scoped = state.scoped && where ? where : null;
      const problem = presetProblem(state) || (state.isDefault && !scoped ? t('drADefaultIsAFolder') : null);
      if (problem) { lineSlot.replaceChildren(h('p', { class: 'confirm-note' }, problem)); return; }
      const line = presetLine(open.op, state, { folder: scoped, original });
      // An edit that changes nothing yet: the line with no change in it.
      const unchanged = original && presetLine('edit', { name: original.name, kind: original.kind, args: presetArgs(original), keepShell: original.keepShell }, { folder: scoped, original });
      const op = open.op;
      lineSlot.replaceChildren(op === 'edit' && line === unchanged
        ? h('p', { class: 'confirm-note' }, acts() ? t('drChangeSomethingToSave') : t('drChangeSomethingTheLineThat'))
        : acts() ? doneWith(op, op === 'add' ? t('drAddPreset') : t('drSavePreset'), () => presetEditArgs(op, state, { folder: scoped, original }))
          : copyLine(line, op === 'add' ? 'the command that adds it' : 'the command that changes it'));
    }

    kinds.replaceChildren(...[['claude', 'Claude'], ['shell', 'Shell']].map(([kind, label]) => kit.segment({
      'data-kind': kind, onclick: () => { state.kind = kind; fill(); },
    }, label)));
    name.addEventListener('input', () => { state.name = name.value; fill(); });
    args.addEventListener('input', () => { state.args = args.value; fill(); });
    drawVariables();
    const ticks = h('div', { class: 'preset-ticks' },
      open.op === 'add' ? tick(t('drOnlyForThisFolder'), 'scoped', !where) : null,
      tick(t('drAShellStaysWhenIt'), 'keepShell'),
      tick(t('drThisFolderSDefault'), 'isDefault', !where));
    const node = h('div', { class: 'preset-form' }, h('div', { class: 'new-fields' }, name, kinds, args), variables, addVariable, names, ticks, lineSlot);
    fill();
    return node;
  }

  function drawList(presets) {
    const mine = presets.filter((preset) => !preset.builtIn);
    list.replaceChildren(...mine.map((preset) => h('div', { class: 'preset-row' },
      h('span', { class: 'preset-name' }, preset.name), h('span', { class: 'preset-note' }, [presetNote(preset), preset.project ? t('drThisFolders') : t('drEveryFolders'), preset.refused ? t('drCantStart', { why: preset.refused }) : null].filter(Boolean).join(' · ')),
      h('span', { class: 'confirm-actions' },
        kit.button('quiet', { size: 's', onclick: () => { open = { op: 'edit', original: preset }; formSlot.replaceChildren(form()); formSlot.querySelector('input')?.focus(); } }, t('drEdit')),
        kit.button('quiet', { size: 's', onclick: () => { open = { op: 'remove', original: preset }; formSlot.replaceChildren(form()); formSlot.querySelector('.copy-button')?.focus(); } }, t('drRemove'))))),
    kit.button('quiet', { size: 's', onclick: () => { open = { op: 'add' }; formSlot.replaceChildren(form()); formSlot.querySelector('input')?.focus(); } }, t('drAddAPreset')));
  }

  return {
    el,
    update(presets, force = false) {
      const key = JSON.stringify([folder(), presets.map((preset) => [preset.name, preset.digest, preset.project, preset.refused])]);
      if (!force && key === drawn) return;
      const moved = drawn && key !== drawn;
      drawn = key;
      drawList(presets);
      // The folder or its presets changed under an open form: it closes, rather than edit what's no longer shown.
      if (moved || force) { open = null; formSlot.replaceChildren(); }
    },
  };
}

// The preset the form shows chosen once the node's list comes: the one you picked while it can start, else the first
// that can (the folder's default, as the node orders them). One the node refuses (a project's preset that takes a
// built-in's name, a variable a preset may not set) is never chosen for you.
export function presetChosen(presets, chosen, picked) {
  if (picked && presets.some((preset) => preset.name === chosen && !preset.refused)) return chosen;
  return presets.find((preset) => !preset.refused)?.name || chosen;
}

// A preset in a few words: what it runs, the variables it sets (by name), whether a shell stays.
export function presetNote(preset) {
  const parts = [];
  if (preset.kind === 'shell') parts.push(t('drAShell'));
  else if (preset.command) parts.push(t('drRunsCommand', { command: preset.command }));
  if (preset.env?.length) parts.push(t('drSets', { list: preset.env.join(', ') }));
  if (preset.keepShell) parts.push(t('drShellStays'));
  if (preset.default) parts.push(t('drFolderDefault'));
  return parts.join(' · ');
}
