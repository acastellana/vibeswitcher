#!/bin/bash
# The web page's files embedded in the server (the live plan's LW-D9): every file of WebApp/ the page loads, as base64
# with its SHA-256, in Sources/VibeNode/Web/WebAssets.generated.swift, which EmbeddedAssets serves. The user's node
# reads no web file from disk. WebAssetsTests.theEmbeddedFilesAreWebAppsToday fails while the checked-in file isn't
# what this makes of WebApp/ today. Only the integrator commits a new one, at each merge of WebApp/: no lane does, so
# no two lanes conflict in it. A scratch server serves a folder instead (--test-web-root=), with no step between.
#
# Left out: dotfiles, Markdown and shell scripts (the folder's notes and tools), LICENSE* (vendor/'s licences), shots/
# (screenshots), test/ and tests/ (Node's tests of the page), wire/vectors.json (those tests' data), and js/mock.js
# (`?mock`'s invented node, which app.js imports only then: WebApp/serve.sh serves it, the node's page doesn't). Refused, naming the file: an SVG, an HTML file but index.html and bench/bench.html,
# a type outside the content-type table (WebAssets.swift's, which the two must agree with), a name with a character
# outside [A-Za-z0-9._/-], a link, anything not a plain file.
# Reproducible: paths sorted in bytes (LC_ALL=C), base64 in lines of 76, no date and no machine's name in it.
#
# Comments are left out of the page's own scripts and style sheet (.js, .mjs, .css; vendor/ is embedded as it is, its
# licences in it), where that is sure: the step below (Node, which the page's tests need too) reads each file as
# tokens, so nothing inside a string, a template or a regular expression is touched, and a comment becomes nothing or
# the line breaks it held, so a line in the browser's console is the same line in WebApp/. A file it can't be sure of
# is embedded whole, said on stderr. WebApp/tests/embed.test.mjs holds literals with // and /* in them unchanged.
#
# scripts/webapp-embed.sh [--root DIR] [--out FILE]
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."

root=WebApp
out=Sources/VibeNode/Web/WebAssets.generated.swift
while (($#)); do
    case $1 in
        --root) root=${2:?--root takes a folder}; shift 2 ;;
        --out) out=${2:?--out takes a file}; shift 2 ;;
        *) echo "webapp-embed.sh: unknown argument $1 (--root DIR, --out FILE)" >&2; exit 64 ;;
    esac
done
[[ -d $root ]] || { echo "webapp-embed.sh: $root isn't a folder" >&2; exit 66; }

refuse() { echo "webapp-embed.sh: refused $1: $2" >&2; exit 65; }

command -v node > /dev/null || { echo "webapp-embed.sh: node isn't on the PATH (it strips the page's comments; its tests need it too)" >&2; exit 69; }
source scripts/lib/scratch.sh

if command -v sha256sum > /dev/null; then sha() { sha256sum < "$1" | cut -d' ' -f1; }
else sha() { shasum -a 256 < "$1" | cut -d' ' -f1; }; fi

# Every path under the root but what's left out, sorted in bytes.
paths=()
while IFS= read -r path; do paths+=("${path#./}"); done < <(
    cd "$root" && find . -mindepth 1 \( -name '.*' -o -path ./shots -o -path ./test -o -path ./tests -o -path ./wire/vectors.json -o -path ./js/mock.js \) -prune \
        -o ! -type d ! -name '*.md' ! -name '*.sh' ! -name 'LICENSE*' -print | sort)

