// The frame before there is anything to show (the design review of 2026-11-25, D6 and D21): until the node's first
// snapshot the centre and the right column are skeletons in the shape of the view they will show (left.js draws the
// left column's), so nothing false is said and nothing jumps when the truth arrives; a node that doesn't answer for a
// while, a page that isn't paired (or was unpaired) and a node with nothing on it each get a page of their own that
// says, in a person's words, what this is, what to do next (its one action) and what happens then. app.js places them.

import * as kit from '../kit.js';
import { h } from '../dom.js';
import { icon } from '../marks.js';
import { t } from '../i18n.js';
import { copyLine } from './cards.js';

// What the centre shows instead of the route's view, from what the frame knows (left.js's `framePhase`): 'down' (the
// node out of reach), 'unpaired' or 'revoked' (with no rows to keep showing, or at home), 'loading' (the lead view's
// skeleton, for a project or home), 'empty' (home on a node with no project and no session: app.js's `settleHome`
// stays there), else null: the route's own view, which says its own loading (a session's skeleton, a list's).
export function framePageKind({ phase, connection, route, sessions = 0 }) {
  const name = route?.name;
  if (phase === 'down') return 'down';
  if (phase === 'off') return name === 'home' || sessions === 0 ? connection : null;
  if (phase === 'loading') return name === 'home' || name === 'project' ? 'loading' : null;
  return name === 'home' ? 'empty' : null;
}

// Each page's words: its title, what this is, what to do, what happens then; its mark.
const PAGES = {
  unpaired: { title: 'frUnpairedTitle', what: 'frUnpairedWhat', todo: 'frUnpairedDo', then: 'frUnpairedThen', mark: 'node' },
  revoked: { title: 'frRevokedTitle', what: 'frRevokedWhat', todo: 'frUnpairedDo', then: 'frUnpairedThen', mark: 'node' },
  down: { title: 'frDownTitle', what: 'frDownWhat', todo: 'frDownDo', then: 'frDownThen', mark: 'node' },
  empty: { title: 'frEmptyTitle', what: 'frEmptyWhat', todo: 'frEmptyDo', then: 'frEmptyThen', mark: 'plus' },
};
export const PAGE_KINDS = Object.keys(PAGES);

// A page of the frame's own. Its one action: pairing is a terminal's line today (device keys aren't built), so the
// line to copy; the node out of reach, a button that tries again now (`retry`: the feed's, never a reload, which would
// lose the page to the browser's own error and a pairing code to the address bar; it says it is trying, then the page
// gives way the moment the node answers); an empty node, a button that starts a session, and New project beside it.
export function framePage(kind, { retry = null, later = (fn, ms) => setTimeout(fn, ms) } = {}) {
  const page = PAGES[kind];
  if (!page) throw new Error(`no frame page ${kind}`);
  const action = kind === 'unpaired' || kind === 'revoked' ? copyLine('vibeswitcher web', t('frPairLine'))
    : kind === 'down' ? (retry ? tryAgain(retry, later) : null)
      : h('span', { class: 'frame-actions' }, kit.button('primary', { tag: 'a', href: '#/sessions/new' }, t('frEmptyStart')),
        kit.button('plain', { tag: 'a', href: '#/new' }, t('newProject')));
  return kit.empty({ size: 'page', class: `frame-${kind}` }, icon(page.mark, 24), h('h1', null, t(page.title)), h('p', null, t(page.what)),
    h('p', null, t(page.todo)), action, h('p', { class: 'frame-then' }, t(page.then)));
}

function tryAgain(retry, later) {
  const button = kit.button('primary', { class: 'frame-action', onclick: () => {
    retry();
    button.disabled = true;
    button.setAttribute('aria-busy', 'true');
    button.textContent = t('frDownTrying');
    later(() => { button.disabled = false; button.removeAttribute('aria-busy'); button.textContent = t('frDownRetry'); }, 2500);
  } }, t('frDownRetry'));
  return button;
}

const bone = (kind = '') => h('span', { class: `bone ${kind}`.trim() });

// The lead view's shape: its header's two rows, the team strip, the conversation's lines, the message box (`box`, the
// roadmap has none). Bars that breathe on the loop; still with reduced motion.
export function centreSkeleton() {
  const box = h('div', { class: 'skeleton-composer' }, h('span', { class: 'skeleton-field' }));
  const el = h('section', { class: 'centre screen frame-skeleton', 'aria-busy': 'true', 'aria-label': t('frLoading'), hidden: true },
    // The header's shape (D11): one row wider, the switch first and the folded dial at its end; a phone's two rows.
    h('div', { class: 'skeleton-head' }, h('span', { class: 'skeleton-row' }, bone('skeleton-title')), h('span', { class: 'skeleton-row' }, bone('skeleton-switch'), bone('skeleton-dial'))),
    h('div', { class: 'skeleton-strip' }, bone('short'), bone('short'), bone('short')),
    h('div', { class: 'skeleton-lines' }, ...['wide', '', 'wide', 'short', ''].map((kind) => h('span', { class: 'skeleton-line' }, h('span', { class: 'skeleton-mark' }), bone(kind)))),
    box);
  return { el, box };
}

// The right column's shape: its head, its tabs, its rows.
export function rightSkeleton() {
  return h('aside', { class: 'right right-skeleton', 'aria-hidden': 'true' },
    h('div', { class: 'colhead' }, bone('short')),
    h('div', { class: 'colbody' }, bone('skeleton-tabs'), ...['', 'wide', 'short', '', 'wide'].map((kind) => bone(kind))));
}
