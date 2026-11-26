// The page's components (the design review of 2026-11-25: D4 and its group B): one button family, one pick-one switch,
// one field and dropdown, one badge, one number tile, one section title, one empty state, each defined once in
// style.css's Components section (right after the tokens) and built by js/kit.js, which every view asks by role. A
// view that builds one of these by a class of its own fails here, by file and line.
// Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { installDom } from './fakedom.test.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const css = readFileSync(join(root, 'style.css'), 'utf8');

installDom();
const kit = await import('../js/kit.js');

// ---- The Components section ----

const bare = css.replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, ' '));
const start = css.indexOf('/* ---- Components:');
const end = css.indexOf('* { box-sizing: border-box; }');
const SECTION = bare.slice(start, end);
// Each selector of the section's rules, and what it declares.
const RULES = [...SECTION.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map((m) => ({ selectors: m[1].trim().split(/,(?![^(]*\))/).map((one) => one.trim()), body: m[2] }));
// The source without its @media blocks (a phone's or a touch screen's sizes adjust a component; they don't draw it).
function withoutMedia(text) {
  let out = '';
  let at = 0;
  for (const match of text.matchAll(/@media[^{]*\{/g)) {
    if (match.index < at) continue;
    out += text.slice(at, match.index);
    let depth = 1; let close = match.index + match[0].length;
    while (close < text.length && depth) { if (text[close] === '{') depth++; else if (text[close] === '}') depth--; close++; }
    at = close;
  }
  return out + text.slice(at);
}
const defines = (selector) => RULES.some((rule) => rule.selectors.includes(selector));

// The components, their variants by role, and their parts.
const COMPONENTS = {
  button: ['.button', '.button.plain', '.button.quiet', '.button.danger', '.button.small', '.button.large', '.button:disabled', '.button.confirming'],
  'icon button': ['.icon-button', '.icon-button.small'],
  switch: ['.segmented', '.segment', '.segment:is([aria-pressed="true"], [aria-current], [aria-selected="true"])', '.segment:disabled'],
  field: ['.field', 'textarea.field', '.field:focus-visible', '.field:disabled', '.field.search', '.field.code', '.select', '.select > .field', '.select > .icon', '.check', '.check:checked', '.check[type="radio"]', '.check:disabled'],
  badge: ['.badge', '.badge.asking', '.badge.working', '.badge.done'],
  tile: ['.tile', '.tile-value', '.tile-label', '.tile-note', '.tile.quiet .tile-value', '.tile.bad .tile-value'],
  'section title': ['.section-title'],
  'empty state': ['.empty', '.empty.page'],
};

test('the components are one section of style.css, right after the tokens, each kind defined there once with its variants', () => {
  assert.ok(start > 0 && end > start, 'a Components section before the base rules');
  // Right after the tokens: only the token blocks (:root, more contrast, reduced motion) come before it.
  const before = bare.slice(0, start).replace(/@media[^{]*\{\s*:root\s*\{[^}]*\}\s*\}/g, '').replace(/@media[^{]*\{\s*\*[^{]*\{[^}]*\}\s*\}/g, '').replace(/:root(\[[^\]]*\])?\s*\{[^}]*\}/g, '');
  assert.equal(before.trim(), '', 'nothing but the tokens before the components');
  const missing = Object.entries(COMPONENTS).flatMap(([kind, selectors]) => selectors.filter((one) => !defines(one)).map((one) => `${kind}: ${one}`));
  assert.deepEqual(missing, []);
  // Defined once: no rule after the section draws a component's base again.
  const after = withoutMedia(bare.slice(end));
  const again = ['.button', '.icon-button', '.segmented', '.segment', '.field', '.badge', '.tile', '.section-title', '.empty']
    .filter((selector) => new RegExp(`(^|[},])\\s*\\${selector}\\s*\\{`).test(after));
  assert.deepEqual(again, [], 'a component drawn again outside its section');
});

test('the components stand on the tokens: three heights, the corners, the colour roles; a select keeps the field’s height and ring', () => {
  const body = (selector) => RULES.filter((rule) => rule.selectors.includes(selector)).map((rule) => rule.body).join(';');
  assert.match(body('.button'), /height: var\(--ctl-m\)/);
  assert.match(body('.button.small'), /height: var\(--ctl-s\)/);
  assert.match(body('.button.large'), /height: var\(--ctl-l\)/);
  assert.match(body('.segment'), /min-height: var\(--ctl-s\)/);
  assert.match(body('.segmented'), /border-radius: var\(--r-2\)/, 'the box, not the pill (the review’s D4a)');
  assert.match(body('.field'), /min-height: var\(--ctl-m\)/);
  assert.match(body('.field:focus-visible'), /box-shadow: var\(--e-focus-in\)/);
  // The browser's own dropdown and checkbox, drawn as the page's: their look reset, the chevron the icons'.
  assert.match(body('.select > .field'), /appearance: none/);
  assert.match(body('.check'), /appearance: none/);
  assert.match(body('.section-title'), /color: var\(--ink-3\)/);
  assert.doesNotMatch(body('.section-title'), /text-transform/, 'sentence case (the review’s D4c)');
  for (const tone of ['asking', 'working', 'done']) assert.match(body(`.badge.${tone}`), /var\(--(asked|working|done)\)/);
});

test('a field pointed at keeps its focus ring: the hover edge never replaces it, even on a frame whose input has focus (a list’s search)', () => {
  const hovers = [...bare.matchAll(/([^{}]+)\{([^{}]*box-shadow: var\(--e-hover-in\)[^{}]*)\}/g)].map((m) => m[1].trim());
  const field = hovers.filter((selector) => /\.field\b/.test(selector));
  assert.ok(field.length, 'a hover edge for the field');
  for (const selector of field) for (const one of selector.split(/,(?![^(]*\))/).filter((part) => /\.field\b/.test(part))) assert.match(one, /:not\(:focus-within\)/, one.trim());
});

// ---- js/kit.js ----

const classes = (node) => node.getAttribute('class').split(' ');

test('kit.js gives each role and size its class, and refuses a role it doesn’t know', () => {
  assert.deepEqual(classes(kit.button('primary', {}, 'Go')), ['button']);
  assert.deepEqual(classes(kit.button('plain', { size: 's', class: 'setting-change' }, 'Change')), ['button', 'plain', 'small', 'setting-change']);
  assert.deepEqual(classes(kit.button('quiet', { size: 's' }, 'Undo')), ['button', 'quiet', 'small']);
  assert.deepEqual(classes(kit.button('danger', {}, 'Stop')), ['button', 'plain', 'danger']);
  assert.deepEqual(classes(kit.button('primary', { size: 'l' }, 'Start')), ['button', 'large']);
  assert.equal(kit.button('plain', {}, 'x').getAttribute('type'), 'button');
  assert.equal(kit.button('primary', { type: 'submit' }, 'x').getAttribute('type'), 'submit');
  assert.equal(kit.button('plain', { tag: 'a', href: '#/' }, 'x').getAttribute('type'), null);
  assert.deepEqual(classes(kit.iconButton({ size: 's', class: 'row-action' })), ['icon-button', 'small', 'row-action']);
  assert.deepEqual(classes(kit.segmented({ tag: 'nav', class: 'dial' })), ['segmented', 'dial']);
  assert.deepEqual(classes(kit.segment({ tag: 'a' }, 'Lead')), ['segment']);
  assert.deepEqual(classes(kit.field({ kind: 'search', class: 'left-filter' })), ['field', 'search', 'left-filter']);
  assert.deepEqual(classes(kit.field({ tag: 'textarea', kind: 'code' })), ['field', 'code']);
  const dropdown = kit.select({ wrap: 'setting-input', 'aria-label': 'Theme' }, kit.field());
  assert.deepEqual(classes(dropdown), ['select', 'setting-input']);
  assert.equal(dropdown.control.tag, 'select', 'the browser’s own select inside');
  assert.equal(dropdown.control.getAttribute('aria-label'), 'Theme', 'its words on the select, for a reader');
  assert.equal(kit.checkbox({ checked: true }).getAttribute('type'), 'checkbox');
  assert.deepEqual(classes(kit.badge('asking', '2')), ['badge', 'asking']);
  assert.equal(kit.badgeClass('neutral', 'tc-meta'), 'badge tc-meta');
  const tile = kit.tile({ value: '12', label: 'merged', note: 'today', tone: 'quiet' });
  assert.deepEqual(classes(tile), ['tile', 'quiet']);
  assert.deepEqual(tile.children.map((child) => child.getAttribute('class')), ['tile-value', 'tile-label', 'tile-note'], 'the number on top');
  assert.deepEqual(classes(kit.sectionTitle('h2', { class: 'col-title' }, 'Projects')), ['section-title', 'col-title']);
  assert.deepEqual(classes(kit.empty({ size: 'page', class: 'placeholder' })), ['empty', 'page', 'placeholder']);
  assert.throws(() => kit.button('secondary', {}, 'x'));
  assert.throws(() => kit.button('plain', { size: 'xl' }, 'x'));
  assert.throws(() => kit.badge('red', 'x'));
  assert.throws(() => kit.field({ kind: 'number' }));
});

// ---- The views use them ----

// Every view's source: app.js and js/ but for the kit itself and what builds no view. The chat (js/views/chat.js) is
// another task's this round: its buttons, field and empty line take the components' classes by alias meanwhile
// (.icon-button, .link, .pane-empty), listed for the join.
const SKIP = new Set(['js/kit.js', 'js/dom.js', 'js/views/chat.js']);
const FILES = ['app.js', ...readdirSync(join(root, 'js'), { recursive: true }).filter((name) => name.endsWith('.js')).map((name) => join('js', name))]
  .filter((file) => !SKIP.has(file));
const lines = (file) => readFileSync(join(root, file), 'utf8').split('\n').map((text, index) => ({ file, line: index + 1, text })).filter((one) => !one.text.trim().startsWith('//'));
const SOURCE = FILES.flatMap(lines);

// Rows and the like: a button that is a row of a list, an option, a fold or a disclosure, a picture. Not a button of
// the family, each its own row style.
const ROWS = new Set(['option', 'copy-button', 'card-question', 'goal-title', 'road-band', 'summary-brief', 'send-way', 'strip-team', 'fold', 'dial-fold',
  'strip-fold', 'chat-image-button', 'attach-choice', 'attached-remove', 'code-run', 'latest', 'send']);
// Fields of their own: the palette's (its big row), a search field's words inside its frame (the frame is the field),
// a colour well, and the lead's message box (one of the two message boxes, the review's U9, not this task's).
const OWN_FIELDS = new Set(['palette-input', 'tc-search', 'look-colour', 'say']);
// What the components replaced: a view naming one of these draws the old way.
const OLD = ['section-title', 'col-title', 'tc-group', 'setting-section-title', 'group-head', 'switch', 'switch-link', 'segmented', 'segment', 'confirm-clear',
  'tile', 'stat-figure', 'stat-label', 'stat-value', 'score-tile', 'score-value', 'stat-badge', 'setting-mark', 'tc-meta', 'badge', 'tone-text-mono',
  'empty-state', 'placeholder', 'empty-line', 'tc-none', 'tc-empty', 'left-empty', 'answer-input', 'setting-input', 'setting-picker', 'look-input', 'left-filter',
  'button', 'icon-button', 'field', 'check', 'empty'];

test('every file that asks the kit imports it from where it is (app.js is at the root, the views a folder down)', () => {
  const wrong = [];
  for (const file of FILES) {
    for (const match of readFileSync(join(root, file), 'utf8').matchAll(/from '([^']*kit\.js)'/g)) {
      if (join(root, dirname(file), match[1]) !== join(root, 'js', 'kit.js')) wrong.push(`${file}: ${match[1]}`);
    }
  }
  assert.deepEqual(wrong, []);
});

test('every view builds its buttons, switches, fields, badges, tiles, titles and empty states through kit.js, never by a class of its own', () => {
  const wrong = [];
  const at = (one, what) => wrong.push(`${one.file}:${one.line} ${what}: ${one.text.trim().slice(0, 90)}`);
  const all = SOURCE.map((one) => one.text).join('\n');
  // A control's tag with its first props, joined across a line break.
  for (const one of SOURCE) {
    const next = SOURCE.find((other) => other.file === one.file && other.line === one.line + 1)?.text || '';
    const text = one.text + ' ' + next.trim();
    for (const match of one.text.matchAll(/h\('(button|input|select|textarea)', \{/g)) {
      const rest = text.slice(text.indexOf(match[0]) + match[0].length);
      const cls = rest.match(/^\s*class: ['`]([a-z0-9-]+)/)?.[1];
      if (match[1] === 'button' && !(cls && ROWS.has(cls))) at(one, `a button by ${cls ? `class "${cls}"` : 'no class'}, not kit.button`);
      if (match[1] !== 'button' && !(cls && OWN_FIELDS.has(cls))) at(one, `a ${match[1]} by ${cls ? `class "${cls}"` : 'no class'}, not kit.field`);
    }
    // A class string made in a view that names a component or one it replaced.
    for (const match of one.text.matchAll(/\bclass: ['`]([^'`]+)['`]/g)) {
      // Handed to a kit call: the nearest builder before it, on this line or the one before, is kit's, not h's.
      const prefix = (SOURCE.find((other) => other.file === one.file && other.line === one.line - 1)?.text || '') + '\n' + one.text.slice(0, match.index);
      const kitAt = prefix.search(/\bkit\.(button|iconButton|segment|segmented|field|select|checkbox|badge|tile|sectionTitle|empty)\((?![\s\S]*\bkit\.[a-zA-Z]+\()/);
      const hAt = Math.max(prefix.lastIndexOf("h('"), prefix.lastIndexOf('h(`'));
      if (kitAt >= 0 && kitAt > hAt) {
        // A placement class handed to a kit call: allowed, unless it names a component itself.
        const named = match[1].split(/\s+/).filter((name) => ['button', 'icon-button', 'segment', 'segmented', 'field', 'badge', 'tile', 'section-title', 'empty', 'quiet', 'plain', 'small'].includes(name));
        if (named.length) at(one, `kit given the class "${named.join(' ')}"`);
        continue;
      }
      const names = match[1].split(/\s+/).filter((name) => OLD.includes(name));
      if (names.length) at(one, `class "${names.join(' ')}" composed in a view`);
    }
  }
  // Every helper is in use: the views moved to them.
  for (const helper of ['button', 'iconButton', 'segmented', 'segment', 'field', 'select', 'checkbox', 'badge', 'badgeClass', 'fieldClass', 'tile', 'sectionTitle', 'empty']) {
    if (!new RegExp(`\\bkit\\.${helper}\\(`).test(all)) wrong.push(`kit.${helper} used by no view`);
  }
  assert.deepEqual(wrong, []);
});

test('a class a view hands a component only places it: no rule outside the Components and States sections gives it a look', () => {
  const placements = new Set();
  for (const one of SOURCE) {
    for (const match of one.text.matchAll(/\bkit\.(button|iconButton|segment|segmented|field|select|checkbox|badge|tile|sectionTitle|empty)\([^;]*?\b(class|wrap): '([a-z0-9 -]+)'/g)) {
      for (const name of match[3].split(/\s+/)) placements.add(name);
    }
  }
  const outside = withoutMedia(bare.slice(0, start) + bare.slice(end, css.indexOf('/* ---- States:')));
  const LOOK = /(^|;)\s*(background(-color)?|color|font(-size|-weight|-family)?|border-radius|box-shadow|height|min-height|text-transform|letter-spacing)\s*:/;
  // Placed with their look on purpose, each for its place: the phone's End as three dots, the pair of Send and its
  // menu joined, the head's chosen icon, the touch block's fingertip, the dial's menu on a phone.
  const ALLOWED = new Set(['end-button', 'send-main', 'send-more', 'tc-new', 'dial', 'tabs', 'presets', 'phone-only', 'team-button', 'palette-open', 'back', 'tc-back',
    'boost-mark', 'inspect-toggle', 'pane-toggle', 'talk-button', 'row-action', 'task-more', 'sheet-close', 'inspect-close', 'tab-banner-close', 'composer-attach', 'setting-text', 'lead-goal',
    'model-input', 'tc-find', 'offer-yes', 'stat-figure', 'look-input', 'narrow', 'start-button', 'take-back', 'card-undo', 'preset-edit-toggle', 'setting-change',
    'answer-input', 'empty-state', 'placeholder', 'tc-empty', 'empty-line', 'tc-none', 'left-empty', 'stat-none', 'col-title', 'tc-group', 'setting-section-title', 'group-head',
    'board-group-head', 'tc-meta', 'setting-mark', 'stat-badge', 'score-tile', 'setting-input', 'left-filter', 'changed', 'rail']);
  const wrong = [];
  for (const match of outside.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const body = match[2];
    if (!LOOK.test(body)) continue;
    for (const selector of match[1].split(/,(?![^(]*\))/).map((one) => one.trim())) {
      const solo = selector.match(/^\.([a-z0-9-]+)$/)?.[1];
      if (!solo || !placements.has(solo)) continue;
      const looks = body.split(';').map((part) => part.trim()).filter((part) => LOOK.test(';' + part));
      // A placement may size its component (a glyph's size, a box's height); never colour, fill, round or letter it.
      if (!ALLOWED.has(solo) || looks.some((part) => /^(background|color|font-weight|font-family|border-radius|box-shadow|text-transform|letter-spacing)/.test(part))) wrong.push(`.${solo} { ${looks.join('; ')} }`);
    }
  }
  assert.ok(placements.size > 20, `placements found: ${placements.size}`);
  assert.deepEqual(wrong, []);
});
