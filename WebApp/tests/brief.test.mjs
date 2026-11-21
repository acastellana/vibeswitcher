// Brief me on the page (js/brief.js, the `brief` kind): the node's vector read in its shape (a page's read), the line
// under its words, the browser's speech found or not, and reading aloud stopping what was being read. Run:
// node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validate } from '../wire/validators.js';
import { briefFoot, speech, speak } from '../js/brief.js';
import { createMock } from '../js/mock.js';

const vectors = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'wire', 'vectors.json'), 'utf8'));

test('the briefing is a read a page may ask, in its shape, and the mock answers so too', async () => {
  const [asked, answered] = structuredClone(vectors.brief);
  assert.equal(validate('request', asked), null);
  assert.equal(validate('brief.args', asked.args ?? {}), null);
  assert.equal(validate('reply.brief', answered), null);
  const mock = createMock({ apply() {}, setConnection() {}, chatSnapshot() {} }, { still: true });
  const reply = await mock.request({ v: 1, id: '1', kind: 'brief', args: {} });
  assert.equal(validate('brief.result', reply.result), null);
  mock.stop();
});

test('the line under it says what waits on you and who wrote it', () => {
  assert.equal(briefFoot({ asks: 0, byModel: false }), 'Nothing waits on you. Written from the boards and logs.');
  assert.equal(briefFoot({ asks: 1, byModel: true }), '1 thing waits on you. Written by Claude Haiku from the boards and logs.');
  assert.equal(briefFoot({ asks: 3, byModel: false }), '3 things wait on you. Written from the boards and logs.');
});

test('the browser’s speech: none where it has none; reading stops what was read first, in the briefing’s language', () => {
  assert.equal(speech({}), null);
  const calls = [];
  class Utterance { constructor(text) { this.text = text; } }
  const synth = { cancel: () => calls.push('cancel'), speak: (said) => calls.push(['speak', said.text, said.lang]) };
  const voice = speech({ speechSynthesis: synth, SpeechSynthesisUtterance: Utterance });
  assert.ok(voice);
  let ended = 0;
  const said = speak(voice, 'Two fixes landed.', 'en', () => { ended += 1; });
  assert.deepEqual(calls, ['cancel', ['speak', 'Two fixes landed.', 'en']]);
  said.onend();
  assert.equal(ended, 1);
});
