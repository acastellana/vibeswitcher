// The level `confirm` against a scratch node, in headless Chrome with a virtual authenticator standing in for the user's
// (DevTools' WebAuthn domain: CTAP2, internal, user verification on and given): run by
// Tests/VibeNodeTests/PasskeyPageCheckTests.swift. The page is opened at http://localhost:PORT (the origin a passkey
// works on). Every check waits on what it looks for (`until`), never a fixed time.
//
// What is looked for comes from the test (EXPECT, a JSON file): { projectHref, first, firstOption }
// - Pair: the page shows its three words (written to OUT/phrase for the test, which confirms them as the terminal does);
//   once confirmed, the banner goes.
// - Register: the test asks a passkey of the page by its words (OUT/passkey.want, the `web.passkey` the terminal sends);
//   the page shows the offer, the check clicks it, the virtual authenticator makes the key, and once the test kept it
//   and set the level to `confirm` (OUT/passkey.done), the page says the level asks a passkey.
// - Act: the first question answered by clicking its option: the page asks a challenge, shows what is approved in its
//   pill, the authenticator signs it, the act is done (its card closes) and the line the node recorded is shown.
// - Console: no error over the whole run.
//
// Usage: node passkey-page-check.cjs URL EXPECT-JSON OUT-FOLDER CHROME   (exit 1 on any fail; a table and report.json in OUT)
'use strict';
const fs = require('fs');
const path = require('path');
const { launch, Protocol, pause } = require('./chrome-cdp.cjs');

const [url, expectFile, out, chromePath] = process.argv.slice(2);
if (!url || !expectFile || !out || !chromePath) {
  console.error('usage: node passkey-page-check.cjs URL EXPECT-JSON OUT-FOLDER CHROME');
  process.exit(64);
}
const expect = JSON.parse(fs.readFileSync(expectFile, 'utf8'));
const WAIT = Number(process.env.PAGE_CHECK_WAIT_MS || 30000);
const results = [];
const record = (row, ok, detail) => results.push({ row, outcome: ok ? 'pass' : 'fail', detail: String(detail ?? '') });

const card = (text) => `[...document.querySelectorAll('.wait-box .card')].find((el) => el.innerText.includes(${JSON.stringify(text)}))`;
const clickOption = (text, option) => `(() => {
  const c = ${card(text)};
  if (!c) return null;
  if (c.classList.contains('folded')) { c.querySelector('.card-unfold').click(); return null; }
  const button = [...c.querySelectorAll('button.option')].find((b) => (b.querySelector('.option-text') || b).innerText.trim().startsWith(${JSON.stringify(option)}));
  if (!button || button.disabled) return null;
  button.click();
  return true;
})()`;
const waitFile = async (file, ms) => {
  const end = Date.now() + ms;
  while (Date.now() < end) { if (fs.existsSync(file)) return true; await pause(150); }
  return false;
};

