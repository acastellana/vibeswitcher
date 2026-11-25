// The left column's keys, as v1 had them (the parity table's "Next needing you (⌘J), sessions 1–9, next and previous"
// and "Group by attention or by project, filter", which the redesign of 2026-11-23 had dropped), on combinations no
// browser keeps for itself:
//
// | Does | macOS | Linux, Windows | Why not the other |
// | --- | --- | --- | --- |
// | The left column's 1st–9th | ⌥1–9 | Ctrl+Shift+1–9 | ⌘1–9 and Ctrl+1–9 are every browser's tabs; Alt+1–9 Chrome's and Firefox's on Linux |
// | Next, previous in it | ⌥↓ ⌥↑ | Alt+↓ Alt+↑ | Alt+← → are Back and Forward |
// | Next needing you | ⌘J, ⌥J | Alt+J | Ctrl+J is the browser's Downloads (Chrome, Edge, Firefox on Windows); ⌥⌘J Chrome's console |
// | Filter it | ⌥F, or / | / | Alt+F opens the browser's menu (Chrome, Edge, Firefox) |
//
// None fires while typing in a field (an input, a text box, a terminal), where those keys type. With no page in it:
// app.js runs what `shortcut` names, and views/left.js says what the column lists (`leftOrder`).

import { waitingPlaces, nextPlace } from './conversation.js';
import { projectHref, sessionHref } from './ui.js';
import { t } from './i18n.js';

// Whether `target` takes typing: a field, a text box, something editable, a terminal's screen.
export function typing(target) {
  if (!target || typeof target.closest !== 'function') return false;
  return !!target.closest('input, textarea, select, [contenteditable=""], [contenteditable="true"], .terminal-screen');
}

// The shortcut a keydown is, or null: { do: 'nth', n } (1–9), { do: 'step', by } (1 next, -1 previous), { do: 'needing' }
// or { do: 'filter' }. `mac`: the Mac's keys.
export function shortcut(event, { mac }) {
  if (typing(event.target)) return null;
  const digit = /^Digit[1-9]$/.test(event.code || '') ? Number(event.code.slice(5)) : 0;
  const arrow = event.key === 'ArrowDown' ? 1 : event.key === 'ArrowUp' ? -1 : 0;
  // AltGr (Ctrl+Alt on some keyboards) types a character: never a shortcut.
  if (event.getModifierState?.('AltGraph')) return null;
  const { altKey: alt, metaKey: meta, ctrlKey: ctrl, shiftKey: shift } = event;
  const altOnly = alt && !meta && !ctrl && !shift;
  if (mac) {
    if (altOnly && digit) return { do: 'nth', n: digit };
    if (altOnly && arrow) return { do: 'step', by: arrow };
    if (altOnly && event.code === 'KeyF') return { do: 'filter' };
    if (event.code === 'KeyJ' && !ctrl && !shift && (meta !== alt)) return { do: 'needing' };
  } else {
    if (ctrl && shift && !alt && !meta && digit) return { do: 'nth', n: digit };
    if (altOnly && arrow) return { do: 'step', by: arrow };
    if (altOnly && event.code === 'KeyJ') return { do: 'needing' };
  }
  return null;
}

// The keys' names as the palette and the README show them.
export function keyNames(mac) {
  return mac
    ? { nth: (n) => `⌥${n}`, next: '⌥↓', previous: '⌥↑', needing: '⌘J', filter: '⌥F' }
    : { nth: (n) => `Ctrl+Shift+${n}`, next: 'Alt+↓', previous: 'Alt+↑', needing: 'Alt+J', filter: '/' };
}

// Where `step` goes in `hrefs` (the left column's, in its order) from `here` (the address shown): the next or the
// previous, round again; the first (or the last, going back) when none of them is shown.
export function stepTo(hrefs, here, by) {
  if (!hrefs.length) return null;
  const at = hrefs.indexOf(here);
  if (at < 0) return by > 0 ? hrefs[0] : hrefs[hrefs.length - 1];
  return hrefs[(at + by + hrefs.length) % hrefs.length];
}


// Whether the left column's `item` ({ kind, id }) is what `route` shows.
export const shownNow = (item, route) => (item.kind === 'project' && route.name === 'project' && route.id === item.id)
  || (item.kind === 'session' && route.name === 'session' && route.id === item.id);

// Next needing you: the place after the one shown with something waiting on you (a project, a session of your own
// that needs you: `own(session)`, or This node), round again; the left column's summary goes to the same one. Null
// when nothing waits.
export function needingHref(state, route, own) {
  const place = nextPlace(waitingPlaces(state, own), route);
  if (!place) return null;
  return place.kind === 'project' ? projectHref(place.id) : place.kind === 'session' ? sessionHref(place.id) : '#/node';
}

// The left column's `n`th (1–9), and the next or previous from what is shown: an address, or null.
export const nthHref = (items, n) => items[n - 1]?.href || null;
export function stepHref(items, route, by) {
  const shown = items.find((item) => shownNow(item, route));
  return stepTo(items.map((item) => item.href), shown ? shown.href : null, by);
}

// The palette's entries for the keys, beside their commands (`go(href)`, `filter()`), and the keys of the left
// column's first nine by id, for the commands that open them.
export function keyCommands({ mac, state, route, items, own, go, filter }) {
  const keys = keyNames(mac);
  const to = (href) => () => { if (href) go(href); };
  return {
    entries: [
      { title: t('apNextNeedingYou'), about: t('apNextNeedingYouAbout'), keys: keys.needing, icon: 'question', run: to(needingHref(state, route, own)) },
      { title: t('apNextInList'), about: t('apInTheLeftColumn'), keys: keys.next, icon: 'chat', run: to(stepHref(items, route, 1)) },
      { title: t('apPreviousInList'), about: t('apInTheLeftColumn'), keys: keys.previous, icon: 'chat', run: to(stepHref(items, route, -1)) },
      { title: t('apFilterLeft'), about: t('apFilterLeftAbout'), keys: keys.filter, icon: 'search', run: filter },
    ],
    nth: new Map(items.slice(0, 9).map((item, index) => [item.id, keys.nth(index + 1)])),
  };
}
