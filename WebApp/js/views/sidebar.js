// The session list (the Mac's SessionListView): Attention or Projects on top, the sessions grouped under quiet
// headers, a filter and one line of summary at the foot. A row leads with its status's shape and says the state in
// the glossary's words; only "needs you" takes colour.

import { h, keyed, setText, setClass, framed } from '../dom.js';
import { sessionMark, icon } from '../marks.js';
import { STATES, stateOf, since, plural } from '../words.js';
import { arrange, summary, sessionHref, projectOf, teamSummary } from '../ui.js';

function sessionRow(app) {
  const mark = sessionMark(20);
  const role = h('span', { class: 'role' });
  const lead = h('span', { class: 'lead-tag' }, 'Lead');
  const title = h('span', { class: 'row-title' });
  const time = h('time', { class: 'row-time' });
  const project = h('span', { class: 'row-project' });
  const state = h('span', { class: 'row-state' });
  const asks = h('span', { class: 'row-asks' }, icon('question', 12), h('span'));
  const teamText = h('span');
  const team = h('button', { class: 'team-toggle', type: 'button' }, teamText, icon('chevron', 9));
  const link = h('a', { class: 'row-link' },
    h('span', { class: 'row-line' }, lead, title, time),
    h('span', { class: 'row-line sub' }, project, state, asks));
  const el = h('li', { class: 'row' }, role, mark.el, h('div', { class: 'row-text' }, link, team));
  let id = null;
  team.addEventListener('click', () => app.ui.toggleTeam(id));

  return {
    el,
    update({ session, nested, team: members, open }) {
      id = session.id;
      const word = stateOf(session);
      const selected = app.ui.state.route.name === 'session' && app.ui.state.route.id === session.id;
      mark.update(word, session.agent);
      link.setAttribute('href', sessionHref(session.id));
      if (selected) link.setAttribute('aria-current', 'page'); else link.removeAttribute('aria-current');
      setClass(el, 'selected', selected);
      setClass(el, 'nested', nested);
      setClass(el, 'dim', word === 'paused' || word === 'ended');
      role.replaceChildren(...(nested ? [icon(session.role === 'verifier' ? 'verifier' : 'worker', 11)] : []));
      role.hidden = !nested;
      lead.hidden = session.role !== 'lead';
      setText(title, session.title || projectOf(session));
      time.dataset.since = session.since;
      setText(time, since(session.since));
      const showProject = app.ui.state.grouping === 'attention' && !nested;
      project.hidden = !showProject;
      setText(project, projectOf(session));
      // What it's doing when it says, else the state's word.
      const text = (word === 'working' || word === 'background') && session.detail ? session.detail : STATES[word].one;
      setText(state, text);
      setClass(state, 'needs', word === 'needs-you');
      const questions = session.role === 'lead' ? app.store.state.leads.get(session.lead)?.questions : null;
      asks.hidden = !(questions?.open > 0);
      if (questions?.open > 0) {
        setText(asks.lastChild, String(questions.open));
        setClass(asks, 'blocking', questions.blocking > 0);
        asks.title = plural(questions.open, 'question') + ' for you' + (questions.blocking > 0 ? ` (${questions.blocking} blocking)` : '');
      }
      team.hidden = !members.length;
      if (members.length) {
        setText(teamText, teamSummary(app.store.state.boards.get(session.lead)) || plural(members.length, 'session'));
        team.setAttribute('aria-expanded', String(open));
        team.title = open ? 'Hide the team' : 'Show the team';
      }
      // One sentence for a screen reader, as the Mac's row has: "Lead: Sync…, example-site, Claude, needs you".
      const spoken = [
        (nested ? (session.role === 'verifier' ? 'Verifier: ' : 'Worker: ') : session.role === 'lead' ? 'Lead: ' : '') + (session.title || projectOf(session)),
        showProject ? projectOf(session) : null, session.agent === 'codex' ? 'Codex' : 'Claude', STATES[word].one,
        questions?.open > 0 ? asks.title : null,
      ].filter(Boolean).join(', ');
      link.setAttribute('aria-label', spoken);
    },
  };
}

