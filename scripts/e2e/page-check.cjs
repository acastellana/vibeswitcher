// The page's DOM code against a scratch node's real server data, in headless Chrome (the architecture review's row 12;
// run by Tests/VibeNodeTests/PageCheckTests.swift in the Linux CI's core job): pair with a fresh code, then each main
// view must draw what the node holds, with no console error. Every check waits on what it looks for (`until`), never a
// fixed time, so a loaded machine is only slower.
//
// What is looked for comes from the test, which made the node's state (EXPECT, a JSON file):
//   { session, chatHref, chat, leadHref, question, shellHref, shell, boardHref, board, plugin, setting }
// - Session list: the sidebar lists the sessions, the named one among them, and a lead.
// - Chat: the session's conversation shows a line of its transcript.
// - Question card: the lead's open question, under its chat.
// - Shell card: the shell plugin's card, under the asking session's chat, with its exact command.
// - Board: the lead's board shows a task by its title.
// - This node: its Health (freezes) and its Plugins, the named plugin on.
// - Settings: the node's settings, a known one among them.
// - Console: no error over the whole run.
// Read-only: it moves between the page's routes and presses nothing.
//
// Usage: node page-check.cjs URL EXPECT-JSON OUT-FOLDER CHROME   (exit 1 on any fail; a table and report.json in OUT)
'use strict';
const fs = require('fs');
const path = require('path');
const { launch, Protocol } = require('./chrome-cdp.cjs');

const [url, expectFile, out, chromePath] = process.argv.slice(2);
if (!url || !expectFile || !out || !chromePath) {
  console.error('usage: node page-check.cjs URL EXPECT-JSON OUT-FOLDER CHROME');
  process.exit(64);
}
const expect = JSON.parse(fs.readFileSync(expectFile, 'utf8'));
// How long one view may take to draw: generous, for a loaded machine.
const WAIT = Number(process.env.PAGE_CHECK_WAIT_MS || 30000);
const results = [];
const record = (row, ok, detail) => results.push({ row, outcome: ok ? 'pass' : 'fail', detail: String(detail ?? '') });
const has = (selector, text) => `(() => {
  const found = [...document.querySelectorAll(${JSON.stringify(selector)})].find((el) => el.offsetParent !== null && el.innerText.includes(${JSON.stringify(text)}));
  return found ? found.innerText.replace(/\\s+/g, ' ').trim().slice(0, 100) : null;
})()`;

// Clicks the visible view tab `selector` matches whose text is `text`: true once clicked (never a control that acts).
const clickTab = (selector, text) => `(() => {
  const el = [...document.querySelectorAll(${JSON.stringify(selector)})].find((e) => e.innerText.trim() === ${JSON.stringify(text)} && e.offsetParent);
  if (!el) return null;
  el.click();
  return true;
})()`;

