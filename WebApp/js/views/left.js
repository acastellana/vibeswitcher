// The left column, small and always there (the redesign's "Left"): the projects, each with a ring of its tasks by
// state and one line (`2 need you`, `4 in motion`, `quiet`); New project; at the bottom Your own sessions, This node
// and Settings; and a summary under them: what needs you, its count a link to the next place that waits, and Brief me.
// Nothing here moves to another column in any state.

import * as kit from '../kit.js';
import { h, s, setText, setClass } from '../dom.js';
import { icon } from '../marks.js';
import { projectsOf, teamCounts, waitingPlaces, nextPlace } from '../conversation.js';
import { projectHref, sessionHref } from '../ui.js';
import { t, lang } from '../i18n.js';
import { actsLine } from '../acting.js';
import { boostMarkText, STATES, stateOf, lastPart } from '../words.js';
import { queryWords, holdsAll } from './twocol.js';
import { typing, shownNow } from '../keys.js';

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

// The left column's filter (⌥F or /, or a letter typed in the column, js/keys.js): the projects and your own sessions
// whose name or folder holds every word, grouped by what needs you: those that do first, then the rest.
// [{ kind: 'project' | 'session', id, href, name, line: { words, tone }, needs }].
export function filterItems(state, query) {
  const words = queryWords(query);
  if (!words.length) return [];
  const projects = projectsOf(state).filter((one) => holdsAll(`${one.name} ${one.root}`, words))
    .map((one) => ({ kind: 'project', id: one.project, href: projectHref(one.project), name: one.name, line: projectLine(one), needs: one.waiting > 0, project: one }));
  const sessions = [...state.sessions.values()].filter(ownSession).map((one) => ({ one, word: stateOf(one), name: one.title || lastPart(one.cwd) || t('owASession') }))
    .filter(({ one, word, name }) => holdsAll(`${name} ${one.cwd || ''} ${STATES[word].label}`, words))
    .map(({ one, word, name }) => ({ kind: 'session', id: one.id, href: sessionHref(one.id), name, line: { words: STATES[word].label, tone: word === 'needs-you' ? 'asked' : '' }, needs: word === 'needs-you' }));
  const all = [...projects, ...sessions];
  return [...all.filter((item) => item.needs), ...all.filter((item) => !item.needs)];
}

// What the left column lists, in its order, for the keys (⌥1–9, next and previous): the filter's rows while it
// holds words, else the projects.
export function leftOrder(state, query = '') {
  if (queryWords(query).length) return filterItems(state, query);
  return projectsOf(state).map((one) => ({ kind: 'project', id: one.project, href: projectHref(one.project) }));
}


export function leftColumn(app, { brief }) {
  const { store, ui } = app;
  const list = h('div', { class: 'projects', role: 'list' });
  const empty = kit.empty({ tag: 'p', class: 'left-empty', hidden: true });
  // The filter's field and rows, over the projects (they stand in for them while it holds words).
  const filter = kit.field({ kind: 'search', class: 'left-filter', type: 'search', placeholder: t('lfPlaceholder'), 'aria-label': t('lfLabel'), autocomplete: 'off', spellcheck: 'false', hidden: true });
  const results = h('div', { class: 'left-results', hidden: true });
  const filterEmpty = kit.empty({ tag: 'p', class: 'left-empty', hidden: true });
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
  const boost = kit.iconButton({ tag: 'a', class: 'boost-mark', href: '#/settings', hidden: true }, icon('bolt', 14));
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
      kit.iconButton({ class: 'phone-only palette-open', 'aria-label': t('paGoToASessionOr'), title: t('paGoToASessionOr'),
        onclick: () => { app.drawer?.(null); app.ui.setPalette(true); } }, icon('search', 16))),
    h('div', { class: 'colbody' }, kit.sectionTitle('h2', { class: 'col-title' }, t('projects')), filter, results, filterEmpty, list, empty, newProject, h('span', { class: 'left-gap' }), ...places.slice(1)),
    summary);
  const rows = new Map();

  // The filter: hidden until asked for (its key, or a letter typed in the column); ↑ ↓ move in its rows, ↩ opens one,
  // Esc clears it.
  let query = '';
  let active = 0;
  const closeFilter = () => {
    query = '';
    filter.value = '';
    filter.hidden = true;
    render();
  };
  filter.addEventListener('input', () => { query = filter.value; active = 0; render(); });
  filter.addEventListener('keydown', (event) => {
    const items = filterItems(store.state, query);
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault();
      if (items.length) active = (active + (event.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
      render();
    } else if (event.key === 'Enter') {
      event.preventDefault();
      const chosen = items[active];
      if (chosen) { ui.go(chosen.href); closeFilter(); }
    } else if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation?.();
      closeFilter();
      list.querySelector?.('a')?.focus?.();
    }
  });
  // A letter typed while the keyboard is in the column (on a project, a place) starts the filter with it; / stays the
  // page's (the screen's own list search, else this filter, app.js).
  el.addEventListener('keydown', (event) => {
    if (typing(event.target) || event.ctrlKey || event.metaKey || event.altKey || event.key?.length !== 1 || !/\S/.test(event.key) || event.key === '/') return;
    event.preventDefault();
    focusFilter(event.key);
  });
  function focusFilter(initial = null) {
    filter.hidden = false;
    if (initial != null) { filter.value = initial; query = initial; active = 0; }
    render();
    filter.focus?.();
    if (initial == null) filter.select?.();
  }

  function drawResults(route) {
    const items = filterItems(store.state, query);
    if (active >= items.length) active = 0;
    const groups = [['needs', t('lfNeedsYou'), items.filter((item) => item.needs)], ['rest', t('lfTheRest'), items.filter((item) => !item.needs)]];
    let index = 0;
    results.replaceChildren(...groups.filter(([, , shown]) => shown.length).flatMap(([key, title, shown]) => [
      h('h3', { class: `left-group ${key}` }, title),
      ...shown.map((item) => {
        const at = index++;
        const link = h('a', { class: 'project left-result' + (at === active ? ' active' : '') + (item.line.tone === 'asked' ? ' asked' : ''), href: item.href,
          'aria-current': shownNow(item, route) ? 'page' : null, onclick: () => closeFilter() },
        item.kind === 'project' ? h('span', { class: 'project-ring' }, ring(teamCounts(item.project.board))) : h('span', { class: 'project-ring' }, icon('chat', 16)),
        h('span', { class: 'project-text' }, h('span', { class: 'project-name' }, item.name),
          h('span', { class: 'project-line' + (item.line.tone ? ` tone-text-${item.line.tone}` : '') }, item.line.words)));
        if (!shownNow(item, route)) link.removeAttribute('aria-current');
        return link;
      })]));
    filterEmpty.hidden = items.length > 0;
    setText(filterEmpty, items.length ? '' : t('lfNoMatch', { query: query.trim() }));
  }

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
    // While the filter holds words, its rows stand in for the projects.
    const filtering = queryWords(query).length > 0;
    list.hidden = filtering;
    results.hidden = !filtering;
    if (filtering) drawResults(route); else filterEmpty.hidden = true;
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
    empty.hidden = filtering || projects.length > 0 || state.connection === 'connecting';
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

  return { el, render, focusFilter: () => focusFilter(), order: () => leftOrder(store.state, query) };
}

// A session of the user's own: outside every project's team (no role), or a lead session that leads nothing now
// (one its project replaced, still running until the engine ends it).
export const ownSession = (session) => !session.role || (session.role === 'lead' && !session.lead);
