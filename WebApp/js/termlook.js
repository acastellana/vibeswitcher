// The terminal's look (the Mac's Settings › Appearance, `TerminalAppearance`): theme, font, size, cursor, ANSI colours,
// scrollback, Option as Meta and the bell, as this browser's own preferences. They live in this browser only
// (`localStorage`, which may refuse: then for this page only), never on the node: each person viewing a node's page
// picks their own. The defaults are the Mac's.
//
// Everything read back is checked before it reaches xterm.js, whose stylesheet is made from its options: a font's name
// is letters, digits, spaces, dots, dashes and underscores only, a colour is #rrggbb, a number is kept in its range,
// and anything else is the default. Nothing the program in the session prints changes any of it.

const KEY = 'vs.terminal';
const changed = new Set();

// The Mac's palettes (TerminalAppearance.swift `Palette`): Terminal.app's basic colours under its light and dark, and
// Solarized.
const STANDARD_ANSI = ['#000000', '#C23621', '#25BC24', '#ADAD27', '#492EE1', '#D338D3', '#33BBC8', '#CBCCCD',
  '#818383', '#FC391F', '#31E722', '#EAEC23', '#5833FF', '#F935F8', '#14F0F0', '#E9EBEB'];
const SOLARIZED_ANSI = ['#073642', '#DC322F', '#859900', '#B58900', '#268BD2', '#D33682', '#2AA198', '#EEE8D5',
  '#002B36', '#CB4B16', '#586E75', '#657B83', '#839496', '#6C71C4', '#93A1A1', '#FDF6E3'];
export const PALETTES = {
  dark: { foreground: '#E5E5E5', background: '#1E1E1E', cursor: '#E5E5E5', selection: '#3A4A6B', ansi: STANDARD_ANSI },
  light: { foreground: '#1F1F1F', background: '#FFFFFF', cursor: '#1F1F1F', selection: '#B4D5FE', ansi: STANDARD_ANSI },
  solarizedDark: { foreground: '#839496', background: '#002B36', cursor: '#93A1A1', selection: '#073642', ansi: SOLARIZED_ANSI },
  solarizedLight: { foreground: '#657B83', background: '#FDF6E3', cursor: '#586E75', selection: '#EEE8D5', ansi: SOLARIZED_ANSI },
};

export const THEMES = [
  { id: 'system', label: 'Match System' }, { id: 'light', label: 'Light' }, { id: 'dark', label: 'Dark' },
  { id: 'solarizedLight', label: 'Solarized Light' }, { id: 'solarizedDark', label: 'Solarized Dark' }, { id: 'custom', label: 'Custom' },
];
export const CURSORS = [{ id: 'block', label: 'Block' }, { id: 'underline', label: 'Underline' }, { id: 'bar', label: 'Bar' }];
export const BELLS = [{ id: 'none', label: 'None' }, { id: 'visual', label: 'Flash' }, { id: 'sound', label: 'Sound' }];
export const ANSI_NAMES = ['black', 'red', 'green', 'yellow', 'blue', 'magenta', 'cyan', 'white',
  'brightBlack', 'brightRed', 'brightGreen', 'brightYellow', 'brightBlue', 'brightMagenta', 'brightCyan', 'brightWhite'];
export const FONT_SIZES = { min: 8, max: 36 };
export const SCROLLBACK = { min: 0, max: 100_000 };

// The Mac's defaults (`TerminalAppearance()`).
export const DEFAULTS = Object.freeze({
  fontName: '', fontSize: 13, theme: 'system', custom: PALETTES.dark, cursorShape: 'block', cursorBlink: true,
  scrollbackLines: 10_000, optionAsMeta: true, bell: 'visual',
});

// The fonts tried after the one named (or alone, when none is): the page's own monospace stack.
export const FALLBACK_FONTS = 'ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace';

const HEX = /^#[0-9a-f]{6}$/i;
const FONT_NAME = /^[A-Za-z0-9 ._-]{1,64}$/;

const colour = (value, fallback) => (typeof value === 'string' && HEX.test(value) ? value.toUpperCase() : fallback);
const within = (value, { min, max }, fallback) => (typeof value === 'number' && Number.isFinite(value) ? Math.min(max, Math.max(min, value)) : fallback);
const oneOf = (value, list, fallback) => (list.some((item) => item.id === value) ? value : fallback);

// A palette read back: each colour #RRGGBB, else the default's; 16 ANSI colours, the default's past those given.
export function cleanPalette(palette, fallback = PALETTES.dark) {
  const given = palette && typeof palette === 'object' ? palette : {};
  const ansi = Array.isArray(given.ansi) ? given.ansi : [];
  return {
    foreground: colour(given.foreground, fallback.foreground), background: colour(given.background, fallback.background),
    cursor: colour(given.cursor, fallback.cursor), selection: colour(given.selection, fallback.selection),
    ansi: fallback.ansi.map((standard, index) => colour(ansi[index], standard)),
  };
}

