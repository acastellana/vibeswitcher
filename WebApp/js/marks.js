// The marks: a status's shape, the agent's badge, and the few line icons the page uses. All drawn here as SVG, so
// the page loads no image and no icon font.

import { s, h } from './dom.js';
import { STATES, AGENTS } from './words.js';

// A status's shape, so it reads without colour: "!" needs you, an open arc working, a half-filled ring background, a
// check done, a small dot idle, a ring unknown, two bars paused. The Mac's StatusMark, same geometry
// (Sources/VibeCore/MacOnly/StatusMark+Paths.swift), on a 100-unit square. Its colour is the class `tone-<state>`.
const SHAPES = {
  alert: () => [
    s('circle', { cx: 50, cy: 50, r: 50 }),
    s('rect', { class: 'on', x: 41, y: 18, width: 18, height: 42, rx: 9 }),
    s('circle', { class: 'on', cx: 50, cy: 77, r: 9.5 }),
  ],
  spinner: () => [s('path', { class: 'stroke', d: 'M50 14A36 36 0 1 0 86 50', 'stroke-width': 28, 'stroke-linecap': 'round' })],
  half: () => [
    s('circle', { class: 'stroke', cx: 50, cy: 50, r: 43, 'stroke-width': 14 }),
    s('path', { d: 'M50 0A50 50 0 0 0 50 100Z' }),
  ],
  check: () => [
    s('circle', { cx: 50, cy: 50, r: 50 }),
    s('path', { class: 'on-stroke', d: 'M27 52L44 69L74 35', 'stroke-width': 17, 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }),
  ],
  dot: () => [s('circle', { cx: 50, cy: 50, r: 30 })],
  outline: () => [s('circle', { class: 'stroke', cx: 50, cy: 50, r: 43, 'stroke-width': 14 })],
  paused: () => [
    s('circle', { cx: 50, cy: 50, r: 50 }),
    s('rect', { class: 'on', x: 32, y: 28, width: 12, height: 44 }),
    s('rect', { class: 'on', x: 56, y: 28, width: 12, height: 44 }),
  ],
};

// The mark for `state` (a key of STATES). Hidden from a screen reader: the row it sits in says the status in words.
export function statusMark(state, size = 10) {
  const svg = s('svg', { class: 'mark', viewBox: '0 0 100 100', width: size, height: size, 'aria-hidden': 'true' });
  setMark(svg, state);
  return svg;
}

// Redraws a mark for another state, only when it changed.
export function setMark(svg, state) {
  if (svg.dataset.state === state) return;
  svg.dataset.state = state;
  svg.setAttribute('class', `mark tone-${state}`);
  svg.replaceChildren(...SHAPES[(STATES[state] || STATES.unknown).mark]());
}

// The agent's glyph, white on its badge, in a 16-unit square.
const GLYPHS = {
  // A four-point sparkle.
  claude: 'M8 2.2C8.5 5.6 10.4 7.5 13.8 8C10.4 8.5 8.5 10.4 8 13.8C7.5 10.4 5.6 8.5 2.2 8C5.6 7.5 7.5 5.6 8 2.2Z',
  codex: null,
  shell: null,
};

// The rounded square that says which agent runs in a row (the Mac's AgentMark): terracotta with a sparkle for
// Claude, indigo with </> for Codex, grey with a prompt for a shell.
export function agentMark(agent, size = 20) {
  const kind = AGENTS[agent] ? agent : 'shell';
  const svg = s('svg', { class: `agent agent-${kind}`, viewBox: '0 0 16 16', width: size, height: size, role: 'img', 'aria-label': AGENTS[kind] });
  svg.append(s('rect', { class: 'badge', width: 16, height: 16, rx: 4.5 }));
  if (kind === 'claude') svg.append(s('path', { class: 'glyph-fill', d: GLYPHS.claude }));
  else if (kind === 'codex') svg.append(s('path', { class: 'glyph', d: 'M5.6 5.2L3 8L5.6 10.8M10.4 5.2L13 8L10.4 10.8M9 4.4L7 11.6' }));
  else svg.append(s('path', { class: 'glyph', d: 'M4 5.5L6.6 8L4 10.5M8.4 10.8H12' }));
  return svg;
}

