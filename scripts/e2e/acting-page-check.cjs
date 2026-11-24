// Acting from the page against a scratch node, in headless Chrome (run by Tests/VibeNodeTests/ActingPageCheckTests.swift):
// the page pairs with a fresh code, shows the three words the terminal is to be given, and once the terminal confirms
// it (the test types the words into `web.confirm`), it acts. Every check waits on what it looks for (`until`), never a
// fixed time.
//
// What is looked for comes from the test (EXPECT, a JSON file):
//   { projectHref, first, firstOption, approval, approve, second, secondOption }
// - Pair: the phrase in the banner (written to OUT/phrase for the test); once confirmed, the banner goes and the
//   page's cards answer for real ("Answer", not "Draft"). The pairing's secret (`paired.act`, read off the wire) is in
//   no storage, cookie, address or console line.
// - Answer by click: the first question answered by clicking its option; its card closes saying so.
// - Approve: the long approval opened and approved by clicking its "Approve <commit>"; its card closes.
// - Changed: the page holds back the node's frames (a test shim around WebSocket, never the page's code), asks the
//   test to reword the second question (OUT/revise.want, answered by OUT/revise.done), then clicks the option it drew:
//   the node refuses it as `changed` and the card says to look again; let go, the card shows the new wording.
// - Level off: This node's Turn off (set web_acts off); the page reconnects reading and drafting: the line that
//   turns acting on, the open card drafts, and the banner at the top says this tab no longer acts (turned off).
// - Reloaded: the tab reloaded says it no longer acts (its pairing was in its memory) and to pair again.
// - Console: no error over the whole run.
//
// Usage: node acting-page-check.cjs URL EXPECT-JSON OUT-FOLDER CHROME   (exit 1 on any fail; a table and report.json in OUT)
'use strict';
const fs = require('fs');
const path = require('path');
const { launch, Protocol, pause } = require('./chrome-cdp.cjs');

const [url, expectFile, out, chromePath] = process.argv.slice(2);
if (!url || !expectFile || !out || !chromePath) {
  console.error('usage: node acting-page-check.cjs URL EXPECT-JSON OUT-FOLDER CHROME');
  process.exit(64);
}
const expect = JSON.parse(fs.readFileSync(expectFile, 'utf8'));
const WAIT = Number(process.env.PAGE_CHECK_WAIT_MS || 30000);
const results = [];
const record = (row, ok, detail) => results.push({ row, outcome: ok ? 'pass' : 'fail', detail: String(detail ?? '') });

// The test's shim, before the page's own code: while `__vsHold` is set, the node's events (frames without `re`) wait;
// replies pass. `__vsRelease()` lets the held ones through, in order.
const HOLD = `(() => {
  const Native = window.WebSocket;
  const held = [];
  window.__vsHold = false;
  window.__vsRelease = () => { window.__vsHold = false; for (const run of held.splice(0)) run(); };
  class Holding extends Native {
    set onmessage(handler) {
      super.onmessage = (event) => {
        if (window.__vsHold && typeof event.data === 'string' && !/"re"\\s*:/.test(event.data)) { held.push(() => handler.call(this, event)); return; }
        handler.call(this, event);
      };
    }
    get onmessage() { return super.onmessage; }
  }
  window.WebSocket = Holding;
})();`;

