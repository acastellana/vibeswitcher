// An agent's text, drawn as nodes: the markdown a reply uses (paragraphs, lists, headings, code, bold) and a diff of
// an edit. Text only ever reaches the page as text nodes. A link is shown as its words and its address, never as an
// anchor: links open only for allow-listed schemes after a confirmation (the design's "The web client"), which
// arrives with the real client.

import { h } from './dom.js';

// `code`, **bold** and the rest as text.
function inline(text) {
  const nodes = [];
  const pattern = /(`[^`\n]+`)|(\*\*[^*\n]+\*\*)/g;
  let from = 0;
  for (const match of text.matchAll(pattern)) {
    if (match.index > from) nodes.push(text.slice(from, match.index));
    if (match[1]) nodes.push(h('code', null, match[1].slice(1, -1)));
    else nodes.push(h('strong', null, match[2].slice(2, -2)));
    from = match.index + match[0].length;
  }
  if (from < text.length) nodes.push(text.slice(from));
  return nodes;
}

// A fenced block: its language, then its lines, which never wrap (a wide one scrolls). `action`: an element beside the
// language (a reply's Run, chat.js), or none.
export function codeBlock(code, language = '', action = null) {
  return h('figure', { class: 'code' },
    language || action ? h('figcaption', null, language ? language.toLowerCase() : '', action) : null,
    h('pre', { tabindex: 0 }, h('code', null, code)));
}

// `options.codeAction(code, language)`: the element a fenced block gets beside its language, or null.
export function markdown(text, options = {}) {
  const out = document.createDocumentFragment();
  const lines = text.split('\n');
  let paragraph = [];
  let list = null;
  const flush = () => {
    if (paragraph.length) out.append(h('p', null, inline(paragraph.join(' '))));
    paragraph = [];
  };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const fence = line.match(/^```(\S*)\s*$/);
    if (fence) {
      flush();
      list = null;
      const body = [];
      // An open fence (a reply still streaming) runs to the end.
      for (i += 1; i < lines.length && !/^```\s*$/.test(lines[i]); i++) body.push(lines[i]);
      const code = body.join('\n');
      out.append(codeBlock(code, fence[1], options.codeAction ? options.codeAction(code, fence[1]) : null));
      continue;
    }
    const item = line.match(/^\s*(?:[-*•]|(\d+)[.)])\s+(.*)$/);
    if (item) {
      flush();
      const tag = item[1] ? 'ol' : 'ul';
      if (!list || list.localName !== tag) {
        list = h(tag);
        out.append(list);
      }
      list.append(h('li', null, inline(item[2])));
      continue;
    }
    list = null;
    const heading = line.match(/^(#{1,3})\s+(.*)$/);
    if (heading) {
      flush();
      out.append(h('h' + (heading[1].length + 2), null, inline(heading[2])));
    } else if (line.trim() === '') {
      flush();
    } else {
      paragraph.push(line.trim());
    }
  }
  flush();
  return out;
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

// An edit as the Mac's chat draws one: a sign column ("+", "−"), added lines on green, removed on red.
export function diffView(changes) {
  // The lines sit in one block as wide as the widest, so a line's colour runs its whole width when the box scrolls.
  const lines = h('div', { class: 'diff-lines' });
  const box = h('div', { class: 'diff', role: 'group', 'aria-label': 'Changes', tabindex: 0 }, lines);
  let added = 0;
  let removed = 0;
  changes.forEach((change, index) => {
    if (index > 0) lines.append(h('div', { class: 'diff-gap' }, '⋯'));
    for (const line of diffLines(change.old || '', change.new || '')) {
      if (line.sign === '+') added++;
      if (line.sign === '-') removed++;
      lines.append(h('div', { class: line.sign === '+' ? 'diff-line added' : line.sign === '-' ? 'diff-line removed' : 'diff-line' },
        h('span', { class: 'sign', 'aria-hidden': 'true' }, line.sign === '-' ? '−' : line.sign === '+' ? '+' : ''),
        h('span', { class: 'line' }, line.text || ' ')));
    }
  });
  return { el: box, added, removed };
}
