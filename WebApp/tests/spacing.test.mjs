// One spacing scale under every screen (the design review of 2026-11-25, section 2, and its group G): every padding,
// margin, gap and inset in style.css is a space token, --s-1 … --s-9 (2, 4, 6, 8, 12, 16, 24, 32, 48 px), or one of
// the kinds listed below with its reason; no spacing length is set as a literal from js. Read from style.css itself,
// as tests/design.test.mjs reads it. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, '..', 'style.css'), 'utf8');
const bare = source.replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, ' '));
const lineAt = (offset) => bare.slice(0, offset).split('\n').length;

// Every declaration with its block's selector and the @media around it.
function declarations() {
  const found = [];
  const walk = (start, end, media) => {
    let at = start;
    while (at < end) {
      const open = bare.indexOf('{', at);
      if (open < 0 || open >= end) break;
      const head = bare.slice(at, open).trim().replace(/\s+/g, ' ');
      let depth = 1; let close = open + 1;
      while (close < end && depth) { if (bare[close] === '{') depth++; else if (bare[close] === '}') depth--; close++; }
      if (head.startsWith('@media') || head.startsWith('@supports')) walk(open + 1, close - 1, head.startsWith('@media') ? head.slice(6).trim() : media);
      else if (!head.startsWith('@keyframes')) {
        let from = open + 1;
        for (const part of bare.slice(open + 1, close - 1).split(';')) {
          const colon = part.indexOf(':');
          if (colon >= 0 && part.trim()) {
            found.push({ selector: head, media, property: part.slice(0, colon).trim(), value: part.slice(colon + 1).trim().replace(/\s+/g, ' '), line: lineAt(from + part.search(/\S/)) });
          }
          from += part.length + 1;
        }
      }
      at = close;
    }
  };
  walk(0, bare.length, '');
  return found;
}
const ALL = declarations();

const SCALE = { '--s-1': '2px', '--s-2': '4px', '--s-3': '6px', '--s-4': '8px', '--s-5': '12px', '--s-6': '16px', '--s-7': '24px', '--s-8': '32px', '--s-9': '48px' };
const SPACING = /^(padding|margin|gap|row-gap|column-gap|inset|top|right|bottom|left|scroll-padding|scroll-margin)(-(top|right|bottom|left|block|inline|block-start|block-end|inline-start|inline-end))?$/;

