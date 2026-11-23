// Settings: the node's own (the machine-wide limits, usage limits, Boost, leads messaging each other, the working policy)
// and a project's (its models and max_workers in workflow.md, its review rules' floor in the host's vault), as
// `vibeswitcher settings [FOLDER]` reads them: each with its value, its default, where it lives and whether it is a
// guard rail. Calm and read-only: Change opens a field, and what you pick becomes the line that sets it from a terminal
// (`vibeswitcher set …`, a click to copy), where the change is shown and a code asked. Nothing here changes a setting.

import { h, setText, framed } from '../dom.js';
import { icon } from '../marks.js';
import { tilde, lastPart } from '../words.js';
import { copyLine } from './cards.js';
import { usageGroup } from './node.js';
import { terminalLookSection } from './termlook.js';
import { settingSections, setLine, draftProblem, shownValue, settingMatches } from '../settings.js';
import { t } from '../i18n.js';
import { actsFor, doButton, pageMaySet } from '../acting.js';

// How often the open page reads the settings again (a `set` from a terminal shows by then).
const REFRESH = 15000;

export const settingsHref = (project) => '#/settings' + (project ? '/' + encodeURIComponent(project) : '');

// One setting's row: its title and value, what it does, where it lives; Change opens its field and the drafted line.
function settingRow(setting, { folder, home, editing, toggle, app = null }) {
  const drafted = editing.get(setting.key);
  const value = h('code', { class: 'setting-value', title: setting.value }, shownValue(setting) || t('svEmpty'));
  const marks = [
    setting.isDefault ? h('span', { class: 'setting-mark' }, t('svMarkDefault')) : h('span', { class: 'setting-mark changed', title: t('svDefaultIs', { x: setting.default }) }, t('svMarkChanged')),
    setting.guardRail ? h('span', { class: 'setting-mark rail', title: t('svAChangeHereIsRecorded') }, t('svMarkRail')) : null,
  ];
  const change = h('button', { class: 'confirm-clear', type: 'button', 'aria-expanded': String(drafted != null), onclick: () => toggle(setting) },
    drafted != null ? t('svClose') : t('svChange'));
  // The machine-wide limits' file keeps the Mac's name (mac-limits.json, which the leads' tools read): this node's.
  const where = [setting.home === 'floor' ? setting.where : (setting.home === 'limits' ? t('svThisNodeSLimits') : '') + tilde(setting.where, home)];
  if (!setting.isDefault) where.push(t('svDefaultWhere', { x: setting.form === 'text' ? t('svFiveRules') : setting.default }));
  if (setting.limits) where.push(setting.limits);
  return h('div', { class: 'setting', data: { key: setting.key } },
    h('div', { class: 'setting-head' },
      h('span', { class: 'setting-title' }, setting.title), marks, h('span', { class: 'setting-spacer' }), value, change),
    h('p', { class: 'setting-about' }, setting.about),
    h('p', { class: 'setting-where' }, where.join(' · ')),
    setting.note ? h('p', { class: 'setting-note' }, icon('warning', 12), setting.note) : null,
    drafted != null ? editor(setting, folder, editing, app) : null);
}

