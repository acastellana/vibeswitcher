// An agent's text, and yours, drawn as nodes: the markdown a chat uses, and a diff of an edit. Text reaches the page
// only as text nodes: the source is read into a plain tree (`parseMarkdown`, no page in it, what the tests check), and
// the tree is built with js/dom.js's `h`. Nothing is parsed as markup.
//
// - Blocks: paragraphs, headings (# to ######, drawn as h3 to h6 so none outranks the page's own), block quotes, lists
//   with their nesting (ordered with their first number), tables (a head row, then the `|---|` row that makes it one),
//   horizontal rules, and fenced code with its language. Inside code nothing is read: it is the text as typed.
// - Inline: `code`, **strong** and __strong__, *emphasis* and _emphasis_, ~~struck~~, and with `links` on, [words](address),
//   <address> and a bare http(s) address. Markers follow CommonMark's flanking, with one change: a marker inside a word
//   (a_b_c.txt, 2*3*4) or beside a slash (src/**/*.js) is a character, never emphasis. A marker that doesn't close is
//   shown as typed and takes nothing with it.
// - A link is an anchor only for http, https and mailto, from the address as the browser's own URL parser reads it (an
//   address with a space, a quote or an angle bracket in it isn't one): it opens in a new tab, `noopener`. Anything
//   else is shown as typed. Links are on only where a caller asks (the chat): what the node made inert (a board's, a
//   card's words) stays text.
// - `streaming`: a reply still arriving. A closing marker at the end of a paragraph closes only an opener of its own
//   length, and a code block's last line that is only part of its closing fence waits: a half-arrived `**` never shows
//   as emphasis on its way to bold, so each marker turns from typed to drawn once.

import { h } from './dom.js';
import { copyButton } from './copying.js';
import { t } from './i18n.js';

// ---- The tree ----
//
// Blocks: { t: 'p', c } · { t: 'h', level, c } · { t: 'quote', c: blocks } · { t: 'ul', items: [blocks] } ·
//   { t: 'ol', start, items } · { t: 'hr' } · { t: 'pre', lang, v } · { t: 'table', align, head: [inline], rows: [[inline]] }
// Inline: a string · { t: 'strong' | 'em' | 'del', c } · { t: 'code', v } · { t: 'a', href, c } · { t: 'br' }

const SCHEMES = new Set(['http:', 'https:', 'mailto:']);

