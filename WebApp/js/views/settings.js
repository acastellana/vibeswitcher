// Settings: the node's own (the machine-wide limits, usage limits, Boost, leads messaging each other, the working policy)
// and a project's (its models and max_workers in workflow.md, its review rules' floor in the host's vault), as
// `vibeswitcher settings [FOLDER]` reads them: each with its value, its default, where it lives and whether it is a
// guard rail. Change opens a field, and the field shows one way to apply what you pick: Set, where the page acts for you
// (`set`) and may set it, else the line that sets it from a terminal (`vibeswitcher set …`, a click to copy), where the
// change is shown and a code asked. Never both.

import * as kit from '../kit.js';
import { h, setText, framed } from '../dom.js';
import { icon } from '../marks.js';
import { tilde, lastPart, elided } from '../words.js';
export { elided };
import { copyLine } from './cards.js';
import { usageGroup } from './node.js';
import { terminalLookSection } from './termlook.js';
import { settingSections, setLine, draftProblem, shownValue, settingMatches, countRange, numberCeiling } from '../settings.js';
import { t } from '../i18n.js';
import { actsFor, doButton, pageMaySet, refusalWords } from '../acting.js';
import { twoColumns, marked, queryWords } from './twocol.js';

// How often the open page reads the settings again (a `set` from a terminal shows by then).
const REFRESH = 15000;

// `#/settings`, a project's (`#/settings/<project>`, its first section), a section of the node's or a project's
// (`#/settings/node/<section>`, `#/settings/<project>/<section>`), and this browser's terminal (`#/settings/terminal`).
export function settingsHref(project, section = null) {
  if (section === 'terminal' && !project) return '#/settings/terminal';
  const scope = project ? '/' + encodeURIComponent(project) : section ? '/node' : '';
  return '#/settings' + scope + (section ? '/' + encodeURIComponent(section) : '');
}
// A section's part of the address: its title, lower-cased, a dash for anything not a letter or a digit.
export const sectionSlug = (title) => String(title || '').toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'section';

// One setting's row: its title and value, what it does, where it lives; Change opens its field and the drafted line.
// With `words` (a search's), each one is marked where it is found: in the title, what it does, or its key.
function settingRow(setting, { folder, home, editing, toggle, app = null, words = [], changed = () => {} }) {
  const drafted = editing.get(setting.key);
  // On or off, where the page may set it: the switch, one press (D16). Else its value in words, and Change.
  const switched = setting.form === 'flag' && pageSets(app, setting, 'on') && pageSets(app, setting, 'off');
  const flagWords = setting.form === 'flag' ? { on: t('noOn'), off: t('noOff') }[setting.value] : null;
  const value = flagWords ? h('span', { class: 'setting-value words' }, flagWords)
    : h('code', { class: 'setting-value', title: setting.value }, shownValue(setting) || t('svEmpty'));
  const marks = [
    setting.isDefault ? kit.badge('neutral', t('svMarkDefault'), { class: 'setting-mark' }) : kit.badge('neutral', t('svMarkChanged'), { class: 'setting-mark changed', title: t('svDefaultIs', { x: setting.default }) }),
    setting.guardRail ? kit.badge('neutral', t('svMarkRail'), { class: 'setting-mark rail', title: t('svAChangeHereIsRecorded') }) : null,
  ];
  // A control that looks like one (the page's quiet button), always at the row's end with the value beside it.
  const change = switched ? null : kit.button('plain', { size: 's', class: 'setting-change', 'aria-expanded': String(drafted != null), onclick: () => toggle(setting) },
    drafted != null ? t('svClose') : t('svChange'));
  const end = switched ? flagSwitch(app, setting, folder, changed) : [value, change];
  // Where it is kept is a file a person never needs to act here: behind "Where it's kept", ~/… and the middle elided,
  // whole on hover (D16, D18). The machine-wide limits' file keeps the Mac's name (mac-limits.json): this node's.
  const place = setting.home === 'floor' ? setting.where : tilde(setting.where, home);
  const where = [];
  if (!setting.isDefault) where.push(t('svDefaultWhere', { x: setting.form === 'text' ? t('svFiveRules') : setting.form === 'flag' ? ({ on: t('noOn'), off: t('noOff') }[setting.default] || setting.default) : setting.default }));
  const range = rangeWords(setting);
  if (range && setting.form !== 'flag') where.push(range);
  return h('div', { class: 'setting', data: { key: setting.key } },
    h('div', { class: 'setting-head' },
      h('span', { class: 'setting-title' }, marked(setting.title, words)), marks, h('span', { class: 'setting-spacer' }), h('span', { class: 'setting-end' }, end)),
    h('p', { class: 'setting-about' }, marked(setting.about, words)),
    h('p', { class: 'setting-where' }, words.some((word) => String(setting.key).toLowerCase().includes(word)) ? [h('code', null, marked(setting.key, words)), ' · '] : null,
      where.length ? where.join(' · ') + ' · ' : null,
      place ? h('span', { class: 'setting-file', title: place, tabindex: 0 }, t('svWhereKept'), ' ', h('span', { class: 'setting-file-path' }, elided(place))) : null),
    setting.note ? h('p', { class: 'setting-note' }, icon('warning', 12), setting.note) : null,
    drafted != null ? editor(setting, folder, editing, app) : null);
}

