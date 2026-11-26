// The UX review's findings U6, U7, U8, U18's "Ahora" and U20–U23 (2026-11-25), each held here: the stylesheet's inks
// against its surfaces in both themes, its sizes, its touch block, the banners' place, and the small states.
// Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

// style.css read as the page draws it: its custom properties in both themes, every rule with the media query around
// it, and the WCAG contrast of two colours. No browser: the values are the stylesheet's own. (Here, not in a module of
// its own: a tests' folder holds Node tests alone, WebAppLintTests.)
const here = dirname(fileURLToPath(import.meta.url));
const css = readFileSync(join(here, '..', 'style.css'), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');

// Every rule as { media, selector, body } in source order; `media` is the @media's condition ('' outside one).
function rules(source = css) {
  const found = [];
  const walk = (text, media) => {
    let at = 0;
    while (at < text.length) {
      const open = text.indexOf('{', at);
      if (open < 0) break;
      const head = text.slice(at, open).trim();
      let depth = 1; let end = open + 1;
      while (end < text.length && depth) { if (text[end] === '{') depth++; else if (text[end] === '}') depth--; end++; }
      const body = text.slice(open + 1, end - 1);
      if (head.startsWith('@media')) walk(body, head.slice(6).trim());
      else if (!head.startsWith('@keyframes') && !head.startsWith('@supports')) found.push({ media, selector: head, body });
      at = end;
    }
  };
  walk(source, '');
  return found;
}

// A rule's declarations, { property: value } (the last wins, as in the browser).
function declarations(body) {
  const out = {};
  for (const part of body.split(';')) {
    const colon = part.indexOf(':');
    if (colon < 0) continue;
    out[part.slice(0, colon).trim()] = part.slice(colon + 1).trim();
  }
  return out;
}

// The custom properties of `:root` (outside any @media, or inside `media`), each as { light, dark }.
function tokens(media = '') {
  const out = {};
  for (const rule of rules()) {
    if (rule.selector !== ':root' || rule.media !== media) continue;
    for (const [name, value] of Object.entries(declarations(rule.body))) {
      if (!name.startsWith('--')) continue;
      const pair = value.match(/^light-dark\((.*)\)$/);
      if (pair) {
        const [light, dark] = splitTop(pair[1]);
        out[name] = { light, dark };
      } else out[name] = { light: value, dark: value };
    }
  }
  return out;
}

function splitTop(text) {
  let depth = 0;
  for (let i = 0; i < text.length; i++) {
    if (text[i] === '(') depth++; else if (text[i] === ')') depth--;
    else if (text[i] === ',' && !depth) return [text.slice(0, i).trim(), text.slice(i + 1).trim()];
  }
  return [text.trim(), text.trim()];
}

// '#rrggbb', '#rgb' or 'rgb(r g b / a)' as [r, g, b, a].
function parseColour(text) {
  const hex = text.match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/i);
  if (hex) {
    const digits = hex[1].length === 3 ? [...hex[1]].map((d) => d + d).join('') : hex[1];
    return [0, 2, 4].map((i) => parseInt(digits.slice(i, i + 2), 16)).concat(1);
  }
  const rgb = text.match(/^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)(?:\s*[/,]\s*([\d.]+))?\s*\)$/);
  if (rgb) return [Number(rgb[1]), Number(rgb[2]), Number(rgb[3]), rgb[4] === undefined ? 1 : Number(rgb[4])];
  throw new Error(`not a colour this reads: ${text}`);
}

// `top` drawn over the opaque `under`.
function over(top, under) {
  const [r, g, b, a] = top;
  return [r * a + under[0] * (1 - a), g * a + under[1] * (1 - a), b * a + under[2] * (1 - a), 1];
}

