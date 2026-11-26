// The chat's renderer (js/text.js, the design review's D7): each construct as its tree, nesting, markers that don't
// close or sit inside words and paths, long lines, right-to-left and emoji text, hostile input; links only to http,
// https and mailto; and while a reply streams, each marker turns from typed to drawn once. Then the nodes it builds:
// anchors that open apart, nothing but elements and text.
// Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { installDom, findAll } from './fakedom.test.mjs';

const dom = installDom();
const { parseMarkdown, markdownNodes, safeHref, diffText, diffView, codeBlock } = await import('../js/text.js');
const { setLanguage } = await import('../js/i18n.js');
setLanguage('en');

const chat = (text, more = {}) => parseMarkdown(text, { links: true, ...more });
const p = (...c) => ({ t: 'p', c });
const em = (...c) => ({ t: 'em', c });
const strong = (...c) => ({ t: 'strong', c });
const del = (...c) => ({ t: 'del', c });
const code = (v) => ({ t: 'code', v });
const a = (href, ...c) => ({ t: 'a', href, c });

// ---- Each construct ----

const CORPUS = [
  ['emphasis, both ways', 'an *odd* and _even_ word', [p('an ', em('odd'), ' and ', em('even'), ' word')]],
  ['strong, both ways', '**this** and __that__', [p(strong('this'), ' and ', strong('that'))]],
  ['strong and emphasis at once', '***both***', [p(em(strong('both')))]],
  ['emphasis inside strong', '**a *b* c**', [p(strong('a ', em('b'), ' c'))]],
  ['strikethrough', '~~gone~~ kept', [p(del('gone'), ' kept')]],
  ['inline code, its contents never read', 'run `a *b* [c](https://x.example)` now', [p('run ', code('a *b* [c](https://x.example)'), ' now')]],
  ['code with a backtick inside', '``a ` b``', [p(code('a ` b'))]],
  ['a link', 'see [the page](https://example.com/a?b=1#c)', [p('see ', a('https://example.com/a?b=1#c', 'the page'))]],
  ['a link’s words keep their emphasis', '[**bold** words](https://example.com)', [p(a('https://example.com/', strong('bold'), ' words'))]],
  ['a link with a title', '[t](https://example.com "Title")', [p(a('https://example.com/', 't'))]],
  ['a mail link', '[write](mailto:dev@example.com)', [p(a('mailto:dev@example.com', 'write'))]],
  ['a bare address, its sentence’s full stop left out', 'Go to https://example.com/docs.', [p('Go to ', a('https://example.com/docs', 'https://example.com/docs'), '.')]],
  ['a bare address in brackets', '(at https://example.com/x)', [p('(at ', a('https://example.com/x', 'https://example.com/x'), ')')]],
  ['an address in angle brackets', '<https://example.com>', [p(a('https://example.com/', 'https://example.com'))]],
  ['headings, from # as h3 to ###### as h6', '# One\n## Two\n### Three\n#### Four\n###### Six', [
    { t: 'h', level: 3, c: ['One'] }, { t: 'h', level: 4, c: ['Two'] }, { t: 'h', level: 5, c: ['Three'] }, { t: 'h', level: 6, c: ['Four'] }, { t: 'h', level: 6, c: ['Six'] }]],
  ['a hash without a space is a word', '#hashtag and #1', [p('#hashtag and #1')]],
  ['a block quote, its blocks its own', '> Note: *this*\n> - one\n\nafter', [{ t: 'quote', c: [p('Note: ', em('this')), { t: 'ul', items: [[p('one')]] }] }, p('after')]],
  ['an unordered list', '- one\n- two\n* three', [{ t: 'ul', items: [[p('one')], [p('two')], [p('three')]] }]],
  ['an ordered list keeps its first number', '3. three\n4. four', [{ t: 'ol', start: 3, items: [[p('three')], [p('four')]] }]],
  ['lists nest by indent', '1. one\n   - a\n     - deep\n2. two\n  - b', [{ t: 'ol', start: 1, items: [
    [p('one'), { t: 'ul', items: [[p('a'), { t: 'ul', items: [[p('deep')]] }]] }],
    [p('two'), { t: 'ul', items: [[p('b')]] }]] }]],
  ['a blank line between items keeps one list', '- a\n\n- b', [{ t: 'ul', items: [[p('a')], [p('b')]] }]],
  ['code inside a list item', '- run:\n  ```sh\n  ls -l\n  ```', [{ t: 'ul', items: [[p('run:'), { t: 'pre', lang: 'sh', v: 'ls -l' }]] }]],
  ['a sentence that starts with a year stays a sentence', 'It began in\n1984. Then it grew.', [p('It began in 1984. Then it grew.')]],
  ['a table, aligned, a pipe inside code kept', '| Token | Ratio |\n|:--|--:|\n| `a|b` | 16.1:1 |\n| x |', [{ t: 'table', align: ['', 'right'],
    head: [['Token'], ['Ratio']], rows: [[[code('a|b')], ['16.1:1']], [['x'], []]] }]],
  ['pipes without the head’s rule are a sentence', 'a | b | c', [p('a | b | c')]],
  ['horizontal rules', 'a\n\n---\n\n* * *\n___', [p('a'), { t: 'hr' }, { t: 'hr' }, { t: 'hr' }]],
  ['fenced code with its language, nothing in it read', '```JS\nconst a = **b** <i>;\n\n  [x](javascript:y)\n```', [{ t: 'pre', lang: 'JS', v: 'const a = **b** <i>;\n\n  [x](javascript:y)' }]],
  ['a tilde fence', '~~~\n```\n~~~', [{ t: 'pre', lang: '', v: '```' }]],
  ['an open fence runs to the end', '```py\nprint(1)', [{ t: 'pre', lang: 'py', v: 'print(1)' }]],
  ['a backslash keeps a marker a character', '\\*not\\* and C:\\Users\\dev', [p('*not* and C:\\Users\\dev')]],
  ['a paragraph’s lines join', 'one\ntwo', [p('one two')]],
  ['your own lines stay lines', 'one\ntwo', [p('one', { t: 'br' }, 'two')], { breaks: true }],

  // ---- Markers that don't close, inside words and paths ----
  ['an unclosed marker shows as typed and takes nothing', 'un*closed and **also here', [p('un*closed and **also here')]],
  ['an unclosed code span shows as typed', 'a `b c', [p('a `b c')]],
  ['inside words and paths', 'a_b_c.txt, 2*3*4, snake_case_name, src/**/*.js, a * b * c', [p('a_b_c.txt, 2*3*4, snake_case_name, src/**/*.js, a * b * c')]],
  ['double markers between words still bold', 'un**frigging**believable', [p('un', strong('frigging'), 'believable')]],
  ['__init__ is bold, as CommonMark has it; `__init__` is code', '__init__.py and `__init__.py`', [p(strong('init'), '.py and ', code('__init__.py'))]],
  ['a lone tilde is approximate', '~5 min and ~x~', [p('~5 min and ~x~')]],
  ['a marker around space is a character', 'a * b and c _ d', [p('a * b and c _ d')]],
  ['a broken link stays as typed, whole', '[x](not a url) and [y](docs/a.md) and [](https://example.com)', [p('[x](not a url) and [y](docs/a.md) and [](https://example.com)')]],

  // ---- Hostile ----
  ['markup is text', '<script>alert(1)</script><img src=x onerror=alert(1)>', [p('<script>alert(1)</script><img src=x onerror=alert(1)>')]],
  ['a script address is not a link', '[click](javascript:alert(1)) [c2](JAVASCRIPT:alert(1)) [c3](data:text/html,x) [c4](vbscript:x) [c5](file:///etc/passwd)', [
    p('[click](javascript:alert(1)) [c2](JAVASCRIPT:alert(1)) [c3](data:text/html,x) [c4](vbscript:x) [c5](file:///etc/passwd)')]],
  ['an address with a quote or a space is not a link', '[q](https://a.example/" onclick="x) [s](https://a.example/a b)', [p('[q](https://a.example/" onclick="x) [s](https://a.example/a b)')]],
  ['an angle-bracket address of another scheme is text', '<javascript:alert(1)> <ftp://x.example>', [p('<javascript:alert(1)> <ftp://x.example>')]],
  ['a bare address of another scheme is text', 'javascript:alert(1) and ftp://x.example', [p('javascript:alert(1) and ftp://x.example')]],

  // ---- Scripts and emoji ----
  ['right-to-left and emoji', 'שלום *עולם* 😀 **مرحبا** 👩‍💻', [p('שלום ', em('עולם'), ' 😀 ', strong('مرحبا'), ' 👩‍💻')]],
  ['Spanish punctuation', '¡*Hola*! ¿**Qué** tal?', [p('¡', em('Hola'), '! ¿', strong('Qué'), ' tal?')]],
];

