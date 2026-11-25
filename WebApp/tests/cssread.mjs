// Reads style.css for the tests that hold its colours, sizes and touch block (tests/uxa.test.mjs): its custom properties
// in both themes, every rule with the media query around it, and the WCAG contrast of two colours. No browser: the
// values are the stylesheet's own, so a test computes what the page draws from the text that draws it.
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
export const css = readFileSync(join(here, '..', 'style.css'), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');

// Every rule as { media, selector, body } in source order; `media` is the @media's condition ('' outside one).
export function rules(source = css) {
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
export function declarations(body) {
  const out = {};
  for (const part of body.split(';')) {
    const colon = part.indexOf(':');
    if (colon < 0) continue;
    out[part.slice(0, colon).trim()] = part.slice(colon + 1).trim();
  }
  return out;
}

// The custom properties of `:root` (outside any @media, or inside `media`), each as { light, dark }.
export function tokens(media = '') {
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
export function parseColour(text) {
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
export function over(top, under) {
  const [r, g, b, a] = top;
  return [r * a + under[0] * (1 - a), g * a + under[1] * (1 - a), b * a + under[2] * (1 - a), 1];
}

const channel = (value) => { const c = value / 255; return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4; };
const luminance = ([r, g, b]) => 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
export function contrast(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

// A font size in px, given the sizes of the tokens it may name; null when it isn't a length this can read.
export function px(value, sizes) {
  const token = value.match(/^var\((--[a-z0-9-]+)\)$/);
  if (token) return sizes[token[1]] ?? null;
  const plain = value.match(/^([\d.]+)px$/);
  if (plain) return Number(plain[1]);
  return null;
}
