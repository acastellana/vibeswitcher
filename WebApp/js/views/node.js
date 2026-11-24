// This node: the session host, the server, the build it runs, and what it wants you to know. `vibeswitcher status`
// as a page, in the same order and the same words (Sources/vibeswitcher-cli/Status.swift).

import { h, framed } from '../dom.js';
import { icon } from '../marks.js';
import { since, plural, tilde } from '../words.js';
import { usageFacts } from '../settings.js';
import { dictationGroup } from '../dictate.js';
import { healthFacts } from '../health.js';
import { updateFacts } from '../updates.js';
import { copyLine } from './cards.js';
import { t } from '../i18n.js';
import { actsLine, actsFor, doButton } from '../acting.js';

const row = (name, ...value) => h('div', { class: 'fact' }, h('dt', null, name), h('dd', null, value));
const ago = (iso) => (iso ? h('time', { data: { since: iso }, title: new Date(iso).toLocaleString() }, since(iso)) : 'unknown');
const group = (title, ...children) => h('section', { class: 'node-group' }, h('h2', { class: 'section-title' }, title), children);

// The account's usage (the node's `usage`): each limit known, the ones holding work back marked; null before the
// node's first read. Also on Settings.
export function usageGroup(usage) {
  const facts = usageFacts(usage);
  if (!facts) return null;
  return group(t('noAccountUsage'),
    h('p', { class: 'node-says' }, t('noBestEffort') + (facts.account ? ` (${facts.account})` : '') + '.'),
    h('dl', { class: 'facts-list' }, facts.limits.length ? facts.limits.map((limit) => row(limit.title,
      h('span', { class: limit.holds ? 'dot tone-needs-you' : 'dot tone-done', 'aria-hidden': 'true' }), limit.value, limit.holds ? t('noHoldsWorkBack') : ''))
      : row(t('noLimits'), t('noNothingKnownYet'))),
    h('ul', { class: 'lines' }, facts.notes.map((note) => h('li', null, note))));
}

// The health digest (`vibeswitcher status --health`): rows, then each freeze, waiting session and error line.
export function healthGroup(health) {
  const facts = healthFacts(health);
  if (!facts) return null;
  return group(t('noHealth'),
    h('dl', { class: 'facts-list' }, facts.rows.map(([name, value], index) => index === 0
      ? row(name, h('span', { class: facts.tone === 'done' ? 'dot tone-done' : 'dot tone-needs-you', 'aria-hidden': 'true' }), value)
      : row(name, value))),
    facts.lines.length ? h('ul', { class: 'lines' }, facts.lines.map((line) => h('li', null, line.at ? [ago(line.at), ' · '] : null, line.text))) : null);
}

// Check for Updates (the node's `update`): up to date or a newer build, the last look's time, why a look failed, and
// the lines to copy (install, switch, check now). A page asks GitHub nothing.
export function updatesGroup(update) {
  const facts = updateFacts(update);
  if (!facts) return null;
  const tone = facts.tone === 'done' ? 'dot tone-done' : facts.tone === 'needs-you' ? 'dot tone-needs-you' : 'dot';
  return group(t('noUpdates'),
    h('dl', { class: 'facts-list' },
      row(t('noState'), h('span', { class: tone, 'aria-hidden': 'true' }), facts.state),
      facts.checkedAt ? row(t('noLastChecked'), t('noAgo', { d: ago(facts.checkedAt) })) : null,
      facts.problem ? row(t('noLastTry'), t('noCouldntLook', { why: facts.problem })) : null),
    h('div', { class: 'card-command' }, h('span', { class: 'card-command-label' }, t('noInATerminal')),
      facts.lines.map((line) => copyLine(line.text, line.label))));
}

