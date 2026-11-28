// A reply's code block as the message that runs it (js/runnable.js, the app's RunnableCommand rules): which blocks get
// a Run and exactly what is drafted.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { runnable, hasHidden } from '../js/runnable.js';

test('a one-line shell block is drafted as `! command`', () => {
  assert.deepEqual(runnable('swift test', 'bash'), { command: 'swift test', prompt: '! swift test' });
  assert.equal(runnable('$ npm install', null)?.prompt, '! npm install');
  assert.equal(runnable('npm install', 'bash title="setup"')?.prompt, '! npm install');
});

test('several standalone lines are joined with &&; a console block takes only its prompt lines', () => {
  assert.equal(runnable('npm ci\nnpm test', 'sh')?.prompt, '! npm ci && npm test');
  assert.equal(runnable('$ make\nbuilding…\n$ make install', 'console')?.prompt, '! make && make install');
  assert.equal(runnable('docker run \\\n  --rm image', 'bash')?.prompt, '! docker run --rm image');
});

test('what the app gives no Run gets none: other languages, heredocs, open quotes, compound lines, hidden characters', () => {
  assert.equal(runnable('print(1)', 'python'), null);
  // An untagged block gets Run only where its one line reads as a command (P-s2, below); a sentence gets none.
  assert.equal(runnable('npm test passes now.', null), null);
  assert.equal(runnable('cat <<EOF\nx\nEOF', 'bash'), null);
  assert.equal(runnable('echo "open', 'bash'), null);
  assert.equal(runnable('if true; then\necho y\nfi', 'bash'), null);
  assert.equal(runnable('ls |\nwc -l', 'bash'), null);
  assert.equal(runnable('echo ok' + ' '.repeat(10) + '; rm -rf ~', 'bash'), null);
  for (const hidden of ['‮', '​', '\u001b[2J', ' ', '　', '⠀', 'ㅤ', '️', '͏', '\u{E0100}', '\r']) {
    assert.equal(runnable(`echo a${hidden}b`, 'bash'), null, JSON.stringify(hidden));
    assert.ok(hasHidden(`a${hidden}b`), JSON.stringify(hidden));
  }
  assert.ok(!hasHidden('echo café →\tdone\n'));
});

// P-s2 (main's aa652c58, `RunnableCommand.untagged`): a block with no language whose only line reads as one plain
// command gets Run, drafted as a tagged block's is (Run never sends: the draft waits, and `vibeswitcher send` shows it
// whole and asks for the code); anything else stays without.
test('P-s2: an untagged block whose only line reads as a command gets Run, drafted as a tagged block’s', () => {
  const server = 'cd /Users/me/dev/site/prototype && python3 -m http.server 8000';
  const commands = [
    server, 'python3 -m http.server 8000', 'npm run dev', 'git status', 'swift test --filter Foo',
    './serve.sh --port 3000', '../bin/start', '~/bin/dev-server', '/usr/bin/env python3 app.py',
    'scripts/build-app.sh --install', 'PORT=8080 npm start', 'DEBUG=1 RUST_LOG=info cargo run',
    'make serve', 'ls -la ~/.config/', 'cd ..', 'docker compose up', 'open http://localhost:8000',
    '\n  npx vite --host\n\n', 'vs-shell run -- make serve', 'rm -rf build',
  ];
  for (const code of commands) {
    const run = runnable(code, null);
    assert.equal(run?.command, code.trim(), JSON.stringify(code));
    assert.equal(run?.prompt, '! ' + code.trim(), JSON.stringify(code));
    // The same rule as a tagged block's: what is drafted is exactly what a `bash` block of that line drafts.
    assert.deepEqual(run, runnable(code.trim(), 'bash'), JSON.stringify(code));
  }
  const wide = 'npm run dev -- ' + Array(40).fill('--flag').join(' ');
  assert.equal(runnable(wide, null)?.command, wide);
  assert.equal(runnable('', null), null);
  assert.equal(runnable('   \n', null), null);
});

test('P-s2: untagged lines that don’t read as one command get no Run: prose, output, several lines, open quotes, hidden characters', () => {
  const refused = [
    // Prose, output, a word that isn't a command, a path-looking word that isn't one.
    'some output', 'Hello world', 'make sure the server is running.', 'Run the tests first:',
    'and/or both', 'error: build failed', 'OK', 'Done!', 'cd into the folder, then run it.',
    'Build succeeded', 'README.md', '/', 'x = 1', 'FOO=bar',
    // More than one line.
    'npm install\nnpm run dev', 'cd site\npython3 -m http.server',
    // A comment, a line continued, unbalanced quotes, a heredoc.
    '# python3 -m http.server', 'docker run \\', 'echo "unclosed', 'cat <<EOF',
    // Hidden characters, and a long blank run that pushes the rest off to the side.
    'npm run dev​', 'git status‮', 'echo hi\u001b[2J', 'npm run dev' + ' '.repeat(12) + '&& rm -rf ~',
    'git status\t\t; rm -rf ~',
  ];
  for (const code of refused) assert.equal(runnable(code, null), null, JSON.stringify(code));
  // A language that isn't a shell's still gets none.
  assert.equal(runnable('npm run dev', 'text'), null);
  assert.equal(runnable('python3 -m http.server', 'python'), null);
});
