// Two columns inside the centre, shared by Your own sessions, This node and Settings (the left column's three places):
// a narrow list (its title and the screen's own buttons at its head, a search box, the rows grouped, links at its foot)
// and the chosen row's detail beside it. The address says which row is chosen (each row is a link), so reload and
// back/forward keep it. The rows are kept by key and updated in place, so a snapshot that changes leaves the list's
// scroll, focus and choice where they were. Under 760 px it folds to one column: the list, or the detail with a link
// back to the list (style.css, `.twocol[data-pane]`).
//
// Keys: ↑ ↓ (and Home, End) move between the rows, ↩ opens one (a link's own), ↓ from the search box goes into the
// list and ↩ there opens the first row; Esc clears the search; `/` focuses it from anywhere on the screen (app.js,
// `wantsSearch`).
//
// An item: { key, href, title, sub?, meta?, tone?, group?, about?, mark?: () => node, markKey? }. `tone: 'asked'` draws
// it in the asking colour; `meta` is its count or one-word state; `group` the heading it goes under (in the order the
// items come); `mark` a node drawn before its title, made again only when `markKey` changes.

import { h, setText, setClass } from '../dom.js';
import { icon } from '../marks.js';
import { t } from '../i18n.js';

// Whether a key press asks for the screen's search box: `/` alone, typed outside any field.
export function wantsSearch(event) {
  if (event.key !== '/' || event.metaKey || event.ctrlKey || event.altKey) return false;
  const target = event.target;
  if (!target || typeof target.closest !== 'function') return true;
  return !target.closest('input, textarea, select, [contenteditable=""], [contenteditable="true"], .terminal-screen');
}

// The words of `query`, lower-cased: what a row or a setting must hold every one of.
export const queryWords = (query) => String(query || '').toLowerCase().split(/\s+/).filter(Boolean);
export const holdsAll = (text, words) => { const said = String(text || '').toLowerCase(); return words.every((word) => said.includes(word)); };

// `text` as nodes with each word of `words` in it marked (<mark>, made as an element, never markup).
export function marked(text, words) {
  const value = String(text ?? '');
  const wanted = (words || []).filter(Boolean);
  if (!wanted.length || !value) return [value];
  const lower = value.toLowerCase();
  const spans = [];
  for (const word of wanted) {
    let at = lower.indexOf(word);
    while (at >= 0) { spans.push([at, at + word.length]); at = lower.indexOf(word, at + word.length); }
  }
  if (!spans.length) return [value];
  spans.sort((a, b) => a[0] - b[0]);
  const merged = [];
  for (const span of spans) {
    const last = merged[merged.length - 1];
    if (last && span[0] <= last[1]) last[1] = Math.max(last[1], span[1]); else merged.push([...span]);
  }
  const parts = [];
  let at = 0;
  for (const [from, to] of merged) {
    if (from > at) parts.push(value.slice(at, from));
    parts.push(h('mark', { class: 'found' }, value.slice(from, to)));
    at = to;
  }
  if (at < value.length) parts.push(value.slice(at));
  return parts;
}

