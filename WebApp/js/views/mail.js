// Between leads: what each project's lead sent other projects' leads with tell_lead and what came back, newest first,
// as `vibeswitcher mail` shows it. Read-only: the page reads the record (its token's `read` right) and changes nothing.

import { h, framed } from '../dom.js';
import { icon } from '../marks.js';
import { since, plural, tilde, lastPart } from '../words.js';
import { mailLine, mailCommand } from '../mail.js';
import { copyLine } from './cards.js';

// How often the open page reads the record again.
const REFRESH = 15000;

export const mailHref = '#/mail';

export function mailView(app) {
  const { store, ui } = app;
  const body = h('div', { class: 'node-column' });
  const el = h('section', { class: 'node mail', 'aria-label': 'Between leads' },
    h('header', { class: 'head' },
      h('a', { class: 'back icon-button', href: '#/node', 'aria-label': 'This node' }, icon('back', 16)),
      h('div', { class: 'head-text' }, h('div', { class: 'head-line' }, h('h1', { class: 'head-title' }, 'Between leads')))),
    h('div', { class: 'pane node-pane' }, body));
  let result = null;
  let failed = null;
  let drawn = '';
  let asking = 0;
  let timer = null;

  function load() {
    const mine = ++asking;
    store.request('mail', {}).then((reply) => {
      if (mine !== asking) return;
      if (reply.ok) { result = reply.result; failed = null; } else {
        failed = reply.error?.code === 'unknown-kind' || reply.error?.code === 'voice'
          ? 'This node doesn’t show the record between leads to a page yet: `vibeswitcher mail` in a terminal does.'
          : reply.error?.message || 'The node couldn’t read the record between leads.';
      }
      render();
    });
  }

  function project(entry, home) {
    const messages = entry.messages || [];
    return h('section', { class: 'node-group' },
      h('h2', { class: 'section-title' }, `${lastPart(entry.root) || entry.project} · ${plural(entry.total, 'message')}`),
      messages.length ? h('ul', { class: 'mail-list' }, messages.map((message) => {
        const line = mailLine(message);
        return h('li', { class: line.sent ? 'mail-message' : 'mail-message refused' },
          h('div', { class: 'mail-head' }, h('span', { class: 'mail-way' }, line.way), ' · ', line.kind, ' · ', line.outcome, ' · ',
            h('time', { data: { since: message.at }, title: new Date(message.at).toLocaleString() }, since(message.at))),
          h('p', { class: 'mail-text' }, line.text),
          line.why ? h('p', { class: 'setting-note' }, icon('warning', 12), line.why) : null);
      })) : h('p', { class: 'node-says' }, 'No message sent or received with tell_lead.'),
      messages.length < entry.total ? h('div', null, h('p', { class: 'node-says' }, `The newest ${messages.length} shown. Every one, in a terminal:`),
        copyLine(mailCommand(tilde(entry.root, home)), 'the command that lists every message')) : null);
  }

  function render() {
    if (ui.state.route.name !== 'mail') return;
    const now = JSON.stringify([result, failed]);
    if (now === drawn) return;
    drawn = now;
    if (failed) return body.replaceChildren(h('p', { class: 'card-notice', role: 'alert' }, failed));
    if (!result) return body.replaceChildren(h('div', { class: 'head-skeleton', 'aria-hidden': 'true' }, h('span', { class: 'bone wide' }), h('span', { class: 'bone' })));
    const home = store.state.node?.home;
    const projects = result.projects || [];
    body.replaceChildren(...(projects.length ? projects.map((entry) => project(entry, home))
      : [h('p', { class: 'node-says' }, 'No project’s lead runs on this node.')]));
  }

  const schedule = framed(render);
  store.subscribe('node', schedule);
  store.subscribe('connection', () => { if (ui.state.route.name === 'mail' && store.state.connection === 'live') load(); });
  ui.subscribe((what) => {
    if (what !== 'route') return;
    clearInterval(timer);
    timer = null;
    if (ui.state.route.name !== 'mail') return;
    render();
    load();
    timer = setInterval(() => { if (!document.hidden) load(); }, REFRESH);
  });
  return { el };
}
