// This node: the session host, the server, the build it runs, and what it wants you to know. `vibeswitcher status`
// as a page, in the same order and the same words (Sources/vibeswitcher-cli/Status.swift).

import * as kit from '../kit.js';
import { h, framed } from '../dom.js';
import { icon } from '../marks.js';
import { since, plural, tilde, dateTime, elided } from '../words.js';
import { usageFacts } from '../settings.js';
import { dictationGroup } from '../dictate.js';
import { healthFacts } from '../health.js';
import { updateFacts, checkedWords } from '../updates.js';
import { copyLine } from './cards.js';
import { t, tParts, nodeWords, lang } from '../i18n.js';
import { actsLine, actsFor, doButton } from '../acting.js';
import { twoColumns, queryWords, holdsAll, marked } from './twocol.js';
import { settingsHref } from './settings.js';
import { waitingPlaces } from '../conversation.js';

// A group's address: `#/node/<group>`; `#/node` opens the one that needs you, else the first.
export const nodeHref = (key) => '#/node' + (key ? '/' + key : '');

// The rows of a group a search looks through: a fact, a line, a notice, a plugin's switch, what the node says.
const ROWS = ['fact', 'plugin-act', 'node-says', 'passkey-row'];
const isRow = (node) => node.tagName === 'LI' || ROWS.some((name) => node.classList?.contains(name));
function rowsOf(node, found = []) {
  for (const child of [...(node.children || [])]) {
    if (child.tagName === '#text') continue;
    if (isRow(child)) found.push(child); else rowsOf(child, found);
  }
  return found;
}
// How many of a group's rows hold every word (all of them when its title does).
function searched(one, words) {
  const titleFound = holdsAll(one.title, words);
  const rows = rowsOf(one.el);
  const found = titleFound ? Math.max(rows.length, 1) : rows.filter((row) => holdsAll(row.textContent, words)).length;
  return { found, titleFound };
}
// Marks each word of `words` where it is in `el`'s text (the rows a search found), as elements.
function markWords(el, words) {
  for (const child of [...(el.childNodes || [])]) {
    if (child.nodeType === 3 || child.tagName === '#text') {
      const parts = marked(child.textContent, words);
      if (parts.length < 2 && typeof parts[0] === 'string') continue;
      for (const part of parts) el.insertBefore(typeof part === 'string' ? document.createTextNode(part) : part, child);
      child.remove();
    } else if (child.tagName !== 'svg' && child.tagName !== 'MARK') markWords(child, words);
  }
}

// Takes back what markWords marked (the parts of a group kept between draws: the plugins', the approvals', this browser's).
function unmarkWords(el) {
  for (const child of [...(el.childNodes || [])]) {
    if (child.tagName === 'MARK' && child.classList.contains('found')) {
      el.insertBefore(document.createTextNode(child.textContent), child);
      child.remove();
    } else if (child.childNodes?.length) unmarkWords(child);
  }
}

// Shows only the rows that hold every word (`words` null: every row again). Only what the search hid is shown again.
function showRows(el, words, all = false) {
  for (const row of rowsOf(el)) {
    const show = !words || all || holdsAll(row.textContent, words);
    if (!show && !row.hidden) { row.hidden = true; row.dataset.searchHid = '1'; }
    if (show && row.dataset.searchHid) { row.hidden = false; delete row.dataset.searchHid; }
  }
}

const row = (name, ...value) => h('div', { class: 'fact' }, h('dt', null, name), h('dd', null, value));
const ago = (iso) => (iso ? h('time', { data: { since: iso }, title: dateTime(iso) }, since(iso)) : 'unknown');
const group = (title, ...children) => h('section', { class: 'node-group' }, kit.sectionTitle('h2', {}, title), children);

// What a person reads first and what only someone fixing the node needs (D18): process ids, the node's own name, its
// state folder. Folded under "Technical details", the rows still found by a search (which opens it).
const technical = (...rows) => h('details', { class: 'node-technical' }, h('summary', null, t('noTechnical')), h('dl', { class: 'facts-list' }, rows));

