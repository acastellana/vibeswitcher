// Acting at the `confirm` level from the page's side (js/passkey.js, the store's challenge, the socket's offer): the
// browser's WebAuthn faked, the node a fake feed that answers as the wire says.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { toB64url, fromB64url, createOptions, getOptions, register } from '../js/passkey.js';
import { createStore } from '../js/store.js';
import { connectSocket } from '../js/socket.js';
import { refusalWords, pageMaySet } from '../js/acting.js';
import { setLanguage } from '../js/i18n.js';

setLanguage('en');
const vectors = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', 'wire', 'vectors.json'), 'utf8'));
const bytes = (...values) => new Uint8Array(values).buffer;
const b64 = (...values) => toB64url(bytes(...values));

test('base64url both ways, without padding', () => {
  for (const length of [0, 1, 2, 3, 4, 31, 32, 33]) {
    const made = new Uint8Array(length).map((_, i) => (i * 37 + 250) % 256);
    const text = toB64url(made);
    assert.equal(/[+/=]/.test(text), false);
    assert.deepEqual(new Uint8Array(fromB64url(text)), made);
  }
});

test('the node’s offer and challenge become WebAuthn’s options: bytes where it wants bytes, ES256 only, user verification', () => {
  const offer = { register: 'r1', challenge: b64(1, 2, 3), rp: { id: 'localhost', name: 'VibeSwitcher' }, user: { id: b64(9, 9), name: 'vibeswitcher', displayName: 'VibeSwitcher on this machine' }, exclude: [b64(7)] };
  const made = createOptions(offer);
  assert.deepEqual(new Uint8Array(made.challenge), new Uint8Array([1, 2, 3]));
  assert.deepEqual(new Uint8Array(made.user.id), new Uint8Array([9, 9]));
  assert.deepEqual(made.pubKeyCredParams.map((param) => param.alg), [-7]);
  assert.equal(made.authenticatorSelection.userVerification, 'required');
  assert.equal(made.attestation, 'none');
  assert.deepEqual(new Uint8Array(made.excludeCredentials[0].id), new Uint8Array([7]));
  const got = getOptions({ challenge: b64(4), allow: [b64(5, 6)], rpId: 'localhost', timeout: 60000 });
  assert.equal(got.rpId, 'localhost');
  assert.equal(got.userVerification, 'required');
  assert.deepEqual(new Uint8Array(got.allowCredentials[0].id), new Uint8Array([5, 6]));
});

// A store on a fake feed whose answers are `answer(message)`; every message it was sent.
function storeOn(answer, credentials) {
  const store = createStore({ credentials });
  const sent = [];
  store.connect({ request: (message) => { sent.push(structuredClone(message)); return Promise.resolve(answer(message, sent)); } });
  return { store, sent };
}
const challenge = { challenge: b64(1, 2, 3), allow: [b64(5, 6)], rpId: 'localhost', timeout: 60000, line: 'Tell the lead of example-app: hi' };
const credential = { rawId: bytes(5, 6), response: { clientDataJSON: bytes(1), authenticatorData: bytes(2), signature: bytes(3) } };

test('at confirm an acting request asks the passkey over exactly that request, shows its line, and goes again with the assertion', async () => {
  let shown = null;
  const credentials = { get: async (options) => { shown = store.state.confirming?.line; assert.deepEqual(new Uint8Array(options.publicKey.challenge), new Uint8Array([1, 2, 3])); return credential; } };
  const { store, sent } = storeOn((message) => {
    if (message.kind === 'act.challenge') return { v: 1, re: message.id, ok: true, result: challenge };
    if (!message.assertion) return { v: 1, re: message.id, ok: false, error: { code: 'assertion-needed', message: 'a passkey, please' } };
    return { v: 1, re: message.id, ok: true, result: {}, recorded: 'Told the lead of example-app: hi (from the page, passkey 0a1b2c3d4e5f)' };
  }, credentials);
  const reply = await store.request('tell', { folder: '/f', text: 'hi' });
  assert.equal(reply.ok, true);
  const [first, asked, again] = sent;
  assert.deepEqual(asked.args, { kind: 'tell', args: { folder: '/f', text: 'hi' }, action: first.action }, 'the challenge is over exactly the request');
  assert.equal(asked.action, undefined, 'the challenge itself is a read');
  assert.equal(again.action, first.action, 'the same action');
  assert.deepEqual(again.args, first.args);
  assert.deepEqual(again.assertion, { id: b64(5, 6), clientDataJSON: b64(1), authenticatorData: b64(2), signature: b64(3) });
  assert.equal(shown, challenge.line, 'the line shown while the browser asks');
  assert.equal(store.state.confirming, null);
  assert.match(store.state.recorded.line, /^Told the lead/);
});