// Preferences read back, each field checked: what isn't right is the default.
export function cleanLook(look) {
  const given = look && typeof look === 'object' ? look : {};
  return {
    fontName: typeof given.fontName === 'string' && FONT_NAME.test(given.fontName.trim()) ? given.fontName.trim() : '',
    fontSize: Math.round(within(given.fontSize, FONT_SIZES, DEFAULTS.fontSize) * 2) / 2,
    theme: oneOf(given.theme, THEMES, DEFAULTS.theme),
    custom: cleanPalette(given.custom),
    cursorShape: oneOf(given.cursorShape, CURSORS, DEFAULTS.cursorShape),
    cursorBlink: typeof given.cursorBlink === 'boolean' ? given.cursorBlink : DEFAULTS.cursorBlink,
    scrollbackLines: Math.round(within(given.scrollbackLines, SCROLLBACK, DEFAULTS.scrollbackLines)),
    optionAsMeta: typeof given.optionAsMeta === 'boolean' ? given.optionAsMeta : DEFAULTS.optionAsMeta,
    bell: oneOf(given.bell, BELLS, DEFAULTS.bell),
  };
}

// The palette a look draws with, the page light or dark (`TerminalAppearance.palette(darkMode:)`).
export function paletteOf(look, dark) {
  switch (look.theme) {
    case 'light': return PALETTES.light;
    case 'dark': return PALETTES.dark;
    case 'solarizedLight': return PALETTES.solarizedLight;
    case 'solarizedDark': return PALETTES.solarizedDark;
    case 'custom': return look.custom;
    default: return dark ? PALETTES.dark : PALETTES.light;
  }
}

// `#RRGGBB` and an alpha as `rgba(…)`.
function rgba(hex, alpha) {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${alpha})`;
}

// xterm.js's theme for a palette: its colours, the cursor's text in the background's colour, the scrollbar in the
// foreground's at a low alpha.
export function xtermTheme(palette) {
  const theme = {
    background: palette.background, foreground: palette.foreground, cursor: palette.cursor, cursorAccent: palette.background,
    selectionBackground: palette.selection, selectionInactiveBackground: rgba(palette.selection, 0.6),
    scrollbarSliderBackground: rgba(palette.foreground, 0.16), scrollbarSliderHoverBackground: rgba(palette.foreground, 0.26),
    scrollbarSliderActiveBackground: rgba(palette.foreground, 0.32),
  };
  ANSI_NAMES.forEach((name, index) => { theme[name] = palette.ansi[index]; });
  return theme;
}

// xterm.js's options for a look: the font named first (quoted), the page's monospace stack after it.
export function xtermOptions(look, dark) {
  return {
    fontFamily: look.fontName ? `"${look.fontName}", ${FALLBACK_FONTS}` : FALLBACK_FONTS,
    fontSize: look.fontSize, theme: xtermTheme(paletteOf(look, dark)), cursorStyle: look.cursorShape, cursorBlink: look.cursorBlink,
    scrollback: look.scrollbackLines, macOptionIsMeta: look.optionAsMeta,
  };
}

// This browser's look, checked (the defaults where it keeps none, or can't be read).
export function loadLook() {
  try { return cleanLook(JSON.parse(globalThis.localStorage?.getItem(KEY) || 'null')); } catch { return cleanLook(null); }
}

let current = null;
// The look now: this browser's, read once, then what was saved since.
export function look() {
  if (!current) current = loadLook();
  return current;
}

// Keeps `next` (checked) as this browser's look and tells whoever follows it. A field left out keeps its value.
export function saveLook(next) {
  current = cleanLook({ ...look(), ...next });
  try { globalThis.localStorage?.setItem(KEY, JSON.stringify(current)); } catch { /* a private window: for this page only */ }
  for (const fn of changed) fn(current);
  return current;
}

// Back to the Mac's defaults.
export function resetLook() {
  try { globalThis.localStorage?.removeItem(KEY); } catch { /* nothing kept */ }
  current = cleanLook(null);
  for (const fn of changed) fn(current);
  return current;
}

// `fn(look)` at each change (another tab's too): a function that stops it.
export function onLook(fn) {
  changed.add(fn);
  return () => changed.delete(fn);
}
globalThis.addEventListener?.('storage', (event) => {
  if (event.key !== KEY) return;
  current = loadLook();
  for (const fn of changed) fn(current);
});
