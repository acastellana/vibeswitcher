// The start page (the Mac's StartPage): what needs you, in one line, starting a session (the line that starts it in a
// terminal, views/drive.js), your recent projects (each with the lines that start a session or its lead there), your
// sessions that ended lately (each with the line that resumes it and its conversation's id to copy), and the keys
// worth knowing. Nothing here starts anything: each line is copied and run in a terminal.

import { h, setText, framed } from '../dom.js';
import { KEY, tilde, lastPart } from '../words.js';
import { summary } from '../ui.js';
import { newSessionForm, newLeadForm } from './drive.js';
import { resumeLine, recentProjects, projectLines } from '../actions.js';
import { boardHref } from '../ui.js';
import { copyLine } from './cards.js';

// How many ended sessions the page lists (the node keeps 20).
const ENDED_SHOWN = 5;

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
  const leading = newLeadForm(app);
  // Your sessions that ended lately (the node's `ended`): the line that resumes one, and its conversation's id.
  const endedList = h('div', { class: 'ended-list' });
  const ended = h('section', { class: 'ended', 'aria-label': 'Ended lately', hidden: true },
    h('h2', { class: 'new-title' }, 'Ended lately'), endedList,
    h('p', { class: 'confirm-note' }, 'Run the line in a terminal on this node: it asks for a code, then starts it again in its same conversation.'));
  let endedDrawn = '';
  function drawEnded() {
    const list = (store.state.node?.ended || []).slice(0, ENDED_SHOWN);
    const key = JSON.stringify(list);
    if (key === endedDrawn) return;
    endedDrawn = key;
    ended.hidden = list.length === 0;
    const home = store.state.node?.home;
    endedList.replaceChildren(...list.map((entry) => h('div', { class: 'ended-row' },
      h('div', { class: 'ended-name' }, h('span', null, entry.name || 'A session'), h('span', { class: 'ended-folder' }, tilde(entry.folder, home))),
      entry.conversation ? copyLine(resumeLine(entry), 'the command that resumes it')
        : h('p', { class: 'confirm-note' }, 'Its conversation id wasn’t known: it can’t be resumed.'),
      entry.conversation ? copyLine(entry.conversation, 'its conversation id') : null)));
  }
  // Recent projects (the Mac's StartPage): each folder with the lines that start a session or its lead there, to copy.
  const recentList = h('div', { class: 'ended-list' });
  const recent = h('section', { class: 'ended recent', 'aria-label': 'Recent projects', hidden: true },
    h('h2', { class: 'new-title' }, 'Recent projects'), recentList,
    h('p', { class: 'confirm-note' }, 'Run a line in a terminal on this node: it asks for a code, then starts it.'));
  let known = null;
  let recentDrawn = '';
  let recentAsked = false;
  function askRecent() {
    if (recentAsked || !store.can?.('recent')) return;
    recentAsked = true;
    store.request('recent', {}).then((reply) => {
      if (reply.ok) { known = reply.result.projects; drawRecent(); } else recentAsked = false;
    });
  }
  function drawRecent() {
    const state = store.state;
    const rows = recentProjects(known, state.sessions.values(), state.node?.ended || [], state.leads.values());
    const key = JSON.stringify([rows, state.node?.home]);
    if (key === recentDrawn) return;
    recentDrawn = key;
    recent.hidden = rows.length === 0;
    const home = state.node?.home;
    recentList.replaceChildren(...rows.map((row) => {
      const lines = projectLines(row);
      return h('div', { class: 'ended-row' },
        h('div', { class: 'ended-name' }, h('span', null, lastPart(row.folder) || row.folder), h('span', { class: 'ended-folder' }, tilde(row.folder, home))),
        copyLine(lines.session, `the command that starts a session in ${lastPart(row.folder)}`),
        lines.lead ? copyLine(lines.lead, `the command that starts its project lead`)
          : h('a', { class: 'link', href: boardHref(row.lead) }, 'Its lead runs: open its board'));
    }));
  }
  const el = h('section', { class: 'start', 'aria-label': 'Start page' },
    h('div', { class: 'start-column' }, title, sub, starting.el, leading.el, recent, ended,
      h('dl', { class: 'keys' }, keys.map(([key, what]) => h('div', null, h('dt', null, h('kbd', null, key)), h('dd', null, what))))));

  function render() {
    const state = store.state;
    if (state.connection === 'connecting') {
      setText(title, 'VibeSwitcher');
      setText(sub, 'Connecting to the node…');
      starting.el.hidden = true;
      leading.el.hidden = true;
      return;
    }
    if ((state.connection === 'unpaired' || state.connection === 'revoked') && state.sessions.size === 0) {
      setText(title, 'Not paired with a node');
      setText(sub, 'Run vibeswitcher web in a terminal, then open the address it prints in this browser.');
      starting.el.hidden = true;
      leading.el.hidden = true;
      return;
    }
    starting.el.hidden = state.connection === 'unpaired' || state.connection === 'revoked';
    leading.el.hidden = starting.el.hidden;
    starting.update();
    drawEnded();
    if (state.connection === 'live') askRecent();
    drawRecent();
    const said = summary(state);
    const needs = [...state.sessions.values()].some((session) => session.status === 'needs-you');
    setText(title, state.sessions.size === 0 ? 'No sessions' : said ? said.charAt(0).toUpperCase() + said.slice(1) : 'Nothing needs you');
    setText(sub, state.sessions.size === 0 ? 'Sessions started on this node show here as they start.'
      : needs ? `${KEY.mod}J goes to the next one waiting on you.` : `Pick a session, or press ${KEY.mod}K to jump anywhere.`);
  }

  const schedule = framed(render);
  store.subscribe('sessions', schedule);
  store.subscribe('connection', schedule);
  store.subscribe('node', schedule);
  store.subscribe('leads', schedule);
  render();
  // The palette's "New … in …": the start page with that folder and preset in its form.
  // The palette's "Start Project Lead in …": the start page with that folder in the lead's form.
  return { el, choose: (folder, preset) => starting.choose(folder, preset), lead: (folder) => leading.choose(folder) };
}
