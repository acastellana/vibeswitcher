// The selected session: its header (who, what state, where), a lead's team strip, and one pane of Chat, Terminal or
// Team. The terminal is a placeholder in this slice.

import { h, setText, setClass, framed } from '../dom.js';
import { agentMark, statusMark, setMark, icon } from '../marks.js';
import { STATES, stateOf, since, tilde, KEY, AGENTS } from '../words.js';
import { projectOf } from '../ui.js';
import { chatView } from './chat.js';
import { teamStrip, teamPane } from './lead.js';

const PANES = [
  { id: 'terminal', label: 'Terminal', key: '1' },
  { id: 'chat', label: 'Chat', key: '2' },
  { id: 'team', label: 'Team', key: '3' },
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
  const head = h('header', { class: 'head' },
    h('a', { class: 'back icon-button', href: '#/', 'aria-label': 'Sessions' }, icon('back', 16)),
    markSlot,
    h('div', { class: 'head-text' }, h('div', { class: 'head-line' }, title, state), place),
    h('div', { class: 'segmented', role: 'group', 'aria-label': 'Show' }, tabs));

  const strip = teamStrip(app);
  const chat = chatView(app);
  const team = teamPane(app);
  const terminalSays = h('p', null, 'The live terminal comes to this page in a later build.');
  const showChat = h('button', { class: 'button quiet', type: 'button', onclick: () => ui.setPane(ui.state.route.id, 'chat') }, 'Show Chat');
  const terminal = h('div', { class: 'pane terminal-pane' },
    h('div', { class: 'placeholder' }, icon('terminal', 22), h('h2', null, 'Terminal'), terminalSays, showChat));
  const gone = h('div', { class: 'pane', hidden: true },
    h('div', { class: 'placeholder' }, h('h2', null, 'This session isn’t here any more'), h('p', null, 'It ended, or its link is from another node.'), h('a', { class: 'button quiet', href: '#/' }, 'Start Page')));
  const loading = h('div', { class: 'pane head-skeleton', hidden: true, 'aria-hidden': 'true' }, h('span', { class: 'bone wide' }), h('span', { class: 'bone' }), h('span', { class: 'bone short' }));
  const el = h('section', { class: 'session', 'aria-label': 'Session' }, head, strip.el, chat.el, terminal, team.el, gone, loading);

  let shownAgent = null;
  let shownPane = null;
  let seenTimer = null;

  function render() {
    if (ui.state.route.name !== 'session') return;
    const id = ui.state.route.id;
    const session = store.state.sessions.get(id);
    const connecting = store.state.connection === 'connecting';
    loading.hidden = !connecting;
    gone.hidden = connecting || !!session;
    for (const part of [head, strip.el, chat.el, terminal, team.el]) part.hidden = !session;
    if (!session) return;

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
    const role = session.role === 'lead' ? 'Lead' : session.role === 'worker' ? 'Worker' : session.role === 'verifier' ? 'Verifier' : null;
    setText(place, [role, tilde(session.cwd, store.state.node?.home) || 'No folder', AGENTS[session.agent], session.hosted ? null : `in another terminal (${session.terminal})`].filter(Boolean).join('  ·  '));

    const isLead = session.role === 'lead';
    // A lead's board (its Team strip and pane) only where the feed follows boards: the node doesn't send them yet.
    const hasTeam = isLead && store.follows('boards');
    let pane = ui.pane(id);
    if (pane === 'team' && !hasTeam) pane = 'chat';
    tabs.forEach((tab, index) => {
      tab.hidden = PANES[index].id === 'team' && !hasTeam;
      tab.setAttribute('aria-pressed', String(PANES[index].id === pane));
    });
    strip.el.hidden = !hasTeam || pane === 'team';
    if (hasTeam) {
      strip.update(session);
      team.update(session);
    }
    // Until the page follows a chat, the terminal's placeholder doesn't send you to one.
    const chatFollowed = store.can('chat');
    showChat.hidden = !chatFollowed;
    setText(terminalSays, chatFollowed ? 'The live terminal comes to this page in a later build. Until then, the session’s conversation is in Chat.'
      : 'The live terminal comes to this page in a later build.');
    chat.el.hidden = pane !== 'chat';
    terminal.hidden = pane !== 'terminal';
    team.el.hidden = pane !== 'team';
    chat.show(id);
    if (shownPane !== id + pane) {
      shownPane = id + pane;
      if (pane === 'chat') chat.reveal();
    }
    setClass(el, 'is-lead', isLead);

    // A finished turn you've now looked at is idle ("finished and already seen").
    clearTimeout(seenTimer);
    if (word === 'done' && document.visibilityState === 'visible' && store.can('seen')) {
      seenTimer = setTimeout(() => { if (ui.state.route.id === id) store.request('seen', { session: id }); }, 1500);
    }
  }

  const schedule = framed(render);
  for (const topic of ['sessions', 'leads', 'boards', 'connection']) store.subscribe(topic, schedule);
  ui.subscribe((what) => { if (what === 'route' || what === 'pane') render(); });
  document.addEventListener('visibilitychange', schedule);
  render();

  return { el, focusComposer: () => chat.focus() };
}