// The card in the waiting block whose text holds `text`, as an expression.
const card = (text) => `[...document.querySelectorAll('.wait-box .card')].find((el) => el.innerText.includes(${JSON.stringify(text)}))`;
// Clicks the option of the card holding `text` whose words start with `option`: true once clicked.
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
    // The pairing's secret as the node sends it, and every console line (none may carry it).
    let secret = null;
    const said = [];
    protocol.listeners.push((message) => {
      if (message.sessionId !== page.sessionId) return;
      if (message.method === 'Network.webSocketFrameReceived') {
        try { const frame = JSON.parse(message.params.response.payloadData); if (frame.kind === 'paired') secret = frame.act; } catch { /* binary */ }
      } else if (message.method === 'Runtime.consoleAPICalled') {
        said.push(message.params.args.map((arg) => String(arg.value ?? arg.description ?? '')).join(' '));
      }
    });
    await page.send('Network.enable');
    await page.send('Page.addScriptToEvaluateOnNewDocument', { source: HOLD });
    await page.send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
    await page.send('Page.navigate', { url });

    // Pair: the phrase, then the terminal's confirmation.
    const phrase = await page.until(`(() => { const p = document.querySelector('.confirm-pairing:not([hidden]) .phrase')?.innerText.trim(); return p && p.split(/\\s+/).length === 3 ? p : null; })()`, WAIT);
    await page.shot('pair-phrase');
    if (phrase) fs.writeFileSync(path.join(out, 'phrase'), phrase);
    await page.go(expect.projectHref);
    const acting = phrase && await page.until(`(() => {
      if (document.querySelector('.confirm-pairing:not([hidden])')) return null;
      const c = ${card(expect.first)};
      return c && c.querySelector('.answer button[type=submit]')?.innerText.trim() === 'Answer' ? 'acts' : null;
    })()`, WAIT);
    const leaks = secret && await page.evaluate(`(() => {
      const secret = ${JSON.stringify(secret || '')};
      const stores = [sessionStorage, localStorage].flatMap((store) => Object.keys(store).map((key) => key + '=' + store.getItem(key)));
      return [...stores, document.cookie, location.href].filter((value) => value.includes(secret)).length;
    })()`);
    const logged = secret ? said.filter((line) => line.includes(secret)).length : 0;
    record('Pair', phrase && acting && secret && leaks === 0 && logged === 0, !phrase ? 'no three-word phrase in the banner' : !acting ? 'the page didn’t act once confirmed' : !secret ? 'no `paired` frame with a secret'
      : leaks || logged ? `the secret is kept outside memory (${leaks} stored, ${logged} logged)` : `“${phrase}” confirmed; the page acts; the secret only in memory`);
    if (!acting) return;

    // Answer by click: the first question.
    const clicked = await page.until(clickOption(expect.first, expect.firstOption), WAIT);
    const answered = clicked && await page.until(`(() => { const c = ${card(expect.first)}; return c && c.classList.contains('closed') ? c.innerText.replace(/\\s+/g, ' ').slice(0, 80) : null; })()`, WAIT);
    record('Answer by click', answered, answered || 'the question’s option didn’t answer it');

    // Approve: the long approval, its "Approve <commit>".
    const approving = await page.until(clickOption(expect.approval, expect.approve), WAIT);
    const approved = approving && await page.until(`(() => { const c = ${card(expect.approval)}; return c && c.classList.contains('closed') ? c.innerText.replace(/\\s+/g, ' ').slice(0, 80) : null; })()`, WAIT);
    await page.shot('approved');
    record('Approve', approved, approved || 'the approval’s option didn’t approve it');

    // Changed: the frames held, the question reworded by its lead, the option the page drew clicked.
    const drawn = await page.until(`(() => { const c = ${card(expect.second)}; return c && !c.classList.contains('folded') && c.querySelector('button.option') ? true : null; })()`, WAIT);
    await page.evaluate('window.__vsHold = true');
    fs.writeFileSync(path.join(out, 'revise.want'), 'reword the second question');
    const revised = drawn && await waitFile(path.join(out, 'revise.done'), 90000);
    const stale = revised && await page.until(clickOption(expect.second, expect.secondOption), WAIT);
    const refused = stale && await page.until(`(() => { const c = ${card(expect.second)}; const said = c?.querySelector('.card-notice[role=alert]')?.innerText || ''; return /look again/.test(said) ? said : null; })()`, WAIT);
    await page.evaluate('window.__vsRelease()');
    const reworded = refused && await page.until(`(() => { const c = ${card(expect.second)}; return c && !c.classList.contains('closed') && /Monday/.test(c.innerText) ? 'the new wording shown' : null; })()`, WAIT);
    await page.shot('changed');
    record('Changed', refused && reworded, !drawn ? 'the second question wasn’t drawn whole' : !revised ? 'the test never reworded it' : !stale ? 'its option couldn’t be clicked' : !refused ? 'no “look again” after the stale click' : !reworded ? 'the new wording never showed' : refused + '; ' + reworded);

    // Level off: This node's Turn off; the page reconnects, reading and drafting.
    await page.go('#/node');
    const off = await page.until(`(() => { const b = [...document.querySelectorAll('.node-column .acts-line button')].find((el) => el.innerText.trim() === 'Turn off'); if (!b || b.disabled) return null; b.click(); return true; })()`, WAIT);
    const reads = off && await page.until(`(() => { const line = document.querySelector('.node-column .acts-line'); return line && line.innerText.includes('vibeswitcher set web_acts trust') ? line.innerText.replace(/\\s+/g, ' ').slice(0, 80) : null; })()`, WAIT);
    await page.go(expect.projectHref);
    const drafts = reads && await page.until(`(() => { const c = ${card(expect.second)}; return c && c.querySelector('.answer button[type=submit]')?.innerText.trim() === 'Draft' ? 'the card drafts' : null; })()`, WAIT);
    // The tab acted and no longer does: said at the top of the centre, with why.
    const banner = drafts && await page.until(`(() => { const b = document.querySelector('.tab-banner:not([hidden])'); return b && /no longer acts/.test(b.innerText) && /turned off/.test(b.innerText) ? b.innerText.replace(/\\s+/g, ' ').slice(0, 90) : null; })()`, WAIT);
    await page.shot('level-off');
    record('Level off', reads && drafts && banner, !off ? 'no Turn off in This node' : !reads ? 'This node never said pages read and draft' : !drafts ? 'the open card still acts' : !banner ? 'no banner saying the tab no longer acts, acting turned off' : reads + '; ' + drafts + '; ' + banner);

    // Reloaded: a tab keeps its pairing in memory only; reloaded, it says so (and to pair again), never silently.
    await page.send('Page.reload');
    const reloaded = await page.until(`(() => { const b = document.querySelector('.tab-banner:not([hidden])'); return b && /no longer acts/.test(b.innerText) && /reloaded/.test(b.innerText) && b.innerText.includes('vibeswitcher web') ? b.innerText.replace(/\\s+/g, ' ').slice(0, 90) : null; })()`, WAIT);
    await page.shot('reloaded');
    record('Reloaded', reloaded, reloaded || 'the reloaded tab didn’t say it no longer acts');
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
