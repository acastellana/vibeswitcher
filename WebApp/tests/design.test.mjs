// The page's one scale (the design review of 2026-11-25: section 2's scale, D1, D2 and its group A): type, control
// heights, corners, elevation, motion and colour roles are tokens on :root, and every rule uses them; every kind of
// control answers a hover, a press and a wait the same way. Read from style.css itself, line by line, so a literal
// that carries its reason in a comment on its own line is allowed and one that doesn't is named.
// Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
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

// ---- States (D1) ----

// The page's controls, from the views themselves: every class a button, a link or a <details>' summary carries.
const scripts = [join(here, '..', 'app.js'), ...readdirSync(join(here, '..', 'js'), { recursive: true }).filter((name) => name.endsWith('.js')).map((name) => join(here, '..', 'js', name))];
const code = scripts.map((file) => readFileSync(file, 'utf8').split('\n').filter((line) => !line.trim().startsWith('//')).join('\n')).join('\n');
const CONTROLS = [];
// The class may come after other properties, or on the next line.
for (const match of code.matchAll(/h\('(button|a)', \{[^}]*?\bclass: ['`]([a-z0-9 -]+)/g)) CONTROLS.push({ tag: match[1], classes: match[2].trim().split(/\s+/) });
for (const match of code.matchAll(/h\('details', \{ class: ['`]([a-z0-9-]+)['`] \}, h\('summary'/g)) CONTROLS.push({ tag: 'summary', classes: [`${match[1]} summary`] });
// And those js/kit.js builds (a button by its role and size, an icon button, a switch's choice), with the call's own class.
const KIT = { button: { primary: ['button'], plain: ['button', 'plain'], quiet: ['button', 'quiet'], danger: ['button', 'plain', 'danger'] } };
for (const match of code.matchAll(/kit\.(button|iconButton|segment)\((?:'([a-z]+)', )?\{([^}]*)/g)) {
  const [, call, role, props] = match;
  const size = props.match(/\bsize: '([sml])'/)?.[1] || 'm';
  const own = props.match(/\bclass: '([a-z0-9 -]+)'/)?.[1].split(/\s+/) || [];
  const base = call === 'button' ? KIT.button[role || 'primary'] : call === 'iconButton' ? ['icon-button'] : ['segment'];
  CONTROLS.push({ tag: /\btag: 'a'/.test(props) ? 'a' : 'button', classes: [...base, ...(size === 's' && call !== 'segment' ? ['small'] : size === 'l' ? ['large'] : []), ...own] });
}

// The classes a selector names, outside its :not(…) (what it excludes is not what it styles).
const named = (selector) => {
  let plain = selector;
  while (/:not\(/.test(plain)) plain = plain.replace(/:not\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*\)/g, '');
  return plain;
};
// Whether some selector of `blocks` styles this control: one of its classes (a summary: its details' class before
// `summary`, or `> summary`), or a button inside .offer.
function styles(blocks, control) {
  return blocks.some((block) => listed(named(block.selector)).concat(listed(named(block.selector)).flatMap((one) => (one.match(/^:is\((.*)\)/s)?.[1] || '').split(/,(?![^(]*\))/).map((part) => part.trim()))).some((one) => {
    if (control.tag === 'summary') { const [cls] = control.classes[0].split(' '); return new RegExp(`\\.${cls}( >)? summary\\b`).test(one); }
    return control.classes.some((cls) => new RegExp(`\\.${cls}(?![a-z0-9-])`).test(one)) || (control.classes.some((cls) => cls.startsWith('offer-')) && /\.offer button/.test(one));
  }));
}
const kind = (control) => control.classes.join('.');

test('states: every kind of control the views draw has a pressed rule (:active), a hover where there is a pointer, and the one transition', () => {
  const pressed = RULES.filter((block) => /:active\b/.test(block.selector) && block.declarations.some((d) => /^(background-color|background|transform|box-shadow|color)$/.test(d.property)));
  const hovered = RULES.filter((block) => /\(hover: hover\)/.test(block.media) && /:hover\b/.test(block.selector));
  const moving = RULES.filter((block) => block.declarations.some((d) => d.property === 'transition' && d.value === 'var(--state-transition)'));
  const missing = [];
  for (const control of CONTROLS) {
    if (!styles(pressed, control)) missing.push(`${kind(control)}: no :active`);
    if (!styles(hovered, control)) missing.push(`${kind(control)}: no hover`);
    if (!styles(moving, control)) missing.push(`${kind(control)}: no transition`);
  }
  assert.ok(CONTROLS.length > 80, `the views' controls found: ${CONTROLS.length}`);
  assert.deepEqual([...new Set(missing)], []);
});

test('states: a hover lives only where there is a pointer, so a tap leaves nothing lit; a press shows on a touch screen too', () => {
  const stray = RULES.filter((block) => /:hover\b/.test(block.selector) && !/\(hover: hover\)/.test(block.media)).map((block) => block.selector.slice(0, 80));
  assert.deepEqual(stray, []);
  // No :active is behind a pointer's query: a finger presses too.
  const hidden = RULES.filter((block) => /:active\b/.test(named(block.selector)) && /hover/.test(block.media)).map((block) => block.selector.slice(0, 80));
  assert.deepEqual(hidden, []);
  // The browser's grey tap flash is off (the pressed state answers instead), and the page listens for touches, which a
  // phone's browser needs before it shows :active.
  assert.ok(RULES.some((block) => block.selector === 'html' && block.declarations.some((d) => d.property === '-webkit-tap-highlight-color' && d.value === 'transparent')));
  assert.match(readFileSync(join(here, '..', 'app.js'), 'utf8'), /addEventListener\('touchstart', \(\) => \{\}, \{ passive: true \}\)/);
});

test('states: pressed is --fill-3 under a quiet control and the accent pressed (and a 0.97 scale) for a solid one; disabled answers nothing', () => {
  const active = RULES.filter((block) => /:active\b/.test(block.selector));
  assert.ok(active.some((block) => block.declarations.some((d) => d.property === 'background-color' && d.value === 'var(--fill-3)')));
  const solid = active.find((block) => /\.button:not\(\.quiet\)/.test(block.selector));
  // As specific as the solid hover (which leaves out .confirming), so a mouse press shows the pressed accent, not the hover's.
  const hover = RULES.find((block) => /\(hover: hover\)/.test(block.media) && /\.button:not\(\.quiet\)/.test(block.selector) && /:hover$/.test(block.selector));
  assert.equal(solid.selector.replace(/:active$/, ''), hover.selector.replace(/:hover$/, ''), 'the solid press and hover name the same buttons, alike');
  assert.ok(solid, 'a pressed rule for the solid button');
  const looks = Object.fromEntries(solid.declarations.map((d) => [d.property, d.value]));
  assert.equal(looks['background-color'], 'var(--accent-press)');
  assert.equal(looks.transform, 'scale(0.97)');
  // Every hover and press of a button, Send, a switch or an option leaves out what is disabled.
  for (const block of RULES.filter((one) => /:(hover|active)\b/.test(one.selector) && /\.(button|send|option|icon-button|copy-button)\b/.test(one.selector))) {
    assert.match(block.selector, /:disabled/, `${block.selector.slice(0, 80)} reacts while disabled`);
  }
  assert.ok(RULES.some((block) => /\.button[^{]*:disabled/.test(block.selector) && block.declarations.some((d) => d.property === 'cursor' && d.value === 'default')));
});

test('states: a control waiting on the node is busy ([aria-busy]): its own look kept, a slow pulse, the wait cursor; the views mark it', () => {
  const busy = RULES.find((block) => block.selector === '.button[aria-busy="true"]');
  assert.ok(busy, 'a busy rule for buttons');
  const looks = Object.fromEntries(busy.declarations.map((d) => [d.property, d.value]));
  assert.equal(looks.cursor, 'progress');
  assert.match(looks.animation, /^busy var\(--loop\)/);
  assert.ok(Number(looks.opacity) >= 0.8, 'never faded under 0.8 (U7), still while motion is reduced');
  assert.ok(ALL.some((block) => block.keyframes === 'busy'));
  // Not the disabled grey while it waits.
  assert.ok(RULES.some((block) => /\.button:not\(\.quiet\)\[aria-busy="true"\]:disabled/.test(block.selector) && block.declarations.some((d) => d.value === 'var(--accent)')));
  // Each request that disables its button while the node answers marks it busy and unmarks it after.
  for (const file of ['js/acting.js', 'js/views/project.js', 'js/views/mail.js', 'js/views/sheet.js']) {
    const source = readFileSync(join(here, '..', file), 'utf8');
    assert.match(source, /\.setAttribute\('aria-busy', 'true'\)/, file);
    assert.match(source, /\.removeAttribute\('aria-busy'\)/, file);
  }
});

test('states: the accent pointed at and pressed keeps its words at 4.5:1, light and dark', () => {
  const hex = (text) => [0, 2, 4].map((i) => parseInt(text.slice(1 + i, 3 + i), 16));
  const pair = (name) => ROOT[name].match(/^light-dark\((#[0-9a-f]{6}), (#[0-9a-f]{6})\)$/i).slice(1).map(hex);
  const channel = (value) => { const c = value / 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
  const luminance = ([r, g, b]) => 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
  const ratio = (a, b) => { const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x); return (hi + 0.05) / (lo + 0.05); };
  const [accent, ink, onAccent] = ['--accent', '--ink', '--on-accent'].map(pair);
  for (const name of ['--accent-hover', '--accent-press']) {
    const share = Number(ROOT[name].match(/var\(--accent\) (\d+)%, var\(--ink\)/)[1]) / 100;
    for (const theme of [0, 1]) {
      const mixed = accent[theme].map((value, i) => value * share + ink[theme][i] * (1 - share));
      assert.ok(ratio(onAccent[theme], mixed) >= 4.5, `${name} ${theme ? 'dark' : 'light'}: ${ratio(onAccent[theme], mixed).toFixed(2)}`);
    }
  }
});

test('states: no selector puts a space before a pseudo-class after a parenthesis (it would style what is inside the control, not the control)', () => {
  const split = RULES.filter((block) => /\)\s+:(not|hover|active|focus|disabled)\b/.test(block.selector)).map((block) => block.selector.slice(0, 100));
  assert.deepEqual(split, []);
});

// ---- Control sizes (D2) ----

// Each kind of button and field, and its height on the scale (rows, options and the palette's big field are rows).
const SIZED = {
  '.button': 'm', '.button.small': 's', '.button.large': 'l', '.icon-button': 'm', '.icon-button.small': 's', '.row-action': 's', '.task-more': 's', '.segment': 's',
  '.copy-button': 's', '.code-run': 's', '.confirm-clear': 's', '.summary-brief': 's', '.offer button': 's', '.latest': 's', '.look-colour': 's',
  '.send': 'l', '.composer-attach': 'l', '.composer-input': 'l',
  '.field': 'm', '.setting-search': 'm', '.tc-find': 'm',
};
const TOUCH = '(hover: none) and (pointer: coarse)';

test('sizes: buttons and fields come in three heights (24, 30, 36), and 44 on a touch screen', () => {
  const wrong = [];
  for (const [selector, size] of Object.entries(SIZED)) {
    const own = RULES.filter((block) => block.media === '' && listed(block.selector).includes(selector)).flatMap((block) => block.declarations);
    const height = own.filter((d) => d.property === 'height' || d.property === 'min-height').at(-1);
    if (!height) wrong.push(`${selector}: no height of its own (its padding decides it)`);
    else if (height.value !== `var(--ctl-${size})`) wrong.push(`${selector}: ${height.property} ${height.value}, not var(--ctl-${size})`);
  }
  // Wherever a button's or a field's height is set, it is one of the scale's.
  for (const block of RULES) {
    const controls = listed(block.selector).filter((one) => SIZED[one] || /\.(button|icon-button|segment|field|dial-fold|strip-fold)(?![a-z0-9-])/.test(named(one)));
    if (!controls.length) continue;
    for (const d of block.declarations) {
      if (!/^(min-)?height$/.test(d.property) || reasoned(d)) continue;
      const allowed = block.media === TOUCH ? /^var\(--ctl-(touch|s|m|l)\)$/ : /^var\(--ctl-(s|m|l|touch)\)$|^auto$/;
      if (!allowed.test(d.value)) wrong.push(where(block, d));
    }
  }
  // A tab inside its track: the track is the standard height (24 and 3 px either side).
  for (const track of ['.segmented']) {
    const padding = RULES.filter((block) => block.media === '' && block.selector === track).flatMap((block) => block.declarations).filter((d) => d.property === 'padding').at(-1)?.value;
    // Its padding in px, the tokens resolved (the spacing scale writes it from the control heights).
    let text = String(padding);
    for (let n = 0; n < 5 && /var\(/.test(text); n++) text = text.replace(/var\((--[\w-]+)\)/g, (_, name) => `(${ROOT[name]})`);
    const side = Function(`return (${text.replace(/calc/g, '').replace(/(\d*\.?\d+)px/g, '$1')})`)();
    if (24 + 2 * side !== 30) wrong.push(`${track}: padding ${padding} makes the track ${24 + 2 * side} px`);
  }
  // The touch block keeps every control a fingertip, on the token.
  const touch = RULES.filter((block) => block.media === TOUCH);
  for (const selector of ['.icon-button', '.send', '.button', '.segment', '.copy-button', '.offer button']) {
    const sizes = touch.filter((block) => listed(block.selector).includes(selector)).flatMap((block) => block.declarations).filter((d) => /^(min-)?height$/.test(d.property)).map((d) => d.value);
    if (!sizes.includes('var(--ctl-touch)')) wrong.push(`${selector}: not 44 on a touch screen`);
  }
  assert.deepEqual(wrong, []);
});

// ---- Type (D3's first step, D19) ----

test('type: every size, weight and line is a token (seven sizes, three weights), every kind of code one size, nothing under 11.5 px', () => {
  const found = [];
  for (const block of RULES) {
    for (const d of block.declarations) {
      if (reasoned(d)) continue;
      if (d.property === 'font-size' && !/^(var\(--t-[a-z-]+\)|inherit)$/.test(d.value)) found.push(where(block, d));
      if (d.property === 'font-weight' && !/^(var\(--w-(regular|medium|strong)\)|inherit)$/.test(d.value)) found.push(where(block, d));
      if (d.property === 'line-height' && !/^(var\(--lh-[a-z]+\)|0|1|normal|inherit)$/.test(d.value)) found.push(where(block, d));
      if (d.property === 'font' && d.value !== 'inherit' && !/^var\(--t-[a-z]+\)\/var\(--lh-[a-z]+\) var\(--(sans|mono)\)$/.test(d.value)) found.push(where(block, d));
    }
  }
  assert.deepEqual(found, []);
  // Every size a rule names is on the scale (or a touch screen's field), and every :root's value of it, wide or on a
  // phone, is a size this page draws: nothing under 11.5.
  const sizes = new Set(RULES.flatMap((block) => block.declarations).filter((d) => d.property === 'font-size').flatMap((d) => [...d.value.matchAll(/var\((--t-[a-z-]+)\)/g)].map((m) => m[1])));
  for (const name of sizes) assert.ok(name in SCALE.type || name === '--t-field-touch', `${name} is not on the scale`);
  for (const [name, values] of Object.entries(VALUES)) {
    if (!name.startsWith('--t-')) continue;
    for (const value of values) assert.ok(parseFloat(value) >= 11.5, `${name}: ${value}`);
  }
  // The old three are gone: one scale.
  for (const name of ['--small', '--text', '--large']) assert.ok(!VALUES[name], `${name} still defined`);
  // Code: inline, fenced, output, diffs and command lines all at --t-code (D19).
  for (const selector of ['.prose code, .card code, .node code', '.code pre', '.output', '.diff', '.tool-title', '.copy-line .copy-text', '.held-diff', '.sheet-body code']) {
    const size = RULES.filter((block) => block.selector === selector).flatMap((block) => block.declarations).filter((d) => d.property === 'font-size').at(-1)?.value;
    assert.equal(size, 'var(--t-code)', selector);
  }
});

test('states: a pointer over a control never paints over what its state class says (confirming, copied, listening, done, failed, asked)', () => {
  // Each pair: a kind of control, and a class that colours it to say something.
  const PAIRS = [['.button.quiet', 'confirming'], ['.icon-button', 'copied'], ['.icon-button', 'listening'], ['.copy-button', 'done'], ['.fold', 'failed'], ['.place', 'asked']];
  const wrong = [];
  for (const block of RULES.filter((one) => /\(hover: hover\)/.test(one.media) && /:hover\b/.test(one.selector))) {
    if (!block.declarations.some((d) => /^(color|background-color|background)$/.test(d.property))) continue;
    for (const [control, modifier] of PAIRS) {
      const list = block.selector.match(/^:is\(([\s\S]*?)\):not\(:where\(([\s\S]*)\)\):hover$/);
      if (!list || !list[1].split(',').map((one) => one.trim()).includes(control)) continue;
      if (!new RegExp(`\\.${modifier}\\b`).test(list[2])) wrong.push(`${control}.${modifier} repainted by ${block.selector.slice(0, 60)}…`);
    }
  }
  assert.deepEqual(wrong, []);
});

test('states: Lo último floats over the chat, so its hover and press are opaque steps, never a see-through fill; the message box keeps its ring while clicked', () => {
  const fills = RULES.filter((block) => /:(hover|active)\b/.test(block.selector) && block.declarations.some((d) => d.property === 'background-color' && /var\(--fill/.test(d.value)));
  assert.ok(!fills.some((block) => /(^|[\s,(])\.latest(?![a-z-])/.test(named(block.selector))), 'Lo último under a translucent fill');
  const own = (selector) => RULES.filter((block) => block.selector === selector).flatMap((block) => block.declarations);
  assert.equal(own('.latest:hover').find((d) => d.property === 'background-color')?.value, 'var(--raised-hover)');
  assert.equal(own('.latest:active').find((d) => d.property === 'background-color')?.value, 'var(--raised-press)');
  for (const name of ['--raised-hover', '--raised-press']) assert.match(ROOT[name], /^color-mix\(in srgb, var\(--raised\) \d+%, var\(--ink\)\)$/);
  // Pressing inside the focused message box: no ring swapped for another.
  const composer = RULES.filter((block) => /:active\b/.test(block.selector) && listed(block.selector).some((one) => /^\.composer-input/.test(one)));
  for (const block of composer) for (const one of listed(block.selector).filter((part) => /^\.composer-input/.test(part))) assert.match(one, /:not\(:focus\)/);
});

test('states: a busy solid button keeps its words at 4.5:1 while it is dimmed, light and dark, on every surface', () => {
  const busy = RULES.find((block) => block.selector === '.button[aria-busy="true"]');
  const opacity = Number(busy.declarations.find((d) => d.property === 'opacity').value);
  const hex = (text) => [0, 2, 4].map((i) => parseInt(text.slice(1 + i, 3 + i), 16));
  const pair = (name) => ROOT[name].match(/^light-dark\((#[0-9a-f]{6}), (#[0-9a-f]{6})\)$/i).slice(1).map(hex);
  const channel = (value) => { const c = value / 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
  const luminance = ([r, g, b]) => 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
  const ratio = (a, b) => { const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x); return (hi + 0.05) / (lo + 0.05); };
  const mix = (top, under) => top.map((value, i) => value * opacity + under[i] * (1 - opacity));
  const [accent, onAccent] = ['--accent', '--on-accent'].map(pair);
  for (const surface of ['--bg', '--side', '--raised']) {
    const under = pair(surface);
    for (const theme of [0, 1]) {
      const value = ratio(mix(onAccent[theme], under[theme]), mix(accent[theme], under[theme]));
      assert.ok(value >= 4.5, `${theme ? 'dark' : 'light'} over ${surface}: ${value.toFixed(2)}`);
    }
  }
});

test('states: a goal’s date says where it comes from on a tap too (focus), not only to a pointer', () => {
  assert.ok(RULES.some((block) => block.media === '' && block.selector === '.road-when[data-basis]:focus::after' && block.declarations.some((d) => d.property === 'display' && d.value === 'block')));
});
