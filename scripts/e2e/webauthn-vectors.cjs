#!/usr/bin/env node
// The WebAuthn vectors of Tests/VibeCoreTests/WebAuthnVectors.swift, made by a real browser engine: headless Chrome's
// virtual authenticator, driven over the DevTools protocol (scripts/e2e/chrome-cdp.cjs's `Protocol` and `Page`). No
// real authenticator, no Keychain, no profile of the user's: Chrome runs on a profile of its own under `--out`, with a
// mock keychain, headless, and the scratch page it opens is served by this script from `--out` on free ports of
// `localhost`. Nothing it does can put a dialog on the screen.
//
//   node scripts/e2e/webauthn-vectors.cjs --out <a scratch folder> [--fixture Tests/VibeCoreTests/WebAuthnVectors.swift]
//
// It writes the fixture (a Swift file holding one JSON document, every byte string in hex) and prints what it measured.
// `$CHROME` names the browser when it isn't at Google Chrome's usual place. What the document holds:
// - `registrations`: each `navigator.credentials.create` answer (clientDataJSON, attestationObject, rawId and Chrome's
//   own `getPublicKey()` SPKI, an independent reading of the key) with what the server expected (challenge, origin,
//   rpId, place) and the outcome the node must reach (`ok`, or the refusal's name).
// - `assertions`: each `navigator.credentials.get` answer (rawId, clientDataJSON, authenticatorData, signature,
//   userHandle), the expectation, the device record it is checked against (credential id, SPKI, enrolled origin, rpId
//   and place, stored sign count, backup eligibility), and the outcome.
// - `shapes`: every distinct shape of clientDataJSON Chrome produced (the challenge and origin replaced by `<c>` and
//   `<o>`), with how many times it was seen, over `--rounds` extra assertions and registrations.
'use strict';
const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const path = require('path');
const { Protocol, killGroup, findChrome } = require('./chrome-cdp.cjs');
const { spawn } = require('child_process');

const args = process.argv.slice(2);
const option = (name, fallback) => { const at = args.indexOf(name); return at >= 0 ? args[at + 1] : fallback; };
const out = option('--out');
const fixture = option('--fixture', path.join('Tests', 'VibeCoreTests', 'WebAuthnVectors.swift'));
const rounds = Number(option('--rounds', '60'));
if (!out) { console.error('usage: webauthn-vectors.cjs --out <scratch folder> [--fixture <file>] [--rounds N]'); process.exit(2); }
fs.mkdirSync(out, { recursive: true });

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const hex = (b64url) => Buffer.from(b64url, 'base64url').toString('hex');
const randomChallenge = () => crypto.randomBytes(32).toString('base64url');

// The scratch page: two helpers the script calls, each answering base64url fields. The page is the same on every port.
const page = String.raw`<!doctype html><meta charset="utf-8"><title>webauthn vectors</title>
<script>
const b64u = (bytes) => btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const unb64u = (text) => Uint8Array.from(atob(text.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - text.length % 4) % 4)), (c) => c.charCodeAt(0));
async function makeCredential(o) {
  const made = await navigator.credentials.create({ publicKey: {
    challenge: unb64u(o.challenge), rp: { id: o.rpId, name: 'vectors' },
    user: { id: unb64u(o.userId), name: o.userName, displayName: o.userName },
    pubKeyCredParams: o.algs.map((alg) => ({ type: 'public-key', alg })),
    authenticatorSelection: { userVerification: o.uv, residentKey: 'required' },
    attestation: 'none', timeout: 20000 } });
  let spki = null; try { spki = made.response.getPublicKey() ? b64u(made.response.getPublicKey()) : null; } catch (e) { spki = null; }
  return { rawId: b64u(made.rawId), clientDataJSON: b64u(made.response.clientDataJSON),
    attestationObject: b64u(made.response.attestationObject), spki, alg: made.response.getPublicKeyAlgorithm() };
}
async function getAssertion(o) {
  const got = await navigator.credentials.get({ publicKey: {
    challenge: unb64u(o.challenge), rpId: o.rpId, userVerification: o.uv, timeout: 20000,
    allowCredentials: (o.allow || []).map((id) => ({ type: 'public-key', id: unb64u(id) })) } });
  return { rawId: b64u(got.rawId), clientDataJSON: b64u(got.response.clientDataJSON),
    authenticatorData: b64u(got.response.authenticatorData), signature: b64u(got.response.signature),
    userHandle: got.response.userHandle ? b64u(got.response.userHandle) : null };
}
// In the frame: asks the parent's message, answers with the outcome (a cross-origin frame's assertion).
addEventListener('message', async (event) => {
  if (!event.data || event.data.ask !== 'get') return;
  try { event.source.postMessage({ answer: await getAssertion(event.data.options) }, '*'); }
  catch (e) { event.source.postMessage({ error: String(e) }, '*'); }
});
// A frame says it has loaded; its parent notes it.
if (parent !== window) parent.postMessage({ ready: true }, '*');
addEventListener('message', (event) => { if (event.data && event.data.ready) window.frameReady = true; });
function askFrame(options) {
  return new Promise((resolve, reject) => {
    addEventListener('message', function once(event) {
      if (!event.data || !(event.data.answer || event.data.error)) return;
      removeEventListener('message', once);
      if (event.data.error) reject(new Error(event.data.error)); else resolve(event.data.answer);
    });
    document.querySelector('iframe').contentWindow.postMessage({ ask: 'get', options }, '*');
  });
}
</script>`;
fs.writeFileSync(path.join(out, 'index.html'), page);