// The values a setting takes, in the page's words where the node words them as numbers ("1 to 12", "above 0, at most
// 48"); the node's own words otherwise (a list of choices, a model's name).
export function rangeWords(setting) {
  const range = countRange(setting.limits);
  if (range) return t('svRange', range);
  const ceiling = numberCeiling(setting.limits);
  if (ceiling !== null) return t('svAtMost', { high: ceiling });
  if (/^above 0$/.test(String(setting.limits || '').trim())) return t('svAboveZero');
  return setting.limits || '';
}

// An on/off setting the page may set: the switch, sent at one press (`set`, as Set sends it), busy while the node
// answers, what it did said beside it, its refusal too with the switch put back.
function flagSwitch(app, setting, folder, changed) {
  const said = h('span', { class: 'act-said', role: 'status' });
  const box = kit.toggle({ 'aria-label': setting.title, checked: setting.value === 'on' });
  box.checked = setting.value === 'on';
  box.addEventListener('change', () => {
    const value = box.checked ? 'on' : 'off';
    box.disabled = true;
    box.setAttribute('aria-busy', 'true');
    setText(said, '');
    said.classList.remove('refused', 'receipt');
    app.store.request('set', { ...(folder && setting.scope === 'project' ? { folder } : {}), key: setting.key, value }).then((reply) => {
      box.disabled = false;
      box.removeAttribute('aria-busy');
      if (reply.ok) {
        setText(said, value === 'on' ? t('svSwitchedOn') : t('svSwitchedOff'));
        said.classList.add('receipt');
        changed();
        return;
      }
      box.checked = !box.checked;
      setText(said, refusalWords(reply.error, setting.title));
      said.classList.add('refused');
    });
  });
  return h('span', { class: 'setting-switch' }, said, box);
}

// Whether the page sets `setting` to `value` itself: it acts for you (`set`), and the setting is one a page may set.
const pageSets = (app, setting, value) => !!app && actsFor(app, 'set') && pageMaySet(setting.key, value);