export function nodeView(app) {
  const { store } = app;
  const body = h('div', { class: 'node-column' });
  const el = h('section', { class: 'node', 'aria-label': t('noThisNode') },
    h('header', { class: 'head' },
      h('a', { class: 'back icon-button', href: '#/', 'aria-label': t('noSessions') }, icon('back', 16)),
      h('div', { class: 'head-text' }, h('div', { class: 'head-line' }, h('h1', { class: 'head-title' }, t('noThisNode'))))),
    h('div', { class: 'pane node-pane' }, body));
  let drawn = '';
  const dictation = dictationGroup();
  // With the `act` right: what one plain accept settles (`approve.list`: the held config, the vouched base moves, the
  // hooks), each listed whole before the click, and the batch approved as the node listed it (`approve`, each item's
  // seen in its order); what needs your own decision listed apart, with its command.
  const approveActs = (() => {
    const el = h('section', { class: 'node-group', hidden: true });
    let asked = '';
    const load = () => store.read('approve.list', {}).then((reply) => {
      const result = reply.ok ? reply.result : null;
      const items = result?.items || [];
      el.hidden = !items.length && !(result?.own || []).length && !result?.terminal?.count;
      el.replaceChildren(h('h2', { class: 'section-title' }, t('acApproveTitle')),
        items.length ? h('ol', { class: 'approve-list' }, items.map((item) => h('li', null, h('b', null, item.subject || item.kind), (item.reasons || []).length ? h('ul', { class: 'lines' }, item.reasons.map((reason) => h('li', null, reason))) : null))) : null,
        items.length && result.batch ? doButton(app, { label: t('acApproveAll', { n: items.length }), kind: 'approve', args: () => ({ batch: result.batch, seen: items.map((item) => item.seen ?? null) }), done: load }).el : null,
        // What a page may not approve (the hooks' install): left out of the list, its count and the terminal's command.
        result?.terminal?.count ? h('p', { class: 'node-says' }, t('acTerminalMore', { n: result.terminal.count }), ' ', h('code', null, result.terminal.command || 'vibeswitcher approve')) : null,
        (result?.own || []).length ? h('div', null, h('p', { class: 'node-says' }, t('acOwnDecision')), h('ul', { class: 'lines' }, result.own.map((one) => h('li', null, one.text, ' ', h('code', null, one.command))))) : null);
    });
    return { el, refresh(key) { if (key !== asked) { asked = key; load(); } } };
  })();
  // With the `act` right: every plugin (`plugin.list`) with its switch, and Remove for one added (shell is built in).
  const pluginActs = (() => {
    const el = h('div', { class: 'plugin-acts' });
    let asked = '';
    const load = () => store.read('plugin.list', {}).then((reply) => {
      const list = reply.ok ? reply.result.plugins || [] : [];
      el.replaceChildren(...list.map((plugin) => h('div', { class: 'plugin-act' },
        h('span', { class: 'plugin-act-name' }, plugin.title || plugin.id, h('small', null, plugin.unavailable || (plugin.on ? t('noOn') : t('noOff')))),
        doButton(app, { label: plugin.on ? t('acTurnOff') : t('acTurnOn'), kind: plugin.on ? 'plugin.off' : 'plugin.on', quiet: plugin.on, args: () => ({ plugin: plugin.id }), done: load }).el,
        plugin.id !== 'shell' && store.can('plugin.remove') ? doButton(app, { label: t('acRemove'), kind: 'plugin.remove', quiet: true, confirm: t('acRemoveSure'), args: () => ({ plugin: plugin.id }), done: load }).el : null)));
    });
    return { el, refresh(key) { if (key !== asked) { asked = key; load(); } } };
  })();

  function render() {
    if (app.ui.state.route.name !== 'node') return;
    const node = store.state.node;
    const now = JSON.stringify([node, store.state.connection, store.acts(), store.state.phrase]);
    if (node && actsFor(app, 'plugin.on') && store.can('plugin.list')) pluginActs.refresh(JSON.stringify(node.plugins));
    if (node && actsFor(app, 'approve') && store.can('approve.list')) approveActs.refresh(JSON.stringify(node.cards));
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

    // replaceChildren would write an absent group as the word "null": the groups a node doesn't have are left out.
    body.replaceChildren(...[
      notices.length ? h('section', { class: 'node-group' }, h('h2', { class: 'section-title' }, plural(notices.length, t('noNotice'))),
        h('ul', { class: 'notices' }, notices.map((notice) => h('li', null, icon('warning', 14), h('span', null, notice))))) : null,
      // Acting from a page (`web_acts`): first, whether this page acts for you and since when, and the switch.
      node.web?.acts ? group(t('acGroupTitle'), actsLine(app)) : null,
      group(t('noSessionHost'),
        h('dl', { class: 'facts-list' },
          row(t('noState'), h('span', { class: connected ? 'dot tone-done' : 'dot tone-needs-you', 'aria-hidden': 'true' }), connected ? t('noConnected') : host.state),
          row(t('noRunningFor'), ago(host.startedAt)),
          row(t('noLiveSessions'), String(host.liveSessions)),
          row(t('noProcess'), `pid ${host.pid ?? '?'}`),
          notes ? row(t('noServerRestarts'), String(notes.serverRestarts)) : null,
          notes?.refusedAppConnections ? row(t('noRefusedConnections'), String(notes.refusedAppConnections)) : null,
          (notes?.replacedPaths || []).map((path) => row(t('noTookBackItsPath'), tilde(path, home))))),
      usageGroup(node.usage),
      // Boost (the node's `boost`): on or off, why, and the limits it raises to.
      node.boost ? group(t('noBoost'),
        h('dl', { class: 'facts-list' },
          row(t('noState'), h('span', { class: node.boost.on ? 'dot tone-working' : 'dot', 'aria-hidden': 'true' }), node.boost.on ? t('noBoostOnWhy', { why: node.boost.why }) : t('noBoostOffWhy', { why: node.boost.why })),
          row(t('noMode'), node.boost.mode),
          node.boost.on ? row(t('noRaisedLimits'), t('noBoostLimits', { load: node.boost.limits.loadThreshold, sessions: node.boost.limits.maxSessions, workers: node.boost.limits.maxWorkers, slots: node.boost.limits.heavySlots })) : null),
        h('a', { class: 'link', href: '#/settings' }, t('noChangeItInSettings'))) : null,
      healthGroup(node.health),
      // The feature plugins that are on (`vibeswitcher plugin list` lists them all; on and off from a terminal).
      Array.isArray(node.plugins) ? group(t('noPlugins'),
        h('dl', { class: 'facts-list' }, node.plugins.length ? node.plugins.map((plugin) => row(plugin.title, h('span', { class: 'dot tone-done', 'aria-hidden': 'true' }), t('noOn')))
          : row(t('noOn'), t('noNone'))),
        actsFor(app, 'plugin.on') && store.can('plugin.list') ? pluginActs.el
          : h('p', { class: 'node-says' }, 'vibeswitcher plugin list shows every plugin; plugin on NAME and plugin off NAME, in your terminal, change them.')) : null,
      group(t('noServer'),
        h('dl', { class: 'facts-list' },
          row(t('noRunningFor'), ago(server.startedAt)),
          row(t('noProcess'), `pid ${server.pid}`),
          row(t('noNode'), node.node),
          row(t('noStateFolder'), tilde(node.root, home)))),
      // The web listener this page came in by (the node's `web`; the mock has none).
      node.web ? group(t('noWebPage'),
        h('dl', { class: 'facts-list' },
          row(t('noState'), node.web.state === 'listening' ? t('noListening', { port: node.web.port }) : node.web.state === 'off' ? t('noOff') : node.web.state),
          row(t('noPagesPaired'), String(node.web.tokens)),
          row(t('noOpenNow'), String(node.web.connections)))) : null,
      // Acting from a page (`web_acts`): whether pages may, since when, and the switch that turns it off.
      actsFor(app, 'approve') && store.can('approve.list') ? approveActs.el : null,
      // With the `act` right: stop the node (every session ends), asked twice.
      actsFor(app, 'stop') ? group(t('acStopTitle'), h('p', { class: 'node-says' }, t('acStopWords')),
        doButton(app, { label: t('acStopNode'), kind: 'stop', confirm: t('acStopSure'), args: () => ({}) }).el) : null,
      updatesGroup(node.update),
      group(t('noBuild'),
        h('dl', { class: 'facts-list' },
          row(t('noRunning'), h('code', null, notes?.build || server.commit)),
          server.commit !== (notes?.build || server.commit) ? row(t('noServer'), h('code', null, server.commit)) : null,
          others.length ? row(t('noAlsoInstalled'), others.map((commit) => h('code', null, commit))) : null,
          builds?.rollback ? row(t('noRollbackGoesTo'), builds.rollback.line) : null)),
      group(t('noWhoMayAct'),
        h('p', { class: 'node-says' }, node.rule?.says || ''),
        h('ul', { class: 'lines' }, (node.facts || []).map((line) => h('li', null, line)))),
      node.journal?.length ? group(t('noJournal'), h('ul', { class: 'lines' }, node.journal.map((line) => h('li', null, line.replace(/^journal: /, ''))))) : null,
      node.accepted?.length ? group(t('noRequestsItTookAsYours'),
        h('ul', { class: 'lines' }, node.accepted.map((entry) => h('li', null, h('code', null, entry.commandLine.join(' ')), ' · ', t('noAgo', { d: ago(entry.at) }), ' · ', entry.cgroup)))) : null,
      group(t('noBetweenLeads'),
        h('p', { class: 'node-says' }, t('noWhatTheProjectsLeadsTold')),
        h('a', { class: 'link', href: '#/mail' }, t('noOpenBetweenLeads'))),
      group(t('noSettings'),
        h('p', { class: 'node-says' }, t('noWhatEveryProjectSLeads')),
        h('a', { class: 'link', href: '#/settings' }, t('noOpenSettings'))),
      app.store.can('stats') ? group(t('noStatistics'),
        h('p', { class: 'node-says' }, t('noLoadUsageMergesQualityAnd')),
        h('a', { class: 'link', href: '#/stats' }, t('noOpenStatistics'))) : null,
      // This page's own: the browser's notifications (js/notify.js).
      app.notifications?.el,
      // This page's own: dictation into a draft (js/dictate.js).
      dictation,
    ].filter(Boolean));
  }

  const schedule = framed(render);
  store.subscribe('node', schedule);
  store.subscribe('connection', schedule);
  app.ui.subscribe((what) => { if (what === 'route') render(); });
  render();
  return { el };
}