export function twoColumns(app, { label, title, searchLabel, placeholder = searchLabel, head = [], foot = null, listHref = null }) {
  let query = '';
  let onSearch = () => {};
  const menu = h('button', { class: 'icon-button phone-only', type: 'button', 'aria-label': t('menu'), onclick: () => app.drawer?.('left') }, icon('menu', 16));
  const search = h('input', {
    class: 'tc-search', type: 'search', placeholder, 'aria-label': searchLabel, spellcheck: 'false', autocomplete: 'off',
    oninput: (event) => { query = event.target.value; onSearch(query); },
  });
  const searchKey = h('kbd', { class: 'tc-key', 'aria-hidden': 'true' }, '/');
  const rows = h('div', { class: 'tc-rows' });
  const none = h('p', { class: 'tc-none', hidden: true });
  const list = h('nav', { class: 'tc-list', 'aria-label': label },
    h('header', { class: 'tc-head' }, menu, h('h1', { class: 'tc-title' }, title), h('span', { class: 'grow' }), ...head),
    h('div', { class: 'tc-find' }, icon('search', 13), search, searchKey),
    none, rows, foot ? h('div', { class: 'tc-foot' }, foot) : null);
  const detail = h('div', { class: 'tc-detail' });
  const el = h('section', { class: 'twocol', 'aria-label': label, data: { pane: 'list' } }, list, detail);
  const drawn = new Map();
  const groups = new Map();
  let order = [];

  function rowFor(item) {
    const markSlot = h('span', { class: 'tc-mark' });
    const name = h('span', { class: 'tc-name' });
    const sub = h('span', { class: 'tc-sub' });
    const meta = h('span', { class: 'tc-meta' });
    const link = h('a', { class: 'tc-row', data: { key: item.key } }, markSlot, h('span', { class: 'tc-words' }, name, sub), meta);
    let markKey = null;
    return {
      el: link,
      update(next, chosen) {
        link.setAttribute('href', next.href);
        if (chosen) link.setAttribute('aria-current', 'page'); else link.removeAttribute('aria-current');
        setText(name, next.title);
        setText(sub, next.sub || '');
        sub.hidden = !next.sub;
        sub.className = 'tc-sub' + (next.subTone ? ` tone-text-${next.subTone}` : '');
        setText(meta, next.meta ?? '');
        // A time the page's clock keeps current (app.js's tick reads `data-since`).
        if (next.since) meta.dataset.since = next.since; else delete meta.dataset.since;
        meta.hidden = next.meta == null || next.meta === '';
        meta.className = 'tc-meta' + (next.metaTone ? ` tone-text-${next.metaTone}` : '');
        setClass(link, 'asked', next.tone === 'asked');
        setClass(link, 'dim', next.tone === 'dim');
        link.title = next.about || '';
        markSlot.hidden = !next.mark;
        if (next.mark && next.markKey !== markKey) { markKey = next.markKey; markSlot.replaceChildren(next.mark()); }
      },
    };
  }

  // The rows now, in order, under their groups; what's no longer listed leaves, the rest stay the same nodes.
  function setItems(items, chosenKey, { empty = '' } = {}) {
    const wanted = [];
    const next = new Map();
    const nextGroups = new Map();
    for (const item of items) {
      if (item.group && !nextGroups.has(item.group)) {
        const heading = groups.get(item.group) || h('h2', { class: 'tc-group' }, item.group);
        nextGroups.set(item.group, heading);
        wanted.push(heading);
      }
      const row = drawn.get(item.key) || rowFor(item);
      row.update(item, item.key === chosenKey);
      next.set(item.key, row);
      wanted.push(row.el);
    }
    // Only what changed moves: a node already in its place is left alone (its focus and the list's scroll with it).
    let cursor = rows.firstChild;
    for (const node of wanted) {
      if (node === cursor) cursor = cursor.nextSibling; else rows.insertBefore(node, cursor);
    }
    for (const node of [...rows.childNodes]) if (!wanted.includes(node)) node.remove();
    drawn.clear();
    for (const [key, row] of next) drawn.set(key, row);
    groups.clear();
    for (const [name, heading] of nextGroups) groups.set(name, heading);
    order = items.map((item) => item.key);
    none.hidden = items.length > 0 || !empty;
    setText(none, empty);
  }

  const rowEls = () => order.map((key) => drawn.get(key)?.el).filter(Boolean);
  function move(from, step) {
    const all = rowEls();
    if (!all.length) return;
    const at = all.indexOf(from);
    const to = step === Infinity ? all.length - 1 : step === -Infinity ? 0 : at < 0 ? 0 : Math.max(0, Math.min(all.length - 1, at + step));
    all[to].focus();
  }
  rows.addEventListener('keydown', (event) => {
    const row = event.target?.closest?.('.tc-row') || rowEls().find((one) => one === event.target);
    if (!row) return;
    const step = { ArrowDown: 1, ArrowUp: -1, Home: -Infinity, End: Infinity }[event.key];
    if (step === undefined) return;
    event.preventDefault();
    if (step === -1 && rowEls().indexOf(row) === 0) { search.focus(); return; }
    move(row, step);
  });
  search.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && query) {
      event.preventDefault();
      event.stopPropagation();
      search.value = '';
      query = '';
      onSearch(query);
    } else if (event.key === 'ArrowDown') {
      event.preventDefault();
      const all = rowEls();
      (all.find((one) => one.hasAttribute('aria-current')) || all[0])?.focus();
    } else if (event.key === 'Enter') {
      const first = rowEls()[0];
      if (first) { event.preventDefault(); app.ui.go(first.getAttribute('href')); }
    }
  });

  // The detail's own header (its title, a line under it, and on a phone the way back to the list) and its body.
  const back = h('a', { class: 'tc-back icon-button', href: listHref || '#/', 'aria-label': t('tcBackToList'), title: t('tcBackToList') }, icon('back', 16));
  const detailTitle = h('h2', { class: 'tc-dtitle' });
  const detailSub = h('span', { class: 'tc-dsub' });
  const detailHead = h('header', { class: 'tc-dhead' }, back, h('div', { class: 'tc-dwords' }, detailTitle, detailSub));
  const detailBody = h('div', { class: 'tc-dbody' });
  const page = h('div', { class: 'tc-page' }, detailHead, detailBody);

  return {
    el, list, rows, detail, search, detailBody,
    query: () => query,
    onSearch(fn) { onSearch = fn; },
    setItems,
    // On a phone: the list (nothing chosen in the address) or the detail.
    fold(chosen) { el.dataset.pane = chosen ? 'detail' : 'list'; },
    // The detail as a header and a body; `own` puts an element of its own there instead (a session's view).
    show({ title: heading = '', sub = '', body = null } = {}) {
      if (detail.firstChild !== page || detail.childNodes.length !== 1) detail.replaceChildren(page);
      setText(detailTitle, heading);
      setText(detailSub, sub);
      detailSub.hidden = !sub;
      // The same parts already there stay where they are (a field being typed in keeps its focus through a snapshot).
      const same = body && body.length === detailBody.childNodes.length && body.every((part, index) => detailBody.childNodes[index] === part);
      if (body && !same) detailBody.replaceChildren(...body);
    },
    own(node) { if (detail.firstChild !== node || detail.childNodes.length !== 1) detail.replaceChildren(node); },
    focusSearch() { search.focus(); search.select?.(); },
    clearSearch() { search.value = ''; query = ''; },
  };
}