// A day as a person says it: "Nov 23", "23 nov".
const dayOf = (iso) => new Date(iso).toLocaleDateString(lang(), { month: 'short', day: 'numeric' });

// The Technical details folds inside `el`.
function foldsOf(el, found = []) {
  for (const child of [...(el.children || [])]) {
    if (child.tagName === 'DETAILS') found.push(child); else foldsOf(child, found);
  }
  return found;
}

// A build's commit: its first 7 characters, quiet, the whole on hover (and selected whole by a click, to copy).
export const shortHash = (commit) => String(commit || '').slice(0, 7);
const hash = (commit) => h('code', { class: 'node-hash', title: commit }, shortHash(commit));

// A build as a person names it (D18): what the node says of it (a commit's subject, the date it has run since), the
// hash after it. The node sends a date only for the running build (its server's start) and a name only for the one a
// rollback goes to (its line): the others are their hash alone until it sends theirs.
export function buildWords({ commit, name = null, since: from = null }) {
  const parts = [];
  if (name) parts.push(h('span', { class: 'node-build-name' }, name));
  if (from) parts.push(h('span', { class: 'node-build-date', title: dateTime(from) }, t('noBuildSince', { date: dateTime(from, { date: 'medium' }) })));
  return h('span', { class: 'node-build' }, parts.flatMap((part, index) => (index ? [' · ', part] : [part])), parts.length ? ' ' : null, hash(commit));
}

// The rollback's line ("200e2c32 v2 journal: …"): its commit and the subject after it.
export function rollbackParts(rollback) {
  const line = String(rollback?.line || '');
  const commit = rollback?.commit || line.split(' ')[0] || '';
  const subject = line.startsWith(commit) ? line.slice(commit.length).trim() : line;
  return { commit, name: subject || null };
}

// Who may act as you, in words (the node's rule's mode): a terminal on this computer, the same with a looser check, no
// one, or with your approval.
export const ruleWords = (mode) => ({ systemd: t('noRuleSystemd'), weaker: t('noRuleWeaker'), closed: t('noRuleClosed'), approval: t('noRuleApproval') }[mode] || mode || '');
// The same in a word or two, for the list's row.
export const ruleShort = (mode) => ({ systemd: t('noRuleShortHere'), weaker: t('noRuleShortHere'), closed: t('noRuleShortNone'), approval: t('noRuleShortApproval') }[mode] || mode || '');

// A request the node took as yours, in words: what it did, and where (a folder shortened, whole on hover).
const ACCEPTED = { lead: 'noAccLead', answer: 'noAccAnswer', approve: 'noAccApprove', set: 'noAccSet', 'session.new': 'noAccNew', new: 'noAccNew', send: 'noAccSend',
  'session.reply': 'noAccAnswer', resume: 'noAccResume', 'session.resume': 'noAccResume', stop: 'noAccStop', push: 'noAccPush' };
export function acceptedWords(entry, home) {
  const what = ACCEPTED[entry.kind] ? t(ACCEPTED[entry.kind]) : t('noAccOther');
  const subject = typeof entry.subject === 'string' && entry.subject.startsWith('/') ? entry.subject : null;
  return [h('span', { title: (entry.commandLine || []).join(' ') || entry.kind }, what),
    subject ? [' · ', h('span', { class: 'node-path', title: subject }, elided(tilde(subject, home)))] : null];
}

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
    facts.lines.length ? h('ul', { class: 'lines' }, facts.lines.map((line) => h('li', null, line.at ? [...tParts('noAgo', { d: ago(line.at) }), ' · '] : null, line.text))) : null);
}

