// Settings › Terminal, this browser's (the Mac's Settings › Appearance): the terminal's theme, font, size, cursor,
// colours, scrollback, Option as Meta and the bell (js/termlook.js). A change is kept in this browser and shows at once
// in an open terminal; Reset puts the Mac's defaults back. Nothing here reaches the node.

import { h } from '../dom.js';
import { THEMES, CURSORS, BELLS, ANSI_NAMES, FONT_SIZES, SCROLLBACK, look, saveLook, resetLook, onLook, paletteOf } from '../termlook.js';
import { KEY } from '../words.js';

const COLOUR_NAMES = { foreground: 'Text', background: 'Background', cursor: 'Cursor', selection: 'Selection' };

function row(label, control, note = null) {
  if (control.matches?.('input, select')) control.setAttribute('aria-label', label);
  return h('div', { class: 'look-row' }, h('span', { class: 'look-label' }, label), control, note ? h('span', { class: 'look-note' }, note) : null);
}

function select(options, value, onchange) {
  return h('select', { class: 'setting-picker', onchange: (event) => onchange(event.target.value) },
    options.map((option) => h('option', { value: option.id, selected: option.id === value }, option.label)));
}

export function terminalLookSection() {
  const body = h('div', { class: 'look-body' });
  const el = h('section', { class: 'node-group look' },
    h('h2', { class: 'section-title' }, 'Terminal · this browser'),
    h('p', { class: 'settings-intro' }, 'How a session’s terminal looks on this page. Kept in this browser only: each person viewing the node picks their own.'),
    body);

  function draw(current) {
    // Someone typing in a field keeps it.
    if (body.contains(document.activeElement) && document.activeElement.matches('input[type="text"], input[type="number"]')) return;
    const dark = globalThis.matchMedia?.('(prefers-color-scheme: dark)')?.matches;
    const palette = paletteOf(current, document.documentElement.dataset.theme === 'dark' || (document.documentElement.dataset.theme !== 'light' && dark));
    const fontInput = h('input', { class: 'look-input', type: 'text', value: current.fontName, placeholder: 'The page’s monospace', maxlength: 64, spellcheck: 'false',
      onchange: (event) => saveLook({ fontName: event.target.value }) });
    const sizeInput = h('input', { class: 'look-input narrow', type: 'number', min: FONT_SIZES.min, max: FONT_SIZES.max, step: 0.5, value: current.fontSize,
      onchange: (event) => saveLook({ fontSize: Number(event.target.value) }) });
    const scrollInput = h('input', { class: 'look-input narrow', type: 'number', min: SCROLLBACK.min, max: SCROLLBACK.max, step: 1000, value: current.scrollbackLines,
      onchange: (event) => saveLook({ scrollbackLines: Number(event.target.value) }) });
    const check = (value, key) => h('input', { type: 'checkbox', checked: value, onchange: (event) => saveLook({ [key]: event.target.checked }) });
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
      row('Theme', select(THEMES, current.theme, (theme) => saveLook(theme === 'custom' && current.theme !== 'custom'
        ? { theme, custom: { ...palette, ansi: [...palette.ansi] } } : { theme }))),
      row('Font', fontInput, 'A font installed on this computer; the page’s monospace when it has none.'),
      row('Size', sizeInput, `${FONT_SIZES.min} to ${FONT_SIZES.max}`),
      row('Cursor', h('span', { class: 'look-pair' }, select(CURSORS, current.cursorShape, (cursorShape) => saveLook({ cursorShape })),
        h('label', { class: 'look-check' }, check(current.cursorBlink, 'cursorBlink'), 'Blink'))),
      row('Scrollback', scrollInput, 'lines'),
      row(KEY.mod === '⌘' ? 'Option as Meta' : 'Alt as Meta', check(current.optionAsMeta, 'optionAsMeta'), 'On a Mac: ⌥ sends Meta, as the Mac’s terminal'),
      row('Bell', select(BELLS, current.bell, (bell) => saveLook({ bell }))),
      h('div', { class: 'look-row' }, h('span', { class: 'look-label' }, 'Colours'),
        h('div', { class: 'look-colours' }, h('div', { class: 'look-named' }, named), h('div', { class: 'look-ansi' }, ansi),
          custom ? null : h('span', { class: 'look-note' }, 'Pick Custom to change them.'))),
      h('div', { class: 'look-row' }, h('span', { class: 'look-label' }), h('button', { class: 'button quiet', type: 'button', onclick: () => resetLook() }, 'Reset to Defaults')),
    );
  }

  onLook(draw);
  return { el, update() { draw(look()); } };
}
