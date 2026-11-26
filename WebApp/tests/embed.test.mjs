// The embed step leaves comments out of the page's own scripts and style sheet (scripts/webapp-embed.sh), and nothing
// else: a small page whose strings, templates and regular expressions hold // and /* is embedded, the files are read
// back from what it wrote, and the stripped module exports exactly what the one in the folder does. Lines keep their
// numbers, a licence stays, vendor/ is untouched, and a file it can't be sure of is embedded whole.
// Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repo = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

// Every literal here holds a comment's opening or closing inside it; the comments around them say COMMENT.
const MODULE = [
  '/*! licence: kept as it is */',
  '// COMMENT a line of its own',
  "export const plain = 'http://example.com/a//b /* not a comment */'; // COMMENT after code",
  'export const double = "// inside \\" quotes /* still */";',
  'export const template = `line one // kept',
  '  /* kept */ line two ${"//" + `${"/*"}nested*/`} end`;',
  '/* COMMENT a block',
  '   over two lines */',
  'export const regex = /\\/\\/[/*]+\\*\\//g;',
  "export const ratio = (10) / 2 / 5; // COMMENT after a division that isn't a regular expression",
  'export const klass = /[/]/.source + /a*/i.flags; /* COMMENT */ export const after = 1;',
  'export const tight = 4/**/ + 1;',
  'const list = [1, 2, 3];',
  'export const sum = list.map((n) => n / 1).reduce((a, b) => a + b) /* COMMENT */ / 3;',
  'export const quote = `a ${`b ${"c // d"}`} e /* f */`;',
  '',
].join('\n');
const STYLE = [
  '/* COMMENT the tokens */',
  ':root { --x: 1px; } /* COMMENT */',
  '.a::before { content: "/* not a comment */ // either"; background: url(data:image/png;base64,AA//BB==); }',
  '.b/**/.c { color: red; }',
  '.d { margin: 0 /* COMMENT */ 2px; }',
  '',
].join('\n');

function embed(files) {
  const root = mkdtempSync(join(tmpdir(), 'embed-'));
  for (const [path, text] of Object.entries(files)) {
    mkdirSync(dirname(join(root, path)), { recursive: true });
    writeFileSync(join(root, path), text);
  }
  const out = join(root, '..', root.split('/').pop() + '-out', 'out.swift');
  const ran = spawnSync('/bin/bash', [join(repo, 'scripts/webapp-embed.sh'), '--root', root, '--out', out], { encoding: 'utf8' });
  assert.equal(ran.status, 0, ran.stderr);
  const said = ran.stdout + ran.stderr;
  const embedded = {};
  for (const match of readFileSync(out, 'utf8').matchAll(/File\(path: "([^"]+)", sha256: "[0-9a-f]+", base64: """\n([\s\S]*?)\n\s*"""\)/g)) {
    embedded[match[1]] = Buffer.from(match[2].replace(/\s+/g, ''), 'base64').toString('utf8');
  }
  return { root, embedded, said };
}
const PAGE = { 'index.html': '<!doctype html><script type="module" src="app.js"></script>', 'app.js': MODULE, 'style.css': STYLE };

test('a module stripped of its comments exports exactly what it did: every string, template and regular expression as written', async () => {
  const { root, embedded } = embed(PAGE);
  const stripped = embedded['app.js'];
  assert.doesNotMatch(stripped, /COMMENT/, 'each comment is gone');
  assert.ok(stripped.startsWith('/*! licence: kept as it is */'), 'a licence stays');
  assert.equal(stripped.split('\n').length, MODULE.split('\n').length, 'every line keeps its number');
  // As modules whatever Node's guess for a .js file.
  writeFileSync(join(root, 'before.mjs'), MODULE);
  writeFileSync(join(root, 'stripped.mjs'), stripped);
  const [before, after] = await Promise.all(['before.mjs', 'stripped.mjs'].map((name) => import(pathToFileURL(join(root, name)).href)));
  const values = (module) => Object.fromEntries(Object.entries(module).map(([key, value]) => [key, value instanceof RegExp ? String(value) : value]));
  assert.deepEqual(values(after), values(before));
  assert.equal(before.plain, 'http://example.com/a//b /* not a comment */');
  assert.equal(before.template, 'line one // kept\n  /* kept */ line two ///*nested*/ end');
  assert.equal(before.tight, 5);
});

test('a style sheet stripped of its comments keeps its strings and urls, and a comment that joins two tokens', () => {
  const { embedded } = embed(PAGE);
  const css = embedded['style.css'];
  assert.doesNotMatch(css, /COMMENT/);
  assert.match(css, /content: "\/\* not a comment \*\/ \/\/ either"/);
  assert.match(css, /url\(data:image\/png;base64,AA\/\/BB==\)/);
  assert.match(css, /\.b\/\*\*\/\.c/, 'between two tokens with no space beside it, a comment is kept: taken out, it would join them');
  assert.equal(css.split('\n').length, STYLE.split('\n').length);
});

test('vendor/ and the other files are embedded as they are; a file it can’t be sure of is embedded whole, and said', () => {
  const vendored = '/* COMMENT a vendored file keeps everything */\nexport const v = 1;\n';
  const unsure = 'export const x = `never closed // COMMENT\n';
  const { embedded, said } = embed({ ...PAGE, 'vendor/lib.mjs': vendored, 'js/unsure.js': unsure, 'data.json': '{"a": "// b"}' });
  assert.equal(embedded['vendor/lib.mjs'], vendored);
  assert.equal(embedded['js/unsure.js'], unsure);
  assert.equal(embedded['data.json'], '{"a": "// b"}');
  assert.equal(embedded['index.html'], PAGE['index.html']);
  assert.match(said, /bytes of comments left out/);
  assert.match(said, /js\/unsure\.js embedded whole/);
});