// Check for Updates (the node's `update`): up to date or a newer build, the last look's time, why a look failed, and
// the lines to copy (install, switch, check now). A page asks GitHub nothing.
// `check`: Check now (a button that asks the node to look, `update.check`), shown in place of the check-now line.
export function updatesGroup(update, check = null) {
  const facts = updateFacts(update);
  if (!facts) return null;
  const lines = check ? facts.lines.filter((line) => !line.checks) : facts.lines;
  const tone = facts.tone === 'done' ? 'dot tone-done' : facts.tone === 'needs-you' ? 'dot tone-needs-you' : 'dot';
  return group(t('noUpdates'),
    h('dl', { class: 'facts-list' },
      row(t('noState'), h('span', { class: tone, 'aria-hidden': 'true' }), facts.state),
      facts.checkedAt ? row(t('noLastChecked'), tParts('noAgo', { d: ago(facts.checkedAt) })) : null,
      facts.problem ? row(t('noLastTry'), t('noCouldntLook', { why: facts.problem })) : null),
    check,
    lines.length ? h('div', { class: 'card-command' }, h('span', { class: 'card-command-label' }, t('noInATerminal')),
      lines.map((line) => copyLine(line.text, line.label))) : null);
}

// Check now (`update.check`, the user's read through an acting page: the node asks GitHub, as the 6 h watch does), with
// what it found said beside it. One for the view, so a node update while it looks keeps it and its words.
function updateCheck(app) {
  const button = doButton(app, { label: t('upCheckNow'), kind: 'update.check', args: () => ({}), busy: t('upChecking'), receipt: (result) => checkedWords(result) });
  return h('div', { class: 'node-act update-check' }, button.el);
}

// Remove all paired browsers (`web.revoke`, the user's through an acting page): every page paired with this node, here
// and over the tailnet, this one too; a second click asks first. Elsewhere `vibeswitcher web --revoke`, and why.
function revokeAll(app) {
  const note = h('p', { class: 'node-says' }, t('noRevokeWords'));
  if (!actsFor(app, 'web.revoke')) {
    return h('div', { class: 'node-act revoke' }, note, h('div', { class: 'card-command' }, h('span', { class: 'card-command-label' }, t('noInATerminal')),
      copyLine('vibeswitcher web --revoke', t('noTheCommandThatRevokes'))), h('p', { class: 'confirm-note' }, app.store.acts() ? t('noRevokeTerminalOnly') : t('noRevokePageReads')));
  }
  const button = doButton(app, { label: t('noRevokeAll'), kind: 'web.revoke', args: () => ({}), danger: true, confirm: t('noRevokeSure'), busy: t('noRevoking'),
    receipt: (result) => t('noRevoked', { n: (result.revoked || 0) + (result.tailnetRevoked || 0) }) });
  return h('div', { class: 'node-act revoke' }, note, button.el);
}

// Whether the node is healthy, in one line, from what it already sends: what waits on you here (`waiting`: what one
// accept settles, and the cards no project holds), its notices, the session host, its health digest and the usage
// limits. { tone: 'calm' | 'asked' | 'working', head, parts: [{ words, group }] }: `asked` when something needs you (each
// part names the group that says why), `working` when only a limit holds work back, `calm` when nothing is wrong.
export function nodeVerdict(node, { accept = 0, cards = 0 } = {}) {
  const asked = [];
  // What one accept settles lists the held cards too (approve.list): counted there, never again as cards. A card no
  // project holds and no group lists (a page that doesn't approve) is said without a link: no group here shows it.
  if (accept) asked.push({ words: t('nvAccept', { n: accept }), group: 'approve' });
  else if (cards) asked.push({ words: t('nvCards', { n: cards }), group: null });
  const notices = node.notices?.length || 0;
  if (notices) asked.push({ words: t('placeNotices', { n: notices }), group: 'notices' });
  if (node.host && node.host.state !== 'connected') asked.push({ words: t('nvHost'), group: 'host' });
  const health = healthFacts(node.health);
  if (health && health.tone !== 'done') asked.push({ words: t('nvHealth'), group: 'health' });
  const limits = usageFacts(node.usage)?.limits?.some((limit) => limit.holds) ? [{ words: t('nvLimits'), group: 'usage' }] : [];
  if (asked.length) return { tone: 'asked', head: t('nvNeedsYou'), parts: [...asked, ...limits] };
  if (limits.length) return { tone: 'working', head: t('nvFineBut'), parts: limits };
  return { tone: 'calm', head: t('nvHealthy'), parts: [] };
}