// The address an anchor may carry, or null: http, https or mailto only, as the URL parser reads it (no base: a relative
// one isn't a link), from text with no space, quote, angle bracket, backtick, backslash or control in it.
export function safeHref(raw) {
  if (typeof raw !== 'string' || !raw || raw.length > 2048) return null;
  // The controls, and the characters an attribute or a shell would read, are refused outright.
  if (/[\s"'<>`\\\u0000-\u001f\u007f]/.test(raw)) return null;
  if (!/^(https?:\/\/|mailto:)/i.test(raw)) return null;
  let url;
  try { url = new URL(raw); } catch { return null; }
  if (!SCHEMES.has(url.protocol)) return null;
  if (url.protocol !== 'mailto:' && !url.hostname) return null;
  if (url.protocol === 'mailto:' && !/^[^@\s]+@[^@\s]+$/.test(decodeURIComponent(url.pathname || ''))) return null;
  return url.href;
}

const isSpace = (c) => c === undefined || /\s/u.test(c);
const isPunct = (c) => c !== undefined && /[\p{P}\p{S}]/u.test(c);
// The punctuation a backslash makes plain (CommonMark's ASCII punctuation).
const ESCAPABLE = /[!-/:-@[-`{-~]/;

function merge(list) {
  const out = [];
  for (const part of list) {
    if (part === '' || part == null) continue;
    if (typeof part === 'string' && typeof out[out.length - 1] === 'string') out[out.length - 1] += part;
    else out.push(part);
  }
  return out;
}

const plain = (token) => (token && token.delim ? token.ch.repeat(token.n) : token);

// A bare address's end: trailing punctuation is the sentence's, and a closing bracket without its opener too.
function trimAddress(text) {
  let end = text.length;
  for (;;) {
    const last = text[end - 1];
    if (/[.,:;!?*_~'"]/.test(last)) { end--; continue; }
    if (last === ')' || last === ']') {
      const open = last === ')' ? '(' : '[';
      const body = text.slice(0, end);
      if (body.split(open).length - 1 < body.split(last).length - 1) { end--; continue; }
    }
    break;
  }
  return text.slice(0, end);
}

// `[words](address "title")` at `at`: { end, label, href } or null (then it is shown as typed).
function readLink(src, at) {
  let depth = 0;
  let close = -1;
  for (let i = at; i < src.length; i++) {
    const c = src[i];
    if (c === '\\') { i++; continue; }
    if (c === '`') { const run = /^`+/.exec(src.slice(i))[0]; const shut = src.indexOf(run, i + run.length); if (shut < 0) break; i = shut + run.length - 1; continue; }
    if (c === '[') depth++;
    else if (c === ']' && --depth === 0) { close = i; break; }
  }
  if (close < 0 || src[close + 1] !== '(') return null;
  let i = close + 2;
  let parens = 0;
  let dest = '';
  for (; i < src.length; i++) {
    const c = src[i];
    if (c === '(') parens++;
    else if (c === ')') { if (parens === 0) break; parens--; }
    else if (/\s/.test(c)) break;
    dest += c;
  }
  // An optional title in quotes, then the closing parenthesis.
  const rest = /^(?:\s+(?:"[^"\n]*"|'[^'\n]*'))?\s*\)/.exec(src.slice(i));
  if (!rest) return null;
  const label = src.slice(at + 1, close);
  if (!label.trim()) return null;
  return { end: i + rest[0].length, label, href: safeHref(dest) };
}

// A run of text as inline nodes.
export function inline(src, opts = {}) {
  const tokens = [];
  let text = '';
  const push = () => { if (text) tokens.push(text); text = ''; };
  for (let i = 0; i < src.length;) {
    const c = src[i];
    if (c === '\\' && ESCAPABLE.test(src[i + 1] || '')) { text += src[i + 1]; i += 2; continue; }
    if (c === '\n' && opts.breaks) { push(); tokens.push({ t: 'br' }); i++; continue; }
    if (c === '`') {
      const run = /^`+/.exec(src.slice(i))[0];
      let shut = src.indexOf(run, i + run.length);
      while (shut >= 0 && src[shut + run.length] === '`') shut = src.indexOf(run, shut + run.length + 1);
      if (shut < 0) { text += run; i += run.length; continue; }
      let body = src.slice(i + run.length, shut).replace(/\n/g, ' ');
      if (body.length > 2 && body.startsWith(' ') && body.endsWith(' ') && body.trim()) body = body.slice(1, -1);
      push();
      tokens.push({ t: 'code', v: body });
      i = shut + run.length;
      continue;
    }
    if (opts.links && c === '[') {
      const link = readLink(src, i);
      if (link?.href) {
        push();
        tokens.push({ t: 'a', href: link.href, c: inline(link.label, { ...opts, links: false }) });
        i = link.end;
        continue;
      }
      if (link) { text += src.slice(i, link.end); i = link.end; continue; }
    }
    if (opts.links && c === '<') {
      const auto = /^<([a-z][a-z0-9+.-]*:[^\s<>]*)>/i.exec(src.slice(i));
      const href = auto ? safeHref(auto[1]) : null;
      if (href) {
        push();
        tokens.push({ t: 'a', href, c: [auto[1].replace(/^mailto:/i, '')] });
        i += auto[0].length;
        continue;
      }
    }
    // A bare address, but not one inside a link that wasn't one (`[words](bad address)` stays as typed, whole).
    if (opts.links && (c === 'h' || c === 'H') && (i === 0 || /[\s([{<"'*_~]/.test(src[i - 1])) && !src.slice(0, i).endsWith('](')) {
      const bare = /^https?:\/\/[^\s<>"'`]+/i.exec(src.slice(i));
      const address = bare ? trimAddress(bare[0]) : '';
      const href = address ? safeHref(address) : null;
      if (href) {
        push();
        tokens.push({ t: 'a', href, c: [address] });
        i += address.length;
        continue;
      }
    }
    if (c === '*' || c === '_' || c === '~') {
      const n = /^(\*+|_+|~+)/.exec(src.slice(i))[0].length;
      const prev = src[i - 1];
      const next = src[i + n];
      if (c === '~' && n !== 2) { text += c.repeat(n); i += n; continue; }
      const left = !isSpace(next) && (!isPunct(next) || isSpace(prev) || isPunct(prev));
      const right = !isSpace(prev) && (!isPunct(prev) || isSpace(next) || isPunct(next));
      // A single one inside a word is a character (a_b_c.txt, 2*3*4), and beside a slash a glob's or a path's
      // (src/**/*.js); a double one between words still is bold (CommonMark's **bold**text, and scripts without spaces).
      const word = /[\p{L}\p{N}]/u;
      const inWord = (n === 1 || c === '_') && word.test(prev || '') && word.test(next || '');
      const path = c !== '~' && (prev === '/' || next === '/');
      push();
      tokens.push({
        delim: true, ch: c, n, end: i + n,
        // CommonMark: `_` opens and closes only at a word's edge; `*` wherever it flanks.
        open: !inWord && !path && left && (c !== '_' || !right || isPunct(prev)),
        close: !inWord && !path && right && (c !== '_' || !left || isPunct(next)),
      });
      i += n;
      continue;
    }
    text += c;
    i++;
  }
  push();
  return resolve(tokens, src.length, opts);
}

// Pairs each closing marker with the nearest opener of its kind (CommonMark's delimiter run, without its rule of 3).
function resolve(tokens, length, opts) {
  // Per marker kind, the index below which no opener can match (so a long line stays linear).
  const bottom = { '*': -1, _: -1, '~': -1 };
  for (let i = 0; i < tokens.length; i++) {
    const closer = tokens[i];
    if (!closer?.delim || !closer.close) continue;
    let matched = true;
    while (closer.n > 0 && matched) {
      matched = false;
      let waited = false;
      for (let j = i - 1; j > bottom[closer.ch]; j--) {
        const opener = tokens[j];
        if (!opener?.delim || opener.ch !== closer.ch || !opener.open || opener.n === 0) continue;
        // Still arriving: a closer at the end takes only an opener of its own length (`**bold*` waits for its `*`).
        if (opts.streaming && closer.end === length && opener.n !== closer.n) { waited = true; break; }
        const use = closer.ch === '~' ? 2 : Math.min(opener.n, closer.n) >= 2 ? 2 : 1;
        const node = { t: closer.ch === '~' ? 'del' : use === 2 ? 'strong' : 'em', c: merge(tokens.slice(j + 1, i).map(plain)) };
        opener.n -= use;
        closer.n -= use;
        tokens.splice(j + 1, i - j - 1, node);
        i = j + 2;
        matched = true;
        break;
      }
      if (!matched && !waited && closer.n > 0 && !closer.open) bottom[closer.ch] = i;
    }
  }
  return merge(tokens.map(plain));
}

// ---- Blocks ----

const FENCE = /^( {0,3})(`{3,}|~{3,})[ \t]*([^\s`]*)[^`]*$/;
const ITEM = /^( *)([-*+•]|(\d{1,9})([.)]))([ \t]+)(.*)$/;
const HEADING = /^ {0,3}(#{1,6})[ \t]+(\S.*?)(?:[ \t]+#+)?[ \t]*$/;
const RULE = /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/;
const QUOTE = /^ {0,3}>/;
const DELIMITER = /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/;

const indentOf = (line) => /^ */.exec(line)[0].length;
const dropIndent = (line, n) => line.slice(Math.min(n, indentOf(line)));

// A table row's cells: split at each `|` that isn't escaped or inside code.
function cells(line) {
  let s = line.trim();
  if (s.startsWith('|')) s = s.slice(1);
  if (s.endsWith('|') && !s.endsWith('\\|')) s = s.slice(0, -1);
  const out = [];
  let cell = '';
  let code = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === '\\' && s[i + 1] === '|') { cell += '|'; i++; continue; }
    if (c === '`') code = code ? 0 : 1;
    if (c === '|' && !code) { out.push(cell.trim()); cell = ''; continue; }
    cell += c;
  }
  out.push(cell.trim());
  return out;
}
const isDelimiter = (line, n) => line.includes('|') && line.includes('-') && DELIMITER.test(line) && cells(line).length === n;
const alignOf = (cell) => (/^:-+:$/.test(cell) ? 'center' : /^-+:$/.test(cell) ? 'right' : '');

// Whether `line` starts a block of its own (so it ends a paragraph).
function starts(line, lines, i) {
  if (FENCE.test(line) || HEADING.test(line) || RULE.test(line) || QUOTE.test(line)) return true;
  const item = ITEM.exec(line);
  // An ordered list breaks into a paragraph only from 1 (a sentence's "1984. Then" stays a sentence).
  if (item && item[6].trim() && (!item[3] || item[3] === '1')) return true;
  return line.includes('|') && i + 1 < lines.length && isDelimiter(lines[i + 1], cells(line).length);
}

// A list from `lines[at]`: its items, each the lines under it read as blocks of their own. Returns the next line's index.
function readList(lines, at, out, opts) {
  const first = ITEM.exec(lines[at]);
  const indent = first[1].length;
  const ordered = !!first[3];
  const list = ordered ? { t: 'ol', start: Number(first[3]), items: [] } : { t: 'ul', items: [] };
  let i = at;
  while (i < lines.length) {
    const item = ITEM.exec(lines[i]);
    if (!item || item[1].length !== indent || !!item[3] !== ordered) break;
    const spaces = item[5].length > 4 ? 1 : item[5].length;
    const column = indent + item[2].length + spaces;
    const body = [item[5].length > 4 ? item[5].slice(1) + item[6] : item[6]];
    let j = i + 1;
    let fenced = FENCE.test(item[6]);
    for (; j < lines.length; j++) {
      const line = lines[j];
      if (!line.trim()) {
        let k = j + 1;
        while (k < lines.length && !lines[k].trim()) k++;
        if (k < lines.length && indentOf(lines[k]) > indent) { body.push(''); continue; }
        break;
      }
      if (indentOf(line) > indent) {
        body.push(dropIndent(line, column));
        if (FENCE.test(dropIndent(line, column))) fenced = !fenced;
        continue;
      }
      // A line run on from the item's words (no indent), unless it starts a block or the next item.
      const last = body[body.length - 1];
      if (!fenced && last && last.trim() && !ITEM.test(line) && !starts(line, lines, j)) { body.push(line.trim()); continue; }
      break;
    }
    list.items.push(blocks(body, opts));
    i = j;
    // A blank line between two items of this list keeps them one list.
    while (i < lines.length && !lines[i].trim()) {
      let k = i;
      while (k < lines.length && !lines[k].trim()) k++;
      const next = k < lines.length ? ITEM.exec(lines[k]) : null;
      if (next && next[1].length === indent && !!next[3] === ordered) i = k; else break;
    }
  }
  out.push(list);
  return i;
}

function blocks(lines, opts) {
  const out = [];
  let paragraph = [];
  const flush = () => {
    if (paragraph.length) out.push({ t: 'p', c: inline(paragraph.join(opts.breaks ? '\n' : ' '), opts) });
    paragraph = [];
  };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const fence = FENCE.exec(line);
    if (fence) {
      flush();
      const mark = fence[2];
      const shut = new RegExp(`^ {0,3}${mark[0] === '`' ? '`' : '~'}{${mark.length},}[ \\t]*$`);
      const body = [];
      let closed = false;
      for (i += 1; i < lines.length; i++) {
        if (shut.test(lines[i])) { closed = true; break; }
        body.push(dropIndent(lines[i], fence[1].length));
      }
      // Still arriving: a last line that is only the start of the closing fence isn't code, nor the new line before it.
      if (!closed && opts.streaming && body.length && new RegExp(`^ {0,3}${mark[0] === '`' ? '`' : '~'}{1,${mark.length}}$`).test(body[body.length - 1])) body.pop();
      if (!closed && opts.streaming && body.length && body[body.length - 1] === '') body.pop();
      out.push({ t: 'pre', lang: fence[3], v: body.join('\n') });
      continue;
    }
    if (!line.trim()) { flush(); continue; }
    const heading = HEADING.exec(line);
    if (heading) {
      flush();
      out.push({ t: 'h', level: Math.min(6, heading[1].length + 2), c: inline(heading[2], opts) });
      continue;
    }
    if (RULE.test(line)) { flush(); out.push({ t: 'hr' }); continue; }
    if (QUOTE.test(line)) {
      flush();
      const inner = [];
      for (; i < lines.length && QUOTE.test(lines[i]); i++) inner.push(lines[i].replace(/^ {0,3}> ?/, ''));
      i -= 1;
      out.push({ t: 'quote', c: blocks(inner, opts) });
      continue;
    }
    const item = ITEM.exec(line);
    if (item && (!paragraph.length || starts(line, lines, i))) {
      flush();
      i = readList(lines, i, out, opts) - 1;
      continue;
    }
    if (line.includes('|') && i + 1 < lines.length && isDelimiter(lines[i + 1], cells(line).length)) {
      flush();
      const head = cells(line);
      const align = cells(lines[i + 1]).map(alignOf);
      const rows = [];
      for (i += 2; i < lines.length && lines[i].trim() && lines[i].includes('|'); i++) {
        const row = cells(lines[i]);
        rows.push(head.map((_, k) => inline(row[k] || '', opts)));
      }
      i -= 1;
      out.push({ t: 'table', align, head: head.map((cell) => inline(cell, opts)), rows });
      continue;
    }
    paragraph.push(opts.breaks ? line.replace(/\s+$/, '') : line.trim());
  }
  flush();
  return out;
}

// `text` as the tree. `options`: `links` (anchors for http, https and mailto), `breaks` (a new line is a line break, as
// you typed it), `streaming` (a reply still arriving).
export function parseMarkdown(text, options = {}) {
  const opts = { links: !!options.links, breaks: !!options.breaks, streaming: !!options.streaming };
  const lines = String(text ?? '').replace(/\r\n?/g, '\n').replace(/\t/g, '    ').split('\n');
  // Still arriving: a last line of only * or _ may be the start of ***bold***, so it is words until its line ends.
  const last = lines.length - 1;
  if (opts.streaming && RULE.test(lines[last]) && /[*_]/.test(lines[last])) lines[last] = '\\' + lines[last].trimStart();
  return blocks(lines, opts);
}

// ---- Nodes ----

function build(node, options) {
  if (typeof node === 'string') return node;
  const kids = (list) => list.map((one) => build(one, options));
  switch (node.t) {
    case 'p': return h('p', null, kids(node.c));
    case 'h': return h('h' + node.level, null, kids(node.c));
    case 'strong': case 'em': case 'del': return h(node.t, null, kids(node.c));
    case 'code': return h('code', null, node.v);
    case 'br': return h('br');
    case 'a': return h('a', { href: node.href, target: '_blank', rel: 'noopener noreferrer' }, kids(node.c));
    case 'hr': return h('hr');
    case 'quote': return h('blockquote', null, kids(node.c));
    case 'ul': case 'ol':
      return h(node.t, node.t === 'ol' && node.start !== 1 ? { start: node.start } : null, node.items.map((item) =>
        // One paragraph: its words straight in the item (a tight list), else its blocks.
        h('li', null, item.length === 1 && item[0].t === 'p' ? kids(item[0].c) : kids(item))));
    case 'pre': return codeBlock(node.v, node.lang, options.codeAction ? options.codeAction(node.v, node.lang) : null);
    case 'table':
      return h('div', { class: 'table', tabindex: 0, role: 'region', 'aria-label': t('txTable') }, h('table', null,
        h('thead', null, h('tr', null, node.head.map((cell, k) => h('th', { class: node.align[k] ? 'align-' + node.align[k] : null }, kids(cell))))),
        h('tbody', null, node.rows.map((row) => h('tr', null, row.map((cell, k) => h('td', { class: node.align[k] ? 'align-' + node.align[k] : null }, kids(cell))))))));
    default: return null;
  }
}

// `text`'s blocks as nodes, in a list. `options`: parseMarkdown's, and `codeAction(code, language)`: the element a
// fenced block gets beside its language and Copy (a reply's Run, chat.js), or null.
export function markdownNodes(text, options = {}) {
  return parseMarkdown(text, options).map((node) => build(node, options)).filter(Boolean);
}

// The same in one fragment, for a caller that appends it whole.
export function markdown(text, options = {}) {
  const out = document.createDocumentFragment();
  out.append(...markdownNodes(text, options));
  return out;
}

// A fenced block: its language, Copy (and `action`, a reply's Run), then its lines, which never wrap: a wide one
// scrolls inside the block. Copy takes the code exactly as it is.
export function codeBlock(code, language = '', action = null) {
  return h('figure', { class: 'code' },
    h('figcaption', null, h('span', { class: 'code-lang' }, language ? language.toLowerCase() : ''), action, copyButton(() => code, t('txCopyCode'))),
    h('pre', { tabindex: 0 }, h('code', null, code)));
}

// The lines of `before` and `after` as a diff: kept lines (' '), removed ('-') and added ('+'), by the longest
// common run of lines. An edit's two texts are short; anything huge is shown whole as removed then added.
export function diffLines(before, after) {
  const a = before === '' ? [] : before.split('\n');
  const b = after === '' ? [] : after.split('\n');
  if (a.length * b.length > 250000) return [...a.map((text) => ({ sign: '-', text })), ...b.map((text) => ({ sign: '+', text }))];
  const width = b.length + 1;
  const table = new Uint32Array((a.length + 1) * width);
  for (let i = a.length - 1; i >= 0; i--) {
    for (let j = b.length - 1; j >= 0; j--) {
      table[i * width + j] = a[i] === b[j] ? table[(i + 1) * width + j + 1] + 1 : Math.max(table[(i + 1) * width + j], table[i * width + j + 1]);
    }
  }
  const lines = [];
  let i = 0;
  let j = 0;
  while (i < a.length && j < b.length) {
    if (a[i] === b[j]) { lines.push({ sign: ' ', text: a[i] }); i++; j++; }
    else if (table[(i + 1) * width + j] >= table[i * width + j + 1]) lines.push({ sign: '-', text: a[i++] });
    else lines.push({ sign: '+', text: b[j++] });
  }
  while (i < a.length) lines.push({ sign: '-', text: a[i++] });
  while (j < b.length) lines.push({ sign: '+', text: b[j++] });
  return lines;
}

// What a diff's Copy takes: the new text (the kept and added lines, no signs: what the file holds after the edit, the
// change's parts joined by a blank line), or the change itself (`as: 'diff'`: each line after its sign, ' ', '-', '+').
export function diffText(changes, as = 'new') {
  return (changes || []).map((change) => diffLines(change.old || '', change.new || '')
    .filter((line) => as === 'diff' || line.sign !== '-')
    .map((line) => (as === 'diff' ? line.sign + line.text : line.text)).join('\n')).join(as === 'diff' ? '\n…\n' : '\n\n');
}

// An edit as the Mac's chat draws one: a sign column ("+", "−"), added lines on green, removed on red; Copy (the new
// text) and Copy as Diff over its corner.
export function diffView(changes) {
  // The lines sit in one block as wide as the widest, so a line's colour runs its whole width when the box scrolls.
  const lines = h('div', { class: 'diff-lines' });
  const scroll = h('div', { class: 'diff-scroll', role: 'group', 'aria-label': t('txChanges'), tabindex: 0 }, lines);
  const box = h('div', { class: 'diff' },
    h('div', { class: 'block-actions' }, copyButton(() => diffText(changes, 'diff'), t('txCopyDiff'), t('txCopyDiffWord')), copyButton(() => diffText(changes), t('txCopyNew'))),
    scroll);
  let added = 0;
  let removed = 0;
  changes.forEach((change, index) => {
    if (index > 0) lines.append(h('div', { class: 'diff-gap' }, '⋯'));
    for (const line of diffLines(change.old || '', change.new || '')) {
      if (line.sign === '+') added++;
      if (line.sign === '-') removed++;
      lines.append(h('div', { class: line.sign === '+' ? 'diff-line added' : line.sign === '-' ? 'diff-line removed' : 'diff-line' },
        h('span', { class: 'sign', 'aria-hidden': 'true' }, line.sign === '-' ? '−' : line.sign === '+' ? '+' : ''),
        h('span', { class: 'diff-text' }, line.text || ' ')));
    }
  });
  return { el: box, added, removed };
}
