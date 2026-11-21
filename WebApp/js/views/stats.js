// Statistics (the Mac's Statistics window): the whole setup's figures for today, 7 or 30 days, worked out by the node
// with the Mac's own collector and worded as the Mac's window words them (`stats`). Read-only: the Mac-wide figures
// (load, freezes, Boost, merges, the accounts' usage with their bars), the projects' table with its totals, then
// quality, autonomy, time and cost, the breakdown by who did the work, the 8-week trend, and the estimate compared with
// working solo. A figure whose source isn't kept reads "Not recorded", one with nothing to count "–" (the node's
// words). Asked again when the range changes and every `REFRESH` ms while it shows.

import { h, setText, framed } from '../dom.js';
import { icon } from '../marks.js';

const REFRESH = 60_000;
export const RANGES = [{ id: 'today', label: 'Today' }, { id: 'week', label: '7 days' }, { id: 'month', label: '30 days' }];
export const statsHref = (range) => '#/stats' + (range && range !== 'week' ? '/' + range : '');

// The range a route asks for: one of RANGES, 7 days otherwise.
export function rangeOf(id) {
  return RANGES.some((range) => range.id === id) ? id : 'week';
}

// A bar of a meter or a trend: its width, per mille of the whole, as a percentage the style takes.
export function percent(permille) {
  return `${Math.max(0, Math.min(1000, permille || 0)) / 10}%`;
}

// A bar's span, its size set through the CSSOM (the page's policy refuses a `style` attribute).
function sized(className, property, value, title = '') {
  const el = h('span', { class: className, title: title || null });
  el.style[property] = value;
  return el;
}

// A figure: its label, value and line under it, a usage bar with its pace mark, and its days as small bars.
function figureView(figure) {
  const parts = [h('div', { class: 'stat-figure-head' }, h('span', { class: 'stat-label' }, figure.label), h('span', { class: 'stat-value' }, figure.value))];
  if (figure.meter) {
    const bar = h('div', { class: 'stat-meter' + (figure.meter.reached ? ' reached' : ''), role: 'img', 'aria-label': `${figure.value} used` },
      sized('stat-meter-fill', 'width', percent(figure.meter.used)));
    if (figure.meter.elapsed !== null && figure.meter.elapsed !== undefined) {
      bar.append(sized('stat-meter-pace', 'left', percent(figure.meter.elapsed), 'How much of its window has gone'));
    }
    parts.push(bar);
  }
  if (figure.detail) parts.push(h('p', { class: 'stat-detail' }, figure.detail));
  const days = figure.trend || [];
  if (days.length > 1) {
    const top = Math.max(1, ...days.map((day) => day.value || 0));
    parts.push(h('div', { class: 'stat-days', role: 'img', 'aria-label': days.map((day) => `${day.label} ${day.text}`).join(', ') },
      days.map((day) => h('span', { class: 'stat-day' + (day.value === null ? ' none' : ''), title: `${day.label}: ${day.text}` },
        sized('stat-day-bar', 'height', percent(day.value === null ? 0 : (day.value / top) * 1000))))));
  }
  return h('div', { class: 'stat-figure', title: figure.help || '' }, parts);
}

// A table: its columns' titles (each with its help on hover), and a row a line.
function table(columns, rows, { help = [], first = '' } = {}) {
  return h('div', { class: 'stat-table-wrap' }, h('table', { class: 'stat-table' },
    h('thead', null, h('tr', null, h('th', { scope: 'col' }, first), columns.map((column, index) => h('th', { scope: 'col', title: help[index] || '' }, column)))),
    h('tbody', null, rows.map((row) => h('tr', { class: row.className || '' },
      h('th', { scope: 'row' }, h('span', null, row.name), row.note ? h('span', { class: 'stat-note' }, row.note) : null),
      row.cells.map((cell) => h('td', null, typeof cell === 'string' ? cell : [cell.value, cell.detail ? h('span', { class: 'stat-note' }, cell.detail) : null])))))));
}