async function run() {
  fs.mkdirSync(out, { recursive: true });
  const browser = await launch(chromePath, out);
  const protocol = new Protocol(browser.endpoint);
  let page = null;
  try {
    await protocol.opened;
    page = await protocol.tab(out);
    let recorded = null;
    // The page's frames, both ways (a failing run's evidence: OUT/frames.log), its requests and their replies only.
    const frames = fs.createWriteStream(path.join(out, 'frames.log'));
    protocol.listeners.push((message) => {
      if (message.sessionId !== page.sessionId) return;
      const sent = message.method === 'Network.webSocketFrameSent', got = message.method === 'Network.webSocketFrameReceived';
      if (!sent && !got) return;
      try {
        const frame = JSON.parse(message.params.response.payloadData);
        if (got && typeof frame.recorded === 'string') recorded = frame.recorded;
        if (frame.id !== undefined || frame.re !== undefined || ['paired', 'passkey', 'hello', 'bye'].includes(frame.kind)) {
          frames.write((sent ? '> ' : '< ') + JSON.stringify(frame).replace(/"(act|token|challenge|signature|clientDataJSON|authenticatorData|attestationObject)":"[^"]*"/g, '"$1":"…"').slice(0, 400) + '\n');
        }
      } catch { /* binary */ }
    });
    await page.send('Network.enable');
    // The user's authenticator, virtual: it makes and uses ES256 keys, verifying the user each time.
    await page.send('WebAuthn.enable', { enableUI: false });
    await page.send('WebAuthn.addVirtualAuthenticator', { options: {
      protocol: 'ctap2', transport: 'internal', hasResidentKey: true, hasUserVerification: true, isUserVerified: true,
      automaticPresenceSimulation: true,
    } });
    await page.send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
    await page.send('Page.navigate', { url });

    // Pair: the words, then the terminal's confirmation.
    const phrase = await page.until(`(() => { const p = document.querySelector('.confirm-pairing:not([hidden]) .phrase')?.innerText.trim(); return p && p.split(/\\s+/).length === 3 ? p : null; })()`, WAIT);
    if (phrase) fs.writeFileSync(path.join(out, 'phrase'), phrase);
    const confirmed = phrase && await page.until(`(() => document.querySelector('.confirm-pairing:not(.passkey-pill):not([hidden])') ? null : true)()`, WAIT);
    record('Pair', phrase && confirmed, !phrase ? 'no three-word phrase in the banner' : !confirmed ? 'never confirmed' : `“${phrase}” confirmed at ${new URL(url).host}`);
    if (!confirmed) return;

    // Register: the offer to this page, the key made by the authenticator, kept by the terminal.
    fs.writeFileSync(path.join(out, 'passkey.want'), phrase);
    const offered = await page.until(`(() => { const b = document.querySelector('.passkey-offer:not([hidden]) button'); if (!b || b.disabled) return null; b.click(); return true; })()`, WAIT);
    // The new key's id as the page shows it, from its own browser's answer (the node never says it): what the user
    // types in the terminal (`web.passkey.add`'s `typed`).
    // (The banner's sentence, i18n's pkAdded: "Your new passkey: <6>. Type these 6 characters in the terminal.")
    const shownID = offered && await page.until(`(() => { const e = document.querySelector('.passkey-offer:not([hidden])'); const m = e && e.innerText.match(/Your new passkey: ([A-Za-z0-9_-]{6})\\./); return m ? m[1] : null; })()`, WAIT);
    await page.shot('passkey-offer');
    if (shownID) fs.writeFileSync(path.join(out, 'passkey.typed'), shownID);
    const kept = shownID && await waitFile(path.join(out, 'passkey.done'), WAIT * 2);
    record('Register', Boolean(offered && shownID && kept), !offered ? 'no passkey offer on the page' : !shownID ? 'the page showed no id of its new key (pkAdded)'
      : !kept ? 'the terminal never kept a key' : `made by the authenticator, its id ${shownID} typed, kept by the terminal, the level confirm`);
    if (!kept) return;

    // Act: the first question answered by clicking its option, the passkey asked and given.
    await page.go(expect.projectHref);
    const clicked = await page.until(clickOption(expect.first, expect.firstOption), WAIT);
    const pill = clicked && await page.until(`(() => { const p = document.querySelector('.passkey-pill'); return p && p.innerText.trim() ? p.innerText.replace(/\\s+/g, ' ').slice(0, 120) : null; })()`, WAIT);
    const answered = clicked && await page.until(`(() => { const c = ${card(expect.first)}; return c && c.classList.contains('closed') ? c.innerText.replace(/\\s+/g, ' ').slice(0, 80) : null; })()`, WAIT);
    const shown = answered && recorded && await page.until(`(() => document.body.innerText.includes(${JSON.stringify((recorded || '').slice(0, 40))}) ? true : null)()`, WAIT);
    await page.shot('passkey-act');
    record('Act', answered && recorded && shown, !clicked ? 'the option couldn’t be clicked' : !answered ? `the act wasn’t done (${pill || 'no pill'})` : !recorded ? 'no recorded line in the reply' : !shown ? 'the recorded line isn’t shown' : `done; recorded “${recorded}”`);
  } catch (error) {
    record('run', false, error.message);
  } finally {
    if (page) record('Console', page.consoleErrors.length === 0, page.consoleErrors.length ? page.consoleErrors.slice(0, 3).join(' | ') : 'no error');
    try { protocol.socket.close(); } catch { /* gone already */ }
    await browser.close().catch((error) => record('Cleanup', false, error.message));
    fs.writeFileSync(path.join(out, 'report.json'), JSON.stringify(results, null, 2));
    const width = Math.max(...results.map((r) => r.row.length));
    for (const r of results) console.log(`${r.row.padEnd(width)}  ${r.outcome.padEnd(4)}  ${r.detail}`);
    process.exit(results.some((r) => r.outcome === 'fail') ? 1 : 0);
  }
}

run();