for (const [name, text, tree, options] of CORPUS) {
  test(`markdown: ${name}`, () => assert.deepEqual(chat(text, options), tree));
}

test('markdown: links stay text where a caller doesn’t ask for them (what the node made inert)', () => {
  assert.deepEqual(parseMarkdown('see [the page](https://example.com) or https://example.com'), [p('see [the page](https://example.com) or https://example.com')]);
});

test('markdown: a very long line, a long run of markers and deep nesting stay quick and whole', () => {
  const long = 'word '.repeat(20000) + 'end';
  let started = performance.now();
  assert.deepEqual(chat(long), [p(long.trim())]);
  const markers = 'a *b '.repeat(5000);
  assert.equal(chat(markers)[0].c.join(''), markers.trim());
  const deep = Array.from({ length: 60 }, (_, i) => ' '.repeat(i * 2) + '- level ' + i).join('\n');
  let node = chat(deep)[0];
  for (let i = 0; i < 59; i++) node = node.items[0][1];
  assert.deepEqual(node.items[0], [p('level 59')]);
  // A run of unclosed brackets (each one a link that might close) stays linear.
  const brackets = '[a '.repeat(20000) + '] and [x](https://example.com)';
  assert.equal(chat(brackets)[0].c.at(-1).href, 'https://example.com/');
  // Quick enough to draw as it streams: well under a frame's budget per kilobyte on any machine that runs the tests.
  assert.ok(performance.now() - started < 3000, `${Math.round(performance.now() - started)} ms`);
});

