// What the page runs that this project didn't write (WebApp/vendor/) is what vendor/README.md says it is: each file
// hashes to the SHA-256 its table records, and nothing is there that the table doesn't name. The tarballs' own SHA-512
// against the registry's is recorded there too, checked when they were taken. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const vendor = join(dirname(fileURLToPath(import.meta.url)), '..', 'vendor');
const readme = readFileSync(join(vendor, 'README.md'), 'utf8');
// The file table's rows: | `name` | from | `sha256` |
const recorded = new Map([...readme.matchAll(/^\| `([^`]+)` \| [^|]+ \| `([0-9a-f]{64})` \|$/gm)].map((match) => [match[1], match[2]]));

test('every vendored file hashes to what vendor/README.md records', () => {
  assert.ok(recorded.size >= 4, `the README's table has ${recorded.size} rows`);
  for (const [name, sha] of recorded) {
    const actual = createHash('sha256').update(readFileSync(join(vendor, name))).digest('hex');
    assert.equal(actual, sha, `${name} changed since it was vendored`);
  }
});

test('nothing is vendored that the README doesn’t name', () => {
  const present = readdirSync(vendor).filter((name) => name !== 'README.md').sort();
  assert.deepEqual(present, [...recorded.keys()].sort());
});

test('the README records each tarball’s version and its registry SHA-512', () => {
  for (const [name, version] of [['@xterm/xterm', '6.0.0'], ['@xterm/addon-fit', '0.11.0'], ['@xterm/addon-search', '0.16.0']]) {
    const row = readme.split('\n').find((line) => line.startsWith(`| \`${name}\` |`));
    assert.ok(row, `${name}'s row`);
    assert.match(row, new RegExp(`\\| ${version.replaceAll('.', '\\.')} \\| https://registry\\.npmjs\\.org/\\S+-${version.replaceAll('.', '\\.')}\\.tgz \\| \`sha512-[A-Za-z0-9+/]{86}==\` \\|`));
  }
});
