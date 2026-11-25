// The side sheet (the redesign's "The whole text of any line opens in a side sheet rendered from its markdown"): over
// the right edge, a line's whole text drawn as nodes by text.js (bold, code, lists, tables), never a string as markup.
// Esc, the close button or a click outside closes it. It says nothing of its own beyond its title and time.

import { h, setText } from '../dom.js';
import { icon } from '../marks.js';
import { markdown } from '../text.js';
import { moment } from '../words.js';
import { t } from '../i18n.js';
import { shortHashes } from '../conversation.js';
import { refusalWords } from '../acting.js';

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

// A held config or a moved base, whole, for the side sheet (`config.held`'s or `base.show`'s card, as the node read it
// now): each held thing with what changed, when, whether outside a team session, its hash and changed files, and for
// one with changes, Show what changed (`config.held` with `diff`: its difference, lines of text); the guard rails with
// their values; a base's branch, its move, why and every commit. `read(kind, args)` asks the node. Returns the sheet's
// parts ({ kicker, title, more }).
export function heldParts(card, { root, kicker = '', read = null, kind = 'config.held' } = {}) {
  const fact = (name, ...value) => [h('dt', null, name), h('dd', null, value)];
  if (card?.kind === 'base' && card.base) {
    const base = card.base;
    return { kicker, title: t('baseMove'), more: [h('dl', { class: 'held-whole' },
      fact(t('acBranch'), h('code', null, base.branch || '')),
      fact(t('acMove'), h('code', null, `${String(base.from || '?').slice(0, 12)} → ${String(base.to || '').slice(0, 12)}`), base.fromIs && base.fromIs !== 'recorded' ? ` (${base.fromIs})` : ''),
      base.reason ? fact(t('acWhy'), base.reason) : null,
      fact(t('cCommits'), (base.commits || []).length ? h('ul', { class: 'files' }, base.commits.map((commit) => h('li', null, commit.subject || '', ' ', h('code', { class: 'dim' }, String(commit.sha || '').slice(0, 8)))))
        : t('shNoCommitsListed')))] };
  }
  const config = card?.config || {};
  const items = config.items || [];
  const rails = config.guarded || [];
  const item = (one) => {
    const slot = h('div', { class: 'held-diff-slot' });
    const changes = !!(one.change || (one.files || []).length);
    const show = changes && read ? h('button', { class: 'button quiet small', type: 'button', onclick: () => {
      show.disabled = true;
      show.textContent = t('shReading');
      read(kind, { folder: root, diff: one.name }).then((reply) => {
        show.disabled = false;
        show.textContent = t('shShowChanges');
        const lines = reply?.ok ? reply.result?.difference : null;
        if (Array.isArray(lines)) slot.replaceChildren(lines.length ? h('pre', { class: 'held-diff' }, lines.join('\n')) : h('p', { class: 'confirm-note' }, t('shNoDifference')));
        else slot.replaceChildren(h('p', { class: 'act-said refused', role: 'status' }, typeof lines === 'string' ? lines : refusalWords(reply?.error, t('shShowChanges'))));
      });
    } }, t('shShowChanges')) : null;
    return h('li', { class: 'held-item' },
      h('div', { class: 'held-name' }, h('b', null, one.name), one.outside ? h('span', { class: 'held-outside' }, ' · ', t('shOutside')) : null),
      one.change ? h('p', null, one.change) : null,
      h('p', { class: 'confirm-note' }, [one.changedAt ? t('shChangedAt', { time: moment(one.changedAt) }) : null, one.sinceAccept ? t('shSinceAccept', { how: one.sinceAccept }) : null].filter(Boolean).join(' · ')),
      (one.files || []).length ? h('ul', { class: 'files' }, one.files.map((file) => (typeof file === 'string' ? h('li', null, h('code', null, file))
        : h('li', null, h('code', null, file.path || ''), file.change ? ` · ${t({ added: 'shAdded', changed: 'shChanged', removed: 'shRemoved' }[file.change] || 'shChanged')}` : '')))) : null,
      show, slot);
  };
  return { kicker, title: t('heldConfig'), more: [
    items.length ? h('ul', { class: 'held-items' }, items.map(item)) : h('p', null, t('shNothingHeld')),
    rails.length ? h('h3', { class: 'sheet-sub' }, t('shGuardRails')) : null,
    rails.length ? h('dl', { class: 'held-whole' }, rails.map((rail) => fact(rail.key, h('code', null, rail.value), rail.sinceAccept ? ` (${rail.sinceAccept})` : ''))) : null,
    config.lastAccept ? h('p', { class: 'confirm-note' }, t('shLastAccept', { time: moment(config.lastAccept) })) : null,
  ].filter(Boolean) };
}