// Allowed outside the scale, each kind once, with its reason.
const KINDS = [
  // 0, auto and the keywords: no length.
  ['none', /^(0|auto|inherit|initial|unset)$/],
  // A hairline, or an optical nudge of one pixel (a mark's stroke against its row, a chip's 1 px above its text).
  ['hairline', /^-?1px$/],
  // A share of the box (a centred popover's 50%, a bar's place on the roadmap's axis): it follows the box, not the scale.
  ['share', /^-?\d*\.?\d+%$/],
  // A share of the screen (the palette's and the not-paired page's distance from the top).
  ['screen', /^\d*\.?\d+(vh|dvh|svh)$/],
  // Room left for a column or a control, by that thing's own size token (the inspector's column, a fingertip's button).
  ['room', /^var\(--(inspector|ctl-(s|m|l|touch))\)$/],
  // The device's own inset (a notch, the home bar).
  ['device', /^env\(safe-area-inset-(top|right|bottom|left)\)$/],
];
// calc(), max() and min() built only from tokens: a space token, a control's height (room left for a control, or a
// control's padding that keeps its height), a line of type, the chat's width, the label column; a share of the box;
// the device's safe area; a unitless factor; a 1 px hairline.
const ATOMS = [/var\(--(s-[1-9]|ctl-(s|m|l|touch)|chat-width|label|head|t-[a-z]+|lh-[a-z]+)\)/g, /env\(safe-area-inset-(top|right|bottom|left)\)/g, /\d*\.?\d+%/g, /\b1px\b/g, /\d*\.?\d+(?![\w%])/g];
function calcAllowed(term) {
  if (!/^(calc|max|min)\(/.test(term)) return false;
  let text = term.replace(/\b(calc|max|min)\(/g, '(');
  for (const atom of ATOMS) text = text.replace(atom, '#');
  return text.includes('#') && /^[#\s()+\-*/,]+$/.test(text);
}

// Values kept off the scale on purpose: snapping them would change what must not move (a control's height, a mark's
// centre, the roadmap's drawing). Each with its reason; the report lists them.
const KEPT = new Map([
  // The roadmap's drawing: each offset centres a bar, a dot or a mark of its own size on its lane, or puts the axis's
  // hours under "Now". Snapped, they would sit off the lines they mark.
  ['.track-base { top }', 'the base line on the lane (10 for a 1 px line in a 21 px lane)'],
  ['.track-bar { top }', 'the bar centred on the lane'],
  ['.track-dot { top }', 'the dot centred on the lane'],
  ['.track-mark { top }', 'the mark centred on the lane'],
  ['.goal-row .track-dot { margin-left }', 'half the goal dot\u2019s 15 px, to centre it on its time'],
  ['.goal-row .track-dot { top }', 'the goal dot centred on its lane'],
  ['.axis-tick { top }', 'the hours under "Now" (a line of small type and its leading)'],
  ['.goal-row::before { top }', 'the goal\u2019s diamond on its first line: the row\u2019s 8 and the line\u2019s middle less half the mark'],
  // A to-do's box on its first line: half the line, whatever the text's size.
  ['.todo::before { top }', 'half an em: the first line\u2019s middle'],
  // A dot centred on its line by half its own 7 px.
  ['.offline.signed-out::before { margin-top }', 'half the 7 px dot'],
]);

// Split a value into its terms at the top level (a calc's spaces stay inside it).
function terms(value) {
  const out = []; let depth = 0; let word = '';
  for (const ch of value) {
    if (ch === '(') depth++;
    if (ch === ')') depth--;
    if (ch === ' ' && !depth) { if (word) out.push(word); word = ''; } else word += ch;
  }
  if (word) out.push(word);
  return out;
}
const isToken = (term) => /^var\(--s-[1-9]\)$/.test(term);
const allowed = (term) => isToken(term) || KINDS.some(([, pattern]) => pattern.test(term)) || calcAllowed(term);

test('the space tokens are the scale, on :root', () => {
  const root = Object.fromEntries(ALL.filter((d) => d.selector === ':root' && d.media === '').map((d) => [d.property, d.value]));
  for (const [token, value] of Object.entries(SCALE)) assert.equal(root[token], value, token);
});

test('every padding, margin, gap and inset in style.css is a space token or an allowed kind', () => {
  const wrong = [];
  for (const d of ALL) {
    if (!SPACING.test(d.property) || d.selector.startsWith(':root')) continue;
    if (KEPT.has(`${d.selector} { ${d.property} }`)) continue;
    const bad = terms(d.value).filter((term) => !allowed(term));
    if (bad.length) wrong.push(`style.css:${d.line} ${d.selector.slice(0, 70)}${d.media ? ' @' + d.media : ''} { ${d.property}: ${d.value} }`);
  }
  assert.deepEqual(wrong, [], `${wrong.length} spacing values off the scale`);
});

test('each kept value is still in style.css, so the list never outlives its rule', () => {
  for (const key of KEPT.keys()) {
    const [, selector, property] = key.match(/^(.*) \{ (.*) \}$/);
    assert.ok(ALL.some((d) => d.selector === selector && d.property === property), key);
  }
});

test('the checker itself: a token, the kinds and calc of tokens pass; a literal length does not', () => {
  for (const ok of ['var(--s-4)', '0', 'auto', '1px', '-1px', '50%', '12vh', 'var(--ctl-touch)', 'env(safe-area-inset-top)', 'calc(var(--s-4) * -1)', 'calc(var(--s-2) + env(safe-area-inset-top))',
    'calc((var(--ctl-m) - var(--ctl-s)) / 2)', 'max(var(--s-7), calc((100% - var(--chat-width)) / 2 + var(--s-7)))', 'calc(100% - var(--s-1))']) assert.ok(allowed(ok), ok);
  for (const no of ['8px', '10px', '-4px', '2.5px', '1em', 'calc(8px + env(safe-area-inset-top))', 'calc(100% - 2px)', 'max(24px, 10%)', 'var(--gap)']) assert.ok(!allowed(no), no);
});

// ---- js: a length set from a script is a token too ----

const jsFiles = [join(here, '..', 'app.js')];
for (const dir of [join(here, '..', 'js'), join(here, '..', 'js', 'views')]) {
  for (const name of readdirSync(dir)) if (name.endsWith('.js')) jsFiles.push(join(dir, name));
}
const JS_SPACING = /(?:style\.(padding|margin|gap|rowGap|columnGap|inset|top|right|bottom|left)\w*\s*=\s*([^;\n]+))|(?:setProperty\(\s*['"`](padding|margin|gap|row-gap|column-gap|inset|top|right|bottom|left)[\w-]*['"`]\s*,\s*([^)\n]+\)?))/g;

// The spacing lengths a script's text sets as literals.
function jsLiterals(text) {
  const wrong = [];
  for (const match of text.matchAll(JS_SPACING)) {
    const value = match[2] || match[4];
    // A share (`${x}%`) or a token is fine; a pixel count is not.
    if (/px\b/.test(value) || /^\s*-?\d/.test(value)) wrong.push(match[0].trim());
  }
  return wrong;
}

test('no spacing length is set as a literal from js', () => {
  const wrong = jsFiles.flatMap((file) => jsLiterals(readFileSync(file, 'utf8')).map((one) => `${file.slice(file.indexOf('WebApp'))}: ${one}`));
  assert.deepEqual(wrong, []);
  // The check itself.
  assert.equal(jsLiterals("el.style.paddingLeft = '12px';").length, 1);
  assert.equal(jsLiterals('el.style.marginTop = depth * 12 + "px";').length, 1);
  assert.equal(jsLiterals("el.style.setProperty('margin-top', `${n}px`);").length, 1);
  assert.equal(jsLiterals("el.style.gap = 8;").length, 1);
  assert.equal(jsLiterals("node.style.setProperty('left', `${axis.x(from)}%`);").length, 0);
  assert.equal(jsLiterals("el.style.paddingLeft = 'var(--s-5)';").length, 0);
});