test('a passkey not given sends nothing more and says so; a failed check is the node’s `passkey`', async () => {
  const { store, sent } = storeOn((message) => (message.kind === 'act.challenge' ? { v: 1, re: message.id, ok: true, result: challenge }
    : { v: 1, re: message.id, ok: false, error: { code: 'assertion-needed', message: '' } }), { get: async () => { throw new Error('The operation either timed out or was not allowed.'); } });
  const reply = await store.request('tell', { folder: '/f', text: 'hi' });
  assert.equal(reply.error.code, 'passkey-cancelled');
  assert.equal(sent.length, 2, 'the request and its challenge, nothing after');
  assert.equal(store.state.confirming, null);
  assert.equal(refusalWords(reply.error), 'No passkey was given: nothing was done.');
  assert.equal(refusalWords({ code: 'passkey', message: 'That passkey isn’t one of this node’s.' }), 'The passkey check failed: nothing was done. That passkey isn’t one of this node’s.');
});

test('at trust nothing changes: no challenge, no assertion', async () => {
  const { store, sent } = storeOn((message) => ({ v: 1, re: message.id, ok: true, result: {} }), { get: async () => assert.fail('no passkey asked') });
  assert.equal((await store.request('tell', { folder: '/f', text: 'hi' })).ok, true);
  assert.equal(sent.length, 1);
  assert.equal('assertion' in sent[0], false);
});

test('the terminal’s offer to add a passkey: shown, added through the browser, told to the node, ended', async () => {
  const store = createStore({ credentials: { create: async (options) => { assert.equal(options.publicKey.rp.id, 'localhost'); return { rawId: bytes(8, 9, 10, 11, 12), response: { clientDataJSON: bytes(1), attestationObject: bytes(2) } }; } } });
  const sockets = [];
  class FakeSocket {
    constructor() { this.sent = []; this.readyState = 0; sockets.push(this); }
    send(text) { this.sent.push(JSON.parse(text)); }
    close() { this.readyState = 3; this.onclose?.(); }
  }
  const feed = connectSocket(store, {
    url: 'ws://localhost:47830/ws', WebSocket: FakeSocket, storage: { getItem: () => 'token', setItem() {}, removeItem() {} }, validate: () => null,
    build: Promise.resolve(null), setTimeout: () => 0, clearTimeout: () => {}, location: { hash: '', pathname: '/', search: '' }, history: { replaceState() {} }, reload() {}, log: () => {},
  });
  store.connect(feed);
  await feed.start();
  const socket = sockets[0];
  socket.readyState = 1;
  socket.onopen();
  socket.onmessage({ data: JSON.stringify({ ...structuredClone(vectors['hello.web']), auth: { rights: ['read', 'draft', 'watch', 'act'] }, kinds: ['passkey.ask', 'passkey.registered', 'status'] }) });
  // The offer: waiting, no challenge; the clicked tab asks for it.
  const expires = new Date(Date.now() + 300000).toISOString();
  socket.onmessage({ data: JSON.stringify({ v: 1, kind: 'passkey', op: 'waiting', register: 'r1', expires }) });
  assert.deepEqual(store.state.passkeyOffer, { register: 'r1', expires });
  const adding = store.addPasskey(register);
  await new Promise((resolve) => setImmediate(resolve));
  const ask = socket.sent.find((message) => message.kind === 'passkey.ask');
  assert.deepEqual(ask.args, { register: 'r1' });
  assert.equal(ask.action, undefined, 'asked as a read');
  socket.onmessage({ data: JSON.stringify({ v: 1, re: ask.id, ok: true, result: { register: 'r1', challenge: b64(1, 2), rp: { id: 'localhost', name: 'VibeSwitcher' },
    user: { id: b64(3), name: 'vibeswitcher', displayName: 'VibeSwitcher on this machine' }, exclude: [], expires } }) });
  for (let turn = 0; turn < 20 && !socket.sent.some((message) => message.kind === 'passkey.registered'); turn += 1) await new Promise((resolve) => setImmediate(resolve));
  const told = socket.sent.find((message) => message.kind === 'passkey.registered');
  assert.deepEqual(told.args, { register: 'r1', id: b64(8, 9, 10, 11, 12), clientDataJSON: b64(1), attestationObject: b64(2) });
  socket.onmessage({ data: JSON.stringify({ v: 1, re: told.id, ok: true, result: { state: 'received' } }) });
  await adding;
  // The 6 characters to type: this tab's own key's, never the node's.
  assert.deepEqual(store.state.passkeyAdding, { state: 'added', id: b64(8, 9, 10, 11, 12).slice(0, 6) });
  socket.onmessage({ data: JSON.stringify({ v: 1, kind: 'passkey', op: 'ended', register: 'r1' }) });
  assert.equal(store.state.passkeyOffer, null);
});