const channel = (value) => { const c = value / 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
const luminance = ([r, g, b]) => 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
function contrast(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

// A font size in px, given the sizes of the tokens it may name; null when it isn't a length this can read.
function px(value, sizes) {
  const token = value.match(/^var\((--[a-z0-9-]+)\)$/);
  if (token) return sizes[token[1]] ?? null;
  const plain = value.match(/^([\d.]+)px$/);
  if (plain) return Number(plain[1]);
  return null;
}


const INKS = ['--ink', '--ink-2', '--ink-3', '--accent', '--needs-you', '--working', '--background', '--done', '--idle', '--blocked', '--kept'];
const BASES = ['--bg', '--side', '--side-hover', '--side-selected', '--raised'];
const FILLS = ['--fill', '--fill-2', '--fill-3', '--accent-fill'];
// Where a fill is laid: the centre, the left column, a card or a panel.
const UNDER_FILLS = ['--bg', '--side', '--raised'];

function surfaces(t, theme) {
  const out = {};
  for (const base of BASES) out[base] = parseColour(t[base][theme]);
  for (const fill of FILLS) for (const base of UNDER_FILLS) out[`${fill} over ${base}`] = over(parseColour(t[fill][theme]), out[base]);
  return out;
}

test('U7: every ink reaches 4.5:1 on every surface, light and dark (and with more contrast asked)', () => {
  const failing = [];
  for (const media of ['', '(prefers-contrast: more)']) {
    const t = { ...tokens(), ...tokens(media) };
    for (const theme of ['light', 'dark']) {
      const all = surfaces(t, theme);
      for (const ink of INKS) {
        for (const [name, surface] of Object.entries(all)) {
          const ratio = contrast(parseColour(t[ink][theme]), surface);
          if (ratio < 4.5) failing.push(`${media || 'default'} ${theme}: ${ink} ${t[ink][theme]} on ${name}: ${ratio.toFixed(2)}`);
        }
      }
      // The words on a filled button or mark: on the accent, on a status colour.
      for (const [ink, fill] of [['--on-accent', '--accent'], ['--on-status', '--needs-you'], ['--on-status', '--done']]) {
        const ratio = contrast(parseColour(t[ink][theme]), parseColour(t[fill][theme]));
        if (ratio < 4.5) failing.push(`${media || 'default'} ${theme}: ${ink} on ${fill}: ${ratio.toFixed(2)}`);
      }
    }
  }
  assert.deepEqual(failing, []);
});

test('U7: a tinted pill (a colour mixed into its background) keeps its words at 4.5:1', () => {
  const t = tokens();
  const failing = [];
  for (const rule of rules()) {
    const d = declarations(rule.body);
    const mix = (d.background || '').match(/^color-mix\(in srgb, var\((--[a-z0-9-]+)\) ([\d.]+)%, (transparent|var\((--[a-z0-9-]+)\))\)$/);
    if (!mix) continue;
    if (!d.color) continue;
    const ink = d.color.match(/^var\((--[a-z0-9-]+)\)$/)?.[1];
    if (!ink) continue;
    const resolve = (name) => (t[name].light.startsWith('var(') ? t[t[name].light.slice(4, -1)] : t[name]);
    for (const theme of ['light', 'dark']) {
      const unders = mix[4] ? [mix[4]] : UNDER_FILLS;
      for (const under of unders) {
        const tint = parseColour(resolve(mix[1])[theme]);
        tint[3] = Number(mix[2]) / 100;
        const surface = over(tint, parseColour(t[under][theme]));
        const ratio = contrast(parseColour(resolve(ink)[theme]), surface);
        if (ratio < 4.5) failing.push(`${rule.selector} ${theme}: ${ink} on ${mix[1]} ${mix[2]}% over ${under}: ${ratio.toFixed(2)}`);
      }
    }
  }
  assert.deepEqual(failing, []);
});

test('U7: text is coloured with an ink, never a fill, and is never faded under 0.8 (an unusable choice is struck through, not faded)', () => {
  const fills = new Set([...FILLS, ...BASES, '--line', '--added', '--removed', '--shadow']);
  const wrong = [];
  for (const rule of rules()) {
    const d = declarations(rule.body);
    const token = (d.color || '').match(/^var\((--[a-z0-9-]+)\)$/)?.[1];
    if (token && fills.has(token)) wrong.push(`${rule.selector}: color ${d.color}`);
    const opacity = Number(d.opacity);
    // Hidden (0) is not faded; these are marks, bars, lines and a picture, no words: a terminal's screen dims while
    // its new replay is drawn (a moment), a picture while it is sent.
    const wordless = /(::before|::after|-bar|track-tick|project-ring|terminal-screen|attached-item)/;
    if (d.opacity && opacity > 0 && opacity < 0.8 && !wordless.test(rule.selector)) wrong.push(`${rule.selector}: opacity ${d.opacity}`);
  }
  assert.deepEqual(wrong, []);
});

test('U7: no text under 11.5 px, in any rule, wide or on a phone; the browser’s own <small> is held to it too', () => {
  const sizes = {};
  for (const media of ['', '(max-width: 760px)']) {
    for (const [name, value] of Object.entries(tokens(media))) {
      const size = px(value.light, {});
      if (size !== null) sizes[name] = Math.min(sizes[name] ?? Infinity, size);
    }
  }
  assert.ok(sizes['--t-caption'] >= 11.5, `--t-caption is ${sizes['--t-caption']}px`);
  const small = [];
  for (const rule of rules()) {
    const d = declarations(rule.body);
    let value = d['font-size'];
    if (!value && d.font && d.font !== 'inherit') value = d.font.match(/^(?:[a-z0-9-]+\s+)*?(var\(--[a-z0-9-]+\)|[\d.]+px)/)?.[1];
    if (!value || value === 'inherit') continue;
    // max(A, B) is at least A.
    const floor = value.match(/^max\(([^,]+),/)?.[1].trim();
    const size = px(floor || value, sizes);
    if (size === null) small.push(`${rule.selector}: ${value} (not a size this can hold to 11.5px)`);
    else if (size < 11.5) small.push(`${rule.selector}: ${value}`);
  }
  assert.deepEqual(small, []);
  const ua = rules().find((rule) => rule.selector === 'small' && rule.media === '');
  assert.ok(ua && px(declarations(ua.body)['font-size'], sizes) >= 11.5, 'a rule for <small> at the small size');
});

test('U8: on a touch screen every kind of control is 44 px both ways by its padding, checkboxes 24 px with their words tappable, text boxes 16 px', () => {
  const touch = rules().filter((rule) => /hover:\s*none/.test(rule.media) && /pointer:\s*coarse/.test(rule.media));
  const size = (selector, property) => {
    let found = null;
    for (const rule of touch) {
      const listed = rule.selector.split(/,(?![^(]*\))/).map((one) => one.trim());
      if (!listed.includes(selector)) continue;
      const value = declarations(rule.body)[property];
      // A token (the scale's --ctl-touch) read as its px.
      const token = value?.match(/^var\((--[a-z0-9-]+)\)$/)?.[1];
      if (value) found = parseFloat(token ? tokens()[token]?.light : value);
    }
    return found;
  };
  const tall = (selector) => Math.max(size(selector, 'min-height') ?? 0, size(selector, 'height') ?? 0);
  const wide = (selector) => Math.max(size(selector, 'min-width') ?? 0, size(selector, 'width') ?? 0);
  const short = [];
  // Icon buttons, a message's actions, Send: square.
  for (const selector of ['.icon-button', '.row-action', '.send', '.composer-attach']) if (tall(selector) < 44 || wide(selector) < 44) short.push(selector);
  // Switches, small and text buttons.
  for (const selector of ['.segment', '.button', '.button.small', '.copy-button', '.confirm-clear', '.link', '.summary-brief', '.take-back', '.fold', '.offer button']) {
    if (tall(selector) < 44 || wide(selector) < 44) short.push(selector);
  }
  // The drawers' rows and the two-column list's rows: the whole width already, 44 tall.
  for (const selector of ['.place', '.project', '.tc-row', '.palette-row', '.option', '.task-link']) if (tall(selector) < 44) short.push(selector);
  assert.deepEqual(short, []);
  assert.equal(size('input[type="checkbox"]', 'width'), 24);
  assert.equal(size('input[type="checkbox"]', 'height'), 24);
  assert.equal(size('label:has(> input[type="checkbox"])', 'min-height'), 44);
  const inputs = touch.find((rule) => rule.selector.startsWith(':is(textarea, select, input'));
  const field = declarations(inputs.body)['font-size'];
  assert.ok(inputs && parseFloat(field.startsWith('var(') ? tokens()[field.slice(4, -1)].light : field) >= 16, 'text boxes at 16 px');
});

test('U6: the reconnecting line, the page not paired and the notifications’ offer are a row of the centre, never over its header', async () => {
  const { readFileSync } = await import('node:fs');
  const app = readFileSync(new URL('../app.js', import.meta.url), 'utf8');
  const centre = app.match(/const centre = h\('main', \{ class: 'centre-wrap' \}, ([^;]+)\);/)?.[1] || '';
  const parts = centre.split(',').map((part) => part.trim());
  // First in the centre, above the header of whatever it shows.
  assert.deepEqual(parts.slice(0, 3), ['offline', 'unpaired', 'app.notifications.offer']);
  const floating = app.match(/root\.replaceChildren\(([^;]+)\);/)?.[1] || '';
  for (const banner of ['offline', 'unpaired', 'notifications.offer']) assert.ok(!floating.includes(banner), `${banner} isn't laid over the page`);
  const row = rules().find((rule) => rule.media === '' && rule.selector.split(',').map((one) => one.trim()).includes('.centre-wrap > .offline.offer'));
  assert.ok(row, 'a rule for the banners in the centre');
  const d = declarations(row.body);
  assert.ok(['relative', 'static'].includes(d.position), `in the flow: ${d.position}`);
  assert.equal(d.top, 'auto');
  assert.equal(d.left, 'auto');
  assert.equal(d.transform, 'none');
});

// A page in miniature for the focus keeper: elements that take the focus, links found by href, a hashchange to fire.
function focusPage() {
  const doc = { activeElement: null, links: [], main: null };
  const element = (tag, href = null) => {
    const el = {
      tag, connected: true, shown: true, attrs: href ? { href } : {},
      get isConnected() { return this.connected; },
      getAttribute(name) { return this.attrs[name] ?? null; },
      hasAttribute(name) { return name in this.attrs; },
      setAttribute(name, value) { this.attrs[name] = value; },
      getClientRects() { return this.shown ? [{}] : []; },
      focus() { if (this.connected && this.shown) doc.activeElement = this; },
    };
    if (href) doc.links.push(el);
    return el;
  };
  doc.body = element('body');
  doc.main = element('main');
  doc.activeElement = doc.body;
  doc.querySelectorAll = (selector) => (selector === 'a[href]' ? doc.links.filter((one) => one.connected) : []);
  doc.querySelector = (selector) => (selector === 'main' ? doc.main : null);
  const listeners = {};
  const timers = [];
  const win = {
    addEventListener(name, fn) { (listeners[name] ||= []).push(fn); },
    removeEventListener(name, fn) { listeners[name] = (listeners[name] || []).filter((one) => one !== fn); },
    setTimeout(fn) { timers.push(fn); },
    fire(name) { const now = listeners[name] || []; listeners[name] = []; now.forEach((fn) => fn()); },
    runTimers() { timers.splice(0).forEach((fn) => fn()); },
  };
  return { doc, win, element };
}

test('U20: Esc on the side sheet or the palette puts the keyboard back on what opened it, or the link drawn in its place, else the centre', async () => {
  const { focusKeeper } = await import('../js/views/sheet.js');
  // The line stays: back on it.
  {
    const { doc, win, element } = focusPage();
    const line = element('a', '#/p/x/lead?sheet=a');
    line.focus();
    const keeper = focusKeeper({ doc, win });
    keeper.remember();
    doc.activeElement = doc.body;
    keeper.restore();
    assert.equal(doc.activeElement, line);
  }
  // Closing the sheet changes the address and the lines are drawn again: back on the new one with the same address.
  {
    const { doc, win, element } = focusPage();
    const line = element('a', '#/p/x/lead?sheet=a');
    line.focus();
    const keeper = focusKeeper({ doc, win });
    keeper.remember();
    doc.activeElement = doc.body;
    keeper.restore();
    line.connected = false;
    doc.activeElement = doc.body;
    const drawnAgain = element('a', '#/p/x/lead?sheet=a');
    win.fire('hashchange');
    assert.equal(doc.activeElement, drawnAgain);
    // Later addresses are someone else's: nothing moves the keyboard then.
    win.runTimers();
    const other = element('a', '#/node');
    other.focus();
    win.fire('hashchange');
    assert.equal(doc.activeElement, other);
  }
  // Closed with no change of address (the palette): a later address change, someone else's, doesn't move the keyboard.
  {
    const { doc, win, element } = focusPage();
    const line = element('a', '#/p/x/lead');
    line.focus();
    const keeper = focusKeeper({ doc, win });
    keeper.remember();
    keeper.restore();
    win.runTimers();
    const other = element('a', '#/node');
    other.focus();
    win.fire('hashchange');
    assert.equal(doc.activeElement, other);
  }
  // A command from the palette opens a session whose terminal takes the keyboard: the address's change leaves it there.
  {
    const { doc, win, element } = focusPage();
    const line = element('a', '#/p/x/lead');
    line.focus();
    const keeper = focusKeeper({ doc, win });
    keeper.remember();
    keeper.restore();
    line.shown = false;
    const terminal = element('div');
    terminal.focus();
    win.fire('hashchange');
    assert.equal(doc.activeElement, terminal);
  }
  // Opened from nowhere (the page's body), or what opened it is gone: the centre, focusable for it.
  {
    const { doc, win } = focusPage();
    const keeper = focusKeeper({ doc, win });
    keeper.remember();
    keeper.restore();
    assert.equal(doc.activeElement, doc.main);
    assert.equal(doc.main.getAttribute('tabindex'), '-1');
  }
});

// The cascade's result for `selector` among the rules outside any @media: the last declaration wins.
const computed = (selector) => Object.assign({}, ...rules().filter((rule) => rule.media === '' && rule.selector === selector).map((rule) => declarations(rule.body)));

test('U21: the team strip wraps to a second line where it doesn’t fit, each count whole; never scrolled out of sight', () => {
  const strip = computed('.team-strip');
  assert.equal(strip['flex-wrap'], 'wrap');
  assert.notEqual(strip['overflow-x'], 'auto');
  assert.equal(computed('.team-strip > *')['white-space'], 'nowrap');
});

test('U18: “Now” sits on a line of its own above the hours, the axis tall enough for both', () => {
  const now = parseFloat(computed('.axis-tick.now').top);
  const hour = parseFloat(computed('.axis-tick').top);
  // A line of the small size on a phone (12.5 px at 1.4): the hours start under it.
  assert.ok(hour - now >= 12.5 * 1.4, `now at ${now}px, the hours at ${hour}px`);
  assert.ok(parseFloat(computed('.axis').height) >= hour + 12.5 * 1.4, 'the axis holds both lines');
});

test('U23: Brief me looks like a button: a surface and an edge, not a grey caption', () => {
  const looks = Object.assign({}, ...rules().filter((rule) => rule.media === '' && rule.selector === '.summary-brief').map((rule) => declarations(rule.body)));
  assert.equal(looks.background, 'var(--raised)');
  // An edge: the hairline itself, or the elevation token that is the hairline (--e-1).
  const edge = looks['box-shadow'] === 'var(--e-1)' ? tokens()['--e-1'].light : looks['box-shadow'] || '';
  assert.match(edge, /var\(--line\)/);
  assert.equal(looks.color, 'var(--ink)');
});

test('U7: asking the system for more contrast never gives an ink less contrast than the default', () => {
  const base = tokens();
  const more = { ...base, ...tokens('(prefers-contrast: more)') };
  const less = [];
  for (const theme of ['light', 'dark']) {
    for (const ink of INKS) {
      for (const surface of BASES) {
        const was = contrast(parseColour(base[ink][theme]), parseColour(base[surface][theme]));
        const now = contrast(parseColour(more[ink][theme]), parseColour(more[surface][theme]));
        if (now < was) less.push(`${theme} ${ink} on ${surface}: ${was.toFixed(2)} → ${now.toFixed(2)}`);
      }
    }
  }
  assert.deepEqual(less, []);
});
