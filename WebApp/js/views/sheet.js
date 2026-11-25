// The side sheet (the redesign's "The whole text of any line opens in a side sheet rendered from its markdown"): over
// the right edge, a line's whole text drawn as nodes by text.js (bold, code, lists, tables), never a string as markup.
// Esc, the close button or a click outside closes it. It says nothing of its own beyond its title and time.

import { h, setText } from '../dom.js';
import { icon } from '../marks.js';
import { markdown } from '../text.js';
import { moment } from '../words.js';
import { t } from '../i18n.js';
import { shortHashes } from '../conversation.js';

// Where the keyboard was when a sheet or the palette opened, put back when it closes: that element, or the link drawn in
// its place since (closing a line's sheet changes the address, and the lines are drawn again for it: put back again then),
// else the centre, never the page's body, where Tab starts again from the top.
export function focusKeeper({ doc = globalThis.document, win = globalThis } = {}) {
  let element = null;
  let href = null;
  let pending = null;
  function back() {
    let target = element?.isConnected && element !== doc.body && element.getClientRects?.().length ? element : null;
    if (!target && href) target = [...doc.querySelectorAll('a[href]')].find((one) => one.getAttribute('href') === href && one.getClientRects().length) || null;
    if (!target) {
      target = doc.querySelector('main');
      if (target && !target.hasAttribute('tabindex')) target.setAttribute('tabindex', '-1');
    }
    target?.focus?.({ preventScroll: true });
  }
  return {
    remember() {
      element = doc.activeElement;
      href = element?.getAttribute?.('href') || null;
    },
    restore() {
      if (!element && !href) return;
      back();
      // The address changes after this (a task later): once it has, and the view is drawn for it, again.
      const token = {};
      pending = token;
      // Only if the keyboard was lost on the way (the element it was put on drawn again): what the new address gave it
      // (a session's terminal) keeps it.
      const lost = () => !doc.activeElement || doc.activeElement === doc.body || !doc.activeElement.isConnected;
      const again = () => { if (pending === token && lost()) back(); };
      win.addEventListener?.('hashchange', again, { once: true });
      win.setTimeout?.(() => {
        win.removeEventListener?.('hashchange', again);
        if (pending === token) { pending = null; element = null; href = null; }
      }, 60);
    },
  };
}

export function sideSheet() {
  const keeper = focusKeeper();
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
    keeper.restore();
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
    if (wasHidden) {
      keeper.remember();
      panel.focus({ preventScroll: true });
    }
    panel.scrollTop = 0;
  }

  addEventListener('keydown', (event) => { if (event.key === 'Escape' && !panel.hidden) { event.preventDefault(); close(); } });
  return { el: panel, scrim, open, close, shown: () => !panel.hidden };
}
