// Settings › Terminal, this browser's (the Mac's Settings › Appearance): the terminal's theme, font, size, cursor,
// colours, scrollback, Option as Meta and the bell (js/termlook.js). A change is kept in this browser and shows at once
// in an open terminal; Reset puts the Mac's defaults back. Nothing here reaches the node.

import * as kit from '../kit.js';
import { h } from '../dom.js';
import { THEMES, CURSORS, BELLS, ANSI_NAMES, FONT_SIZES, SCROLLBACK, look, saveLook, resetLook, onLook, paletteOf } from '../termlook.js';
import { KEY } from '../words.js';
import { t } from '../i18n.js';

const COLOUR_NAMES = { foreground: t('tlText'), background: t('tlBackground'), cursor: t('tlCursor'), selection: t('tlSelection') };

function row(label, control, note = null) {
  const field = control.control || control;
  if (field.matches?.('input, select')) field.setAttribute('aria-label', label);
  return h('div', { class: 'look-row' }, h('span', { class: 'look-label' }, label), control, note ? h('span', { class: 'look-note' }, note) : null);
}

function select(options, value, onchange) {
  return kit.select({ onchange: (event) => onchange(event.target.value) },
    options.map((option) => h('option', { value: option.id, selected: option.id === value }, option.label)));
}

export function terminalLookSection() {
  const body = h('div', { class: 'look-body' });
  const el = h('section', { class: 'node-group look' },
    kit.sectionTitle('h2', {}, t('tlTerminalThisBrowser')),
    h('p', { class: 'settings-intro' }, t('tlHowASessionSTerminal')),
    body);

  function draw(current) {
    // Someone typing in a field keeps it.
    if (body.contains(document.activeElement) && document.activeElement.matches('input[type="text"], input[type="number"]')) return;
    const dark = globalThis.matchMedia?.('(prefers-color-scheme: dark)')?.matches;
    const palette = paletteOf(current, document.documentElement.dataset.theme === 'dark' || (document.documentElement.dataset.theme !== 'light' && dark));
    const fontInput = kit.field({ class: 'look-input', type: 'text', value: current.fontName, placeholder: t('tlThePageSMonospace'), maxlength: 64, spellcheck: 'false',
      onchange: (event) => saveLook({ fontName: event.target.value }) });
    const sizeInput = kit.field({ class: 'look-input narrow', type: 'number', min: FONT_SIZES.min, max: FONT_SIZES.max, step: 0.5, value: current.fontSize,
      onchange: (event) => saveLook({ fontSize: Number(event.target.value) }) });
    const scrollInput = kit.field({ class: 'look-input narrow', type: 'number', min: SCROLLBACK.min, max: SCROLLBACK.max, step: 1000, value: current.scrollbackLines,
      onchange: (event) => saveLook({ scrollbackLines: Number(event.target.value) }) });
    const check = (value, key) => kit.checkbox({ checked: value, onchange: (event) => saveLook({ [key]: event.target.checked }) });
    const custom = current.theme === 'custom';
    const colour = (value, set) => h('input', { class: 'look-colour', type: 'color', value: value.toLowerCase(), disabled: !custom, onchange: (event) => set(event.target.value) });
    const named = Object.entries(COLOUR_NAMES).map(([key, name]) => h('span', { class: 'look-swatch' },
      colour(palette[key], (value) => saveLook({ custom: { ...current.custom, [key]: value } })), name));
    const ansi = palette.ansi.map((value, index) => colour(value, (next) => {
      const list = [...current.custom.ansi];
      list[index] = next;
      saveLook({ custom: { ...current.custom, ansi: list } });
    }));
    ansi.forEach((input, index) => { input.title = ANSI_NAMES[index]; input.setAttribute('aria-label', `ANSI ${ANSI_NAMES[index]}`); });
    body.replaceChildren(
      row(t('tlTheme'), select(THEMES, current.theme, (theme) => saveLook(theme === 'custom' && current.theme !== 'custom'
        ? { theme, custom: { ...palette, ansi: [...palette.ansi] } } : { theme }))),
      row(t('tlFont'), fontInput, t('tlAFontInstalledOnThis')),
      row(t('tlSize'), sizeInput, t('tlRange', { min: FONT_SIZES.min, max: FONT_SIZES.max })),
      row(t('tlCursor'), h('span', { class: 'look-pair' }, select(CURSORS, current.cursorShape, (cursorShape) => saveLook({ cursorShape })),
        h('label', { class: 'look-check' }, check(current.cursorBlink, 'cursorBlink'), t('tlBlink')))),
      row(t('tlScrollback'), scrollInput, 'lines'),
      row(KEY.mod === '⌘' ? t('tlOptionAsMeta') : t('tlAltAsMeta'), check(current.optionAsMeta, 'optionAsMeta'), t('tlOnAMacSendsMeta')),
      row(t('tlBell'), select(BELLS, current.bell, (bell) => saveLook({ bell }))),
      h('div', { class: 'look-row' }, h('span', { class: 'look-label' }, t('tlColours')),
        h('div', { class: 'look-colours' }, h('div', { class: 'look-named' }, named), h('div', { class: 'look-ansi' }, ansi),
          custom ? null : h('span', { class: 'look-note' }, t('tlPickCustomToChangeThem')))),
      h('div', { class: 'look-row' }, h('span', { class: 'look-label' }), kit.button('plain', { onclick: () => resetLook() }, t('tlResetToDefaults'))),
    );
  }

  onLook(draw);
  return { el, update() { draw(look()); } };
}