// The whole page for one `stats` result.
export function statsBody(result) {
  const parts = [];
  parts.push(h('section', { class: 'node-group' }, h('h2', { class: 'section-title' }, 'This node'),
    h('div', { class: 'stat-figures' }, (result.mac || []).map(figureView))));
  const rows = (result.projects || []).map((row) => ({ name: row.name, note: row.note, cells: row.cells }));
  if (result.total) rows.push({ name: result.total.name, note: result.total.note, cells: result.total.cells, className: 'total' });
  parts.push(h('section', { class: 'node-group' }, h('h2', { class: 'section-title' }, 'Projects'),
    rows.length ? table(result.columns || [], rows, { first: 'Project' })
      : h('p', { class: 'stat-empty' }, 'No project with a lead’s board on this node yet.')));
  const quality = result.quality;
  if (quality) {
    for (const section of quality.sections || []) {
      parts.push(h('section', { class: 'node-group' }, h('h2', { class: 'section-title' }, section.title),
        h('div', { class: 'stat-figures' }, (section.figures || []).map(figureView))));
    }
    if ((quality.breakdown || []).length) {
      parts.push(h('section', { class: 'node-group' }, h('h2', { class: 'section-title' }, 'By who did the work'),
        table(quality.columns || [], quality.breakdown.map((row) => ({ name: row.name, cells: row.cells, className: row.model ? 'model' : '' })),
          { help: quality.columnHelp || [] }),
        quality.modelsNote ? h('p', { class: 'stat-empty' }, quality.modelsNote) : null));
    }
    if ((quality.trend || []).length) {
      parts.push(h('section', { class: 'node-group' }, h('h2', { class: 'section-title' }, 'The last 8 weeks'),
        h('div', { class: 'stat-weeks' }, quality.trend.map((week) => h('div', { class: 'stat-week', title: `Week of ${week.label}: ${week.merged} merged, first-audit pass rate ${week.passRate}, cost per merged task ${week.cost}` },
          h('div', { class: 'stat-week-bars' },
            sized('stat-week-bar pass', 'height', percent(week.passBar ?? 0)),
            sized('stat-week-bar cost', 'height', percent(week.costBar ?? 0))),
          h('span', { class: 'stat-week-label' }, week.label), h('span', { class: 'stat-note' }, `${week.merged} merged`)))),
        h('p', { class: 'stat-legend' }, h('span', { class: 'swatch pass' }), 'first-audit pass rate', h('span', { class: 'swatch cost' }), 'cost per merged task')));
    }
    const compared = quality.compared;
    if (compared && (compared.groups || []).length) {
      parts.push(h('section', { class: 'node-group' },
        h('h2', { class: 'section-title', title: compared.method }, compared.title, h('span', { class: 'stat-badge' }, compared.badge)),
        h('p', { class: 'stat-empty' }, compared.method),
        compared.groups.map((group) => h('div', { class: 'stat-compared' }, h('h3', { class: 'setting-section-title' }, group.title),
          table(compared.columns || [], group.rows.map((row) => ({ name: row.label, cells: row.cells })), { help: [] })))));
    }
  }
  return parts;
}

export function statsView(app) {
  const { store, ui } = app;
  const picker = h('div', { class: 'segmented', role: 'group', 'aria-label': 'Range' },
    RANGES.map((range) => h('button', { type: 'button', 'data-range': range.id, onclick: () => ui.go(statsHref(range.id)) }, range.label)));
  const span = h('span', { class: 'head-state' });
  const body = h('div', { class: 'node-column stats-column' });
  const el = h('section', { class: 'node stats', 'aria-label': 'Statistics' },
    h('header', { class: 'head' },
      h('a', { class: 'back icon-button', href: '#/node', 'aria-label': 'This node' }, icon('back', 16)),
      h('div', { class: 'head-text' }, h('div', { class: 'head-line' }, h('h1', { class: 'head-title' }, 'Statistics'), span)), picker),
    h('div', { class: 'pane node-pane' }, body));
  let results = new Map();
  let failed = null;
  let asking = 0;
  let timer = null;

  const range = () => rangeOf(ui.state.route.name === 'stats' ? ui.state.route.id : null);

  function load() {
    const wanted = range();
    const mine = ++asking;
    store.read('stats', { range: wanted }).then((reply) => {
      if (mine !== asking) return;
      if (reply.ok) { results.set(wanted, reply.result); failed = null; } else {
        failed = reply.error?.code === 'unknown-kind'
          ? 'This node has no statistics yet: its build is older than this page. `vibeswitcher switch` to a newer one.'
          : reply.error?.message || 'The node couldn’t work out its statistics.';
      }
      render();
    });
  }

  let drawn = '';
  function render() {
    if (ui.state.route.name !== 'stats') {
      clearInterval(timer);
      timer = null;
      return;
    }
    if (!timer) timer = setInterval(load, REFRESH);
    const wanted = range();
    picker.querySelectorAll('button').forEach((button) => button.setAttribute('aria-pressed', String(button.dataset.range === wanted)));
    const result = results.get(wanted);
    setText(span, result ? result.span : '');
    const now = JSON.stringify([wanted, result, failed]);
    if (now === drawn) return;
    drawn = now;
    if (result) body.replaceChildren(...statsBody(result));
    else if (failed) body.replaceChildren(h('p', { class: 'stat-empty' }, failed));
    else body.replaceChildren(h('div', { class: 'inspect-skeleton', 'aria-hidden': 'true' }, h('span', { class: 'bone wide' }), h('span', { class: 'bone' }), h('span', { class: 'bone short' })));
  }

  const schedule = framed(render);
  store.subscribe('connection', () => { if (ui.state.route.name === 'stats') load(); });
  ui.subscribe((what) => {
    if (what !== 'route') return;
    if (ui.state.route.name === 'stats') load();
    schedule();
  });
  if (ui.state.route.name === 'stats') load();
  return { el };
}