// The verdict as the detail's first line: a dot, the words, each part a link to its group.
function verdictLine(verdict) {
  const parts = verdict.parts.flatMap((part, index) => [index ? ' · ' : '',
    part.group ? h('a', { class: 'link', href: nodeHref(part.group) }, part.words) : part.words]).filter((part) => part !== '');
  return h('p', { class: `node-verdict ${verdict.tone}`, role: 'status' },
    h('span', { class: verdict.tone === 'calm' ? 'dot tone-done' : verdict.tone === 'asked' ? 'dot tone-needs-you' : 'dot tone-working', 'aria-hidden': 'true' }),
    h('span', { class: 'node-verdict-words' }, h('span', { class: 'node-verdict-head' }, verdict.head), parts.length ? ' ' : null, parts));
}

// The node's passkeys for acting at `confirm` (`node.web.acts.keys`), and its notice when one was added lately.
function passkeysPart(acts) {
  const keys = acts.keys || [];
  if (!keys.length && !acts.notice) return null;
  const when = (iso) => (iso ? dateTime(iso) : t('pkNeverUsed'));
  return h('div', { class: 'passkeys' },
    acts.notice ? h('p', { class: 'node-says passkey-notice' }, acts.notice) : null,
    keys.length ? kit.sectionTitle('p', { class: 'col-title' }, t('pkKeys', { n: keys.length })) : null,
    keys.map((key, index) => h('p', { class: 'passkey-row' }, h('span', { title: key.id }, t('pkKeyN', { n: index + 1 })), ' · ', t('pkKeyWhen', { added: when(key.added), used: when(key.lastUsed) }))));
}

