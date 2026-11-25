// Between leads: what each project's lead sent other projects' leads with tell_lead and what came back, newest first,
// as `vibeswitcher mail` shows it. Read-only: the page reads the record (its token's `read` right) and changes nothing;
// a project's newest 20, and Show all for every one of them (`mail` with `all`).

import { h, setText, framed } from '../dom.js';
import { icon } from '../marks.js';
import { since, plural, tilde, lastPart, dateTime } from '../words.js';
import { mailLine, mailCommand } from '../mail.js';
import { copyLine } from './cards.js';
import { t } from '../i18n.js';
import { refusalWords } from '../acting.js';

// How often the open page reads the record again.
const REFRESH = 15000;

export const mailHref = '#/mail';

export function mailView(app) {
  const { store, ui } = app;
  const body = h('div', { class: 'node-column' });
  const el = h('section', { class: 'node mail', 'aria-label': t('mvBetweenLeads') },
    h('header', { class: 'head' },
      h('a', { class: 'back icon-button', href: '#/node', 'aria-label': t('mvThisNode') }, icon('back', 16)),
      h('div', { class: 'head-text' }, h('div', { class: 'head-line' }, h('h1', { class: 'head-title' }, t('mvBetweenLeads'))))),
    h('div', { class: 'pane node-pane' }, body));
  let result = null;
  let failed = null;
  let drawn = '';
  let asking = 0;
  let timer = null;

  // The projects shown whole (Show all: `mail` with `all`), by root: read whole again at each refresh.
  const whole = new Map();
  const merged = (projects) => (projects || []).map((entry) => whole.get(entry.root) || entry);
  function load() {
    const mine = ++asking;
    store.request('mail', {}).then((reply) => {
      if (mine !== asking) return;
      if (reply.ok) {
        result = { ...reply.result, projects: merged(reply.result.projects) };
        failed = null;
        for (const root of whole.keys()) readWhole(root);
      } else {
        failed = reply.error?.code === 'unknown-kind' || reply.error?.code === 'voice'
          ? t('mvThisNodeDoesnTShow')
          : reply.error?.message || t('mvTheNodeCouldnTRead');
      }
      render();
    });
  }

  // One project's every message (`mail` with its folder and `all`), in place of its newest.
  function readWhole(root) {
    return store.request('mail', { folder: root, all: true }).then((reply) => {
      const found = reply.ok ? (reply.result.projects || []).find((one) => one.root === root) : null;
      if (found) {
        whole.set(root, found);
        if (result) result = { ...result, projects: merged(result.projects) };
        render();
      }
      return reply.ok && !found ? { ok: false, error: { code: 'gone', message: t('mvNoLongerThere') } } : reply;
    });
  }

  // Show all: a button that reads them whole; Loading…, then all of them in the list; the node's refusal beside it.
  function showAll(entry) {
    const said = h('span', { class: 'act-said', role: 'status' });
    const button = h('button', { class: 'button quiet small', type: 'button', onclick: () => {
      button.disabled = true;
      button.textContent = t('mvLoading');
      said.classList.remove('refused');
      setText(said, '');
      readWhole(entry.root).then((reply) => {
        button.disabled = false;
        button.textContent = t('mvShowAll', { n: entry.total });
        if (!reply.ok) { setText(said, refusalWords(reply.error, t('mvShowAll', { n: entry.total }))); said.classList.add('refused'); }
      });
    } }, t('mvShowAll', { n: entry.total }));
    return h('span', { class: 'act' }, button, said);
  }

  function project(entry, home) {
    const messages = entry.messages || [];
    return h('section', { class: 'node-group' },
      h('h2', { class: 'section-title' }, `${lastPart(entry.root) || entry.project} · ${t('mvMessages', { n: entry.total })}`),
      messages.length ? h('ul', { class: 'mail-list' }, messages.map((message) => {
        const line = mailLine(message);
        return h('li', { class: line.sent ? 'mail-message' : 'mail-message refused' },
          h('div', { class: 'mail-head' }, h('span', { class: 'mail-way' }, line.way), ' · ', line.kind, ' · ', line.outcome, ' · ',
            h('time', { data: { since: message.at }, title: dateTime(message.at) }, since(message.at))),
          h('p', { class: 'mail-text' }, line.text),
          line.why ? h('p', { class: 'setting-note' }, icon('warning', 12), line.why) : null);
      })) : h('p', { class: 'node-says' }, t('mvNoMessageSentOrReceived')),
      messages.length < entry.total ? h('div', null, h('p', { class: 'node-says' }, t('mvNewestShown', { n: messages.length })),
        // Where the node lists `mail` (a read: any paired page, the phone's too), Show all reads them here.
        store.can('mail') ? showAll(entry) : copyLine(mailCommand(tilde(entry.root, home)), t('mvTheCommandThatListsEvery'))) : null,
      whole.has(entry.root) && messages.length >= entry.total && entry.total > 0 ? h('p', { class: 'act-said receipt', role: 'status' }, t('mvAllShown', { n: entry.total })) : null);
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
      : [h('p', { class: 'node-says' }, t('mvNoProjectSLeadRuns'))]));
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
