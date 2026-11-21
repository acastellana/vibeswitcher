// The terminal's look, this browser's (js/termlook.js): the Mac's defaults and palettes, everything read back checked
// before it reaches xterm.js (whose stylesheet is made from its options), and kept in localStorage. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';

// A localStorage of the test's own, before the module reads it.
const kept = new Map();
globalThis.localStorage = { getItem: (key) => kept.get(key) ?? null, setItem: (key, value) => kept.set(key, String(value)), removeItem: (key) => kept.delete(key) };
const { DEFAULTS, PALETTES, cleanLook, cleanPalette, paletteOf, xtermOptions, xtermTheme, loadLook, saveLook, resetLook, look, onLook, FALLBACK_FONTS } = await import('../js/termlook.js');

test('the defaults are the Mac’s TerminalAppearance()', () => {
  assert.deepEqual(cleanLook(null), { fontName: '', fontSize: 13, theme: 'system', custom: PALETTES.dark, cursorShape: 'block', cursorBlink: true,
    scrollbackLines: 10000, optionAsMeta: true, bell: 'visual' });
  assert.equal(DEFAULTS.fontSize, 13);
  assert.equal(PALETTES.dark.background, '#1E1E1E');
  assert.equal(PALETTES.solarizedLight.background, '#FDF6E3');
  assert.equal(PALETTES.light.ansi.length, 16);
});

test('what is read back is checked: a font name can’t carry CSS, a colour is #rrggbb, numbers stay in range', () => {
  const bad = cleanLook({ fontName: 'x"; } body { display: none } /*', fontSize: 400, theme: 'neon', cursorShape: 'smiley', cursorBlink: 'yes',
    scrollbackLines: -5, optionAsMeta: 1, bell: 'siren', custom: { foreground: 'red', background: '#123', cursor: 'url(x)', selection: '#ABCDEF', ansi: ['#010203', 'javascript:'] } });
  assert.equal(bad.fontName, '');
  assert.equal(bad.fontSize, 36);
  assert.equal(bad.theme, 'system');
  assert.equal(bad.cursorShape, 'block');
  assert.equal(bad.cursorBlink, true);
  assert.equal(bad.scrollbackLines, 0);
  assert.equal(bad.optionAsMeta, true);
  assert.equal(bad.bell, 'visual');
  assert.deepEqual([bad.custom.foreground, bad.custom.background, bad.custom.cursor, bad.custom.selection], ['#E5E5E5', '#1E1E1E', '#E5E5E5', '#ABCDEF']);
  assert.equal(bad.custom.ansi[0], '#010203');
  assert.equal(bad.custom.ansi[1], PALETTES.dark.ansi[1]);
  assert.equal(cleanLook({ fontName: ' JetBrains Mono ' }).fontName, 'JetBrains Mono');
  assert.equal(cleanLook({ fontSize: 12.3 }).fontSize, 12.5);
  assert.deepEqual(cleanPalette({ ansi: 'nope' }).ansi, PALETTES.dark.ansi);
});

test('xterm.js gets the palette the theme names, and the font named first before the page’s stack', () => {
  const system = cleanLook({});
  assert.equal(paletteOf(system, true), PALETTES.dark);
  assert.equal(paletteOf(system, false), PALETTES.light);
  assert.equal(paletteOf(cleanLook({ theme: 'solarizedDark' }), false), PALETTES.solarizedDark);
  const options = xtermOptions(cleanLook({ fontName: 'Iosevka', fontSize: 15, cursorShape: 'bar', cursorBlink: false, scrollbackLines: 2000, optionAsMeta: false }), true);
  assert.equal(options.fontFamily, `"Iosevka", ${FALLBACK_FONTS}`);
  assert.deepEqual([options.fontSize, options.cursorStyle, options.cursorBlink, options.scrollback, options.macOptionIsMeta], [15, 'bar', false, 2000, false]);
  assert.equal(xtermOptions(cleanLook({}), true).fontFamily, FALLBACK_FONTS);
  const theme = xtermTheme(PALETTES.solarizedDark);
  assert.equal(theme.background, '#002B36');
  assert.equal(theme.brightWhite, '#FDF6E3');
  assert.equal(theme.cursorAccent, '#002B36');
  assert.match(theme.selectionInactiveBackground, /^rgba\(7, 54, 66, 0.6\)$/);
});

test('a look is kept in this browser, followed, and reset to the defaults', () => {
  const heard = [];
  const stop = onLook((next) => heard.push(next.theme));
  saveLook({ theme: 'solarizedLight', fontSize: 16 });
  assert.equal(JSON.parse(kept.get('vs.terminal')).theme, 'solarizedLight');
  assert.equal(loadLook().fontSize, 16);
  assert.equal(look().theme, 'solarizedLight');
  // A field left out keeps its value.
  saveLook({ bell: 'none' });
  assert.equal(look().fontSize, 16);
  resetLook();
  assert.equal(kept.has('vs.terminal'), false);
  assert.deepEqual(look(), cleanLook(null));
  assert.deepEqual(heard, ['solarizedLight', 'solarizedLight', 'system']);
  stop();
  // Something not JSON is the defaults.
  kept.set('vs.terminal', '{oops');
  assert.deepEqual(loadLook(), cleanLook(null));
});