test('safeHref: only http, https and mailto, as the URL parser reads them; everything else is null', () => {
  assert.equal(safeHref('https://example.com/a b'), null);
  for (const bad of ['javascript:alert(1)', ' javascript:alert(1)', 'jav\tascript:x', 'data:text/html,x', 'vbscript:x', 'file:///etc/passwd', '//example.com',
    '/relative', 'docs/a.md', 'https://', 'http:example.com', 'https://a.example/"x', "https://a.example/'x", 'https://a.example/<x>', 'mailto:nobody', 'https://a\u0000.example']) {
    assert.equal(safeHref(bad), null, bad);
  }
  assert.equal(safeHref('HTTPS://Example.com/Path'), 'https://example.com/Path');
  assert.equal(safeHref('mailto:dev@example.com'), 'mailto:dev@example.com');
});

// ---- Streaming: each marker from typed to drawn once ----

// What a reader sees of a tree: its words, a block a line.
function visible(nodes) {
  const inlineText = (list) => list.map((one) => (typeof one === 'string' ? one : one.t === 'code' ? one.v : one.t === 'br' ? '\n' : inlineText(one.c || []))).join('');
  const blockText = (block) => {
    if (block.t === 'p' || block.t === 'h') return inlineText(block.c);
    if (block.t === 'pre') return block.v;
    if (block.t === 'quote') return visible(block.c);
    if (block.t === 'ul' || block.t === 'ol') return block.items.map(visible).join('\n');
    if (block.t === 'table') return [block.head, ...block.rows].map((row) => row.map(inlineText).join(' ').trimEnd()).join('\n');
    return '';
  };
  return nodes.map(blockText).filter(Boolean).join('\n');
}

const STREAMED = [
  ['**bold** then *it* then ~~gone~~ then `code`', 4],
  ['A [link](https://example.com/a) and https://example.com/b.', 1],
  ['## Heading\n\nText.', 1],
  ['- one\n- two\n  - nested', 3],
  ['1. one\n2. two', 2],
  ['> quoted *words*', 1],
  ['| a | b |\n|---|---|\n| 1 | 2 |', 1],
  ['```js\nconst a = 1;\n```\nafter', 1],
  ['a\n\n---\n\nb', 1],
  ['***both*** and __this__', 2],
];

for (const [text, markers] of STREAMED) {
  test(`streaming: ${JSON.stringify(text).slice(0, 50)} turns from typed to drawn at most once a marker`, () => {
    let shown = '';
    let rewrites = 0;
    const changes = [];
    for (let k = 1; k <= text.length; k++) {
      const now = visible(chat(text.slice(0, k), { streaming: k < text.length }));
      if (!now.startsWith(shown)) { rewrites += 1; changes.push(`${JSON.stringify(shown)} → ${JSON.stringify(now)}`); }
      shown = now;
    }
    assert.ok(rewrites <= markers, `${rewrites} rewrites for ${markers} markers:\n${changes.join('\n')}`);
    // And the whole, once it ended, as it reads when not streaming.
    assert.deepEqual(chat(text, { streaming: false }), chat(text));
  });
}

test('streaming: a half-arrived ** never shows as emphasis on its way to bold', () => {
  assert.deepEqual(chat('**bold*', { streaming: true }), [p('**bold*')]);
  assert.deepEqual(chat('**bold**', { streaming: true }), [p(strong('bold'))]);
  // Once the reply is whole, what it says stands.
  assert.deepEqual(chat('**bold*'), [p('*', em('bold'))]);
  // A code block's closing fence arriving isn't drawn as code first.
  assert.deepEqual(chat('```\nx\n``', { streaming: true }), [{ t: 'pre', lang: '', v: 'x' }]);
});

// ---- The nodes ----