// The field for a new value and one way to apply it: Set where the page sets it (pageSets), else the line that sets it
// from a terminal with its Copy, and what running it does. Never both, so it is clear which one applies it.
export function editor(setting, folder, editing, app = null) {
  const lineSlot = h('div');
  const problem = h('p', { class: 'card-notice', role: 'alert', hidden: true });
  let control;
  const draw = () => {
    const value = editing.get(setting.key) ?? '';
    const why = draftProblem(setting, value);
    problem.hidden = !why;
    if (why) setText(problem, t('svIsWhy', { key: setting.key, why }));
    // With the `act` right, Set sets it from here (`set`), but for what a page may not set (a floor, the policy,
    // web_acts raised): those stay the terminal's line.
    const project = setting.scope === 'project';
    if (why) lineSlot.replaceChildren(h('span'));
    else if (pageSets(app, setting, value)) {
      lineSlot.replaceChildren(doButton(app, { label: t('acSet'), kind: 'set',
        args: () => ({ ...(folder ? { folder } : {}), key: setting.key, value: String(editing.get(setting.key) ?? '') }), done: () => { editing.delete(setting.key); } }).el,
      h('p', { class: 'confirm-note' }, project ? t('svSetNowProject') : t('svSetNow')));
    } else {
      lineSlot.replaceChildren(...[copyLine(setLine(setting, value, folder), t('svSetsCommand', { key: setting.key })),
        h('p', { class: 'confirm-note' }, project ? t('svRunItInATerminal') : t('svRunItInATerminal2')),
        // A page that acts, on a setting the node keeps to a terminal: why there is no Set here.
        app && actsFor(app, 'set') && !pageMaySet(setting.key, value) ? h('p', { class: 'confirm-note set-why' }, t('svTerminalKeeps')) : null].filter(Boolean));
    }
  };
  const take = (value) => { editing.set(setting.key, value); draw(); };
  const name = t('svNewValue', { title: setting.title });
  switch (setting.form) {
    case 'flag':
    case 'choice': {
      const choices = setting.form === 'flag' ? ['on', 'off'] : setting.choices;
      control = kit.select({ wrap: 'setting-input', 'aria-label': name, onchange: (event) => take(event.target.value) },
        choices.map((choice) => h('option', { value: choice, selected: choice === editing.get(setting.key) }, choice)));
      break;
    }
    case 'text':
      control = kit.field({ tag: 'textarea', kind: 'code', class: 'setting-input setting-text', rows: 7, 'aria-label': name, oninput: (event) => take(event.target.value) });
      control.value = editing.get(setting.key) ?? '';
      break;
    default:
      control = kit.field({ kind: 'code', class: 'setting-input', 'aria-label': name, inputmode: setting.form === 'count' || setting.form === 'number' ? 'decimal' : 'text',
        spellcheck: 'false', autocomplete: 'off', oninput: (event) => take(event.target.value) });
      control.value = editing.get(setting.key) ?? '';
  }
  // A number keeps its field, with the values it takes said beside it.
  const range = setting.form === 'count' || setting.form === 'number' ? rangeWords(setting) : '';
  const reset = kit.button('quiet', { size: 's', title: t('svDraftTheLineThatPuts'), onclick: () => {
    if (!control.control) control.value = 'default';
    take('default');
  } }, t('svDefault'));
  draw();
  return h('div', { class: 'confirm setting-editor', role: 'group', 'aria-label': t(pageSets(app, setting, setting.value) ? 'svChangeIt' : 'svChangeFrom', { title: setting.title }) },
    h('div', { class: 'setting-controls' }, control, range ? h('span', { class: 'setting-range' }, range) : null, reset), problem, lineSlot);
}


// The settings' sections, as the list shows them: the node's, then each project's (its folder's name), then this
// browser's terminal, each with how many settings it holds; with a search, only the sections holding a match, with
// how many match. Each: { key, href, title, group, settings, matches, scope, project, folder, kind }.
export function settingsList(results, query, { projects = [], leftOut = [] } = {}) {
  const words = queryWords(query);
  const items = [];
  const add = (group, scope, project, folder, settings) => {
    for (const section of settingSections(settings)) {
      const slug = sectionSlug(section.title);
      const matches = section.settings.filter((setting) => settingMatches(setting, query));
      if (words.length && !matches.length) continue;
      items.push({ key: `${scope}/${slug}`, href: settingsHref(project, slug), title: section.title, group, scope, project, folder, kind: 'settings',
        settings: section.settings, matches, meta: String(words.length ? matches.length : section.settings.length) });
    }
  };
  if (results?.node) {
    add(t('svThisNodeEveryProject'), 'node', null, null, results.node.settings);
    if (!words.length && leftOut.length) {
      items.push({ key: 'node/not-on-a-node', href: settingsHref(null, 'not-on-a-node'), title: t('svNotOnANode'), group: t('svThisNodeEveryProject'), scope: 'node', kind: 'left-out', meta: String(leftOut.length), tone: 'dim' });
    }
  }
  for (const one of projects) {
    if (one.result?.settings) add(t('svProjectGroup', { name: lastPart(one.result.root || one.root) }), one.project, one.project, one.result.root || one.root, one.result.settings);
  }
  // This browser's own, not among what the search looks through (none of its words are settings').
  if (!words.length) items.push({ key: 'terminal', href: settingsHref(null, 'terminal'), title: t('svTerminal'), group: t('svThisBrowser'), scope: 'terminal', kind: 'terminal' });
  return items;
}

