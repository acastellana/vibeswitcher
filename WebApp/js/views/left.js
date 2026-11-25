// The left column, small and always there (the redesign's "Left"): the projects, each with a ring of its tasks by
// state and one line (`2 need you`, `4 in motion`, `quiet`); New project; at the bottom Your own sessions, This node
// and Settings; and a summary under them: what needs you, its count a link to the next place that waits, and Brief me.
// Nothing here moves to another column in any state.

import { h, s, setText, setClass } from '../dom.js';
import { icon } from '../marks.js';
import { projectsOf, teamCounts, waitingPlaces, nextPlace } from '../conversation.js';
import { projectHref, sessionHref } from '../ui.js';
import { t, lang } from '../i18n.js';
import { actsLine } from '../acting.js';
import { boostMarkText } from '../words.js';

// The ring's colours, in the order they go round: one meaning each, as everywhere on the page.
const RING = ['working', 'review', 'ready', 'blocked', 'queued'];

// A ring of `counts` by colour, `size` wide; an empty grey ring for a project with no tasks.
export function ring(counts, size = 28) {
  const total = RING.reduce((sum, tone) => sum + (counts[tone] || 0), 0);
  const r = size / 2 - 3;
  const length = 2 * Math.PI * r;
  const arcs = [];
  let offset = 0;
  for (const tone of RING) {
    const n = counts[tone] || 0;
    if (!n) continue;
    const arc = (length * n) / total;
    arcs.push(s('circle', { class: `ring-arc tone-${tone}`, cx: size / 2, cy: size / 2, r, 'stroke-dasharray': `${Math.max(arc - (total > 1 ? 2 : 0), 1)} ${length}`,
      'stroke-dashoffset': String(-offset), transform: `rotate(-90 ${size / 2} ${size / 2})` }));
    offset += arc;
  }
  return s('svg', { class: 'ring', width: size, height: size, viewBox: `0 0 ${size} ${size}`, 'aria-hidden': 'true' },
    s('circle', { class: 'ring-base', cx: size / 2, cy: size / 2, r }), ...arcs);
}

// The project's one line: what needs the user, else what moves, else quiet.
export function projectLine(project) {
  if (project.waiting) return { words: t('needYou', { n: project.waiting }), tone: 'asked' };
  if (project.board?.allDone && !project.board.allDone.seen) return { words: t('allDone'), tone: 'ready' };
  if (project.motion) return { words: t('inMotion', { n: project.motion }), tone: '' };
  return { words: project.lead && !project.live ? t('noLead') : t('quiet'), tone: 'quiet' };
}