test('nodes: a link opens in a new tab with noopener, and nothing carries a handler, a style or markup', () => {
  const nodes = markdownNodes('[a](https://example.com) <https://b.example> https://c.example [bad](javascript:alert(1)) <b onclick=x>', { links: true });
  const all = nodes.flatMap((node) => findAll(node, () => true));
  const anchors = all.filter((node) => node.tag === 'a');
  assert.deepEqual(anchors.map((one) => [one.attrs.href, one.attrs.target, one.attrs.rel]), [
    ['https://example.com/', '_blank', 'noopener noreferrer'], ['https://b.example/', '_blank', 'noopener noreferrer'], ['https://c.example/', '_blank', 'noopener noreferrer']]);
  for (const node of all) {
    for (const name of Object.keys(node.attrs)) assert.ok(!/^on|^style$|^srcdoc$/i.test(name), `${node.tag} has ${name}`);
    assert.ok(['#text', 'p', 'a', 'b', 'strong', 'em'].includes(node.tag), node.tag);
  }
  assert.ok(nodes[0].textContent.includes('[bad](javascript:alert(1)) <b onclick=x>'));
});

test('nodes: headings, quotes, rules, nested lists and tables are the elements their CSS styles', () => {
  const nodes = markdownNodes('# H\n> q\n\n---\n\n- a\n  - b\n\n3. c\n\n| x | y |\n|:-:|--|\n| 1 | 2 |', { links: true });
  assert.deepEqual(nodes.map((node) => node.tag), ['h3', 'blockquote', 'hr', 'ul', 'ol', 'div']);
  assert.equal(nodes[4].attrs.start, '3');
  assert.equal(findAll(nodes[3], (node) => node.tag === 'ul').length, 2, 'the nested list inside the first');
  assert.equal(nodes[5].attrs.class, 'table');
  assert.equal(nodes[5].attrs.tabindex, '0', 'a wide table scrolls in its own box, by keyboard too');
  assert.equal(findAll(nodes[5], (node) => node.tag === 'th')[0].attrs.class, 'align-center');
});

// ---- Copy (D9) ----

function clipboard(refuse = false) {
  const copied = [];
  Object.defineProperty(globalThis, 'navigator', { value: { platform: 'MacIntel', clipboard: { writeText: async (text) => { if (refuse) throw new Error('refused'); copied.push(text); } } }, configurable: true });
  return copied;
}
const click = async (button) => { for (const fn of button.handlers.click || []) await fn({ currentTarget: button }); };
const copyOf = (node) => findAll(node, (one) => one.tag === 'button' && one.classList.contains('block-copy'));

test('copy: a code block’s Copy takes the code exactly, then says Copied; a refusal says which keys', async () => {
  const copied = clipboard();
  const text = '  indented\n\ttab and `ticks` **not bold**\n';
  const block = codeBlock(text, 'Py');
  const [button] = copyOf(block);
  assert.ok(button, 'every code block has Copy');
  await click(button);
  assert.deepEqual(copied, [text]);
  assert.equal(button.textContent, 'Copied');
  assert.ok(button.classList.contains('done'));
  clipboard(true);
  await click(button);
  assert.equal(button.textContent, '⌘C');
});

test('copy: a fenced block in a reply copies its code as typed, markers and all', async () => {
  const copied = clipboard();
  const [figure] = markdownNodes('```sh\necho "a *b*" | grep [x](y)\n```', { links: true });
  await click(copyOf(figure)[0]);
  assert.deepEqual(copied, ['echo "a *b*" | grep [x](y)']);
});

test('copy: a diff copies its new text without signs, or the change with them', async () => {
  const changes = [{ old: 'a\nb\nc', new: 'a\nB\nc\nd' }, { old: 'x', new: 'y' }];
  assert.equal(diffText(changes), 'a\nB\nc\nd\n\ny');
  assert.equal(diffText(changes, 'diff'), ' a\n-b\n+B\n c\n+d\n…\n-x\n+y');
  const copied = clipboard();
  const view = diffView(changes);
  const [asDiff, asNew] = copyOf(view.el);
  await click(asNew);
  await click(asDiff);
  assert.deepEqual(copied, ['a\nB\nc\nd\n\ny', ' a\n-b\n+B\n c\n+d\n…\n-x\n+y']);
  assert.equal(view.added, 3);
  assert.equal(view.removed, 2);
});

test('D8: a diff’s text has its own class, not the lead conversation’s `.line` (14.5 px in 28 px rows)', () => {
  const view = diffView([{ old: 'a', new: 'b' }]);
  const spans = findAll(view.el, (node) => node.tag === 'span' && !node.classList.contains('sign') && node.parentNode?.classList.contains('diff-line'));
  assert.equal(spans.length, 2);
  for (const span of spans) assert.equal(span.attrs.class, 'diff-text');
  assert.equal(findAll(view.el, (node) => node.classList.contains('line')).length, 0);
});

test.after(() => dom.restore());
