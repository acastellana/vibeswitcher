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
  assert.equal(runnable('npm test', null), null);
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
