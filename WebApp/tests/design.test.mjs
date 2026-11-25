// The page's one scale (the design review of 2026-11-25: section 2's scale, D1, D2 and its group A): type, control
// heights, corners, elevation, motion and colour roles are tokens on :root, and every rule uses them; every kind of
// control answers a hover, a press and a wait the same way. Read from style.css itself, line by line, so a literal
// that carries its reason in a comment on its own line is allowed and one that doesn't is named.
// Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, '..', 'style.css'), 'utf8');

// ---- style.css as declarations, each with its block's selector, the @media around it and its line ----

// The lines holding a comment (or part of one).
const commented = new Set();
for (const match of source.matchAll(/\/\*[\s\S]*?\*\//g)) {
  const first = source.slice(0, match.index).split('\n').length;
  const last = first + match[0].split('\n').length - 1;
  for (let line = first; line <= last; line++) commented.add(line);
}
// The source with comments blanked to spaces (newlines kept), so offsets still give lines.
const bare = source.replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, ' '));
const lineAt = (offset) => bare.slice(0, offset).split('\n').length;

// Every block: { selector, media, declarations: [{ property, value, line }] }; @keyframes' blocks have `keyframes`.
function blocks() {
  const found = [];
  const walk = (start, end, media, keyframes) => {
    let at = start;
    while (at < end) {
      const open = bare.indexOf('{', at);
      if (open < 0 || open >= end) break;
      const head = bare.slice(at, open).trim();
      let depth = 1; let close = open + 1;
      while (close < end && depth) { if (bare[close] === '{') depth++; else if (bare[close] === '}') depth--; close++; }
      if (head.startsWith('@media') || head.startsWith('@supports')) walk(open + 1, close - 1, head.startsWith('@media') ? head.slice(6).trim() : media, null);
      else if (head.startsWith('@keyframes')) walk(open + 1, close - 1, media, head.slice(10).trim());
      else {
        const declarations = [];
        let from = open + 1;
        for (const part of bare.slice(open + 1, close - 1).split(';')) {
          const colon = part.indexOf(':');
          if (colon >= 0 && part.trim()) {
            const offset = from + part.search(/\S/);
            declarations.push({ property: part.slice(0, colon).trim(), value: part.slice(colon + 1).trim().replace(/\s+/g, ' '), line: lineAt(offset) });
          }
          from += part.length + 1;
        }
        found.push({ selector: head.replace(/\s+/g, ' '), media, keyframes, declarations });
      }
      at = close;
    }
  };
  walk(0, bare.length, '', null);
  return found;
}
const ALL = blocks();
// The token and theme blocks: :root's own, wherever they are (a phone's sizes, more contrast).
const isTokens = (block) => /^:root(\[data-theme="(dark|light)"\])?$/.test(block.selector);
const RULES = ALL.filter((block) => !isTokens(block));
const listed = (selector) => selector.split(/,(?![^(]*\))/).map((one) => one.trim());
// A declaration's place, for a failure's message.
const where = (block, d) => `style.css:${d.line} ${block.selector.slice(0, 70)} { ${d.property}: ${d.value} }`;
const reasoned = (d) => commented.has(d.line);

// The tokens of :root outside any @media.
const ROOT = Object.fromEntries(ALL.filter((block) => block.selector === ':root' && block.media === '').flatMap((block) => block.declarations).map((d) => [d.property, d.value]));
// Each token's values in every :root (a phone's, more contrast's).
const VALUES = {};
for (const block of ALL.filter((one) => one.selector === ':root')) for (const d of block.declarations) (VALUES[d.property] ||= new Set()).add(d.value);

// ---- The scale, as the review proposed it ----

