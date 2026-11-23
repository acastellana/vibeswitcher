// The side sheet (the redesign's "The whole text of any line opens in a side sheet rendered from its markdown"): over
// the right edge, a line's whole text drawn as nodes by text.js (bold, code, lists, tables), never a string as markup.
// Esc, the close button or a click outside closes it. It says nothing of its own beyond its title and time.

import { h, setText } from '../dom.js';
import { icon } from '../marks.js';
import { markdown } from '../text.js';
import { moment } from '../words.js';
import { t } from '../i18n.js';
import { shortHashes } from '../conversation.js';

export function sideSheet() {
  const kicker = h('p', { class: 'sheet-kicker' });
  const title = h('h2', { class: 'sheet-title', id: 'sheet-title' });
  const when = h('p', { class: 'sheet-when' });
  const body = h('div', { class: 'sheet-body markdown' });
  let onClose = null;
  const closeButton = h('button', { class: 'icon-button sheet-close', type: 'button', 'aria-label': t('close'), title: t('close'), onclick: () => close() }, icon('close', 16));
  const panel = h('aside', { class: 'sheet', role: 'dialog', 'aria-modal': 'false', 'aria-labelledby': 'sheet-title', tabindex: -1, hidden: true },
    closeButton, kicker, title, when, body);
  const scrim = h('div', { class: 'sheet-scrim', hidden: true, onclick: () => close() });

  function close() {
    if (panel.hidden) return;
    panel.hidden = true;
    scrim.hidden = true;
    const done = onClose;
    onClose = null;
    done?.();
  }

  // `parts`: { kicker, title, at, text (markdown), more: [nodes after it] }; `closed`: told when it closes.
  function open(parts, closed = null) {
    setText(kicker, parts.kicker || '');
    kicker.hidden = !parts.kicker;
    setText(title, shortHashes(parts.title || ''));
    setText(when, parts.at ? moment(parts.at) : '');
    when.hidden = !parts.at;
    body.replaceChildren(markdown(shortHashes(parts.text || '')), ...(parts.more || []));
    const wasHidden = panel.hidden;
    panel.hidden = false;
    scrim.hidden = false;
    onClose = closed;
    if (wasHidden) panel.focus({ preventScroll: true });
    panel.scrollTop = 0;
  }

  addEventListener('keydown', (event) => { if (event.key === 'Escape' && !panel.hidden) { event.preventDefault(); close(); } });
  return { el: panel, scrim, open, close, shown: () => !panel.hidden };
}