// Line icons on a 16-unit square, drawn in the text's colour.
const ICONS = {
  chevron: 'M6 3.5L10.5 8L6 12.5',
  back: 'M10 3L5 8L10 13',
  terminal: 'M2.5 3.5H13.5V12.5H2.5ZM5 6.5L7 8.2L5 9.9M8.5 10H11',
  chat: 'M2.5 3.5H13.5V10.5H7.5L4.5 13V10.5H2.5Z',
  team: 'M5.5 7A2 2 0 1 0 5.5 3A2 2 0 0 0 5.5 7ZM10.8 7.2A1.7 1.7 0 1 0 10.8 3.8M1.8 12.5C2 10.4 3.5 9.2 5.5 9.2S9 10.4 9.2 12.5M11 9.4C12.7 9.5 14 10.6 14.2 12.5',
  filter: 'M2.5 4.5H13.5M4.5 8H11.5M6.5 11.5H9.5',
  close: 'M4 4L12 12M12 4L4 12',
  search: 'M7 11.5A4.5 4.5 0 1 0 7 2.5A4.5 4.5 0 0 0 7 11.5ZM10.4 10.4L13.5 13.5',
  node: 'M2.5 3H13.5V7H2.5ZM2.5 9H13.5V13H2.5ZM4.7 5H4.8M4.7 11H4.8',
  home: 'M2.5 7.5L8 2.8L13.5 7.5M4 6.5V13H12V6.5',
  send: 'M8 13V3.5M4 7.2L8 3.2L12 7.2',
  down: 'M8 3V12.5M4 8.8L8 12.8L12 8.8',
  pause: 'M5.5 3.5V12.5M10.5 3.5V12.5',
  worker: 'M9.6 2.6L13.4 6.4L11.6 8.2L10.6 7.2L5 12.8L3.2 11L8.8 5.4L7.8 4.4Z',
  verifier: 'M8 1.8L9.7 3.1L11.9 3.1L12.5 5.2L14.2 6.5L13.5 8.5L14.2 10.5L12.5 11.8L11.9 13.9L9.7 13.9L8 15.2L6.3 13.9L4.1 13.9L3.5 11.8L1.8 10.5L2.5 8.5L1.8 6.5L3.5 5.2L4.1 3.1L6.3 3.1ZM5.6 8.6L7.3 10.3L10.5 6.6',
  question: 'M2.5 3.5H13.5V10.5H7.5L4.5 13V10.5H2.5ZM6.6 6.1C6.7 5.3 7.3 4.9 8 4.9C8.8 4.9 9.4 5.4 9.4 6.1C9.4 7 8 7 8 8M8 9.3V9.4',
  file: 'M4 2.5H9.5L12 5V13.5H4ZM9.5 2.5V5H12',
  pencil: 'M3 13L3.5 10.5L10.5 3.5L12.5 5.5L5.5 12.5ZM9.3 4.7L11.3 6.7',
  tool: 'M9.5 2.8A3 3 0 0 0 6.4 6.7L2.8 10.3L5.7 13.2L9.3 9.6A3 3 0 0 0 13.2 6.5L11.4 8.3L9.3 7.9L8.9 5.8Z',
  note: 'M4 2.5H12V13.5H4ZM6 5.5H10M6 8H10M6 10.5H8.5',
  warning: 'M8 2.5L14 13H2ZM8 6.5V9.5M8 11.3V11.4',
  plus: 'M8 3V13M3 8H13',
  check: 'M3.5 8.5L6.5 11.5L12.5 4.5',
  // A window with its right column: the inspector's toggle (the Mac's sidebar.right).
  inspector: 'M2.5 3.5H13.5V12.5H2.5ZM10 3.5V12.5',
};

export function icon(name, size = 16) {
  return s('svg', { class: 'icon', viewBox: '0 0 16 16', width: size, height: size, 'aria-hidden': 'true' }, s('path', { d: ICONS[name] }));
}

// The mark a session's row leads with: its status's shape, with the agent's badge small on its corner (the Mac's
// AgentMark with `statusFirst`). Returns { el, update(state, agent) }.
export function sessionMark(size = 20) {
  const status = statusMark('unknown', Math.round(size * 0.8));
  const slot = h('span', { class: 'session-mark-agent' });
  const el = h('span', { class: 'session-mark', 'aria-hidden': 'true' }, status, slot);
  let shown = null;
  return {
    el,
    update(state, agent) {
      setMark(status, state);
      if (shown !== agent) {
        shown = agent;
        slot.replaceChildren(agentMark(agent, Math.round(size * 0.5)));
      }
    },
  };
}
