// The Team tab's records that need no page (views/records.js): a closed question's line and what opens under it, as the
// Mac's ClosedQuestionList says them, and the Files line. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { questionLine, questionDetail, filesLine } from '../js/views/records.js';

test('a closed question reads as the Mac’s list: its first line and what it closed with', () => {
  assert.deepEqual(questionLine({ state: 'answered', text: 'Which colour?\nThe hero needs one.', answer: 'blue' }), { gist: 'Which colour?', outcome: '→ blue', withdrawn: false });
  assert.deepEqual(questionLine({ state: 'autoDecided', text: 'Name it Parser?', proposal: 'Parser', answer: null }), { gist: 'Name it Parser?', outcome: '→ Parser', withdrawn: false });
  assert.deepEqual(questionLine({ state: 'withdrawn', text: 'Rename it?', answer: null }), { gist: 'Rename it?', outcome: null, withdrawn: true });
  const long = questionLine({ state: 'answered', text: 'Q', answer: 'a'.repeat(50) });
  assert.equal(long.outcome, '→ ' + 'a'.repeat(34) + '…');
  assert.deepEqual(questionDetail({ state: 'withdrawn', why: 'Settled by the spec.' }), ['Withdrawn by the lead.', 'Why: Settled by the spec.']);
  assert.deepEqual(questionDetail({ state: 'autoDecided', proposal: 'Parser', answer: 'Reader' }), ['No answer in time: the lead went ahead with Parser; you answered later: Reader.']);
  assert.deepEqual(questionDetail({ state: 'answered', answer: 'blue', reworded: true }), ['Answered → blue', 'It was reworded after you answered.']);
});

test('the files line says where the lead keeps them, the home as ~', () => {
  assert.equal(filesLine({ root: '/home/u/site', recordsDir: 'docs/lead' }, '/home/u'),
    'workflow.md is kept in ~/site/.vibeswitcher (not committed); decisions.md, progress.md and incidents.md in ~/site/docs/lead, committed to the lead’s branch.');
  assert.equal(filesLine({ root: '/srv/site', recordsDir: null }, '/home/u'), 'Kept in /srv/site/.vibeswitcher (not committed).');
});
