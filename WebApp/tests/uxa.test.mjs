// The UX review's findings U6, U7, U8, U18's "Ahora" and U20–U23 (2026-11-25), each held here: the stylesheet's inks
// against its surfaces in both themes, its sizes, its touch block, the banners' place, and the small states.
// Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { rules, declarations, tokens, parseColour, over, contrast, px } from './cssread.mjs';

const INKS = ['--ink', '--ink-2', '--ink-3', '--accent', '--needs-you', '--working', '--background', '--done', '--idle', '--blocked', '--kept'];
const BASES = ['--bg', '--side', '--side-hover', '--side-selected', '--raised'];
const FILLS = ['--fill', '--fill-2', '--accent-fill'];
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
  assert.ok(sizes['--small'] >= 11.5, `--small is ${sizes['--small']}px`);
  const small = [];
  for (const rule of rules()) {
    const d = declarations(rule.body);
    let value = d['font-size'];
    if (!value && d.font && d.font !== 'inherit') value = d.font.match(/^(?:[a-z0-9-]+\s+)*?(var\(--[a-z]+\)|[\d.]+px)/)?.[1];
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
      if (value) found = parseFloat(value);
    }
    return found;
  };
  const tall = (selector) => Math.max(size(selector, 'min-height') ?? 0, size(selector, 'height') ?? 0);
  const wide = (selector) => Math.max(size(selector, 'min-width') ?? 0, size(selector, 'width') ?? 0);
  const short = [];
  // Icon buttons, a message's actions, Send: square.
  for (const selector of ['.icon-button', '.row-action', '.send', '.composer-attach']) if (tall(selector) < 44 || wide(selector) < 44) short.push(selector);
  // Switches, small and text buttons.
  for (const selector of ['.switch-link', '.segmented button', '.button', '.button.small', '.copy-button', '.confirm-clear', '.link', '.summary-brief', '.take-back', '.fold', '.offer button']) {
    if (tall(selector) < 44 || wide(selector) < 44) short.push(selector);
  }
  // The drawers' rows and the two-column list's rows: the whole width already, 44 tall.
  for (const selector of ['.place', '.project', '.tc-row', '.palette-row', '.option', '.task-link']) if (tall(selector) < 44) short.push(selector);
  assert.deepEqual(short, []);
  assert.equal(size('input[type="checkbox"]', 'width'), 24);
  assert.equal(size('input[type="checkbox"]', 'height'), 24);
  assert.equal(size('label:has(> input[type="checkbox"])', 'min-height'), 44);
  const inputs = touch.find((rule) => rule.selector.startsWith(':is(textarea, select, input'));
  assert.ok(inputs && parseFloat(declarations(inputs.body)['font-size']) >= 16, 'text boxes at 16 px');
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
