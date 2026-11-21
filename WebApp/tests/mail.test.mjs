// Between leads on the page (views/mail.js's data, the `mail` kind): the node's vector read in its shape (a page's read:
// its token's `read` right, never a state change), each message said as `vibeswitcher mail` says it, the command that
// lists a project's whole record quoted as the shell needs, the route, and the mock's answer in the node's shape.
// Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validate } from '../wire/validators.js';
import { mailLine, mailCommand } from '../js/mail.js';
import { parseRoute } from '../js/ui.js';
import { createMock } from '../js/mock.js';

const vectors = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'wire', 'vectors.json'), 'utf8'));
const [asked, answered] = structuredClone(vectors.mail);

test('the record between leads is a read a page may ask, in its shape', () => {
  assert.equal(asked.kind, 'mail');
  assert.equal(validate('request', asked), null);
  assert.equal(validate('mail.args', asked.args), null);
  assert.equal(validate('reply.mail', answered), null);
});

test('each message says which way it went, its kind, what became of it, and why when it wasn’t sent', () => {
  const [refused, answer, question] = answered.result.projects[0].messages;
  assert.deepEqual(mailLine(question), { way: 'to the lead of acme-api', kind: 'Question', outcome: 'delivered', text: question.text, why: null, sent: true });
  assert.equal(mailLine(answer).way, 'from the lead of acme-api');
  assert.equal(mailLine(answer).outcome, 'waiting in its inbox');
  assert.equal(mailLine(refused).kind, 'No kind');
  assert.equal(mailLine(refused).why, 'Refused, not sent: the kind is question, report or answer');
});

test('the command that lists every message is quoted for the shell, and Between leads has an address', () => {
  assert.equal(mailCommand('~/acme-site'), 'vibeswitcher mail ~/acme-site --all');
  assert.equal(mailCommand("/home/u/it's here"), "vibeswitcher mail '/home/u/it'\\''s here' --all");
  assert.deepEqual(parseRoute('#/mail'), { name: 'mail' });
});

test('the mock answers mail in the node’s shape', async () => {
  const mock = createMock({ apply() {}, setConnection() {}, chatSnapshot() {} }, { still: true });
  const reply = await mock.request({ v: 1, id: '1', kind: 'mail', args: {} });
  assert.equal(validate('mail.result', reply.result), null);
  assert.ok(reply.result.projects[0].messages.length > 0);
  mock.stop();
});
