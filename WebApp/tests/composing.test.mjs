// The page's composer (the composer's lane, 2026-11-20): the word at the caret that asks for completion, as the app's
// composer finds it; a completion taken into the box; an image in the parts `session.attach` takes, each under a page's
// 64 KiB message; and a draft that names its images. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tokenAt, accept, parts, base64, PART } from '../js/composing.js';
import { createStore } from '../js/store.js';
import { presetChosen } from '../js/views/drive.js';
import { validate } from '../wire/validators.js';

const vectors = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'wire', 'vectors.json'), 'utf8'));

test('a slash at the start and an at-sign anywhere ask for completion; other words do not', () => {
  assert.deepEqual(tokenAt('/comp', 5), { kind: 'slash', query: 'comp', start: 0, end: 5 });
  assert.deepEqual(tokenAt('/', 1), { kind: 'slash', query: '', start: 0, end: 1 });
  assert.equal(tokenAt('run /comp', 9), null, 'a slash command is the message’s first word');
  assert.deepEqual(tokenAt('look at @src/lo', 15), { kind: 'mention', query: 'src/lo', start: 8, end: 15 });
  assert.deepEqual(tokenAt('see @a and', 6), { kind: 'mention', query: 'a', start: 4, end: 6 }, 'the caret inside the word');
  assert.equal(tokenAt('plain words', 11), null);
  assert.equal(tokenAt('ends with a space ', 18), null);
  assert.equal(tokenAt('x', 5), null);
});

test('a completion replaces the word and leaves the caret after it', () => {
  assert.deepEqual(accept('/comp', tokenAt('/comp', 5), '/compact '), { text: '/compact ', caret: 9 });
  const text = 'read @src/lo then';
  assert.deepEqual(accept(text, tokenAt(text, 12), '@src/login.ts '), { text: 'read @src/login.ts then', caret: 19 });
});

test('an image goes in parts the node can take whole', () => {
  const bytes = new Uint8Array(PART * 2 + 10).map((_, i) => i % 251);
  const list = parts(bytes);
  assert.deepEqual(list.map((part) => [part.part, part.parts]), [[0, 3], [1, 3], [2, 3]]);
  const back = Buffer.concat(list.map((part) => Buffer.from(part.data, 'base64')));
  assert.deepEqual(new Uint8Array(back), bytes);
  // Each part's message, with its envelope, is under a page's 64 KiB.
  const message = JSON.stringify({ v: 1, id: '99', kind: 'session.attach', action: crypto.randomUUID(),
    args: { session: 'local:' + crypto.randomUUID(), upload: crypto.randomUUID(), type: 'image/png', ...list[0] } });
  assert.ok(message.length < 64 * 1024, `${message.length} bytes`);
  assert.equal(parts(new Uint8Array(3)).length, 1);
  assert.equal(base64(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])), 'iVBORw0KGgo=');
});

test('the store sends an image part by part, then a draft that names it', async () => {
  const store = createStore();
  const sent = [];
  const session = vectors['session.attach'][0].args.session;
  store.connect({
    request(message) {
      sent.push(message);
      if (message.kind === 'session.attach') {
        const last = message.args.part + 1 === message.args.parts;
        return Promise.resolve({ ok: true, result: { session, received: message.args.part + 1, ...(last ? { path: '/n/attachments/pasted-x.png' } : {}) } });
      }
      return Promise.resolve({ ok: true, result: { session, applied: { sessions: 1 } } });
    },
  });
  store.apply({ kind: 'snapshot', epoch: 'e', seq: 1, state: { sessions: [{ id: session, hosted: true, draft: null, queued: [] }] } });
  const reply = await store.attach(session, new Uint8Array(PART + 1), 'image/png');
  assert.equal(reply.result.path, '/n/attachments/pasted-x.png');
  assert.deepEqual(sent.map((m) => [m.kind, m.args.part, m.args.parts]), [['session.attach', 0, 2], ['session.attach', 1, 2]]);
  assert.equal(new Set(sent.map((m) => m.args.upload)).size, 1, 'one upload id for its parts');
  assert.ok(sent.every((m) => m.action), 'each part an action');
  for (const message of sent) assert.equal(validate('session.attach.args', message.args), null);

  store.sessionDraft(session, 'What is this?', [reply.result.path]);
  assert.deepEqual(store.sessionDraftOf(session), { text: 'What is this?', images: ['/n/attachments/pasted-x.png'], now: false, sending: true, mine: true });
  const draft = sent.at(-1);
  assert.equal(draft.kind, 'session.draft');
  assert.deepEqual(draft.args.images, ['/n/attachments/pasted-x.png']);
  assert.equal(validate('session.draft.args', draft.args), null);

  const read = sent.length;
  await store.read('session.complete', { session, kind: 'mention', query: 'lo' });
  assert.equal(sent[read].action, undefined, 'a read carries no action id');
});

test('a send-now draft asks the node to steer, and shows so here and from the node', async () => {
  const store = createStore();
  const sent = [];
  const session = vectors['session.attach'][0].args.session;
  store.connect({ request(message) { sent.push(message); return new Promise(() => {}); } });
  store.apply({ kind: 'snapshot', epoch: 'e', seq: 1, state: { sessions: [{ id: session, hosted: true, draft: null, queued: [] }] } });
  store.sessionDraft(session, 'Stop and read the logs', [], true);
  assert.deepEqual(sent.at(-1).args, { session, text: 'Stop and read the logs', now: true });
  assert.equal(validate('session.draft.args', sent.at(-1).args), null);
  assert.equal(store.sessionDraftOf(session).now, true);
  store.sessionDraft(session, 'After the turn');
  assert.deepEqual(sent.at(-1).args, { session, text: 'After the turn' }, 'no now unless asked');
  assert.equal(store.sessionDraftOf(session).now, false);

  // Left on another page: the node's value says it.
  const other = createStore();
  other.apply({ kind: 'snapshot', epoch: 'e', seq: 1, state: { sessions: [{ id: session, hosted: true, queued: [],
    draft: { text: 'Now', images: [], at: '2026-11-20T10:00:00Z', action: 'a', now: true } }] } });
  assert.equal(other.sessionDraftOf(session).now, true);
});

test('a preset the node refuses is never the form’s default, a built-in’s name taken by a project’s included', () => {
  const presets = [
    { name: 'Claude', kind: 'claude', default: true, refused: 'its name is a built-in preset’s (Claude), which it would stand in for: rename it' },
    { name: 'Opus', kind: 'claude', refused: null },
    { name: 'Claude', kind: 'claude', refused: null },
  ];
  assert.equal(presetChosen(presets, 'Claude', false), 'Opus');
  assert.equal(presetChosen(presets, 'Claude', true), 'Claude', 'picked, a Claude the node can start is there');
  assert.equal(presetChosen([{ name: 'Shell', refused: 'x' }, { name: 'Tests', refused: null }], 'Shell', true), 'Tests');
});