export function leftColumn(app, { brief }) {
  const { store, ui } = app;
  const list = h('div', { class: 'projects', role: 'list' });
  const empty = h('p', { class: 'left-empty', hidden: true });
  const place = (route, iconName, key) => h('a', { class: 'place', href: route, data: { place: key } }, icon(iconName, 16), h('span', null, t(key)));
  const newProject = place('#/new', 'plus', 'newProject');
  const own = place('#/sessions', 'chat', 'ownSessions');
  // How many sessions are yours (plain), or, when some need you, how many in words ("1 needs you", in the asking colour).
  const ownWaiting = h('span', { class: 'place-waiting' });
  const ownCount = h('span', { class: 'place-count' });
  own.append(ownWaiting, ownCount);
  const nodeLink = place('#/node', 'node', 'thisNode');
  // The node's notices beside This node, in words ("1 notice"), and Boost while it's on (a bolt that opens Settings).
  const notices = h('span', { class: 'place-count tone-text-working' });
  nodeLink.append(notices);
  const boost = h('a', { class: 'icon-button boost-mark', href: '#/settings', hidden: true }, icon('bolt', 14));
  const places = [newProject, own, nodeLink, place('#/settings', 'settings', 'settings')];
  // The summary: what needs you, as a link to the next place that waits (another project, a session of yours, This
  // node); what moves; and Brief me.
  const summaryCount = h('a', { class: 'summary-count' });
  const summaryRest = h('span', { class: 'summary-rest' });
  const briefButton = h('button', { class: 'summary-brief', type: 'button', onclick: () => brief() }, icon('note', 14), t('briefMe'));
  const actsSlot = h('div', { class: 'acts-slot' });
  const summary = h('div', { class: 'left-summary' }, h('span', { class: 'summary-words' }, summaryCount, summaryRest), briefButton, actsSlot);
  let actsDrawn = '';
  const el = h('nav', { class: 'left', 'aria-label': t('projects') },
    h('div', { class: 'colhead' }, h('a', { class: 'brand', href: '#/' }, 'VibeSwitcher'), h('span', { class: 'grow' }), boost,
      // A phone has no ⌘K: the palette from the drawer's head.
      h('button', { class: 'icon-button phone-only palette-open', type: 'button', 'aria-label': t('paGoToASessionOr'), title: t('paGoToASessionOr'),
        onclick: () => { app.drawer?.(null); app.ui.setPalette(true); } }, icon('search', 16))),
    h('div', { class: 'colbody' }, h('h2', { class: 'col-title' }, t('projects')), list, empty, newProject, h('span', { class: 'left-gap' }), ...places.slice(1)),
    summary);
  const rows = new Map();

  function row(id) {
    const ringSlot = h('span', { class: 'project-ring' });
    const name = h('span', { class: 'project-name' });
    const line = h('span', { class: 'project-line' });
    const link = h('a', { class: 'project', role: 'listitem' }, ringSlot, h('span', { class: 'project-text' }, name, line));
    let drawnRing = '';
    return {
      el: link,
      update(project, selected) {
        link.setAttribute('href', projectHref(id));
        if (selected) link.setAttribute('aria-current', 'page'); else link.removeAttribute('aria-current');
        setText(name, project.name);
        link.title = project.root;
        const said = projectLine(project);
        setText(line, said.words);
        line.className = 'project-line' + (said.tone ? ` tone-text-${said.tone}` : '');
        const counts = teamCounts(project.board);
        const key = JSON.stringify(counts);
        if (key !== drawnRing) { drawnRing = key; ringSlot.replaceChildren(ring(counts)); }
        setClass(link, 'dim', !project.live && !project.waiting);
      },
    };
  }

  function render() {
    const state = store.state;
    const projects = projectsOf(state);
    const route = ui.state.route;
    const current = route.name === 'project' ? route.id : null;
    const next = new Map();
    let cursor = list.firstChild;
    for (const project of projects) {
      const r = rows.get(project.project) || row(project.project);
      next.set(project.project, r);
      r.update(project, project.project === current);
      if (r.el === cursor) cursor = cursor.nextSibling; else list.insertBefore(r.el, cursor);
    }
    for (const [id, r] of rows) if (!next.has(id)) r.el.remove();
    rows.clear();
    for (const [id, r] of next) rows.set(id, r);
    empty.hidden = projects.length > 0 || state.connection === 'connecting';
    setText(empty, t('noProjectsSub'));
    for (const placeLink of places) {
      if (!placeLink.dataset.place) continue;
      const on = { newProject: 'new', ownSessions: 'sessions', thisNode: 'node', settings: 'settings' }[placeLink.dataset.place] === route.name;
      if (on) placeLink.setAttribute('aria-current', 'page'); else placeLink.removeAttribute('aria-current');
    }
    const mine = [...state.sessions.values()].filter(ownSession);
    const waits = waitingPlaces(state, ownSession);
    const needs = waits.reduce((sum, place) => sum + place.count, 0);
    const moving = projects.reduce((sum, project) => sum + project.motion, 0);
    const upNext = nextPlace(waits, route);
    setText(summaryCount, needs ? t('needYouInAll', { n: needs }) : t('nothingNeedsYou'));
    if (upNext) {
      summaryCount.setAttribute('href', upNext.kind === 'project' ? projectHref(upNext.id) : upNext.kind === 'session' ? sessionHref(upNext.id) : '#/node');
      summaryCount.title = t('nextWaiting');
    } else { summaryCount.removeAttribute('href'); summaryCount.title = ''; }
    setClass(summaryCount, 'asked', needs > 0);
    setText(summaryRest, moving ? ` · ${t('inMotion', { n: moving })}` : '');
    // A page the node doesn't know (not paired, or its access taken back) knows nothing to count or brief.
    const off = state.connection === 'unpaired' || state.connection === 'revoked';
    summaryCount.hidden = off;
    summaryRest.hidden = off;
    briefButton.hidden = off || !store.can?.('brief');
    // Whether this page acts for the user, and since when, with the switch that turns it off.
    const actsKey = JSON.stringify([state.node?.web?.acts, store.acts(), state.phrase, lang()]);
    if (actsKey !== actsDrawn) { actsDrawn = actsKey; actsSlot.replaceChildren(...[actsLine(app, { compact: true })].filter(Boolean)); }
    // The places that hold what waits carry the asking colour, so the user sees where it is.
    const ownWaits = waits.filter((place) => place.kind === 'session').reduce((sum, place) => sum + place.count, 0);
    setClass(own, 'asked', ownWaits > 0);
    // Two numbers side by side read as nothing: what needs you, in words, else how many are yours.
    setText(ownWaiting, ownWaits ? t('ownWaiting', { n: ownWaits }) : '');
    ownWaiting.hidden = !ownWaits;
    setText(ownCount, !ownWaits && mine.length ? String(mine.length) : '');
    ownCount.hidden = !!ownWaits || !mine.length;
    own.title = mine.length ? t('owCount', { n: mine.length }) : '';
    setClass(nodeLink, 'asked', waits.some((place) => place.kind === 'node'));
    const count = state.node?.notices?.length || 0;
    setText(notices, count ? t('placeNotices', { n: count }) : '');
    notices.hidden = !count;
    const mark = boostMarkText(state.node?.boost);
    boost.hidden = !mark;
    if (mark) { boost.title = mark.help; boost.setAttribute('aria-label', mark.label); }
  }

  return { el, render };
}

// A session of the user's own: outside every project's team (no role), or a lead session that leads nothing now
// (one its project replaced, still running until the engine ends it).
export const ownSession = (session) => !session.role || (session.role === 'lead' && !session.lead);