const SCALE = {
  type: { '--t-caption': '12px', '--t-body': '13px', '--t-read': '15px', '--t-title': '15px', '--t-heading': '17px', '--t-large': '20px', '--t-code': '12.5px' },
  // Each size's line, in px, as the review wrote them: the ratio tokens give them back to a tenth of a pixel.
  lines: { '--t-caption': 16, '--t-body': 18, '--t-read': 22, '--t-title': 20, '--t-heading': 22, '--t-large': 24, '--t-code': 18 },
  weights: { '--w-regular': '400', '--w-medium': '500', '--w-strong': '600' },
  controls: { '--ctl-s': '24px', '--ctl-m': '30px', '--ctl-l': '36px', '--ctl-touch': '44px' },
  radii: { '--r-1': '4px', '--r-2': '8px', '--r-3': '12px', '--r-4': '16px', '--r-pill': '999px' },
  motion: { '--dur-1': '120ms', '--dur-2': '180ms', '--loop': '1.2s', '--ease-out': 'cubic-bezier(0.2, 0.8, 0.2, 1)', '--ease-in': 'cubic-bezier(0.4, 0, 1, 1)' },
};

test('the scale is tokens on :root: type with its lines and weights, control heights, corners, elevation, motion and colour roles', () => {
  const wrong = [];
  for (const group of ['type', 'weights', 'controls', 'radii', 'motion']) {
    for (const [name, value] of Object.entries(SCALE[group])) if (ROOT[name] !== value) wrong.push(`${name}: ${ROOT[name]} (the scale says ${value})`);
  }
  for (const [size, px] of Object.entries(SCALE.lines)) {
    const ratio = Number(ROOT[size.replace('--t-', '--lh-')]);
    const drawn = parseFloat(SCALE.type[size]) * ratio;
    if (!(Math.abs(drawn - px) < 0.1)) wrong.push(`${size.replace('--t-', '--lh-')}: ${ROOT[size.replace('--t-', '--lh-')]} draws ${drawn.toFixed(2)} px, not ${px}`);
  }
  for (const name of ['--e-1', '--e-2', '--e-3']) if (!ROOT[name]) wrong.push(`${name} missing`);
  assert.match(ROOT['--e-1'] || '', /^0 0 0 1px var\(--line\)$/);
  assert.match(ROOT['--e-2'] || '', /^0 0 0 1px var\(--line\), 0 6px 20px var\(--shadow\)$/);
  assert.match(ROOT['--e-3'] || '', /^0 0 0 1px var\(--line\), 0 24px 60px var\(--shadow\)$/);
  // The colour roles, with the three new ones: pressed, the scrim, the highlight (and failed's own name).
  for (const name of ['--bg', '--side', '--raised', '--ink', '--ink-2', '--ink-3', '--line', '--fill', '--fill-2', '--fill-3', '--accent', '--accent-fill', '--on-accent',
    '--accent-hover', '--accent-press', '--scrim', '--highlight', '--danger']) if (!ROOT[name]) wrong.push(`${name} missing`);
  // One transition for every control's states, on the motion tokens.
  assert.match(ROOT['--state-transition'] || '', /background-color var\(--dur-1\) var\(--ease-out\)/);
  assert.deepEqual(wrong, []);
});

test('colour: no hex, rgb or named colour outside the token and theme blocks, unless the line says why', () => {
  const literal = /#[0-9a-f]{3,8}\b|\b(rgba?|hsla?|hwb|lab|lch|oklab|oklch)\(|(^|[\s,(])(white|black|red|green|blue|yellow|orange|gray|grey)(?=$|[\s,)])/i;
  const found = [];
  for (const block of RULES) for (const d of block.declarations) if (literal.test(d.value) && !reasoned(d)) found.push(where(block, d));
  assert.deepEqual(found, []);
});

