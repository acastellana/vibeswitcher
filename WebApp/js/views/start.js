// The start page (the Mac's StartPage): what needs you, in one line, starting a session (the line that starts it in a
// terminal, views/drive.js), and the keys worth knowing.

import { h, setText, framed } from '../dom.js';
import { KEY } from '../words.js';
import { summary } from '../ui.js';
import { newSessionForm } from './drive.js';

export function startView(app) {
  const { store } = app;
  const title = h('h1', { class: 'start-title' });
  const sub = h('p', { class: 'start-sub' });
  const keys = [
    [`${KEY.mod}K`, 'Jump to any session or command'],
    [`${KEY.mod}J`, 'Next session needing you'],
    [`${KEY.alt}1–9`, 'Go to a session'],
    [`${KEY.alt}↓ ${KEY.alt}↑`, 'Next and previous session'],
    [`${KEY.alt}F`, 'Filter the list'],
    ['1–9', 'Pick that option on the focused question'],
  ];
  // The folder offered first: the most recent session's that the node's host runs, else the node's home.
  const folder = () => {
    const hosted = [...store.state.sessions.values()].filter((session) => session.hosted && session.cwd);
    hosted.sort((a, b) => String(b.startedAt || '').localeCompare(String(a.startedAt || '')));
    return hosted[0]?.cwd || store.state.node?.home || '';
  };
  const starting = newSessionForm(app, { folder });
  const el = h('section', { class: 'start', 'aria-label': 'Start page' },
    h('div', { class: 'start-column' }, title, sub, starting.el,
      h('dl', { class: 'keys' }, keys.map(([key, what]) => h('div', null, h('dt', null, h('kbd', null, key)), h('dd', null, what))))));

  function render() {
    const state = store.state;
    if (state.connection === 'connecting') {
      setText(title, 'VibeSwitcher');
      setText(sub, 'Connecting to the node…');
      starting.el.hidden = true;
      return;
    }
    if ((state.connection === 'unpaired' || state.connection === 'revoked') && state.sessions.size === 0) {
      setText(title, 'Not paired with a node');
      setText(sub, 'Run vibeswitcher web in a terminal, then open the address it prints in this browser.');
      starting.el.hidden = true;
      return;
    }
    starting.el.hidden = state.connection === 'unpaired' || state.connection === 'revoked';
    starting.update();
    const said = summary(state);
    const needs = [...state.sessions.values()].some((session) => session.status === 'needs-you');
    setText(title, state.sessions.size === 0 ? 'No sessions' : said ? said.charAt(0).toUpperCase() + said.slice(1) : 'Nothing needs you');
    setText(sub, state.sessions.size === 0 ? 'Sessions started on this node show here as they start.'
      : needs ? `${KEY.mod}J goes to the next one waiting on you.` : `Pick a session, or press ${KEY.mod}K to jump anywhere.`);
  }

  const schedule = framed(render);
  store.subscribe('sessions', schedule);
  store.subscribe('connection', schedule);
  render();
  return { el };
}
