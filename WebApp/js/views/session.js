// The selected session: its header (who, what state, where), then a lead's team strip and one pane of Chat or
// Terminal, with the inspector beside them (the Mac's window: session | inspector). The terminal is the session's
// screen where the node opens one (views/terminal.js), and says to use the session's own terminal elsewhere.

import * as kit from '../kit.js';
import { h, setText, setClass, framed, motionOK } from '../dom.js';
import { agentMark, statusMark, setMark, icon } from '../marks.js';
import { STATES, ROLES, stateOf, since, tilde, KEY, AGENTS, clock } from '../words.js';
import { projectOf, projectHref } from '../ui.js';
import { chatView } from './chat.js';
import { teamStrip } from './lead.js';
import { inspector } from './inspector.js';
import { terminalView } from './terminal.js';
import { actionsStrip, resumeOrLine } from './drive.js';
import { actsFor } from '../acting.js';
import { endedEntry, resumeLine } from '../actions.js';
import { t } from '../i18n.js';

const PANES = [
  { id: 'terminal', label: t('seTerminal'), key: '1' },
  { id: 'chat', label: t('seChat'), key: '2' },
];

export function sessionView(app) {
  const { store, ui } = app;
  const markSlot = h('span', { class: 'head-agent' });
  const title = h('h1', { class: 'head-title' });
  const stateMark = statusMark('unknown', 10);
  const stateWord = h('span');
  const stateTime = h('time');
  const state = h('span', { class: 'head-state' }, stateMark, stateWord, stateTime);
  const place = h('p', { class: 'head-place' });
  const tabs = PANES.map((pane) => kit.segment({
    title: `${pane.label} (${KEY.mod}${KEY.alt}${pane.key})`,
    onclick: () => ui.setPane(ui.state.route.id, pane.id),
  }, pane.label));
  // Quiet, at the header's end, where it stays whether the inspector is open or not.
  const toggle = kit.iconButton({
    class: 'inspect-toggle', 'aria-label': t('seInspector'), 'aria-controls': 'inspector', 'aria-expanded': 'false',
    title: `${t('seToggleInspector')} (${KEY.mod}${KEY.alt}0)`, onclick: () => ui.toggleInspector(),
  }, icon('inspector', 16));
  // Renaming, pausing, ending a session and the rest of the Mac's row menu: the line that does each, under the header.
  const acting = actionsStrip(app);
  // On a phone (style.css's 760 px) its three dots, the words its name.
  const end = kit.button('plain', { class: 'end-button', title: t('seRenamePauseOrEndThis'), 'aria-label': t('seActions'), onclick: () => acting.toggle() },
    icon('more', 16), h('span', { class: 'end-words' }, t('seActions')));
  // On a phone the header is one row: Terminal | Chat is this one button, the other pane's, and only where the node
  // gives this session a terminal (a tab that says the terminal comes later leads nowhere there).
  const paneToggle = kit.iconButton({ class: 'pane-toggle', onclick: () => {
    const id = ui.state.route.id;
    ui.setPane(id, ui.pane(id) === 'terminal' ? 'chat' : 'terminal');
  } });
  let toggleShows = null;
  const phoneQuery = globalThis.matchMedia?.('(max-width: 760px)');
  const phone = () => !!phoneQuery?.matches;
  phoneQuery?.addEventListener?.('change', () => render());
  // The node opens this session's terminal to this page: its kind, a session its host runs, a feed with frames.
  const terminalOffered = (session) => session.hosted !== false && store.can('term.open') && store.watches?.() !== false
    && typeof app.feed?.sendBinary === 'function' && typeof app.feed?.onBinary === 'function';
  // Back: to the project a team's session works for, else to Your own sessions (on a phone it opens the left column).
  const back = kit.iconButton({ tag: 'a', class: 'back', href: '#/sessions', 'aria-label': t('seBack') }, icon('back', 16));
  const head = h('header', { class: 'head' },
    back,
    markSlot,
    h('div', { class: 'head-text' }, h('div', { class: 'head-line' }, title, state), place),
    end,
    kit.segmented({ role: 'group', 'aria-label': t('seShow') }, tabs),
    paneToggle,
    toggle);

  const strip = teamStrip(app);
  const chat = chatView(app);
  const inspect = inspector(app);
  const term = terminalView(app);
  const terminal = term.el;
  // A session that ended lately (the node's `ended`) says so, with the line that resumes it where its conversation is known.
  const goneWhy = h('p', null, t('seItEndedOrItsLink'));
  const goneResume = h('div', { class: 'gone-resume', hidden: true });
  // How it ended, as the host recorded it (the Mac's inspector's Exit): "exited 0 at 10:42", "killed by SIGTERM at 10:42".
  const goneExit = h('p', { class: 'gone-exit', hidden: true });
  const gone = h('div', { class: 'pane', hidden: true },
    kit.empty({ size: 'page', class: 'placeholder' }, h('h2', null, t('seThisSessionIsnTHere')), goneWhy, goneExit, goneResume, kit.button('plain', { tag: 'a', href: '#/' }, t('seStartPage'))));
  let goneDrawn = '';
  function drawGone(id) {
    const entry = endedEntry(store.state.node, id);
    const key = JSON.stringify([entry, store.acts(), store.can('session.resume')]);
    if (key === goneDrawn) return;
    goneDrawn = key;
    const line = resumeLine(entry);
    // Where the page acts and the node lists `session.resume`, Resume starts it again from here (views/drive.js).
    const acts = !!line && actsFor(app, 'session.resume');
    setText(goneWhy, !entry ? t('seItEndedOrItsLink')
      : acts ? t('seItEndedResume') : line ? t('seItEndedThisStartsIt') : t('seItEndedAndItsConversation'));
    goneExit.hidden = !entry?.exit;
    setText(goneExit, entry?.exit ? t('seExit', { cause: entry.exit.cause, time: clock(entry.exit.at) }) : '');
    goneResume.hidden = !line;
    goneResume.replaceChildren(...(line ? resumeOrLine(app, entry) : []));
  }
  const loading = h('div', { class: 'pane head-skeleton', hidden: true, 'aria-hidden': 'true' }, h('span', { class: 'bone wide' }), h('span', { class: 'bone' }), h('span', { class: 'bone short' }));
  // The session's own column, and the inspector over its right edge: open as a column, the session's column gives
  // it the room (style.css), so the inspector itself never moves anything.
  const body = h('div', { class: 'session-body' }, h('div', { class: 'session-main' }, strip.el, chat.el, terminal), inspect.scrim, inspect.el);
  const el = h('section', { class: 'session', 'aria-label': t('seSession') }, head, acting.el, body, gone, loading);
  // On a phone the messages waiting to go in and the draft over the box are a line each (style.css): a touch on one,
  // not on its buttons, opens it whole, and again folds it.
  body.addEventListener('click', (event) => {
    const box = event.target.closest?.('.composer-draft');
    if (!box || !phone() || event.target.closest?.('button, a, input, textarea, select')) return;
    box.classList.toggle('open');
  });

  let shownAgent = null;
  let shownPane = null;
  let seenTimer = null;
  let placed = false;
  let sheet = false;

  // The room the inspector's column takes comes and goes in one step, and what is centred in the session's column
  // glides to its new place (a transform, no layout per frame). A chat at its end stays there.
  function glide(work) {
    const moving = placed && motionOK() && !body.hidden
      ? [...body.querySelectorAll('.chat-column, .composer, .composer-hint, .placeholder, .latest')].filter((node) => node.offsetParent !== null) : [];
    const before = moving.map((node) => node.getBoundingClientRect().left);
    chat.hold(work);
    moving.forEach((node, index) => {
      const delta = before[index] - node.getBoundingClientRect().left;
      if (Math.abs(delta) >= 1) node.animate([{ transform: `translateX(${delta}px)` }, { transform: 'none' }], { duration: 160, easing: 'cubic-bezier(.2,.8,.2,1)' });
    });
  }

  function placeInspector() {
    const shown = ui.inspectorShown();
    const column = shown && ui.inspectorWide();
    toggle.setAttribute('aria-expanded', String(shown));
    if (el.classList.contains('with-inspector') !== column) glide(() => setClass(el, 'with-inspector', column));
    const wasSheet = sheet;
    sheet = shown && !column;
    setClass(el, 'inspector-sheet', sheet);
    placed = true;
    return wasSheet;
  }

  function render() {
    if (ui.state.route.name !== 'session') return;
    const id = ui.state.route.id;
    const session = store.state.sessions.get(id);
    const connecting = store.state.connection === 'connecting';
    loading.hidden = !connecting;
    gone.hidden = connecting || !!session;
    for (const part of [head, body]) part.hidden = !session;
    end.hidden = !acting.update(session, store.state.node);
    if (!session) {
      // It ended and left the list (or the link is another node's): its stream went with it on the node.
      if (!connecting) term.hide({ gone: true });
      drawGone(id);
      return;
    }

    const word = stateOf(session);
    if (shownAgent !== session.agent) {
      shownAgent = session.agent;
      markSlot.replaceChildren(agentMark(session.agent, 26));
    }
    setText(title, session.title || projectOf(session));
    setMark(stateMark, word);
    state.className = `head-state tone-text-${word}`;
    setText(stateWord, STATES[word].label);
    // No duration where the node knows no moment the status began (the clock skips an element without one).
    if (session.since) stateTime.dataset.since = session.since; else delete stateTime.dataset.since;
    setText(stateTime, since(session.since));
    stateTime.hidden = !session.since;
    setText(place, [ROLES[session.role], tilde(session.cwd, store.state.node?.home) || t('seNoFolder'), AGENTS[session.agent], session.hosted ? null : t('seOtherTerminal', { terminal: session.terminal })].filter(Boolean).join('  ·  '));

    back.setAttribute('href', session.lead ? projectHref(session.lead) : '#/sessions');
    const isLead = session.role === 'lead';
    // A lead's Team strip only where the feed follows boards: the node doesn't send them yet.
    const hasBoard = isLead && store.follows('boards');
    const offered = terminalOffered(session);
    setClass(el, 'no-terminal', !offered);
    // On a phone with no terminal to show, the chat.
    const pane = ui.pane(id) === 'terminal' && (offered || !phone()) ? 'terminal' : 'chat';
    const other = pane === 'terminal' ? 'chat' : 'terminal';
    if (toggleShows !== other) {
      toggleShows = other;
      paneToggle.replaceChildren(icon(other, 16));
      paneToggle.setAttribute('aria-label', other === 'terminal' ? t('seTerminal') : t('seChat'));
    }
    tabs.forEach((tab, index) => tab.setAttribute('aria-pressed', String(PANES[index].id === pane)));
    strip.el.hidden = !hasBoard;
    if (hasBoard) strip.update(session);
    chat.el.hidden = pane !== 'chat';
    terminal.hidden = pane !== 'terminal';
    chat.show(id);
    if (pane === 'terminal') term.show(id); else term.hide();
    if (shownPane !== id + pane) {
      shownPane = id + pane;
      if (pane === 'chat') chat.reveal();
      else term.focus();
    }
    setClass(el, 'is-lead', isLead);

    const wasSheet = placeInspector();
    inspect.update(session);
    // A sheet takes the focus as it opens, and gives it back to its button as it closes.
    if (sheet && !wasSheet) inspect.focus();
    else if (wasSheet && !sheet && (inspect.el.contains(document.activeElement) || document.activeElement === document.body)) toggle.focus({ preventScroll: true });

    // A finished turn you've now looked at is idle ("finished and already seen").
    clearTimeout(seenTimer);
    if (word === 'done' && document.visibilityState === 'visible' && store.can('seen')) {
      seenTimer = setTimeout(() => { if (ui.state.route.id === id) store.request('seen', { session: id }); }, 1500);
    }
  }

  const schedule = framed(render);
  for (const topic of ['sessions', 'leads', 'boards', 'connection', 'node']) store.subscribe(topic, schedule);
  ui.subscribe((what) => { if (what === 'route' || what === 'pane' || what === 'inspector') render(); });
  document.addEventListener('visibilitychange', schedule);
  render();

  return {
    el, focusComposer: () => chat.focus(), act: (tab) => acting.open(tab),
    // The chat's own commands, its pane shown first.
    chat: (command) => {
      const id = ui.state.route.id;
      if (ui.pane(id) === 'terminal') ui.setPane(id, 'chat');
      requestAnimationFrame(() => chat[command]());
    },
  };
}