test('colour: a failure is drawn in its own role (--danger), the scrims in one (--scrim), find in one (--highlight)', () => {
  const value = (selector, property) => RULES.filter((block) => listed(block.selector).includes(selector)).flatMap((block) => block.declarations).filter((d) => d.property === property).at(-1)?.value;
  for (const selector of ['.inspect-scrim', '.palette', '.sheet-scrim', '.app[data-drawer="left"] .drawer-scrim']) assert.equal(value(selector, 'background'), 'var(--scrim)', selector);
  assert.equal(value('::highlight(chat-find)', 'background'), 'var(--highlight)');
  assert.equal(value('mark.found', 'background'), 'var(--highlight)');
  for (const selector of ['.fold.failed', '.output.failed', '.task-failure', '.act-said.refused']) assert.equal(value(selector, 'color'), 'var(--danger)', selector);
});

test('motion: every duration is --dur-1, --dur-2 or --loop, every curve named (never the browser’s default), and reduced motion stops it all', () => {
  const found = [];
  for (const block of RULES) {
    for (const d of block.declarations) {
      if (!/^(transition|animation)(-duration|-delay|-timing-function)?$/.test(d.property) || reasoned(d)) continue;
      // A literal time other than 0s.
      if (/(^|[\s,(])(?!0s\b)\d*\.?\d+m?s\b/.test(d.value)) found.push(`${where(block, d)}: a literal duration`);
      if (d.property !== 'transition' && d.property !== 'animation') continue;
      if (/^none( !important)?$/.test(d.value) || d.value === 'var(--state-transition)') continue;
      for (const part of d.value.split(/,(?![^(]*\))/).map((one) => one.trim())) {
        if (/^visibility 0s/.test(part)) continue;
        if (!/var\(--(dur-1|dur-2|loop)\)/.test(part)) found.push(`${where(block, d)}: "${part}" without a duration token`);
        else if (!/var\(--ease-(out|in)\)|\blinear\b|ease-in-out/.test(part)) found.push(`${where(block, d)}: "${part}" on the browser’s default curve`);
        else if (/ease-in-out|linear/.test(part) && !/var\(--loop\)/.test(part)) found.push(`${where(block, d)}: "${part}": linear and ease-in-out are for loops`);
      }
    }
  }
  assert.deepEqual(found, []);
  const reduced = ALL.find((block) => /prefers-reduced-motion: reduce/.test(block.media) && block.selector.startsWith('*'));
  assert.ok(reduced, 'a reduced-motion block for everything');
  assert.match(reduced.declarations.map((d) => `${d.property}: ${d.value}`).join('; '), /animation: none !important; transition: none !important/);
});

test('elevation: a shadow is --e-1, --e-2 or --e-3 (or a field’s edge, ring or a switch’s chosen part), unless the line says why', () => {
  const found = [];
  for (const block of RULES) {
    for (const d of block.declarations) {
      if (d.property !== 'box-shadow' || reasoned(d) || d.value === 'none') continue;
      const parts = d.value.split(/,(?![^(]*\))/).map((one) => one.trim());
      if (!parts.every((part) => /^var\(--e-[a-z0-9-]+\)$/.test(part))) found.push(where(block, d));
    }
  }
  assert.deepEqual(found, []);
  // Every --e-* a rule names is one of the scale's.
  const names = new Set(RULES.flatMap((block) => block.declarations).filter((d) => d.property === 'box-shadow').flatMap((d) => [...d.value.matchAll(/var\((--e-[a-z0-9-]+)\)/g)].map((m) => m[1])));
  for (const name of names) assert.ok(ROOT[name], `${name} is no token`);
});

test('corners: every radius is --r-1 to --r-4 or the pill (a circle is 50%, a part inside a track the track’s less its padding), unless the line says why', () => {
  const ok = (part) => /^(0|50%|inherit|var\(--r-(1|2|3|4|pill)\)|calc\(var\(--r-(1|2|3|4)\) - \d+(\.\d+)?px\))$/.test(part);
  const found = [];
  for (const block of RULES) {
    for (const d of block.declarations) {
      if (!/^border(-[a-z]+)*-radius$/.test(d.property) || reasoned(d)) continue;
      if (!d.value.split(/ (?![^(]*\))/).every(ok)) found.push(where(block, d));
    }
  }
  assert.deepEqual(found, []);
});