function section(app) {
  const title = h('span');
  const count = h('span', { class: 'count' });
  const list = h('ul', { class: 'rows' });
  const el = h('section', { class: 'group' }, h('h2', { class: 'group-head' }, title, count), list);
  const rows = new Map();
  return {
    el,
    update(group) {
      setText(title, group.title);
      setText(count, String(group.rows.filter((row) => !row.nested).length));
      keyed(list, rows, group.rows, (row) => row.session.id, () => sessionRow(app), { enter: true });
    },
  };
}

export function sidebar(app) {
  const { store, ui } = app;
  const tabs = ['attention', 'projects'].map((grouping) =>
    h('button', { type: 'button', onclick: () => ui.setGrouping(grouping) }, grouping === 'attention' ? 'Attention' : 'Projects'));
  const groups = h('div', { class: 'groups' });
  const empty = h('p', { class: 'list-empty', hidden: true });
  const skeleton = h('div', { class: 'skeleton-list', 'aria-hidden': 'true' },
    [0, 1, 2, 3, 4].map(() => h('div', { class: 'skeleton-row' }, h('span', { class: 'bone dot' }), h('span', { class: 'bone-lines' }, h('span', { class: 'bone' }), h('span', { class: 'bone short' })))));
  const filter = h('input', {
    class: 'filter-input', type: 'search', placeholder: 'Filter', 'aria-label': 'Filter sessions', autocomplete: 'off', spellcheck: 'false',
    oninput: () => ui.setFilter(filter.value),
    onkeydown: (event) => {
      if (event.key !== 'Escape') return;
      filter.value = '';
      ui.setFilter('');
      filter.blur();
    },
  });
  const line = h('span', { class: 'foot-summary', role: 'status' });
  const nodeDot = h('span', { class: 'notice-dot', hidden: true });
  const nodeLink = h('a', { class: 'icon-button', href: '#/node', title: 'This node', 'aria-label': 'This node' }, icon('node', 15), nodeDot);
  const el = h('nav', { class: 'sidebar', 'aria-label': 'Sessions' },
    h('div', { class: 'sidebar-top' }, h('div', { class: 'segmented', role: 'group', 'aria-label': 'Group by' }, tabs)),
    h('div', { class: 'list' }, skeleton, groups, empty),
    h('div', { class: 'sidebar-foot' },
      h('label', { class: 'filter' }, icon('filter', 13), filter),
      h('div', { class: 'foot-line' }, line, nodeLink)));

  const sections = new Map();
  let arranged = { sections: [], order: [], total: 0 };

  function render() {
    const state = store.state;
    const loading = state.connection === 'connecting';
    skeleton.hidden = !loading;
    tabs.forEach((tab, index) => tab.setAttribute('aria-pressed', String((index === 0) === (ui.state.grouping === 'attention'))));
    arranged = loading ? { sections: [], order: [], total: 0 } : arrange(state, ui.state);
    keyed(groups, sections, arranged.sections, (group) => group.id, () => section(app), { move: true });
    empty.hidden = loading || arranged.sections.length > 0;
    const signedOut = state.connection === 'unpaired' || state.connection === 'revoked';
    if (!empty.hidden) setText(empty, arranged.total === 0 ? (signedOut ? '' : 'No sessions') : 'No matches');
    const said = summary(state);
    setText(line, loading || arranged.total === 0 ? '' : said || plural(arranged.total, 'session'));
    const notices = state.node?.notices?.length || 0;
    nodeDot.hidden = notices === 0;
    nodeLink.title = notices ? `This node · ${plural(notices, 'notice')}` : 'This node';
    if (ui.state.route.name === 'node') nodeLink.setAttribute('aria-current', 'page'); else nodeLink.removeAttribute('aria-current');
  }

  const schedule = framed(render);
  for (const topic of ['sessions', 'leads', 'boards', 'node', 'connection']) store.subscribe(topic, schedule);
  ui.subscribe((what) => { if (what === 'list' || what === 'route') schedule(); });
  render();

  return {
    el,
    // The rows from top to bottom: what ⌘1–9 counts and ⌥↓ walks.
    order: () => arranged.order,
    focusFilter() { filter.focus(); filter.select(); },
  };
}