test('a page may lower acting to a passkey per action, never raise it', () => {
  assert.equal(pageMaySet('web_acts', 'confirm'), true);
  assert.equal(pageMaySet('web_acts', 'off'), true);
  assert.equal(pageMaySet('web_acts', 'trust'), false);
});

test('an authenticator that can’t make an ES256 passkey is said plainly, apart from a cancel', async () => {
  const fail = (name) => createStore({ credentials: { create: async () => { const error = new Error('no'); error.name = name; throw error; } } });
  for (const [name, state] of [['NotSupportedError', 'unsupported'], ['NotAllowedError', 'cancelled']]) {
    const store = fail(name);
    store.setPasskeyOffer({ register: 'r1', challenge: b64(1), rp: { id: 'localhost', name: 'VibeSwitcher' }, user: { id: b64(2), name: 'v', displayName: 'V' } });
    await store.addPasskey(register);
    assert.equal(store.state.passkeyAdding.state, state);
  }
});

test('the ways to send follow the session’s agent, and the note says what the node did, in its words first', async () => {
  const { waysFor, sendArgs, sentWords } = await import('../js/sendways.js');
  assert.deepEqual(waysFor({}), ['step', 'now'], 'until the node lists them');
  assert.deepEqual(waysFor({ sendWays: ['interrupt', 'after', 'step', 'now', 'sideways'] }), ['step', 'now', 'after', 'interrupt']);
  assert.deepEqual(sendArgs({ id: 's1', sendWays: ['step', 'now'] }, 'hi', 'now'), { session: 's1', text: 'hi', when: 'now', now: true }, 'now said the old way too');
  assert.deepEqual(sendArgs({ id: 's1', sendWays: ['interrupt'] }, 'hi', 'interrupt', ['/a.png']), { session: 's1', text: 'hi', when: 'interrupt', images: ['/a.png'] });
  assert.deepEqual(sendArgs({ id: 's1' }, 'hi', 'now'), { session: 's1', text: 'hi', now: true }, 'no `when` to a node that lists no ways');
  assert.deepEqual(sendArgs({ id: 's1' }, 'hi', 'step'), { session: 's1', text: 'hi' });
  assert.equal(sentWords('after', { when: 'step', said: 'Claude Code has no queue for after its turn: sent at its next step.' }), 'Claude Code has no queue for after its turn: sent at its next step.');
  assert.equal(sentWords('now', { when: 'step' }), 'Sent: read at its next step.', 'what was done, not what was asked');
  assert.equal(sentWords('interrupt', { when: 'interrupt' }), 'Interrupted, then sent.');
  assert.equal(sentWords('now', { queued: true, waits: 'a question is open on its screen' }), 'Held: a question is open on its screen. It goes in as soon as that closes.');
});

test('a contested offer (another tab asked first) adds nothing and says so', async () => {
  const store = createStore({ credentials: { create: async () => assert.fail('no passkey made') } });
  store.connect({ request: (message) => Promise.resolve(message.kind === 'passkey.ask'
    ? { v: 1, re: message.id, ok: false, error: { code: 'voice', message: 'another page asked for this offer: it is contested and ended' } } : { v: 1, re: message.id, ok: true, result: {} }) });
  store.setPasskeyOffer({ register: 'r1', expires: null });
  await store.addPasskey(register);
  assert.deepEqual(store.state.passkeyAdding, { state: 'refused', why: 'another page asked for this offer: it is contested and ended' });
});
