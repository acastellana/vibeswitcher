// Push-to-talk dictation (js/dictate.js): found only where the browser recognises speech, off until turned on, each
// final phrase put into the box at the caret with a space where words would run together, interim ones left. It fills
// the box only. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { recognizer, dictationOn, setDictation, insertSpoken, finalWords } from '../js/dictate.js';

const storage = () => { const kept = new Map(); return { getItem: (key) => kept.get(key) ?? null, setItem: (key, value) => kept.set(key, value) }; };

test('the browser’s recognition, by either name; none in Firefox', () => {
  class Recognition {}
  assert.equal(recognizer({ SpeechRecognition: Recognition }), Recognition);
  assert.equal(recognizer({ webkitSpeechRecognition: Recognition }), Recognition);
  assert.equal(recognizer({}), null);
});

test('off until turned on in this browser, and told to the open boxes', () => {
  const kept = storage();
  const events = [];
  const target = { dispatchEvent: (event) => events.push(event.type) };
  assert.equal(dictationOn(kept), false);
  setDictation(true, kept, target);
  assert.equal(dictationOn(kept), true);
  setDictation(false, kept, target);
  assert.equal(dictationOn(kept), false);
  assert.deepEqual(events, ['vibeswitcher-dictation', 'vibeswitcher-dictation']);
  assert.equal(dictationOn({ getItem() { throw new Error('blocked'); } }), false, 'a private window: off');
});

test('what was said goes in at the caret, a space between it and the words either side', () => {
  assert.deepEqual(insertSpoken('', 0, 0, ' ship it '), { value: 'ship it', caret: 7 });
  assert.deepEqual(insertSpoken('Please', 6, 6, 'ship it'), { value: 'Please ship it', caret: 14 });
  assert.deepEqual(insertSpoken('Please today', 6, 6, 'ship it'), { value: 'Please ship it today', caret: 14 });
  assert.deepEqual(insertSpoken('Please X today', 7, 8, 'ship it'), { value: 'Please ship it today', caret: 14 }, 'over the selection');
  assert.deepEqual(insertSpoken('Hi', 2, 2, '   '), { value: 'Hi', caret: 2 }, 'nothing said: nothing changes');
});

test('only the final phrases, from the event’s first new result', () => {
  const result = (transcript, isFinal) => Object.assign([{ transcript }], { isFinal });
  const event = { resultIndex: 1, results: [result('old', true), result('ship it', true), result('and then', false)] };
  assert.equal(finalWords(event), 'ship it');
  assert.equal(finalWords({ resultIndex: 0, results: [result('maybe', false)] }), '');
});