// The field for a new value and the line it makes: a click to copy, never sent from here.
function editor(setting, folder, editing, app = null) {
  const lineSlot = h('div');
  const problem = h('p', { class: 'card-notice', role: 'alert', hidden: true });
  let control;
  const draw = () => {
    const value = editing.get(setting.key) ?? '';
    const why = draftProblem(setting, value);
    problem.hidden = !why;
    if (why) setText(problem, t('svIsWhy', { key: setting.key, why }));
    // With the `act` right, Set sets it from here (`set`), but for what a page may not set (a floor, the policy,
    // web_acts on): those stay the terminal's line.
    const acts = !why && app && actsFor(app, 'set') && pageMaySet(setting.key, value);
    lineSlot.replaceChildren(...(why ? [h('span')] : [acts ? doButton(app, { label: t('acSet'), kind: 'set',
      args: () => ({ ...(folder ? { folder } : {}), key: setting.key, value: String(editing.get(setting.key) ?? '') }), done: () => { editing.delete(setting.key); } }).el : null,
    copyLine(setLine(setting, value, folder), t('svSetsCommand', { key: setting.key }))].filter(Boolean)));
  };
  const take = (value) => { editing.set(setting.key, value); draw(); };
  const name = t('svNewValue', { title: setting.title });
  switch (setting.form) {
    case 'flag':
    case 'choice': {
      const choices = setting.form === 'flag' ? ['on', 'off'] : setting.choices;
      control = h('select', { class: 'setting-input', 'aria-label': name, onchange: (event) => take(event.target.value) },
        choices.map((choice) => h('option', { value: choice, selected: choice === editing.get(setting.key) }, choice)));
      break;
    }
    case 'text':
      control = h('textarea', { class: 'setting-input setting-text', rows: 7, 'aria-label': name, oninput: (event) => take(event.target.value) });
      control.value = editing.get(setting.key) ?? '';
      break;
    default:
      control = h('input', { class: 'setting-input', 'aria-label': name, inputmode: setting.form === 'count' || setting.form === 'number' ? 'decimal' : 'text',
        spellcheck: 'false', autocomplete: 'off', oninput: (event) => take(event.target.value) });
      control.value = editing.get(setting.key) ?? '';
  }
  const reset = h('button', { class: 'confirm-clear', type: 'button', title: t('svDraftTheLineThatPuts'), onclick: () => {
    if (control.tagName !== 'SELECT') control.value = 'default';
    take('default');
  } }, t('svDefault'));
  draw();
  return h('div', { class: 'confirm setting-editor', role: 'group', 'aria-label': t('svChangeFrom', { title: setting.title }) },
    h('div', { class: 'setting-controls' }, control, reset), problem, lineSlot,
    h('p', { class: 'confirm-note' }, setting.scope === 'project'
      ? t('svRunItInATerminal')
      : t('svRunItInATerminal2')));
}

