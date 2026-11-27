// The first load asks for every module at once (D26, a cold load on a slow link): index.html lists a
// `<link rel="modulepreload">` for each module app.js imports, directly or through others (its static imports), and
// nothing else: not app.js itself, not what is imported only on demand (xterm.js and its add-ons with a terminal, the
// mock with ?mock). The page's policy stays as strict as it was: the same meta policy, no inline script or style.
// Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { join, dirname, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const html = readFileSync(join(root, 'index.html'), 'utf8');
const read = (file) => readFileSync(join(root, file), 'utf8');

// A module's static imports and re-exports (`import … from './x.js'`, `import './x.js'`, `export … from`), as paths
// under WebApp/; and its on-demand ones (`import('./x.js')`).
const staticImports = (file) => [...read(file).matchAll(/^\s*(?:import|export)\s[^'"`;]*?from\s*['"]([^'"]+)['"]|^\s*import\s*['"]([^'"]+)['"]/gm)]
  .map((match) => normalize(join(dirname(file), match[1] || match[2])));
const dynamicImports = (file) => [...read(file).matchAll(/import\(\s*['"]([^'"]+)['"]\s*\)/g)].map((match) => normalize(join(dirname(file), match[1])));

function closure(start) {
  const seen = new Set([start]);
  const queue = [start];
  while (queue.length) for (const next of staticImports(queue.shift())) if (!seen.has(next)) { seen.add(next); queue.push(next); }
  seen.delete(start);
  return seen;
}
const preloads = [...html.matchAll(/<link rel="modulepreload" href="([^"]+)">/g)].map((match) => match[1]);

test('D26: index.html preloads exactly the modules app.js imports, sorted, once each', () => {
  const wanted = [...closure('app.js')].sort();
  assert.ok(wanted.length > 40, `${wanted.length} modules`);
  assert.deepEqual(preloads, wanted,
    `index.html's modulepreload list is stale; it should read:\n${wanted.map((file) => `<link rel="modulepreload" href="${file}">`).join('\n')}`);
  assert.equal(new Set(preloads).size, preloads.length);
  for (const file of preloads) assert.ok(existsSync(join(root, file)), file);
});

test('D26: nothing loaded on demand is preloaded: xterm.js and its add-ons, the mock', () => {
  const onDemand = new Set([...closure('app.js'), 'app.js'].flatMap(dynamicImports));
  for (const file of ['vendor/xterm.mjs', 'vendor/addon-fit.mjs', 'vendor/addon-search.mjs', 'js/mock.js']) assert.ok(onDemand.has(file), `${file} is loaded on demand`);
  for (const file of onDemand) assert.ok(!preloads.includes(file), `${file} is preloaded`);
  assert.ok(!preloads.includes('app.js'), 'app.js is the page’s script, asked for by its own tag');
});

test('D26: the page’s policy and its one script are as they were: no inline code, no remote file', () => {
  assert.ok(html.includes(`<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' blob:; font-src 'self'; connect-src 'self'; manifest-src 'self'; worker-src 'self'; base-uri 'none'; form-action 'none'; require-trusted-types-for 'script'; trusted-types 'none'">`));
  assert.deepEqual([...html.matchAll(/<script\b[^>]*>/g)].map((match) => match[0]), ['<script type="module" src="app.js">']);
  assert.ok(!/<style\b|\sstyle="|\son[a-z]+="/i.test(html), 'no inline style or handler');
  for (const match of html.matchAll(/\s(?:href|src)="([^"]+)"/g)) assert.ok(!/^[a-z]+:|^\/\//i.test(match[1]), match[1]);
});