// Which section the detail shows: the one the address names when it is listed, else (an address naming none, or one
// the search left out) the first of the project the address names, else the first listed.
export function chosenSection(items, route) {
  const scope = route.id || (route.section === 'terminal' ? 'terminal' : 'node');
  const key = route.section === 'terminal' ? 'terminal' : route.section ? `${scope}/${route.section}` : null;
  return items.find((item) => item.key === key) || (route.id ? items.find((item) => item.scope === route.id) : null) || items[0] || null;
}

export function settingsView(app) {
  const { store, ui } = app;
  // What the page says Change does: Set where the page acts for you, else the line for a terminal (render keeps it so).
  const intro = h('p', { class: 'tc-note' });
  const columns = twoColumns(app, { label: t('svSettings'), title: t('svSettings'), searchLabel: t('svSearchSettings'), listHref: '#/settings', foot: intro });
  columns.onSearch(() => { drawn = ''; render(true); });
  // This browser's own: the terminal's look (views/termlook.js).
  const terminalLook = terminalLookSection();
  // Per section's scope (the node's, each project's) and key: the value being drafted (its field open). Kept while the
  // page reads the settings again.
  const editing = new Map();
  const editingOf = (scope) => { if (!editing.has(scope)) editing.set(scope, new Map()); return editing.get(scope); };
  let result = null;
  let failed = null;
  // Each project's settings, by its id: { project, root, result, asked }.
  const projects = new Map();
  let drawn = '';
  let asking = 0;
  let timer = null;

  // Every project the page knows a folder for: its lead's, else its board's (a project whose lead isn't running).
  const leads = () => {
    const known = new Map();
    for (const one of [...store.state.leads.values(), ...store.state.boards.values()]) if (one.project && one.root && !known.has(one.project)) known.set(one.project, { project: one.project, root: one.root });
    return [...known.values()].sort((a, b) => lastPart(a.root).localeCompare(lastPart(b.root)));
  };

  // The node's settings (asked without a folder) and each project's (asked with its folder), all again at each look.
  function load() {
    const mine = ++asking;
    store.request('settings', {}).then((reply) => {
      if (mine !== asking) return;
      if (reply.ok) { result = reply.result; failed = null; } else {
        failed = reply.error?.code === 'unknown-kind' ? t('svThisNodeHasNoSettings') : reply.error?.message || t('svTheNodeCouldnTRead');
      }
      render();
    });
    for (const lead of leads()) {
      const known = projects.get(lead.project);
      if (!known || known.root !== lead.root) projects.set(lead.project, { project: lead.project, root: lead.root, result: null });
      store.request('settings', { folder: lead.root }).then((reply) => {
        if (mine !== asking) return;
        const one = projects.get(lead.project);
        if (one && reply.ok && reply.result.project) { one.result = reply.result.project; render(); }
      });
    }
    const still = new Set(leads().map((lead) => lead.project));
    for (const id of [...projects.keys()]) if (!still.has(id)) projects.delete(id);
  }

  function toggle(scope, setting) {
    const mine = editingOf(scope);
    if (mine.has(setting.key)) mine.delete(setting.key);
    else mine.set(setting.key, setting.value);
    drawn = '';
    render();
  }

  function sectionBody(item, words) {
    const home = store.state.node?.home;
    if (item.kind === 'terminal') return [terminalLook.el];
    if (item.kind === 'left-out') return [h('ul', { class: 'lines' }, (result.leftOut || []).map((one) => h('li', null, `${one.title}: ${one.why}`)))];
    const shown = words.length ? item.matches : item.settings;
    const scope = item.scope;
    const usage = !words.length && scope === 'node' && item.settings.some((setting) => /usage/.test(setting.key)) ? usageGroup(result.usage) : null;
    return [
      usage,
      h('div', { class: 'setting-section' }, shown.map((setting) => settingRow(setting, {
        folder: item.folder, home, editing: editingOf(scope), toggle: (one) => toggle(scope, one), app, words, changed: () => load() }))),
    ].filter(Boolean);
  }

  function render(typing = false) {
    if (ui.state.route.name !== 'settings') return;
    setText(intro, actsFor(app, 'set') ? t('svIntroActs') : t('svWhatTheLeadsAndTheir'));
    const route = ui.state.route;
    const query = columns.query();
    const words = queryWords(query);
    const listed = [...projects.values()];
    const items = settingsList(result, query, { projects: listed, leftOut: result?.leftOut || [] });
    const chosen = chosenSection(items, route);
    columns.fold(!!(route.id || route.section));
    columns.setItems(items, chosen?.key, { empty: result && words.length ? t('svNoMatch', { query: query.trim() }) : '' });
    // Someone typing in a field keeps it: the page draws again once they leave it.
    const active = document.activeElement;
    if (!typing && active && columns.detail.contains(active) && active.matches?.('input, textarea, select')) return;
    const now = JSON.stringify([result && chosen ? [chosen.key, chosen.settings, result.usage, result.leftOut] : null, failed, chosen?.kind,
      [...(editing.get(chosen?.scope) || new Map()).keys()], query, store.acts(), store.state.node?.home]);
    if (now === drawn) return;
    drawn = now;
    if (failed) {
      columns.show({ title: t('svSettings'), body: [h('p', { class: 'card-notice', role: 'alert' }, failed)] });
      return;
    }
    if (!result) {
      columns.show({ title: t('svSettings'), body: [h('div', { class: 'head-skeleton', 'aria-hidden': 'true' }, h('span', { class: 'bone wide' }), h('span', { class: 'bone' }), h('span', { class: 'bone short' }))] });
      return;
    }
    if (!chosen) {
      columns.show({ title: t('svSettings'), body: [kit.empty({ tag: 'p', size: 'page', class: 'tc-empty' }, words.length ? t('svNoMatchLong', { query: query.trim() }) : t('svNoneHere'))] });
      return;
    }
    const counted = chosen.kind === 'settings' ? (words.length ? t('svMatchCount', { n: chosen.matches.length }) : t('svCount', { n: chosen.settings.length })) : '';
    columns.show({ title: chosen.title, sub: [chosen.group, counted].filter(Boolean).join(' · '), body: sectionBody(chosen, words) });
  }

  const schedule = framed(render);
  let leadsAsked = '';
  const projectsChanged = () => {
    if (ui.state.route.name !== 'settings') return;
    // A project came or went, or its folder came with the leads: its settings asked for.
    const key = JSON.stringify(leads().map((lead) => [lead.project, lead.root]));
    if (key !== leadsAsked) { leadsAsked = key; load(); }
    schedule();
  };
  store.subscribe('leads', projectsChanged);
  store.subscribe('boards', projectsChanged);
  store.subscribe('node', schedule);
  store.subscribe('connection', () => { if (ui.state.route.name === 'settings' && store.state.connection === 'live') load(); });
  let inside = false;
  function entered() {
    const here = ui.state.route.name === 'settings';
    if (here) terminalLook.update();
    if (here === inside) { if (here) render(); return; }
    inside = here;
    clearInterval(timer);
    timer = null;
    if (!here) return;
    leadsAsked = JSON.stringify(leads().map((lead) => [lead.project, lead.root]));
    drawn = '';
    render();
    load();
    timer = setInterval(() => { if (!document.hidden) load(); }, REFRESH);
  }
  ui.subscribe((what) => { if (what === 'route') entered(); });
  entered();
  return { el: columns.el, focusSearch: () => columns.focusSearch(), columns };
}