export function settingsView(app) {
  const { store, ui } = app;
  const picker = h('select', { class: 'setting-picker', 'aria-label': t('svWhoseSettings'), onchange: (event) => ui.go(settingsHref(event.target.value)) });
  // The app's search: the settings whose words hold every word typed.
  let query = '';
  const search = h('input', { class: 'setting-search', type: 'search', placeholder: t('svSearchSettings'), 'aria-label': t('svSearchSettings'),
    spellcheck: 'false', autocomplete: 'off', oninput: (event) => { query = event.target.value; drawn = ''; render(true); } });
  const body = h('div', { class: 'node-column settings-column' });
  // This browser's own: the terminal's look (views/termlook.js), drawn apart from the node's settings.
  const terminalLook = terminalLookSection();
  const el = h('section', { class: 'node settings', 'aria-label': t('svSettings') },
    h('header', { class: 'head' },
      h('a', { class: 'back icon-button', href: '#/node', 'aria-label': t('svThisNode') }, icon('back', 16)),
      h('div', { class: 'head-text' }, h('div', { class: 'head-line' }, h('h1', { class: 'head-title' }, t('svSettings')), picker))),
    h('div', { class: 'pane node-pane' }, search, body, h('div', { class: 'node-column settings-column' }, terminalLook.el)));
  // Per key: the value being drafted (its field open). Kept while the page reads the settings again.
  const editing = new Map();
  let result = null;
  let failed = null;
  let shownFor = undefined;
  let drawn = '';
  let asking = 0;
  let askedFolder = undefined;
  let timer = null;

  const project = () => (ui.state.route.name === 'settings' ? ui.state.route.id || null : null);
  const leads = () => [...store.state.leads.values()].filter((lead) => lead.root).sort((a, b) => lastPart(a.root).localeCompare(lastPart(b.root)));
  const folderOf = (id) => (id ? store.state.leads.get(id)?.root || store.state.boards.get(id)?.root || null : null);

  function load() {
    const id = project();
    const folder = folderOf(id);
    askedFolder = folder;
    const mine = ++asking;
    store.request('settings', folder ? { folder } : {}).then((reply) => {
      if (mine !== asking) return;
      if (reply.ok) { result = reply.result; failed = null; } else {
        failed = reply.error?.code === 'unknown-kind'
          ? t('svThisNodeHasNoSettings')
          : reply.error?.message || t('svTheNodeCouldnTRead');
      }
      render();
    });
  }

  function toggle(setting) {
    if (editing.has(setting.key)) editing.delete(setting.key);
    else editing.set(setting.key, setting.value);
    drawn = '';
    render();
  }

  function group(title, all, folder, home) {
    const settings = all.filter((setting) => settingMatches(setting, query));
    if (query && settings.length === 0) return null;
    return h('section', { class: 'node-group' }, h('h2', { class: 'section-title' }, title),
      settingSections(settings).map((section) => h('div', { class: 'setting-section' },
        h('h3', { class: 'setting-section-title' }, section.title),
        section.settings.map((setting) => settingRow(setting, { folder, home, editing, toggle, app })))));
  }

  function render(typing = false) {
    if (ui.state.route.name !== 'settings') return;
    const id = project();
    // The project's folder came with the leads after the page asked without it: asked again with it.
    if (id && folderOf(id) && askedFolder === null) load();
    const choices = leads();
    const key = JSON.stringify([id, choices.map((lead) => [lead.project, lead.root])]);
    if (picker.dataset.drawn !== key) {
      picker.dataset.drawn = key;
      picker.replaceChildren(h('option', { value: '' }, t('svThisNode')),
        ...choices.map((lead) => h('option', { value: lead.project, selected: lead.project === id }, lastPart(lead.root))));
      picker.value = id && choices.some((lead) => lead.project === id) ? id : '';
      picker.hidden = choices.length === 0;
    }
    // Someone typing in a field keeps it: the page draws again once they leave it.
    if (!typing && body.contains(document.activeElement) && document.activeElement.matches('input, textarea, select')) return;
    const now = JSON.stringify([result, failed, [...editing.keys()], query]);
    if (now === drawn) return;
    drawn = now;
    const home = store.state.node?.home;
    if (failed) {
      body.replaceChildren(h('p', { class: 'card-notice', role: 'alert' }, failed));
      return;
    }
    if (!result) {
      body.replaceChildren(h('div', { class: 'head-skeleton', 'aria-hidden': 'true' }, h('span', { class: 'bone wide' }), h('span', { class: 'bone' }), h('span', { class: 'bone short' })));
      return;
    }
    const projectPart = result.project
      ? group(t('svProject', { name: lastPart(result.project.root) }), result.project.settings, result.project.root, home) : null;
    body.replaceChildren(...[
      h('p', { class: 'settings-intro' }, t('svWhatTheLeadsAndTheir')),
      projectPart,
      group(t('svThisNodeEveryProject'), result.node.settings, null, home),
      query && ![...(result.project?.settings || []), ...result.node.settings].some((setting) => settingMatches(setting, query))
        ? h('p', { class: 'node-says' }, t('svNoMatch', { query })) : null,
      query ? null : usageGroup(result.usage),
      !query && result.leftOut?.length ? h('section', { class: 'node-group' }, h('h2', { class: 'section-title' }, t('svNotOnANode')),
        h('ul', { class: 'lines' }, result.leftOut.map((item) => h('li', null, `${item.title}: ${item.why}`)))) : null,
    ].filter(Boolean));
  }

  const schedule = framed(render);
  store.subscribe('leads', schedule);
  store.subscribe('node', schedule);
  store.subscribe('connection', () => { if (ui.state.route.name === 'settings' && store.state.connection === 'live') load(); });
  function entered() {
    clearInterval(timer);
    if (ui.state.route.name === 'settings') terminalLook.update();
    timer = null;
    if (ui.state.route.name !== 'settings') return;
    const id = project();
    if (id !== shownFor) {
      shownFor = id;
      result = null;
      failed = null;
      editing.clear();
      drawn = '';
    }
    render();
    load();
    timer = setInterval(() => { if (!document.hidden) load(); }, REFRESH);
  }
  ui.subscribe((what) => { if (what === 'route') entered(); });
  entered();
  return { el };
}