# Every refusal first, before anything is read or written.
strippable=()
for path in "${paths[@]}"; do
    file=$root/$path
    [[ -L $file ]] && refuse "$path" "a link"
    [[ -f $file ]] || refuse "$path" "not a plain file"
    [[ $path =~ ^[A-Za-z0-9._/-]+$ ]] || refuse "$path" "a character outside [A-Za-z0-9._/-] in its name"
    case $path in
        *.svg) refuse "$path" "no SVG is served (it can run script)" ;;
        index.html | bench/bench.html) ;;
        *.html) refuse "$path" "no HTML but index.html and bench/bench.html" ;;
        *.js | *.mjs | *.css | *.json | *.webmanifest | *.png | *.ico | *.woff2) ;;
        *) refuse "$path" "its type isn't in the content-type table (WebAssets.contentTypes)" ;;
    esac
    case $path in
        vendor/*) ;;
        *.js | *.mjs | *.css) strippable+=("$path") ;;
    esac
done

# index.html's preload list (D26, kept to app.js's imports by WebApp/tests/preload.test.mjs) names files embedded here:
# a name that isn't would be a 404 at every load.
if [[ -f $root/index.html ]]; then
    while IFS= read -r href; do
        found=""
        for path in "${paths[@]}"; do [[ $path == "$href" ]] && found=1 && break; done
        [[ -n $found ]] || refuse index.html "its modulepreload $href isn't a file embedded here"
    done < <(grep -o '<link rel="modulepreload" href="[^"]*"' "$root/index.html" | sed 's/.*href="//; s/"$//')
fi

mkdir -p "$(dirname "$out")"
# The stripped files, beside the output while it is made, and gone after (Ctrl-C too).
stage=$out.stripped.$$
on_exit "rm -rf $(printf '%q' "$stage")"
IFS= read -r -d '' strip <<'JS' || true
const fs = require('fs'); const path = require('path'); const vm = require('vm');
const [root, stage, ...paths] = process.argv.slice(1);
const WORD = /[A-Za-z0-9_$\u0080-￿]/;
const KEYWORDS = new Set('return typeof instanceof in of new delete void throw case do else yield await'.split(' '));
// { comments: [[from, to]], literals: [text] }, or null where the file doesn't read to its end.
function scan(src, css, parenRegex) {
  const comments = []; const literals = []; const braces = []; const n = src.length;
  let i = 0; let last = '';
  // Where a / starts a regular expression: 'yes', 'no', or after ")" or "}" what this reading prefers ('maybe' or 'no').
  const regexHere = () => (!last || last === 'keyword' ? 'yes' : last === ')' ? (parenRegex ? 'maybe' : 'no')
    : last === '}' ? (parenRegex ? 'no' : 'maybe') : ['word', ']'].includes(last) ? 'no' : 'yes');
  // The end of a regular expression from `from`, or -1: one never spans a line.
  const regexEnd = (from) => {
    let j = from + 1; let inClass = false;
    while (j < n && (inClass || src[j] !== '/')) { if (src[j] === '\\') j++; else if (src[j] === '[') inClass = true; else if (src[j] === ']') inClass = false; if (src[j] === '\n') return -1; j++; }
    if (j >= n) return -1;
    j++; while (j < n && /[a-z]/i.test(src[j])) j++;
    return j;
  };
  const quoted = (from, quote) => { let j = from + 1; while (j < n && src[j] !== quote) { if (src[j] === '\\') j++; else if (src[j] === '\n') return -1; j++; } return j < n ? j + 1 : -1; };
  while (i < n) {
    const c = src[i];
    if (c === '/' && src[i + 1] === '*') { const j = src.indexOf('*/', i + 2); if (j < 0) return null; comments.push([i, j + 2]); i = j + 2; continue; }
    if (!css && c === '/' && src[i + 1] === '/') { const j = src.indexOf('\n', i); comments.push([i, j < 0 ? n : j]); i = j < 0 ? n : j; continue; }
    if (c === '"' || c === "'") { const j = quoted(i, c); if (j < 0) return null; literals.push(src.slice(i, j)); i = j; last = 'word'; continue; }
    if (css && /^url\(/i.test(src.slice(i, i + 4)) && !/^url\(\s*['"]/i.test(src.slice(i, i + 40))) {
      const j = src.indexOf(')', i); if (j < 0) return null; literals.push(src.slice(i, j + 1)); i = j + 1; continue;
    }
    if (!css && (c === '`' || (c === '}' && braces.at(-1) === 0))) {
      if (c === '}') braces.pop();
      let j = i + 1; while (j < n && src[j] !== '`' && !(src[j] === '$' && src[j + 1] === '{')) { if (src[j] === '\\') j++; j++; }
      if (j >= n) return null;
      literals.push(src.slice(i, j + 1));
      if (src[j] === '`') { i = j + 1; last = 'word'; } else { braces.push(0); i = j + 2; last = '('; }
      continue;
    }
    if (!css && c === '/') {
      const here = regexHere();
      const j = here === 'no' ? -1 : regexEnd(i);
      // Where it may be either, one that can't end on its line divides.
      if (here === 'yes' && j < 0) return null;
      if (j < 0) { last = '/'; i++; continue; }
      literals.push(src.slice(i, j)); i = j; last = 'word'; continue;
    }
    if (WORD.test(c)) { let j = i; while (j < n && WORD.test(src[j])) j++; last = KEYWORDS.has(src.slice(i, j)) ? 'keyword' : 'word'; i = j; continue; }
    if (/\s/.test(c)) { i++; continue; }
    if (braces.length && c === '{') braces[braces.length - 1]++;
    if (braces.length && c === '}') braces[braces.length - 1]--;
    last = c; i++;
  }
  return braces.length ? null : { comments, literals };
}
const kept = (text) => text.startsWith('/*!') || /@license|@preserve/.test(text);
function strip(src, css, comments) {
  let out = ''; let at = 0;
  for (const [from, to] of comments) {
    const text = src.slice(from, to);
    const before = src[from - 1] ?? '\n'; const after = src[to] ?? '\n';
    const breaks = text.replace(/[^\n]/g, '');
    if (kept(text) || (css && !breaks && !/\s/.test(before) && !/\s/.test(after))) { out += src.slice(at, to); at = to; continue; }
    let head = src.slice(at, from);
    // The spaces before it go too where a line break follows: what was a comment's line is an empty line.
    if (breaks || after === '\n') head = head.replace(/[ \t]+$/, '');
    out += head + (breaks || (!css && !/\s/.test(before) && !/\s/.test(after) ? ' ' : ''));
    at = to;
  }
  return out + src.slice(at);
}
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const parses = (code) => { if (!vm.SourceTextModule) return null; try { new vm.SourceTextModule(code); return true; } catch { return false; } };
let saved = 0;
for (const file of paths) {
  const css = file.endsWith('.css');
  const src = fs.readFileSync(path.join(root, file), 'utf8');
  const whole = (why) => process.stderr.write(`webapp-embed.sh: ${file} embedded whole: ${why}\n`);
  const one = scan(src, css, false); const other = css ? one : scan(src, css, true);
  if (!one || !other) { whole("it doesn't read to its end as tokens"); continue; }
  if (!same(one.comments, other.comments)) { whole('a / that may divide or start a regular expression changes what is a comment'); continue; }
  if (!one.comments.length) continue;
  const out = strip(src, css, one.comments);
  const again = scan(out, css, false); const againOther = css ? again : scan(out, css, true);
  const left = (read) => read.comments.map(([from, to]) => out.slice(from, to));
  if (!again || !againOther || !same(again.literals, one.literals) || !same(againOther.literals, other.literals)
    || ![again, againOther].every((read) => left(read).every((text) => kept(text) || css))) {
    whole('read again stripped, its literals or comments differ'); continue;
  }
  if (!css && parses(src) === true && parses(out) !== true) { whole('stripped, it no longer parses'); continue; }
  fs.mkdirSync(path.dirname(path.join(stage, file)), { recursive: true });
  fs.writeFileSync(path.join(stage, file), out);
  saved += Buffer.byteLength(src) - Buffer.byteLength(out);
}
process.stdout.write(String(saved));
JS
saved=0
if ((${#strippable[@]})); then
    saved=$(node --experimental-vm-modules --no-warnings -e "$strip" -- "$root" "$stage" "${strippable[@]}") || { echo "webapp-embed.sh: stripping the comments failed" >&2; exit 70; }
fi

body=""
for path in "${paths[@]}"; do
    file=$root/$path
    [[ -f $stage/$path ]] && file=$stage/$path
    hash=$(sha "$file")
    # A line of exactly 40 base64 characters reads as an AWS secret key to SecretShapeLint: such a line (a file's
    # last, unpadded) is split in two. The decoder ignores the newline (`.ignoreUnknownCharacters`).
    encoded=$(base64 < "$file" | tr -d '\n' | fold -w 76 | awk 'length($0) == 40 { print substr($0, 1, 20); print substr($0, 21); next } { print }' | sed 's/^/            /')
    body+="        EmbeddedAssets.File(path: \"$path\", sha256: \"$hash\", base64: \"\"\"
$encoded
            \"\"\"),
"
done

# Written beside it, then moved over it: never half a file. Every refusal is above, before anything is written.
partial=$out.partial.$$
{
    echo "// Generated by scripts/webapp-embed.sh from WebApp/: don't edit it, run the script. Only the integrator commits it"
    echo "// (the live plan's LW-D9); WebAssetsTests.theEmbeddedFilesAreWebAppsToday fails while it is stale."
    echo
    echo "extension EmbeddedAssets {"
    echo "    static let embedded: [File] = ["
    printf '%s' "$body"
    echo "    ]"
    echo "}"
} > "$partial" || { rm -f "$partial"; exit 74; }
mv "$partial" "$out" || { rm -f "$partial"; exit 74; }
echo "webapp-embed.sh: ${#paths[@]} files from $root in $out, $saved bytes of comments left out"