// One server per port, each serving the page; `/frame?src=…` the page with a cross-origin frame allowed to ask.
function serve() {
  return new Promise((resolve) => {
    const server = http.createServer((request, response) => {
      const url = new URL(request.url, 'http://localhost');
      let body = fs.readFileSync(path.join(out, 'index.html'), 'utf8');
      if (url.pathname === '/frame') {
        body += `<iframe src="${url.searchParams.get('src')}" allow="publickey-credentials-get *"></iframe>`;
      }
      response.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
      response.end(body);
    });
    server.listen(0, 'localhost', () => resolve(server));
  });
}

function chromePath() {
  const mac = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
  if (process.env.CHROME) return process.env.CHROME;
  try { fs.accessSync(mac, fs.constants.X_OK); return mac; } catch { return findChrome(); }
}

// Chrome on its own profile, with a mock keychain and a basic password store: it never asks the Mac's Keychain.
async function launch() {
  const profile = path.join(out, `chrome-profile-${process.pid}`);
  fs.mkdirSync(profile, { recursive: true });
  const chrome = spawn(chromePath(), ['--headless=new', '--use-mock-keychain', '--password-store=basic',
    '--remote-debugging-port=0', `--user-data-dir=${profile}`, '--no-first-run', '--no-default-browser-check',
    '--disable-extensions', '--disable-sync', '--disable-background-networking', '--disable-component-update',
    'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'], detached: true });
  chrome.stderr.on('data', () => {});
  const portFile = path.join(profile, 'DevToolsActivePort');
  const end = Date.now() + 60000;
  while (!fs.existsSync(portFile) && Date.now() < end) await pause(100);
  if (!fs.existsSync(portFile)) { killGroup(chrome); throw new Error("Chrome didn't open its DevTools port in 60 s"); }
  const [port, browserPath] = fs.readFileSync(portFile, 'utf8').split('\n');
  return { chrome, profile, endpoint: `ws://127.0.0.1:${port}${browserPath}` };
}