export function nodeView(app) {
  const { store } = app;
  // The places This node points to, at the list's foot: each its own screen.
  const elsewhere = h('div', { class: 'tc-links' });
  const columns = twoColumns(app, { label: t('noThisNode'), title: t('noThisNode'), searchLabel: t('noSearch'), listHref: '#/node', foot: elsewhere });
  columns.onSearch(() => { drawn = ''; render(); });
  const el = columns.el;
  let drawn = '';
  const dictation = dictationGroup();
  // With the `act` right: what one plain accept settles (`approve.list`: the held config, the vouched base moves, the
  // hooks), each listed whole before the click, and the batch approved as the node listed it (`approve`, each item's
  // seen in its order); what needs your own decision listed apart, with its command.
  const approveActs = (() => {
    const el = h('section', { class: 'node-group', hidden: true });
    let asked = '';
    const self = { el, count: 0, refresh(key) { if (key !== asked) { asked = key; load(); } } };
    const load = () => store.read('approve.list', {}).then((reply) => {
      const result = reply.ok ? reply.result : null;
      const items = result?.items || [];
      el.hidden = !items.length && !(result?.own || []).length && !result?.terminal?.count;
      self.count = items.length + (result?.own || []).length + (result?.terminal?.count || 0);
      el.replaceChildren(kit.sectionTitle('h2', {}, t('acApproveTitle')),
        items.length ? h('ol', { class: 'approve-list' }, items.map((item) => h('li', null, h('b', null, item.subject || item.kind), (item.reasons || []).length ? h('ul', { class: 'lines' }, item.reasons.map((reason) => h('li', null, reason))) : null))) : null,
        items.length && result.batch ? doButton(app, { label: t('acApproveAll', { n: items.length }), kind: 'approve', args: () => ({ batch: result.batch, seen: items.map((item) => item.seen ?? null) }), done: load }).el : null,
        // What a page may not approve (the hooks' install): left out of the list, its count and the terminal's command.
        result?.terminal?.count ? h('p', { class: 'node-says' }, t('acTerminalMore', { n: result.terminal.count }), ' ', h('code', null, result.terminal.command || 'vibeswitcher approve')) : null,
        (result?.own || []).length ? h('div', null, h('p', { class: 'node-says' }, t('acOwnDecision')), h('ul', { class: 'lines' }, result.own.map((one) => h('li', null, one.text, ' ', h('code', null, one.command))))) : null);
      // What it holds counts in the list: drawn again.
      drawn = '';
      render();
    });
    return self;
  })();
  // With the `act` right: every plugin (`plugin.list`) with its switch, and Remove for one added (shell is built in).
  const pluginActs = (() => {
    const el = h('div', { class: 'plugin-acts' });
    let asked = '';
    const load = () => store.read('plugin.list', {}).then((reply) => {
      const list = reply.ok ? reply.result.plugins || [] : [];
      el.replaceChildren(...list.map((plugin) => h('div', { class: 'plugin-act' },
        h('span', { class: 'plugin-act-name' }, plugin.title || plugin.id, h('small', null, plugin.unavailable || (plugin.on ? t('noOn') : t('noOff')))),
        doButton(app, { label: plugin.on ? t('acTurnOff') : t('acTurnOn'), kind: plugin.on ? 'plugin.off' : 'plugin.on', plain: plugin.on, args: () => ({ plugin: plugin.id }), done: load }).el,
        plugin.id !== 'shell' && store.can('plugin.remove') ? doButton(app, { label: t('acRemove'), kind: 'plugin.remove', plain: true, confirm: t('acRemoveSure'), args: () => ({ plugin: plugin.id }), done: load }).el : null)));
    });
    return { el, refresh(key) { if (key !== asked) { asked = key; load(); } } };
  })();

  // Check now and Remove all: made once (again when acting or the language changes), so the groups drawn again at a
  // node update keep them, their busy state and what they said.
  let controls = { key: null };
  const controlsNow = () => {
    const key = JSON.stringify([store.acts(), store.can('update.check'), store.can('web.revoke'), lang()]);
    if (key !== controls.key) controls = { key, check: actsFor(app, 'update.check') ? updateCheck(app) : null, revoke: revokeAll(app) };
    return controls;
  };

  // The page's groups, in its order (what needs you and the notices first), each with its key in the address, its
  // title, its count or one-word state (`meta`), and its section; the groups a node doesn't have are left out.
  function groupsOf(node) {
    const { host, server, builds } = node;
    const notes = host.notes;
    const home = node.home;
    const connected = host.state === 'connected';
    const notices = node.notices || [];
    const others = (builds?.installed || []).filter((commit) => commit !== notes?.build);
    const usage = usageFacts(node.usage);
    const health = healthFacts(node.health);
    const update = updateFacts(node.update);
    const approving = actsFor(app, 'approve') && store.can('approve.list') && !approveActs.el.hidden;
    const top = usage?.limits?.length ? Math.max(...usage.limits.map((limit) => limit.percent)) : null;
    return [
      approving ? { key: 'approve', title: t('acApproveTitle'), meta: approveActs.count ? String(approveActs.count) : '', tone: 'asked', metaTone: 'asked', el: approveActs.el } : null,
      notices.length ? { key: 'notices', title: t('noNotices'), meta: String(notices.length), metaTone: 'working', el: h('section', { class: 'node-group' }, kit.sectionTitle('h2', {}, plural(notices.length, t('noNotice'))),
        h('ul', { class: 'notices' }, notices.map((notice) => h('li', null, icon('warning', 14), h('span', null, notice))))) } : null,
      // Acting from a page (`web_acts`): whether this page acts for you and since when, and the switch.
      node.web?.acts ? { key: 'acting', title: t('acGroupTitle'), meta: store.acts() ? t('noOn') : t('noOff'), el: group(t('acGroupTitle'), actsLine(app), passkeysPart(node.web.acts)) } : null,
      { key: 'host', title: t('noSessionHost'), meta: connected ? t('noConnected') : host.state, metaTone: connected ? '' : 'asked', el: group(t('noSessionHost'),
        h('dl', { class: 'facts-list' },
          row(t('noState'), h('span', { class: connected ? 'dot tone-done' : 'dot tone-needs-you', 'aria-hidden': 'true' }), connected ? t('noConnected') : host.state),
          row(t('noRunningFor'), ago(host.startedAt)),
          row(t('noLiveSessions'), String(host.liveSessions)),
          notes ? row(t('noServerRestarts'), String(notes.serverRestarts)) : null,
          notes?.refusedAppConnections ? row(t('noRefusedConnections'), String(notes.refusedAppConnections)) : null),
        technical(row(t('noProcess'), `pid ${host.pid ?? '?'}`),
          (notes?.replacedPaths || []).map((path) => row(t('noTookBackItsPath'), h('span', { class: 'node-path', title: path }, elided(tilde(path, home))))))) },
      usage ? { key: 'usage', title: t('noAccountUsage'), meta: top === null ? '' : `${top}%`, metaTone: usage.limits.some((limit) => limit.holds) ? 'asked' : '', el: usageGroup(node.usage) } : null,
      // Boost (the node's `boost`): on or off, why, and the limits it raises to.
      node.boost ? { key: 'boost', title: t('noBoost'), meta: node.boost.on ? t('noOn') : t('noOff'), metaTone: node.boost.on ? 'working' : '', el: group(t('noBoost'),
        h('dl', { class: 'facts-list' },
          row(t('noState'), h('span', { class: node.boost.on ? 'dot tone-working' : 'dot', 'aria-hidden': 'true' }), node.boost.on ? t('noBoostOnWhy', { why: nodeWords(node.boost.why) }) : t('noBoostOffWhy', { why: nodeWords(node.boost.why) })),
          row(t('noMode'), { on: t('noOn'), off: t('noOff'), automatic: t('noAutomatic') }[node.boost.mode] || node.boost.mode),
          node.boost.on ? row(t('noRaisedLimits'), t('noBoostLimits', { load: node.boost.limits.loadThreshold, sessions: node.boost.limits.maxSessions, workers: node.boost.limits.maxWorkers, slots: node.boost.limits.heavySlots })) : null),
        h('a', { class: 'link', href: settingsHref(null, 'boost') }, t('noChangeItInSettings'))) } : null,
      health ? { key: 'health', title: t('noHealth'), meta: health.tone === 'done' ? t('noFine') : t('noLook'), metaTone: health.tone === 'done' ? '' : 'asked', el: healthGroup(node.health) } : null,
      // The feature plugins that are on (`vibeswitcher plugin list` lists them all; on and off from a terminal).
      Array.isArray(node.plugins) ? { key: 'plugins', title: t('noPlugins'), meta: t('noOnCount', { n: node.plugins.length }), el: group(t('noPlugins'),
        h('dl', { class: 'facts-list' }, node.plugins.length ? node.plugins.map((plugin) => row(plugin.title, h('span', { class: 'dot tone-done', 'aria-hidden': 'true' }), t('noOn')))
          : row(t('noOn'), t('noNone'))),
        actsFor(app, 'plugin.on') && store.can('plugin.list') ? pluginActs.el
          : h('p', { class: 'node-says' }, t('noPluginsInATerminal'))) } : null,
      { key: 'server', title: t('noServer'), meta: '', el: group(t('noServer'),
        h('dl', { class: 'facts-list' },
          row(t('noRunningFor'), ago(server.startedAt))),
        technical(row(t('noProcess'), `pid ${server.pid}`),
          row(t('noNode'), node.node),
          row(t('noStateFolder'), h('span', { class: 'node-path', title: node.root }, elided(tilde(node.root, home)))))) },
      // The web listener this page came in by (the node's `web`; the mock has none).
      node.web ? { key: 'web', title: t('noWebPage'), meta: node.web.state === 'listening' ? t('noOn') : node.web.state === 'off' ? t('noOff') : node.web.state, el: group(t('noWebPage'),
        h('dl', { class: 'facts-list' },
          row(t('noState'), node.web.state === 'listening' ? t('noListening', { port: node.web.port }) : node.web.state === 'off' ? t('noOff') : node.web.state),
          row(t('noPagesPaired'), String(node.web.tokens)),
          row(t('noOpenNow'), String(node.web.connections))),
        controlsNow().revoke) } : null,
      update ? { key: 'updates', title: t('noUpdates'), meta: update.tone === 'needs-you' ? t('noNewer') : update.tone === 'done' ? t('noCurrent') : '', metaTone: update.tone === 'needs-you' ? 'asked' : '', el: updatesGroup(node.update, controlsNow().check) } : null,
      { key: 'build', title: t('noBuild'), meta: server.startedAt ? dayOf(server.startedAt) : shortHash(notes?.build || server.commit),
        el: group(t('noBuild'),
          h('dl', { class: 'facts-list' },
            row(t('noRunning'), buildWords({ commit: notes?.build || server.commit, since: server.commit === (notes?.build || server.commit) ? server.startedAt : null })),
            server.commit !== (notes?.build || server.commit) ? row(t('noServer'), buildWords({ commit: server.commit, since: server.startedAt })) : null,
            builds?.rollback ? row(t('noRollbackGoesTo'), buildWords(rollbackParts(builds.rollback))) : null,
            others.filter((commit) => commit !== builds?.rollback?.commit).length
              ? row(t('noAlsoInstalled'), others.filter((commit) => commit !== builds?.rollback?.commit).flatMap((commit, index) => [index ? ', ' : null, hash(commit)])) : null)) },
      { key: 'rule', title: t('noWhoMayAct'), meta: ruleShort(node.rule?.mode), el: group(t('noWhoMayAct'),
        h('dl', { class: 'facts-list' }, row(t('noWhoMayActNow'), ruleWords(node.rule?.mode))),
        h('p', { class: 'node-says' }, node.rule?.says || ''),
        h('ul', { class: 'lines' }, (node.facts || []).map((line) => h('li', null, line)))) },
      node.accepted?.length ? { key: 'accepted', title: t('noRequestsItTookAsYours'), meta: String(node.accepted.length), el: group(t('noRequestsItTookAsYours'),
        h('ul', { class: 'lines' }, node.accepted.map((entry) => h('li', null, acceptedWords(entry, home), ' · ', tParts('noAgo', { d: ago(entry.at) }))))) } : null,
      node.journal?.length ? { key: 'journal', title: t('noJournal'), meta: String(node.journal.length), el: group(t('noJournal'), h('ul', { class: 'lines' }, node.journal.map((line) => h('li', null, line.replace(/^journal: /, ''))))) } : null,
      // With the `act` right: stop the node (every session ends), asked twice.
      actsFor(app, 'stop') ? { key: 'stop', title: t('acStopTitle'), meta: '', el: group(t('acStopTitle'), h('p', { class: 'node-says' }, t('acStopWords')),
        doButton(app, { label: t('acStopNode'), kind: 'stop', danger: true, confirm: t('acStopSure'), args: () => ({}) }).el) } : null,
      // This page's own: the browser's notifications (js/notify.js) and dictation into a draft (js/dictate.js).
      app.notifications?.el ? { key: 'notifications', title: t('noNotifications'), group: t('noThisBrowser'), meta: app.notifications.enabled?.() ? t('noOn') : t('noOff'), el: app.notifications.el } : null,
      dictation ? { key: 'dictation', title: t('noDictation'), group: t('noThisBrowser'), meta: '', el: dictation } : null,
    ].filter(Boolean).map((one) => ({ ...one, href: nodeHref(one.key) }));
  }

  // The group the address names (when listed), else the one that needs you, else the first; with a search, the first
  // that holds a match when the named one holds none.
  const chosenOf = (listed, route) => listed.find((one) => one.key === route.group) || listed.find((one) => one.tone === 'asked') || listed[0] || null;

  let groups = [];
  // The verdict over every group's detail, drawn again only when it says something else.
  let verdictKey = '';
  let verdictEl = null;
  function verdictOf(node) {
    const approving = actsFor(app, 'approve') && store.can('approve.list') && !approveActs.el.hidden;
    const cards = waitingPlaces(store.state, () => false).find((place) => place.kind === 'node')?.count || 0;
    const verdict = nodeVerdict(node, { accept: approving ? approveActs.count : 0, cards });
    const key = JSON.stringify(verdict);
    if (key !== verdictKey) { verdictKey = key; verdictEl = verdictLine(verdict); }
    return verdictEl;
  }
  function render() {
    if (app.ui.state.route.name !== 'node') return;
    const node = store.state.node;
    const route = app.ui.state.route;
    const query = columns.query();
    const now = JSON.stringify([node, store.state.connection, store.acts(), store.state.phrase, store.state.pageWords, query, approveActs.count, approveActs.el.hidden]);
    if (node && actsFor(app, 'plugin.on') && store.can('plugin.list')) pluginActs.refresh(JSON.stringify(node.plugins));
    if (node && actsFor(app, 'approve') && store.can('approve.list')) approveActs.refresh(JSON.stringify(node.cards));
    columns.fold(!!route.group);
    elsewhere.replaceChildren(
      h('a', { class: 'link', href: '#/mail', title: t('noWhatTheProjectsLeadsTold') }, t('noBetweenLeads')),
      h('a', { class: 'link', href: '#/settings', title: t('noWhatEveryProjectSLeads') }, t('noSettings')),
      app.store.can('stats') ? h('a', { class: 'link', href: '#/stats', title: t('noLoadUsageMergesQualityAnd') }, t('noStatistics')) : null);
    if (now !== drawn) {
      drawn = now;
      groups = node ? groupsOf(node) : [];
    }
    const words = queryWords(query);
    const listed = words.length ? groups.map((one) => ({ ...one, ...searched(one, words) })).filter((one) => one.found) : groups;
    const chosen = chosenOf(listed, route);
    columns.setItems(listed.map((one) => ({ ...one, meta: words.length ? String(one.found) : one.meta, metaTone: words.length ? '' : one.metaTone })), chosen?.key,
      { empty: node && words.length ? t('noNoMatch', { query: query.trim() }) : '' });
    if (!node) {
      columns.show({ title: t('noThisNode'), top: null, body: [h('div', { class: 'head-skeleton', 'aria-hidden': 'true' }, h('span', { class: 'bone wide' }), h('span', { class: 'bone' }), h('span', { class: 'bone short' }))] });
      return;
    }
    const top = verdictOf(node);
    for (const one of groups) { unmarkWords(one.el); if (!words.length) showRows(one.el, null); }
    if (!chosen) {
      columns.show({ title: t('noThisNode'), top, body: [kit.empty({ tag: 'p', size: 'page', class: 'tc-empty' }, t('noNoMatchLong', { query: query.trim() }))] });
      return;
    }
    if (words.length) {
      showRows(chosen.el, words, chosen.titleFound);
      // The words found, marked (the groups are drawn again for each search, so nothing marked stays).
      for (const row of rowsOf(chosen.el)) if (!row.hidden) markWords(row, words);
      // A row found under Technical details: open, so what was found shows.
      for (const fold of foldsOf(chosen.el)) if (rowsOf(fold).some((row) => !row.hidden)) fold.open = true;
    }
    if (columns.detailBody.firstChild !== chosen.el || columns.detailBody.childNodes.length !== 1) columns.show({ title: chosen.title, sub: chosen.group, top, body: [chosen.el] });
    else columns.show({ title: chosen.title, sub: chosen.group, top });
  }

  const schedule = framed(render);
  store.subscribe('node', schedule);
  store.subscribe('connection', schedule);
  // A card no project holds waits here: the verdict counts it.
  store.subscribe('cards', schedule);
  app.ui.subscribe((what) => { if (what === 'route') render(); });
  render();
  return { el, focusSearch: () => columns.focusSearch(), columns };
}
