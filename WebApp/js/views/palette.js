// ⌘K: go to a session or run a command (the Mac's CommandPalette, its words and its order: sessions, then commands).
// Type to narrow, ↑ ↓ to choose, ↩ to go, Esc to close. The focus stays in the field; the list is read through
// aria-activedescendant.

import { h } from '../dom.js';
import { sessionMark, icon } from '../marks.js';
import { STATES, stateOf, since } from '../words.js';
import { projectOf } from '../ui.js';

// How well `text` answers `query`: a run at the start of a word beats one inside it, and the letters in order
// anywhere beat nothing. 0: no match.
function score(text, query) {
  if (!query) return 1;
  const hay = text.toLowerCase();
  const at = hay.indexOf(query);
  if (at === 0) return 100;
  if (at > 0) return /\W/.test(hay[at - 1]) ? 80 : 60;
  let from = 0;
  for (const letter of query) {
    from = hay.indexOf(letter, from) + 1;
    if (from === 0) return 0;
  }
  return 20;
}

export function palette(app) {
  const { store, ui } = app;
  const input = h('input', {
    class: 'palette-input', type: 'text', placeholder: 'Go to a session or run a command', role: 'combobox', 'aria-expanded': 'true',
    'aria-controls': 'palette-list', 'aria-autocomplete': 'list', 'aria-label': 'Go to a session or run a command', autocomplete: 'off', spellcheck: 'false',
  });
  const list = h('ul', { class: 'palette-list', id: 'palette-list', role: 'listbox' });
  const none = h('p', { class: 'palette-none', hidden: true }, 'No matches');
  const panel = h('div', { class: 'palette-panel', role: 'dialog', 'aria-modal': 'true', 'aria-label': 'Command palette' },
    h('div', { class: 'palette-field' }, icon('search', 16), input), list, none);
  const el = h('div', { class: 'palette', hidden: true }, panel);
  let entries = [];
  let chosen = 0;
  let before = null;

  function candidates() {
    const sessions = app.order().map((session) => ({
      session,
      title: session.title || projectOf(session),
      about: `${projectOf(session)} · ${STATES[stateOf(session)].one} · ${since(session.since)}`,
      run: () => ui.select(session.id),
    }));
    return [...sessions, ...app.commands()];
  }

  function draw() {
    const query = input.value.trim().toLowerCase();
    entries = candidates()
      .map((entry, index) => ({ entry, index, rank: Math.max(score(entry.title, query), score(entry.about || '', query) / 2) }))
      .filter((scored) => scored.rank > 0)
      .sort((a, b) => b.rank - a.rank || a.index - b.index)
      .slice(0, 50)
      .map((scored) => scored.entry);
    chosen = Math.min(chosen, Math.max(entries.length - 1, 0));
    list.replaceChildren(...entries.map((entry, index) => {
      let lead;
      if (entry.session) {
        const mark = sessionMark(18);
        mark.update(stateOf(entry.session), entry.session.agent);
        lead = mark.el;
      } else lead = h('span', { class: 'palette-icon' }, icon(entry.icon || 'chevron', 15));
      return h('li', { class: 'palette-row', id: 'palette-' + index, role: 'option', 'aria-selected': String(index === chosen), onclick: () => run(index), onpointermove: () => choose(index) },
        lead, h('span', { class: 'palette-text' }, h('span', { class: 'palette-title' }, entry.title), entry.about ? h('span', { class: 'palette-about' }, entry.about) : null),
        entry.keys ? h('kbd', null, entry.keys) : null);
    }));
    none.hidden = entries.length > 0;
    mark();
  }

  function mark() {
    [...list.children].forEach((row, index) => row.setAttribute('aria-selected', String(index === chosen)));
    if (entries.length) input.setAttribute('aria-activedescendant', 'palette-' + chosen); else input.removeAttribute('aria-activedescendant');
    list.children[chosen]?.scrollIntoView({ block: 'nearest' });
  }

  function choose(index) {
    if (index === chosen) return;
    chosen = index;
    mark();
  }

  function run(index) {
    const entry = entries[index];
    close();
    entry?.run();
  }

  function close() { ui.setPalette(false); }

  input.addEventListener('input', () => { chosen = 0; draw(); });
  input.addEventListener('keydown', (event) => {
    if (event.key === 'ArrowDown') { event.preventDefault(); choose(Math.min(chosen + 1, entries.length - 1)); }
    else if (event.key === 'ArrowUp') { event.preventDefault(); choose(Math.max(chosen - 1, 0)); }
    else if (event.key === 'Enter') { event.preventDefault(); run(chosen); }
    else if (event.key === 'Escape') { event.preventDefault(); close(); }
    else if (event.key === 'Tab') event.preventDefault();
  });
  el.addEventListener('pointerdown', (event) => { if (event.target === el) close(); });

  ui.subscribe((what) => {
    if (what !== 'palette') return;
    const open = ui.state.palette;
    el.hidden = !open;
    if (open) {
      before = document.activeElement;
      input.value = '';
      chosen = 0;
      draw();
      input.focus();
    } else if (before?.isConnected) before.focus();
  });
  // The rows stay true while it's open: a status that changes shows here as it does in the list.
  store.subscribe('sessions', () => { if (ui.state.palette) draw(); });

  // `refresh`: the commands changed while it's open (a folder's presets came from the node).
  return { el, refresh: () => { if (ui.state.palette) draw(); } };
}