let browser = null;
let servers = [];
async function main() {
  servers = [await serve(), await serve()];
  const [portA, portB] = servers.map((server) => server.address().port);
  const originA = `http://localhost:${portA}`;
  const originB = `http://localhost:${portB}`;
  const originSub = `http://sub.localhost:${portA}`;
  browser = await launch();
  const protocol = new Protocol(browser.endpoint);
  await protocol.opened;
  const version = (await protocol.send('Browser.getVersion')).product;
  const tab = await protocol.tab(out);
  await tab.send('WebAuthn.enable', { enableUI: false });

  const evaluate = async (expression) => {
    const result = await tab.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true, userGesture: true });
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
    return result.result.value;
  };
  const open = async (url) => {
    await tab.send('Page.navigate', { url });
    // A page with a frame waits for the frame's own page to say it loaded.
    if (!(await tab.until(`document.readyState === 'complete' && typeof makeCredential === 'function'` +
      (url.includes('/frame') ? ' && window.frameReady === true' : '')))) throw new Error(`${url} didn't load`);
  };
  const authenticator = async (options) => (await tab.send('WebAuthn.addVirtualAuthenticator', { options: {
    protocol: 'ctap2', ctap2Version: 'ctap2_1', transport: 'internal', hasResidentKey: true, hasUserVerification: true,
    isUserVerified: true, automaticPresenceSimulation: true, ...options } })).authenticatorId;
  const create = (options) => evaluate(`makeCredential(${JSON.stringify(options)})`).catch((error) => {
    throw new Error(`create ${JSON.stringify({ rpId: options.rpId, uv: options.uv, algs: options.algs })}: ${error.message}`);
  });
  const get = (options) => evaluate(`getAssertion(${JSON.stringify(options)})`);

  const registrations = [];
  const assertions = [];
  const notMade = [];
  const shapes = new Map();
  const shapeOf = (clientDataJSON, challenge, origin) => {
    const text = Buffer.from(clientDataJSON, 'base64url').toString('utf8');
    return text.split(challenge).join('<c>').split(origin).join('<o>');
  };
  const see = (shape) => shapes.set(shape, (shapes.get(shape) || 0) + 1);
  const user = () => ({ userId: crypto.randomBytes(16).toString('base64url'), userName: 'vectors' });

  const register = async (label, expect, { origin, rpId, uv = 'required', algs = [-7] }) => {
    const challenge = randomChallenge();
    const made = await create({ challenge, rpId, uv, algs, ...user() });
    see(shapeOf(made.clientDataJSON, challenge, origin));
    const record = { label, expect, origin, rpId, place: 'loopback', challenge: hex(challenge), rawId: hex(made.rawId),
      clientDataJSON: hex(made.clientDataJSON), attestationObject: hex(made.attestationObject),
      spki: made.spki ? hex(made.spki) : null, alg: made.alg };
    registrations.push(record);
    return { record, made };
  };
  const device = (registration, signCount, overrides = {}) => ({ credentialId: registration.rawId, spki: registration.spki,
    origin: registration.origin, rpId: registration.rpId, place: 'loopback', signCount, backupEligible: false, ...overrides });
  const signCountOf = (authenticatorData) => Buffer.from(authenticatorData, 'base64url').readUInt32BE(33);
  const assert = async (label, expect, { origin, rpId, registration, uv = 'required', allow = true, stored = 0,
    expected = {}, ask = get }) => {
    const challenge = randomChallenge();
    const got = await ask({ challenge, rpId, uv, allow: allow ? [Buffer.from(registration.rawId, 'hex').toString('base64url')] : [] });
    see(shapeOf(got.clientDataJSON, challenge, origin));
    const record = { label, expect, challenge: hex(expected.challenge || challenge),
      listener: { origin: expected.origin || origin, rpId: expected.rpId || rpId, place: 'loopback' },
      device: device(registration, stored, expected.device || {}), rawId: hex(got.rawId),
      clientDataJSON: hex(got.clientDataJSON), authenticatorData: hex(got.authenticatorData),
      signature: hex(got.signature), userHandle: got.userHandle ? hex(got.userHandle) : null,
      signCount: signCountOf(got.authenticatorData) };
    assertions.push(record);
    return record;
  };

  // ES256, user verification, a discoverable credential, on origin A.
  await open(`${originA}/`);
  const uvAuthenticator = await authenticator({});
  const { record: main } = await register('es256-uv-discoverable', 'ok', { origin: originA, rpId: 'localhost' });
  const resident = (await tab.send('WebAuthn.getCredentials', { authenticatorId: uvAuthenticator })).credentials
    .filter((credential) => credential.isResidentCredential).length;
  const first = await assert('es256-uv-allowed', 'ok', { origin: originA, rpId: 'localhost', registration: main });
  const second = await assert('es256-uv-discoverable', 'ok', { origin: originA, rpId: 'localhost', registration: main,
    allow: false, stored: first.signCount });
  // The same bytes as `first`, checked after `second` was taken: its count no longer exceeds the stored one.
  assertions.push({ ...first, label: 'stale-sign-count', expect: 'signCount', device: device(main, second.signCount) });
  assertions.push({ ...second, label: 'repeated-sign-count', expect: 'signCount', device: device(main, second.signCount) });
  await assert('another-challenge', 'clientDataChallenge', { origin: originA, rpId: 'localhost', registration: main,
    expected: { challenge: randomChallenge() } });
  // The node's listener is on origin A; the assertion was made on another port of localhost (C11).
  await open(`${originB}/`);
  await assert('another-port', 'clientDataOrigin', { origin: originB, rpId: 'localhost', registration: main,
    expected: { origin: originA, device: { origin: originA } } });
  // A frame of origin B inside a page of origin A asks: crossOrigin true. Checked as origin B's own listener.
  await open(`${originA}/frame?src=${encodeURIComponent(`${originB}/`)}`);
  try {
    await assert('cross-origin-frame', 'clientDataCrossOrigin', { origin: originB, rpId: 'localhost', registration: main,
      expected: { device: { origin: originB } }, ask: (options) => evaluate(`askFrame(${JSON.stringify(options)})`) });
  } catch (error) { notMade.push(`cross-origin-frame: ${error.message}`); }
  // The wrong type: a registration's clientDataJSON (webauthn.create) beside an assertion's bytes.
  await open(`${originA}/`);
  const typed = await assert('wrong-type', 'clientDataType', { origin: originA, rpId: 'localhost', registration: main });
  typed.clientDataJSON = main.clientDataJSON;
  typed.challenge = main.challenge;
  // And an assertion's clientDataJSON (webauthn.get) handed in as a registration's.
  registrations.push({ ...main, label: 'wrong-type', expect: 'clientDataType', clientDataJSON: first.clientDataJSON,
    challenge: first.challenge });
  // Another rpId: a page of sub.localhost, its passkey for rpId sub.localhost. A browser asks only for its own origin's
  // domain or a registrable suffix of it, and `localhost` is no registrable suffix (Chrome refuses rpId `localhost` on
  // sub.localhost), so an assertion for another rpId always names another origin too: checked as the listener of
  // `localhost`, the origin refuses it first. Checked as its own listener with the record of a device enrolled on
  // `localhost`, the device's binding refuses it (N5). With its own listener and record it passes: the vector is genuine.
  await open(`${originSub}/`);
  const own = { origin: originSub, rpId: 'sub.localhost', place: 'loopback' };
  const { record: sub } = await register('another-rpid-registration', 'clientDataOrigin', { origin: originSub, rpId: 'sub.localhost' });
  sub.origin = originA; sub.rpId = 'localhost';
  const subDevice = { ...sub, origin: originSub, rpId: 'sub.localhost' };
  const other = await assert('another-rpid', 'clientDataOrigin', { origin: originSub, rpId: 'sub.localhost', registration: subDevice,
    expected: { origin: originA, rpId: 'localhost', device: { origin: originA, rpId: 'localhost' } } });
  assertions.push({ ...other, label: 'another-rpid-own-listener', expect: 'ok', listener: own, device: device(subDevice, 0) });
  assertions.push({ ...other, label: 'another-rpid-device-enrolled-on-localhost', expect: 'enrolledElsewhere', listener: own,
    device: device(subDevice, 0, { origin: originA, rpId: 'localhost' }) });
  try { await create({ challenge: randomChallenge(), rpId: 'localhost', uv: 'required', algs: [-7], ...user() }); }
  catch (error) { notMade.push(`rpId localhost from ${originSub} (refused by Chrome, as expected): ${error.message.split('.')[0]}`); }
  await open(`${originA}/`);
  await tab.send('WebAuthn.removeVirtualAuthenticator', { authenticatorId: uvAuthenticator });

  // An authenticator without user verification: the registration and the assertion both lack UV.
  const plain = await authenticator({ hasUserVerification: false, isUserVerified: false });
  const { record: noUV } = await register('no-uv-registration', 'userVerification', { origin: originA, rpId: 'localhost', uv: 'discouraged' });
  await assert('no-uv', 'userVerification', { origin: originA, rpId: 'localhost', registration: noUV, uv: 'discouraged' });
  await tab.send('WebAuthn.removeVirtualAuthenticator', { authenticatorId: plain });

  // Algorithms other than ES256, where the virtual authenticator makes them.
  const others = await authenticator({});
  for (const [alg, label] of [[-257, 'rs256-registration'], [-8, 'eddsa-registration']]) {
    try { await register(label, 'coseKey', { origin: originA, rpId: 'localhost', algs: [alg] }); }
    catch (error) { notMade.push(`${label}: ${error.message}`); }
  }

  // The shapes, over more rounds: assertions and registrations on origin A. The authenticator holds three
  // discoverable credentials at most, so it starts empty and each round's new one is removed once read.
  await tab.send('WebAuthn.clearCredentials', { authenticatorId: others });
  const { record: shaped } = await register('es256-uv-discoverable-2', 'ok', { origin: originA, rpId: 'localhost' });
  let count = 0;
  for (let round = 0; round < rounds; round += 1) {
    const challenge = randomChallenge();
    const got = await get({ challenge, rpId: 'localhost', uv: 'required', allow: [Buffer.from(shaped.rawId, 'hex').toString('base64url')] });
    const shape = shapeOf(got.clientDataJSON, challenge, originA);
    see(shape);
    // One vector of each assertion shape, checked in order of its count.
    if (!assertions.some((a) => a.shape === shape)) {
      assertions.push({ label: `shape-${assertions.filter((a) => a.shape).length + 1}`, expect: 'ok', shape,
        challenge: hex(challenge), listener: { origin: originA, rpId: 'localhost', place: 'loopback' },
        device: device(shaped, count), rawId: hex(got.rawId), clientDataJSON: hex(got.clientDataJSON),
        authenticatorData: hex(got.authenticatorData), signature: hex(got.signature),
        userHandle: got.userHandle ? hex(got.userHandle) : null, signCount: signCountOf(got.authenticatorData) });
    }
    count = signCountOf(got.authenticatorData);
    const challenge2 = randomChallenge();
    let made;
    try { made = await create({ challenge: challenge2, rpId: 'localhost', uv: 'required', algs: [-7], ...user() }); }
    catch (error) { notMade.push(`shape round ${round}: ${error.message}`); continue; }
    await tab.send('WebAuthn.removeCredential', { authenticatorId: others, credentialId: Buffer.from(made.rawId, 'base64url').toString('base64') });
    const madeShape = shapeOf(made.clientDataJSON, challenge2, originA);
    see(madeShape);
    if (!registrations.some((r) => r.shape === madeShape)) {
      registrations.push({ label: `shape-${registrations.filter((r) => r.shape).length + 1}`, expect: 'ok', shape: madeShape,
        origin: originA, rpId: 'localhost', place: 'loopback', challenge: hex(challenge2), rawId: hex(made.rawId),
        clientDataJSON: hex(made.clientDataJSON), attestationObject: hex(made.attestationObject),
        spki: made.spki ? hex(made.spki) : null, alg: made.alg });
    }
  }
  await tab.send('WebAuthn.removeVirtualAuthenticator', { authenticatorId: others });

  const document = { chrome: version, made: new Date().toISOString().slice(0, 10), residentCredentials: resident,
    ports: 'random free ports of localhost; the origins below name them', notMade,
    shapes: [...shapes].map(([shape, seen]) => ({ shape, seen })).sort((a, b) => b.seen - a.seen),
    registrations, assertions };
  const json = JSON.stringify(document, null, 1);
  const swift = `// Generated by scripts/e2e/webauthn-vectors.cjs (${version}, ${document.made}): don't edit by hand; run it again.\n` +
    `// Assertions and registrations made by headless Chrome's virtual authenticator, every byte string in hex.\n` +
    `enum WebAuthnVectors {\n    static let json = #"""\n${json}\n"""#\n}\n`;
  fs.writeFileSync(fixture, swift);
  console.log(JSON.stringify({ chrome: version, registrations: registrations.length, assertions: assertions.length,
    resident, notMade, shapes: document.shapes }, null, 1));

  for (const server of servers) server.close();
  protocol.socket.close();
  const exited = new Promise((resolve) => { if (browser.chrome.exitCode !== null || browser.chrome.signalCode) resolve(); else browser.chrome.once('exit', resolve); });
  killGroup(browser.chrome);
  await exited;
}

// Chrome and the servers stopped on a failure too: nothing of this run outlives it.
main().then(() => process.exit(0), (error) => {
  console.error(error);
  for (const server of servers) server.close();
  if (browser) killGroup(browser.chrome);
  process.exit(1);
});
