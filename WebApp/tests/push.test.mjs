// The push a lead asks for, as the page shows it: what goes where, its commits, and the two lines that settle it in a
// terminal, the folder quoted as one shell word. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { pushLines } from '../js/push.js';

const push = { id: '3c9e1f20', commit: 'c'.repeat(40), short: 'cccccccc', branch: 'main', remote: 'origin', target: 'origin/main',
  url: 'git@example.invalid:r.git', ahead: 3, subjects: ['ccccccc One', 'ddddddd Two'], askedAt: '2026-11-20T09:00:00.000Z' };

test('a push request reads as what goes where, with the lines that push and decline it', () => {
  const said = pushLines(push, '/home/dev/projects/example-site');
  assert.equal(said.what, 'main at cccccccc, 3 commits ahead of origin/main');
  assert.equal(said.url, 'git@example.invalid:r.git');
  assert.deepEqual(said.subjects, ['ccccccc One', 'ddddddd Two']);
  assert.equal(said.more, 1, 'the commits the request lists fewer of');
  assert.equal(said.push, 'vibeswitcher push /home/dev/projects/example-site');
  assert.equal(said.decline, 'vibeswitcher decline-push /home/dev/projects/example-site');
});

test('a folder that needs quoting is one shell word, and nothing is said with no request', () => {
  const said = pushLines({ ...push, ahead: 1, subjects: ['ccccccc One'] }, "/home/dev/it's here; rm -rf x");
  assert.equal(said.push, `vibeswitcher push '/home/dev/it'\\''s here; rm -rf x'`);
  assert.equal(said.what, 'main at cccccccc, 1 commit ahead of origin/main');
  assert.equal(said.more, 0);
  assert.equal(pushLines(null, '/r'), null);
  assert.equal(pushLines(push, null), null);
});
