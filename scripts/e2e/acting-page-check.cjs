// Acting from the page against a scratch node, in headless Chrome (run by Tests/VibeNodeTests/ActingPageCheckTests.swift):
// the page pairs with a fresh code, shows the three words the terminal is to be given, and once the terminal confirms
// it (the test types the words into `web.confirm`), it acts. Every check waits on what it looks for (`until`), never a
// fixed time.
//
// What is looked for comes from the test (EXPECT, a JSON file):
//   { projectHref, first, firstOption, approval, approve, second, secondOption, third, thirdFirst, thirdSecond, fourth, fourthFirst }
// - Pair: the phrase in the banner (written to OUT/phrase for the test); once confirmed, the banner goes and the
//   page's cards answer for real ("Answer", not "Draft"). The pairing's secret (`paired.act`, read off the wire) is in
//   no storage, cookie, address or console line.
// - Answer by click: the first question answered by clicking its option; its card closes saying so.
// - Approve: the long approval opened and approved by clicking its "Approve <commit>"; its card closes.
// - Changed: the page holds back the node's frames (a test shim around WebSocket, never the page's code), asks the
//   test to reword the second question (OUT/revise.want, answered by OUT/revise.done), then clicks the option it drew:
//   the node refuses it as `changed` and the card says to look again; let go, the card shows the new wording.
// - Send menu: the ways the node lists for the lead's agent, the next step first (a Claude never "after"); the second
//   sent, and the note says what the node did, or why not.
// - Told and taken back: a message at the next step offers Take back while the lead hasn't had it; taken back, it says
//   so.
// - Change while unread: an answer the lead hasn't had is changed from its pill.
// - Read by the lead: the lead's hook takes its inbox (OUT/take.want, answered by OUT/take.done); a Change opened
//   before is refused after; the message says the lead read it.
// - Older build: the served page changes under the tab (OUT/switch.want, answered by OUT/switch.done once the test
//   changed a file); at its next hello the acting tab says it is from an older build, with Reload, and still acts.
// - Level off: This node's Turn off (set web_acts off); the page reconnects reading and drafting: the line that
//   turns acting on, the open card drafts, and the banner at the top says this tab no longer acts (turned off).
// - Reloaded: the tab reloaded says it no longer acts (its pairing was in its memory) and to pair again.
// - Rules only: a project whose rules changed and nothing else: its title says so.
// - Held config: the long held-config card in four blocks before any click (rules at five, updates at three), no
//   technical words on its face.
// - Two tabs: a second tab opened by hand acts with the first one's pairing, held in memory only.
// - Can't act yet: acting on again (OUT/trust.want) with no tab paired: one plain banner with the command; a pick is
//   one line, "Not sent", the terminal's way behind a disclosure.
// - Settle from the card: the command on each held-config card, run in the scratch terminal with its code, closes it.
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
  window.__vsSockets = [];
  class Holding extends Native {
    constructor(...args) { super(...args); window.__vsSockets.push(this); }
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

    // Held config: the long card (seven things, nineteen rules) in four lines before any click: a plain title, what it
    // holds back, the rules that changed (only those), and Accept or the terminal's one line; no hash, snapshot, seal
    // or vault on its face; the rest behind Show details, closed.
    const held = await page.until(`(() => { try {
      const card = document.querySelector('.wait-box .card.held-config');
      if (!card) return null;
      const details = card.querySelector('.hc-details');
      const face = [...card.children].filter((el) => el !== details && el.tagName !== 'HEADER');
      // The words, its command aside (a card's id is in the command the node gives to settle it).
      const words = face.filter((el) => !el.classList.contains('hc-terminal')).map((el) => el.innerText).join(' ');
      // Four blocks: the title (with the things named under it), what it holds back, the rules that would change, the
      // action (Accept, or the terminal's line); quiet lines beside them. Every thing that isn't an update is named, so
      // blocks are counted, not lines; what may be capped is: rules at five, updates at three.
      const main = face.filter((el) => !el.classList.contains('hc-quiet'));
      const updatesNamed = [...card.querySelectorAll('.hc-things li')].filter((li) => /looks like .*update|update/i.test(li.innerText) && !li.classList.contains('hc-quiet')).length;
      const why = details?.open ? 'details open' : main.length > 4 ? 'more than four blocks: ' + face.map((el) => el.className).join(', ')
        : card.querySelectorAll('.hc-rules .hc-rail').length > 5 ? 'more than five rules on its face'
        : updatesNamed > 3 ? 'more than three updates named'
        : /snapshot|sealed|vault|[0-9a-f]{12}/i.test(words) ? 'technical words on its face: ' + words.slice(0, 120)
        : !(card.querySelector('.card-acts button') || card.querySelector('.hc-terminal .copy-line')) ? 'neither Accept nor the terminal’s line'
        : null;
      return why ? 'FAIL ' + why : card.querySelector('.card-question').innerText + ' / ' + face.slice(1).map((el) => el.innerText.replace(/\\s+/g, ' ').slice(0, 60)).join(' / ');
    } catch (error) { return 'FAIL ' + error.message; } })()`, WAIT);
    await page.evaluate(`document.querySelector('.wait-box .card.held-config')?.scrollIntoView({ block: 'center' })`);
    await page.shot('held-config');
    await page.evaluate(`(() => { const d = document.querySelector('.wait-box .card.held-config .hc-details'); if (d) d.open = true; })()`);
    await page.shot('held-config-details');
    await page.evaluate(`(() => { const d = document.querySelector('.wait-box .card.held-config .hc-details'); if (d) d.open = false; })()`);
    // Dark, and at a phone's width.
    await page.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'dark' }] });
    await page.shot('held-config-dark');
    await page.send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 2, mobile: true });
    await page.evaluate(`document.querySelector('.wait-box .card.held-config')?.scrollIntoView({ block: 'start' })`);
    await page.shot('held-config-phone-dark');
    await page.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'light' }] });
    await page.shot('held-config-phone-light');
    await page.send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
    await page.send('Emulation.setEmulatedMedia', { features: [] });
    record('Held config', held && !held.startsWith('FAIL'), held || 'no held-config card in the waiting block');

    // Rules only (a second project whose rules were written after its accept, nothing else changed): the title says the
    // project's rules changed, never "the agents' config"; the rules that would change under it.
    await page.go(expect.rulesHref);
    const rulesOnly = await page.until(`(() => { const card = document.querySelector('.wait-box .card.held-config'); if (!card) return null; const title = card.querySelector('.card-question')?.innerText || ''; return /rules changed/.test(title) && card.querySelectorAll('.hc-rules .hc-rail').length ? title + ' / ' + [...card.querySelectorAll('.hc-rail')].map((el) => el.innerText).join(', ') : 'FAIL ' + title; })()`, WAIT);
    await page.evaluate(`document.querySelector('.wait-box .card.held-config')?.scrollIntoView({ block: 'center' })`);
    await page.shot('held-config-rules-only');
    record('Rules only', rulesOnly && !rulesOnly.startsWith('FAIL'), rulesOnly || 'no card in the second project');
    await page.go(expect.projectHref);

    // Two tabs: a second tab of the same origin, opened by hand (no code, no token), acts too: it asks its sibling over
    // the origin's channel and connects with the pairing it holds.
    const second = await protocol.tab(out);
    await second.send('Page.navigate', { url: `${new URL(url).origin}/${expect.projectHref}` });
    const both = await second.until(`(() => { const c = [...document.querySelectorAll('.wait-box .card')].find((el) => el.innerText.includes(${JSON.stringify(expect.first)})); return c && c.querySelector('.answer button[type=submit]')?.innerText.trim() === 'Answer' && !document.querySelector('.tab-banner:not([hidden])') ? 'the second tab acts' : null; })()`, WAIT);
    const kept = secret && await second.evaluate(`[sessionStorage, localStorage].flatMap((store) => Object.keys(store).map((key) => store.getItem(key))).filter((value) => value.includes(${JSON.stringify(secret || '')})).length`);
    await second.shot('second-tab');
    record('Two tabs', both && kept === 0, !both ? 'the second tab didn’t act' : kept ? 'the secret is stored in the second tab' : both + ', the secret in memory only');
    await protocol.send('Target.closeTarget', { targetId: (await second.send('Target.getTargetInfo')).targetInfo.targetId }).catch(() => {});

    // Answer by click: the first question.
    const clicked = await page.until(clickOption(expect.first, expect.firstOption), WAIT);
    const answered = clicked && await page.until(`(() => { const c = ${card(expect.first)}; return c && c.classList.contains('closed') ? c.innerText.replace(/\\s+/g, ' ').slice(0, 80) : null; })()`, WAIT);
    // Answered, the card says so in the waiting block for a few seconds, then leaves it: the conversation is the record.
    const gone = answered && await page.until(`!${card(expect.first)} ? true : null`, WAIT);
    record('Answer by click', answered && gone, !answered ? 'the question’s option didn’t answer it' : !gone ? 'the answered card stayed in the waiting block' : answered + '; then gone from the waiting block');

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

    // Told and taken back: a message at the lead's next step (`tell`) offers Take back until the lead has it; taken
    // back, it says so. A second one stays, for the read mark below.
    const tell = (text) => page.evaluate(`(() => { const say = document.querySelector('.project-view .say'); say.value = ${JSON.stringify(text)}; document.querySelector('.project-view .lead-send .send-main').click(); return true; })()`);
    const noteOf = (text) => `[...document.querySelectorAll('.project-view .note')].find((el) => el.querySelector('.mine')?.innerText === ${JSON.stringify(text)})`;
    await tell('Keep the old name');
    const offered = await page.until(`(() => { const note = ${noteOf('Keep the old name')}; const back = note?.querySelector('.take-back'); if (!back) return null; back.click(); return true; })()`, WAIT);
    const takenBack = offered && await page.until(`(() => { const said = ${noteOf('Keep the old name')}?.querySelector('.confirm-note')?.innerText || ''; return /Taken back/.test(said) ? said : null; })()`, WAIT);
    await tell('And ship it on Monday');
    const stays = await page.until(`${noteOf('And ship it on Monday')}?.querySelector('.take-back') ? true : null`, WAIT);
    record('Told and taken back', takenBack && stays, !offered ? 'no Take back under a message the lead hasn’t had' : !takenBack ? 'taking it back didn’t say so' : !stays ? 'the second message offers no Take back' : takenBack);

    // Change while unread: the third question answered by click; its pill offers Change while the lead hasn't had it,
    // and the answer changes.
    const pillOf = (text) => `(() => { const line = [...document.querySelectorAll('.project-view .line.kind-ask')].find((el) => el.innerText.includes(${JSON.stringify(text)})); let next = line?.nextElementSibling; const out = []; while (next && !next.classList.contains('line') && !next.classList.contains('day')) { out.push(next); next = next.nextElementSibling; } return out; })()`;
    const answeredThird = await page.until(clickOption(expect.third, expect.thirdFirst), WAIT);
    const change = answeredThird && await page.until(`(() => { const button = ${pillOf(expect.third)}.flatMap((el) => [...el.querySelectorAll('button')]).find((b) => b.innerText.trim() === 'Change'); if (!button) return null; button.click(); return true; })()`, WAIT);
    const chose = change && await page.until(`(() => { const option = ${pillOf(expect.third)}.flatMap((el) => [...el.querySelectorAll('.answer-change button.option')]).find((b) => b.innerText.includes(${JSON.stringify(expect.thirdSecond)})); if (!option) return null; option.click(); return true; })()`, WAIT);
    const changed = chose && await page.until(`(() => { const pill = ${pillOf(expect.third)}.find((el) => el.classList.contains('mine')); return pill && pill.innerText.includes(${JSON.stringify(expect.thirdSecond)}) ? pill.innerText : null; })()`, WAIT);
    await page.shot('changed-answer');
    record('Change while unread', changed, !answeredThird ? 'the third question couldn’t be answered' : !change ? 'no Change under an answer the lead hasn’t had' : !chose ? 'Change offered no other option' : changed ? 'changed to ' + changed : 'the answer didn’t change');

    // The lead's step: its hook takes what waits for it (OUT/take.want, answered by OUT/take.done). A Change opened
    // before it is refused after it; the message and the first answer say the lead has read them.
    const answeredFourth = await page.until(clickOption(expect.fourth, expect.fourthFirst), WAIT);
    const opened = answeredFourth && await page.until(`(() => { const button = ${pillOf(expect.fourth)}.flatMap((el) => [...el.querySelectorAll('button')]).find((b) => b.innerText.trim() === 'Change'); if (!button) return null; button.click(); return true; })()`, WAIT);
    fs.writeFileSync(path.join(out, 'take.want'), 'the lead takes its inbox');
    const took = opened && await waitFile(path.join(out, 'take.done'), 60000);
    // The option clicked if the open Change is still there; the node's read mark may close it first: either way, the
    // pill says the answer was read and the change can't be made.
    const late = took && await page.evaluate(`(() => { const option = ${pillOf(expect.fourth)}.flatMap((el) => [...el.querySelectorAll('.answer-change button.option')])[0]; option?.click(); return true; })()`);
    const refusedLate = late && await page.until(`(() => { const all = ${pillOf(expect.fourth)}; const said = all.map((el) => (el.classList.contains('card-notice') ? el.innerText : el.querySelector('.card-notice')?.innerText) || '').find(Boolean); return said && /read your answer already/.test(said) && all.some((el) => /Read by the lead/.test(el.innerText)) ? said : null; })()`, WAIT);
    const readMarks = refusedLate && await page.until(`(() => {
      const told = ${noteOf('And ship it on Monday')}?.querySelector('.confirm-note')?.innerText || '';
      return /Read by the lead/.test(told) ? told : null;
    })()`, WAIT);
    await page.shot('read-by-lead');
    record('Read by the lead', refusedLate && readMarks, !answeredFourth ? 'the fourth question couldn’t be answered' : !opened ? 'no Change under the fourth answer before the lead’s step' : !took ? 'the lead’s hook never took its inbox' : !late ? 'the open Change offered no option' : !refusedLate ? 'a Change after the lead’s step wasn’t refused as read' : !readMarks ? 'the message never said the lead read it' : refusedLate + '; ' + readMarks);

    // Send menu (after the rows above: typing into an idle lead lets its prompt hook take what waits): the ways the lead's
    // agent takes a message, as the node lists them (a Claude never "After this turn"),
    // the next step first; the second one sent, and the note says what the node did (or why not).
    const ways = await page.evaluate(`(() => {
      const more = document.querySelector('.project-view .lead-send .send-more');
      if (!more || more.hidden) return null;
      more.click();
      return [...document.querySelectorAll('.lead-send .send-way strong')].map((el) => el.innerText.trim());
    })()`);
    const known = ['At its next step', 'Now', 'After this turn', 'Interrupt, then send'];
    const fits = ways && ways[0] === 'At its next step' && ways.every((way) => known.includes(way)) && !ways.includes('After this turn')
      && ways.every((way, index) => index === 0 || known.indexOf(way) > known.indexOf(ways[index - 1]));
    const secondWay = fits && ways.length > 1 ? ways[1] : null;
    if (secondWay) {
      await page.evaluate(`(() => {
        document.querySelector('.project-view .say').value = 'Run the audits on Fable';
        [...document.querySelectorAll('.lead-send .send-way')].find((el) => el.querySelector('strong')?.innerText.trim() === ${JSON.stringify(secondWay)})?.click();
      })()`);
    }
    const did = secondWay && await page.until(`(() => { const note = [...document.querySelectorAll('.project-view .note .confirm-note')].pop()?.innerText || ''; return note && !/Sending/.test(note) ? note : null; })()`, WAIT);
    await page.shot('send-menu');
    record('Send menu', did, !ways ? 'no menu beside Send' : !fits ? 'the menu’s ways aren’t the node’s: ' + ways.join(', ') : !secondWay ? 'only one way listed' : !did ? 'no note on what was done' : ways.join(', ') + ' → ' + secondWay + ': ' + did);

    // Older build: the node's files change under the tab (the test edits the served folder); at its next hello the
    // tab, which acts, isn't reloaded behind the user's back: the banner at the top says it is from an older build,
    // that reloading ends acting, and offers Reload.
    fs.writeFileSync(path.join(out, 'switch.want'), 'change the served page');
    const switched = await waitFile(path.join(out, 'switch.done'), 90000);
    if (switched) await page.evaluate('window.__vsSockets.at(-1).close()');
    const older = switched && await page.until(`(() => { const b = document.querySelector('.tab-banner:not([hidden])'); return b && /older build/.test(b.innerText) && /ends acting/.test(b.innerText) && [...b.querySelectorAll('button')].some((el) => el.innerText.trim() === 'Reload') ? b.innerText.replace(/\\s+/g, ' ').slice(0, 90) : null; })()`, WAIT);
    const stillActs = older && await page.until(`(() => { const c = ${card(expect.second)}; return c && c.querySelector('.answer button[type=submit]')?.innerText.trim() === 'Answer' ? true : null; })()`, WAIT);
    await page.shot('older-build');
    record('Older build', older && stillActs, !switched ? 'the test never changed the served page' : !older ? 'no banner saying the tab is from an older build, with Reload' : !stillActs ? 'the tab stopped acting' : older + '; still acts');

    // Level off: This node's Turn off; the page reconnects, reading and drafting.
    await page.go('#/node');
    const off = await page.until(`(() => { const b = [...document.querySelectorAll('.node-column .acts-line button')].find((el) => el.innerText.trim() === 'Turn off'); if (!b || b.disabled) return null; b.click(); return true; })()`, WAIT);
    const reads = off && await page.until(`(() => { const line = document.querySelector('.node-column .acts-line'); return line && line.innerText.includes('vibeswitcher set web_acts trust') ? line.innerText.replace(/\\s+/g, ' ').slice(0, 80) : null; })()`, WAIT);
    await page.go(expect.projectHref);
    const drafts = reads && await page.until(`(() => { const c = ${card(expect.second)}; return c && c.querySelector('.answer button[type=submit]')?.innerText.trim() === 'Draft' ? 'the card drafts' : null; })()`, WAIT);
    // The tab acted and no longer does: said at the top of the centre, with why (acting turned off; this tab, from an
    // older build and no longer acting, may have reloaded to the node's meanwhile, which it says too).
    const banner = drafts && await page.until(`(() => { const b = document.querySelector('.tab-banner:not([hidden])'); return b && /no longer acts/.test(b.innerText) && /(turned off|is off too)/.test(b.innerText) && b.innerText.includes('vibeswitcher set web_acts trust') ? b.innerText.replace(/\\s+/g, ' ').slice(0, 90) : null; })()`, WAIT);
    await page.shot('level-off');
    record('Level off', reads && drafts && banner, !off ? 'no Turn off in This node' : !reads ? 'This node never said pages read and draft' : !drafts ? 'the open card still acts' : !banner ? 'no banner saying the tab no longer acts, acting turned off' : reads + '; ' + drafts + '; ' + banner);

    // Reloaded: a tab keeps its pairing in memory only; reloaded, it says so (and to pair again), never silently.
    await page.send('Page.reload');
    const reloaded = await page.until(`(() => { const b = document.querySelector('.tab-banner:not([hidden])'); return b && /no longer acts/.test(b.innerText) && /reloaded/.test(b.innerText) && b.innerText.includes('vibeswitcher web') ? b.innerText.replace(/\\s+/g, ' ').slice(0, 90) : null; })()`, WAIT);
    await page.shot('reloaded');
    record('Reloaded', reloaded, reloaded || 'the reloaded tab didn’t say it no longer acts');

    // Can't act yet: acting on again from a terminal (OUT/trust.want, answered by OUT/trust.done), and no tab holds a
    // pairing: one plain banner with the command and its copy button; a pick on a card is one line, not sent, the
    // terminal's way behind a disclosure.
    fs.writeFileSync(path.join(out, 'trust.want'), 'set web_acts trust');
    const trusted = await waitFile(path.join(out, 'trust.done'), 60000);
    const cant = trusted && await page.until(`(() => { const b = document.querySelector('.tab-banner:not([hidden])'); return b && /can’t act yet/.test(b.innerText) && b.querySelector('.copy-line')?.innerText.includes('vibeswitcher web') ? b.innerText.replace(/\\s+/g, ' ').slice(0, 90) : null; })()`, WAIT);
    await page.go(expect.projectHref);
    const picked = cant && await page.until(clickOption(expect.second, 'Drop it today'), WAIT);
    const oneLine = picked && await page.until(`(() => { const c = ${card(expect.second)}; const line = c?.querySelector('.card-notsent')?.innerText || ''; const terminal = c?.querySelector('details.card-terminal'); return /Not sent/.test(line) && terminal && !terminal.open && !c.querySelector('.card-keys') ? line : null; })()`, WAIT);
    await page.shot('cant-act-yet');
    // The held config in Spanish, light and dark (the page reloaded with ?lang=es: it reads from here on).
    await page.send('Page.navigate', { url: `${new URL(url).origin}/?lang=es${expect.projectHref}` });
    await page.until(`document.querySelector('.wait-box .card.held-config') ? true : null`, WAIT);
    await page.evaluate(`document.querySelector('.wait-box .card.held-config')?.scrollIntoView({ block: 'center' })`);
    await page.shot('held-config-spanish-light');
    await page.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'dark' }] });
    await page.shot('held-config-spanish-dark');
    await page.send('Emulation.setEmulatedMedia', { features: [] });
    record('Can’t act yet', cant && oneLine, !trusted ? 'the test never turned acting on again' : !cant ? 'no banner saying this tab can’t act yet, with the command' : !oneLine ? 'a pick isn’t one line with the terminal behind a disclosure' : cant + '; ' + oneLine);

    // Settle from the card: the command on each held-config card's face (the main project's, then the rules-only one's),
    // run in the scratch node's terminal with its code (OUT/settle-N.want, answered by OUT/settle-N.done, which says
    // how many steps it took); the card closes.
    const settled = [];
    for (const [index, href] of [[1, expect.projectHref], [2, expect.rulesHref]]) {
      await page.send('Page.navigate', { url: `${new URL(url).origin}/${href}` });
      const command = await page.until(`document.querySelector('.wait-box .card.held-config .hc-terminal .copy-text')?.innerText.trim() || null`, WAIT);
      if (!command) { settled.push(`${index}: no command on the card`); continue; }
      fs.writeFileSync(path.join(out, `settle-${index}.want`), command);
      const done = await waitFile(path.join(out, `settle-${index}.done`), 90000);
      const how = done ? fs.readFileSync(path.join(out, `settle-${index}.done`), 'utf8') : 'never run';
      const closed = done && await page.until(`!document.querySelector('.wait-box .card.held-config') ? true : null`, WAIT);
      settled.push(`${index}: ${command} → ${how}${closed ? ', the card closed' : ', the card stayed'}`);
    }
    // One step each: the node's `config accept <card>` (its `settle`), and the card closes.
    record('Settle from the card', settled.every((line) => / config accept local:card:\S+ → one step, the card closed$/.test(line)), settled.join('; '));
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
