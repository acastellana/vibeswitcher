// The selected session: its header (who, what state, where), then a lead's team strip and one pane of Chat or
// Terminal, with the inspector beside them (the Mac's window: session | inspector). The terminal is the session's
// screen where the node opens one (views/terminal.js), and says to use the session's own terminal elsewhere.

import { h, setText, setClass, framed, motionOK } from '../dom.js';
import { agentMark, statusMark, setMark, icon } from '../marks.js';
import { STATES, ROLES, stateOf, since, tilde, KEY, AGENTS } from '../words.js';
import { projectOf } from '../ui.js';
import { chatView } from './chat.js';
import { teamStrip } from './lead.js';
import { inspector } from './inspector.js';
import { terminalView } from './terminal.js';

const PANES = [
  { id: 'terminal', label: 'Terminal', key: '1' },
  { id: 'chat', label: 'Chat', key: '2' },
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
  const tabs = PANES.map((pane) => h('button', {
    type: 'button', title: `${pane.label} (${KEY.mod}${KEY.alt}${pane.key})`,
    onclick: () => ui.setPane(ui.state.route.id, pane.id),
  }, pane.label));
  // Quiet, at the header's end, where it stays whether the inspector is open or not.
  const toggle = h('button', {
    class: 'icon-button inspect-toggle', type: 'button', 'aria-label': 'Inspector', 'aria-controls': 'inspector', 'aria-expanded': 'false',
    title: `Toggle Inspector (${KEY.mod}${KEY.alt}0)`, onclick: () => ui.toggleInspector(),
  }, icon('inspector', 16));
  const head = h('header', { class: 'head' },
    h('a', { class: 'back icon-button', href: '#/', 'aria-label': 'Sessions' }, icon('back', 16)),
    markSlot,
    h('div', { class: 'head-text' }, h('div', { class: 'head-line' }, title, state), place),
    h('div', { class: 'segmented', role: 'group', 'aria-label': 'Show' }, tabs),
    toggle);

  const strip = teamStrip(app);
  const chat = chatView(app);
  const inspect = inspector(app);
  const term = terminalView(app);
  const terminal = term.el;
  const gone = h('div', { class: 'pane', hidden: true },
    h('div', { class: 'placeholder' }, h('h2', null, 'This session isn’t here any more'), h('p', null, 'It ended, or its link is from another node.'), h('a', { class: 'button quiet', href: '#/' }, 'Start Page')));
  const loading = h('div', { class: 'pane head-skeleton', hidden: true, 'aria-hidden': 'true' }, h('span', { class: 'bone wide' }), h('span', { class: 'bone' }), h('span', { class: 'bone short' }));
  // The session's own column, and the inspector over its right edge: open as a column, the session's column gives
  // it the room (style.css), so the inspector itself never moves anything.
  const body = h('div', { class: 'session-body' }, h('div', { class: 'session-main' }, strip.el, chat.el, terminal), inspect.scrim, inspect.el);
  const el = h('section', { class: 'session', 'aria-label': 'Session' }, head, body, gone, loading);

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
    if (!session) {
      // It ended and left the list (or the link is another node's): its stream went with it on the node.
      if (!connecting) term.hide({ gone: true });
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
    setText(place, [ROLES[session.role], tilde(session.cwd, store.state.node?.home) || 'No folder', AGENTS[session.agent], session.hosted ? null : `in another terminal (${session.terminal})`].filter(Boolean).join('  ·  '));

    const isLead = session.role === 'lead';
    // A lead's Team strip only where the feed follows boards: the node doesn't send them yet.
    const hasBoard = isLead && store.follows('boards');
    const pane = ui.pane(id) === 'terminal' ? 'terminal' : 'chat';
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
  for (const topic of ['sessions', 'leads', 'boards', 'connection']) store.subscribe(topic, schedule);
  ui.subscribe((what) => { if (what === 'route' || what === 'pane' || what === 'inspector') render(); });
  document.addEventListener('visibilitychange', schedule);
  render();

  return { el, focusComposer: () => chat.focus() };
}
