// One Send button with a small menu of the ways the session's agent takes a message (js/sendways.js): the button
// sends at its next step (Enter), the arrow beside it opens the others, each with its one line. Returns
// { el, update(ways), close() }; `send(way)` is the caller's.

import * as kit from '../kit.js';
import { h } from '../dom.js';
import { t } from '../i18n.js';
import { wayName, wayLine } from '../sendways.js';

export function sendMenu({ send, className = '', primary = 'step' }) {
  let ways = ['step', 'now'];
  // The button's own way: the next step, unless the caller's says otherwise (a draft left to steer a working agent).
  const main = kit.button('primary', { size: 's', class: 'send-main', title: wayLine(primary), onclick: () => send(primary) }, t('swSend'));
  const list = h('div', { class: 'send-ways', role: 'menu', hidden: true });
  const toggle = kit.button('plain', { size: 's', class: 'send-more', 'aria-haspopup': 'menu', 'aria-expanded': 'false', 'aria-label': t('swMore'), title: t('swMore'),
    onclick: () => (list.hidden ? open() : close()) }, '▾');
  const el = h('div', { class: 'send-menu ' + className }, main, toggle, list);

  function open() {
    list.replaceChildren(...ways.map((way) => h('button', { class: 'send-way', type: 'button', role: 'menuitem', onclick: () => { close(); send(way); } },
      h('strong', null, wayName(way)), h('small', null, wayLine(way)))));
    list.hidden = false;
    toggle.setAttribute('aria-expanded', 'true');
    list.querySelector('button')?.focus();
  }
  function close() {
    list.hidden = true;
    toggle.setAttribute('aria-expanded', 'false');
  }
  el.addEventListener('keydown', (event) => { if (event.key === 'Escape' && !list.hidden) { event.preventDefault(); close(); toggle.focus(); } });
  el.addEventListener('focusout', (event) => { if (!el.contains(event.relatedTarget)) close(); });

  return {
    el,
    update(next) {
      ways = next;
      toggle.hidden = ways.length < 2;
    },
    close,
  };
}
