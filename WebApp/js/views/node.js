// This node: the session host, the server, the build it runs, and what it wants you to know. `vibeswitcher status`
// as a page, in the same order and the same words (Sources/vibeswitcher-cli/Status.swift).

import { h, framed } from '../dom.js';
import { icon } from '../marks.js';
import { since, plural, tilde } from '../words.js';

const row = (name, ...value) => h('div', { class: 'fact' }, h('dt', null, name), h('dd', null, value));
const ago = (iso) => (iso ? h('time', { data: { since: iso }, title: new Date(iso).toLocaleString() }, since(iso)) : 'unknown');
const group = (title, ...children) => h('section', { class: 'node-group' }, h('h2', { class: 'section-title' }, title), children);

export function nodeView(app) {
  const { store } = app;
  const body = h('div', { class: 'node-column' });
  const el = h('section', { class: 'node', 'aria-label': 'This node' },
    h('header', { class: 'head' },
      h('a', { class: 'back icon-button', href: '#/', 'aria-label': 'Sessions' }, icon('back', 16)),
      h('div', { class: 'head-text' }, h('div', { class: 'head-line' }, h('h1', { class: 'head-title' }, 'This node')))),
    h('div', { class: 'pane node-pane' }, body));
  let drawn = '';

  function render() {
    if (app.ui.state.route.name !== 'node') return;
    const node = store.state.node;
    const now = JSON.stringify([node, store.state.connection]);
    if (now === drawn) return;
    drawn = now;
    if (!node) {
      body.replaceChildren(h('div', { class: 'head-skeleton', 'aria-hidden': 'true' }, h('span', { class: 'bone wide' }), h('span', { class: 'bone' }), h('span', { class: 'bone short' })));
      return;
    }
    const { host, server, builds } = node;
    const notes = host.notes;
    const home = node.home;
    const connected = host.state === 'connected';
    const notices = node.notices || [];
    const others = (builds?.installed || []).filter((commit) => commit !== notes?.build);

    body.replaceChildren(
      notices.length ? h('section', { class: 'node-group' }, h('h2', { class: 'section-title' }, plural(notices.length, 'Notice')),
        h('ul', { class: 'notices' }, notices.map((notice) => h('li', null, icon('warning', 14), h('span', null, notice))))) : null,
      group('Session host',
        h('dl', { class: 'facts-list' },
          row('State', h('span', { class: connected ? 'dot tone-done' : 'dot tone-needs-you', 'aria-hidden': 'true' }), connected ? 'Connected' : host.state),
          row('Running for', ago(host.startedAt)),
          row('Live sessions', String(host.liveSessions)),
          row('Process', `pid ${host.pid ?? '?'}`),
          notes ? row('Server restarts', String(notes.serverRestarts)) : null,
          notes?.refusedAppConnections ? row('Refused connections', String(notes.refusedAppConnections)) : null,
          (notes?.replacedPaths || []).map((path) => row('Took back its path', tilde(path, home))))),
      group('Server',
        h('dl', { class: 'facts-list' },
          row('Running for', ago(server.startedAt)),
          row('Process', `pid ${server.pid}`),
          row('Node', node.node),
          row('State folder', tilde(node.root, home)))),
      group('Build',
        h('dl', { class: 'facts-list' },
          row('Running', h('code', null, notes?.build || server.commit)),
          server.commit !== (notes?.build || server.commit) ? row('Server', h('code', null, server.commit)) : null,
          others.length ? row('Also installed', others.map((commit) => h('code', null, commit))) : null,
          builds?.rollback ? row('Rollback goes to', builds.rollback.line) : null)),
      group('Who may act',
        h('p', { class: 'node-says' }, node.rule?.says || ''),
        h('ul', { class: 'lines' }, (node.facts || []).map((line) => h('li', null, line)))),
      node.journal?.length ? group('Journal', h('ul', { class: 'lines' }, node.journal.map((line) => h('li', null, line.replace(/^journal: /, ''))))) : null,
      node.accepted?.length ? group('Requests it took as yours',
        h('ul', { class: 'lines' }, node.accepted.map((entry) => h('li', null, h('code', null, entry.commandLine.join(' ')), ' · ', ago(entry.at), ' ago · ', entry.cgroup)))) : null);
  }

  const schedule = framed(render);
  store.subscribe('node', schedule);
  store.subscribe('connection', schedule);
  app.ui.subscribe((what) => { if (what === 'route') render(); });
  render();
  return { el };
}
