// The design's rule for the web client: what an agent wrote is never markup. No file here may parse a string as HTML
// or run one as code, load anything from another origin, or carry inline script or style; and the page's content
// policy has to say the same. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const scripts = ['app.js', ...readdirSync(join(root, 'js'), { recursive: true }).filter((name) => name.endsWith('.js')).map((name) => join('js', name))];
const read = (name) => readFileSync(join(root, name), 'utf8');
// Comments may name what's forbidden; code may not use it. SVG's namespace is a name, not an address anything loads.
const code = (name) => read(name).split('\n').filter((line) => !line.trim().startsWith('//')).join('\n').replaceAll("'http://www.w3.org/2000/svg'", "''");

const FORBIDDEN = [
  ['innerHTML', /\binnerHTML\b/], ['outerHTML', /\bouterHTML\b/], ['insertAdjacentHTML', /\binsertAdjacentHTML\b/],
  ['document.write', /\bdocument\.write(ln)?\b/], ['DOMParser', /\bDOMParser\b/], ['createContextualFragment', /\bcreateContextualFragment\b/],
  ['setHTML', /\bsetHTML(Unsafe)?\b/], ['srcdoc', /\bsrcdoc\b/], ['eval', /\beval\s*\(/], ['new Function', /\bnew\s+Function\b/],
  ['a string given to a timer', /\bset(Timeout|Interval)\s*\(\s*['"`]/], ['a remote address', /['"`](https?:)?\/\/[a-z0-9]/i],
];

test('no script parses a string as markup, runs one as code, or names another origin', () => {
  const found = [];
  for (const name of scripts) {
    // mock.js invents an agent's output, which may mention an address; it never fetches one.
    for (const [what, pattern] of FORBIDDEN) {
      if (what === 'a remote address' && name === join('js', 'mock.js')) continue;
      if (pattern.test(code(name))) found.push(`${name}: ${what}`);
    }
  }
  assert.deepEqual(found, []);
});

test('the page allows only its own scripts and styles, with Trusted Types and no policy', () => {
  const page = read('index.html');
  const policy = page.match(/http-equiv="Content-Security-Policy" content="([^"]+)"/)?.[1] || '';
  const directives = Object.fromEntries(policy.split(';').map((part) => part.trim().split(/\s+/)).map(([name, ...values]) => [name, values.join(' ')]));
  assert.equal(directives['default-src'], "'none'");
  assert.equal(directives['script-src'], "'self'");
  assert.equal(directives['style-src'], "'self'");
  // `blob:`: a chat's images, their bytes asked of the node (`chat.image`) and shown as object URLs; nothing else.
  assert.equal(directives['img-src'], "'self' blob:");
  assert.equal(directives['require-trusted-types-for'], "'script'");
  assert.equal(directives['trusted-types'], "'none'");
  assert.doesNotMatch(policy, /unsafe|https?:|data:|\*/);
  assert.doesNotMatch(page, /<script(?![^>]*\bsrc=)[^>]*>/, 'an inline script');
  assert.doesNotMatch(page, /\sstyle=|<style\b|\son[a-z]+=/, 'inline style or an inline handler');
  assert.doesNotMatch(page + read('style.css'), /(src|href)="(https?:)?\/\/|url\(|@import/, 'something loaded from elsewhere');
});