async function run() {
  fs.mkdirSync(out, { recursive: true });
  const browser = await launch(chromePath, out);
  const protocol = new Protocol(browser.endpoint);
  let page = null;
  try {
    await protocol.opened;
    page = await protocol.tab(out);
    await page.send('Emulation.setDeviceMetricsOverride', { width: 1400, height: 900, deviceScaleFactor: 1, mobile: false });
    await page.send('Page.navigate', { url });

    // Session list: paired, connected, the sessions listed from the node.
    const listed = await page.until(`(() => {
      if (!sessionStorage.getItem('vibeswitcher.token') || document.querySelector('.offline:not([hidden])')) return null;
      const rows = [...document.querySelectorAll('.sidebar .row')].map((row) => row.innerText);
      return rows.some((text) => text.includes(${JSON.stringify(expect.session)})) && rows.some((text) => /lead/i.test(text)) ? rows.length : null;
    })()`, WAIT);
    await page.shot('session-list');
    record('Session list', listed, listed ? `${listed} sessions, ${expect.session} and a lead among them` : 'not paired, or the sessions never listed');
    if (!listed) return;

    // Chat: the session's conversation, from its transcript.
    await page.go(expect.chatHref);
    const chat = await page.until(has('.chat-rows .chat-row', expect.chat), WAIT);
    await page.shot('chat');
    record('Chat', chat, chat || `no row with "${expect.chat}"`);

    // Question card: the lead's question, under its chat.
    await page.go(expect.leadHref);
    const question = await page.until(has('.chat .card', expect.question), WAIT);
    await page.shot('question-card');
    record('Question card', question, question || `no card with "${expect.question}"`);

    // Team tab: the project's lead's inspector has it, its tasks the board's (opened by the lead's id, never the first
    // LEAD row: a lead session the project replaced may run beside it).
    const teamTab = await page.until(clickTab('.inspector .segmented button', 'Team'), WAIT);
    const team = teamTab && await page.until(has('.inspector .task', expect.board), WAIT);
    await page.shot('team-tab');
    record('Team tab', team, team || (teamTab ? `no task "${expect.board}" in the Team tab` : 'no Team tab on the lead'));

    // Replaced lead: a lead session its project replaced says so on its row (its tag grey), and has no Team tab.
    if (expect.replacedHref) {
      await page.go(expect.replacedHref);
      const replaced = await page.until(`(() => {
        const row = [...document.querySelectorAll('.sidebar .row')].find((r) => decodeURIComponent(r.querySelector('.row-link')?.getAttribute('href') || '') === ${JSON.stringify(expect.replacedHref)});
        if (!row || !row.querySelector('.lead-tag.replaced') || !/replaced/i.test(row.innerText)) return null;
        const tab = [...document.querySelectorAll('.inspector .segmented button')].find((b) => b.innerText.trim() === 'Team');
        return document.querySelector('.inspector') && (!tab || tab.hidden) ? 'marked replaced, no Team tab' : null;
      })()`, WAIT);
      await page.shot('replaced-lead');
      const seen = replaced ? null : await page.evaluate(`(() => {
        const row = [...document.querySelectorAll('.sidebar .row')].find((r) => decodeURIComponent(r.querySelector('.row-link')?.getAttribute('href') || '') === ${JSON.stringify(expect.replacedHref)});
        const tab = [...document.querySelectorAll('.inspector .segmented button')].find((b) => b.innerText.trim() === 'Team');
        return row ? 'its row: ' + row.innerText.replace(/\\s+/g, ' ').slice(0, 120) + (row.querySelector('.lead-tag.replaced') ? ' (tag grey)' : ' (tag not grey)')
          + (tab && !tab.hidden ? '; a Team tab' : '; no Team tab') : 'no row for it';
      })()`);
      record('Replaced lead', replaced, replaced || seen);
    }

    // Shell card: the shell plugin's card under the asking session's chat, its command whole.
    await page.go(expect.shellHref);
    const shell = await page.until(has('.chat .card, .chat article', expect.shell), WAIT);
    await page.shot('shell-card');
    record('Shell card', shell, shell || `no card with "${expect.shell}"`);

    // Board: the lead's board, a task by its title.
    await page.go(expect.boardHref);
    const board = await page.until(has('.board-task', expect.board), WAIT);
    await page.shot('board');
    record('Board', board, board || `no task "${expect.board}"`);

    // This node: Health and Plugins.
    await page.go('#/node');
    const node = await page.until(`(() => {
      const text = document.querySelector('.node-column')?.innerText || '';
      return /\\bHealth\\b/i.test(text) && /\\bFreezes\\b/.test(text) && /\\bPlugins\\b/i.test(text) && text.includes(${JSON.stringify(expect.plugin)}) ? 'health and plugins shown' : null;
    })()`, WAIT);
    await page.shot('this-node');
    record('This node', node, node || `no Health with Freezes, or no Plugins with ${expect.plugin}`);

    // Settings: the node's, read from it.
    await page.go('#/settings');
    const settings = await page.until(`(() => {
      const rows = [...document.querySelectorAll('.setting')];
      return rows.length && rows.some((row) => row.innerText.includes(${JSON.stringify(expect.setting)})) ? rows.length : null;
    })()`, WAIT);
    await page.shot('settings');
    record('Settings', settings, settings ? `${settings} settings, "${expect.setting}" among them` : `no setting "${expect.setting}"`);
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
