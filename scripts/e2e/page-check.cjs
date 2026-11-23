// The page's DOM code against a scratch node's real server data, in headless Chrome (the architecture review's row 12;
// run by Tests/VibeNodeTests/PageCheckTests.swift in the Linux CI's core job): pair with a fresh code, then each main
// view must draw what the node holds, with no console error. Every check waits on what it looks for (`until`), never a
// fixed time, so a loaded machine is only slower.
//
// What is looked for comes from the test, which made the node's state (EXPECT, a JSON file):
//   { session, chatHref, chat, projectHref, question, result, statement, task, shellHref, shell, board, replacedHref, plugin, setting }
// The page is the redesigned one (docs/superpowers/specs/2026-11-23-v2-web-ui-design.md): three columns, a project's
// lead conversation in the centre, its team on the right, the session view under Your own sessions.
// - Projects and own sessions: the left lists the project; Your own sessions lists the named session.
// - Chat: the session's conversation shows a line of its transcript (the session view, at its old address).
// - Question card: the lead's open question, in the project's waiting block, under "1 question for you", saying
//   the lead asks.
// - Lead conversation: the lead's result as a line, and the header saying what needs you.
// - Latest statement: the lead's latest decision at the top of a short conversation.
// - What waits elsewhere: the summary's count a link to the next place that waits, that place marked.
// - Side sheet: the result's line opens its whole text, its markdown table drawn as a table.
// - Team tab: the right column's Team tab shows a task by its title, and it opens in place.
// - Replaced lead: a lead session its project replaced is marked so in Your own sessions, and its inspector has no
//   Team tab.
// - Shell card: the shell plugin's card, under the asking session's chat, with its exact command.
// - Roadmap: the project's roadmap shows the task, and the board page's old address opens the lead conversation.
// - Deep links: an address with the dial, a tab and a task draws exactly that.
// - This node: its Health (freezes) and its Plugins, the named plugin on.
// - Settings: the node's settings, a known one among them.
// - Language: the page in Spanish with ?lang=es.
// - Phone: at 390 px wide, nothing wider than the screen, the header and the waiting block shown.
// - Console: no error over the whole run.
// Read-only: it moves between the page's routes and opens views; it presses nothing that acts and types nothing.
// With PAGE_SHOTS=DIR it also leaves each main state's screenshot there, light and dark, wide and at 390 px.
//
// Usage: node page-check.cjs URL EXPECT-JSON OUT-FOLDER CHROME   (exit 1 on any fail; a table and report.json in OUT)
'use strict';
const fs = require('fs');
const path = require('path');
const { launch, Protocol, pause } = require('./chrome-cdp.cjs');

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

// Each main state, light and dark, wide and at 390 px, for the record (WebApp/shots/): never read by a check.
async function shots(page, origin, folder) {
  fs.mkdirSync(folder, { recursive: true });
  const project = expect.projectHref;
  const states = [
    ['lead', project], ['lead-everything', project + '?show=all'], ['lead-waiting', project + '?show=asks'], ['task-open', project + '?task=' + encodeURIComponent(expect.task || '')],
    ['stats', project + '?tab=stats'], ['files', project + '?tab=files'], ['roadmap', project.replace(/\/lead$/, '/roadmap')],
    ['roadmap-queue', project.replace(/\/lead$/, '/roadmap') + '?open=queue'], ['own-sessions', '#/sessions'], ['session', expect.chatHref], ['shell-request', expect.shellHref],
    ['new-project', '#/new'], ['this-node', '#/node'], ['settings', '#/settings'],
  ];
  for (const [width, height, suffix] of [[1440, 900, ''], [390, 844, '-phone']]) {
    for (const theme of ['light', 'dark']) {
      await page.send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: width < 600 });
      await page.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
      for (const [name, hash] of states) {
        if (suffix && ['stats', 'files', 'lead-waiting', 'roadmap-queue', 'new-project', 'settings'].includes(name)) continue;
        await page.go(hash);
        await pause(900);
        const { data } = await page.send('Page.captureScreenshot', { format: 'png' });
        fs.writeFileSync(path.join(folder, `${name}${suffix}-${theme}.png`), Buffer.from(data, 'base64'));
      }
      // The side sheet, and on a phone the left column as a drawer.
      await page.go(project);
      await pause(900);
      await page.evaluate(`document.querySelector('.project-view .line.kind-result')?.click()`);
      await pause(700);
      fs.writeFileSync(path.join(folder, `sheet${suffix}-${theme}.png`), Buffer.from((await page.send('Page.captureScreenshot', { format: 'png' })).data, 'base64'));
      if (suffix) {
        await page.go(project);
        await pause(700);
        await page.evaluate(`document.querySelector('.project-view .phone-only')?.click()`);
        await pause(500);
        fs.writeFileSync(path.join(folder, `drawer${suffix}-${theme}.png`), Buffer.from((await page.send('Page.captureScreenshot', { format: 'png' })).data, 'base64'));
        await page.evaluate(`document.querySelector('.drawer-scrim')?.click()`);
      }
    }
  }
  // The page in Spanish (?lang=es), its roadmap too.
  await page.send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
  for (const theme of ['light', 'dark']) {
    await page.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
    for (const [name, hash] of [['lead', project], ['roadmap', project.replace(/\/lead$/, '/roadmap')]]) {
      await page.send('Page.navigate', { url: `${origin}/?lang=es${hash}` });
      await pause(1500);
      fs.writeFileSync(path.join(folder, `${name}-spanish-${theme}.png`), Buffer.from((await page.send('Page.captureScreenshot', { format: 'png' })).data, 'base64'));
    }
  }
  await page.send('Emulation.setEmulatedMedia', { features: [] });
}

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

    // Projects and own sessions: paired, connected, the project listed on the left, the session under Your own sessions.
    const listed = await page.until(`(() => {
      if (!sessionStorage.getItem('vibeswitcher.token') || document.querySelector('.offline:not([hidden])')) return null;
      const projects = document.querySelectorAll('.left .project').length;
      return projects ? projects : null;
    })()`, WAIT);
    await page.go('#/sessions');
    const own = listed && await page.until(`(() => {
      const rows = [...document.querySelectorAll('.own-row')].map((row) => row.innerText);
      return rows.some((text) => text.includes(${JSON.stringify(expect.session)})) ? rows.length : null;
    })()`, WAIT);
    await page.shot('projects-and-sessions');
    record('Projects and own sessions', listed && own, listed ? (own ? `${listed} projects; ${own} own sessions, ${expect.session} among them` : `no own session ${expect.session}`) : 'not paired, or no project listed');
    if (!listed) return;

    // Chat: the session's conversation, from its transcript.
    await page.go(expect.chatHref);
    const chat = await page.until(has('.chat-rows .chat-row', expect.chat), WAIT);
    await page.shot('chat');
    record('Chat', chat, chat || `no row with "${expect.chat}"`);

    // Question card: the lead's question, in the project's waiting block.
    await page.go(expect.projectHref);
    const question = await page.until(`(() => {
      const card = [...document.querySelectorAll('.project-view .card')].find((el) => el.offsetParent && el.innerText.includes(${JSON.stringify(expect.question)}));
      const title = document.querySelector('.project-view .asked-title')?.innerText || '';
      return card && /question/i.test(title) && /the lead/.test(card.querySelector('.card-asker')?.innerText || '') ? title + ': ' + card.innerText.replace(/\\s+/g, ' ').slice(0, 80) : null;
    })()`, WAIT);
    await page.shot('question-card');
    record('Question card', question, question || `no card with "${expect.question}" under the waiting block's title`);

    // Lead conversation: the result as a line; the header says what needs you.
    await page.go(expect.projectHref);
    const talk = await page.until(`(() => {
      const line = [...document.querySelectorAll('.project-view .line.kind-result')].find((el) => el.innerText.includes(${JSON.stringify(expect.result)}));
      const big = document.querySelector('.project-view .big');
      return line && big && /needs? you/.test(big.innerText) && big.classList.contains('asked') ? big.innerText + ' · ' + line.innerText.replace(/\\s+/g, ' ') : null;
    })()`, WAIT);
    record('Lead conversation', talk, talk || `no result line "${expect.result}", or the header doesn't say what needs you`);

    // Latest statement: the conversation is short (one line), so the lead's latest decision shows at its top.
    const statement = await page.until(`(() => { const said = document.querySelector('.project-view .latest-said'); return said && said.innerText.includes(${JSON.stringify(expect.statement)}) ? said.innerText.replace(/\\s+/g, ' ') : null; })()`, WAIT);
    record('Latest statement', statement, statement || `no "${expect.statement}" above a short conversation`);

    // What waits elsewhere: the header counts this project's; the summary's count links to the next place that waits,
    // and Your own sessions (where the replaced lead needs you) carries the asking colour.
    const elsewhere = await page.until(`(() => {
      const count = document.querySelector('.summary-count');
      const own = document.querySelector('.place.asked');
      return count && /^#\\/s\\//.test(count.getAttribute('href') || '') && own && own.dataset.place === 'ownSessions' ? count.innerText + ' → ' + decodeURIComponent(count.getAttribute('href')).slice(0, 24) + '; Your own sessions marked' : null;
    })()`, WAIT);
    record('What waits elsewhere', elsewhere, elsewhere || 'the summary’s count doesn’t lead to the session that waits, or Your own sessions isn’t marked');

    // Side sheet: the result's whole text, its table a table.
    const opened = talk && await page.evaluate(`(() => { const line = [...document.querySelectorAll('.project-view .line.kind-result')].find((el) => el.innerText.includes(${JSON.stringify(expect.result)})); line?.click(); return !!line; })()`);
    const sheet = opened && await page.until(`(() => {
      const sheet = document.querySelector('.sheet:not([hidden])');
      return sheet && sheet.querySelector('.sheet-body table td') && /[?&]sheet=/.test(location.hash) ? sheet.querySelector('.sheet-title').innerText + ', a table of ' + sheet.querySelectorAll('.sheet-body td').length + ' cells' : null;
    })()`, WAIT);
    await page.shot('side-sheet');
    record('Side sheet', sheet, sheet || 'the result line opened no sheet with a table');
    await page.evaluate(`document.querySelector('.sheet-close')?.click()`);

    // Team tab: the right column's tasks, one opening in place.
    await page.go(expect.projectHref);
    const teamRow = await page.until(`(() => {
      const row = [...document.querySelectorAll('.right .task-row2')].find((el) => el.offsetParent && el.innerText.includes(${JSON.stringify(expect.board)}));
      if (!row) return null;
      row.click();
      return true;
    })()`, WAIT);
    const team = teamRow && await page.until(`(() => { const open = document.querySelector('.right .task-row2.open + .tdet'); return open && /[?&]task=/.test(location.hash) ? open.innerText.replace(/\\s+/g, ' ').slice(0, 80) : null; })()`, WAIT);
    await page.shot('team-tab');
    record('Team tab', team, team || (teamRow ? 'the task didn’t open in place' : `no task "${expect.board}" in the Team tab`));

    // Replaced lead: marked so in Your own sessions, and no Team tab in its inspector.
    if (expect.replacedHref) {
      await page.go('#/sessions');
      const marked = await page.until(`(() => {
        const row = [...document.querySelectorAll('.own-row')].find((r) => decodeURIComponent(r.getAttribute('href') || '') === ${JSON.stringify(expect.replacedHref)});
        return row && row.querySelector('.lead-tag.replaced:not([hidden])') ? 'marked replaced' : null;
      })()`, WAIT);
      await page.go(expect.replacedHref);
      const noTeam = marked && await page.until(`(() => {
        const tab = [...document.querySelectorAll('.inspector .segmented button')].find((b) => b.innerText.trim() === 'Team');
        return document.querySelector('.inspector') && (!tab || tab.hidden) ? 'no Team tab' : null;
      })()`, WAIT);
      await page.shot('replaced-lead');
      record('Replaced lead', marked && noTeam, marked ? (noTeam ? 'marked replaced in Your own sessions, no Team tab' : 'a Team tab on it') : 'not marked replaced in Your own sessions');
    }

    // Shell card: the shell plugin's card under the asking session's chat, its command whole.
    await page.go(expect.shellHref);
    const shell = await page.until(has('.chat .card, .chat article', expect.shell), WAIT);
    await page.shot('shell-card');
    record('Shell card', shell, shell || `no card with "${expect.shell}"`);

    // Roadmap: the task on the project's roadmap; the board page's old address is the lead conversation.
    await page.go(expect.projectHref.replace(/\/lead$/, '/roadmap'));
    const road = await page.until(has('.road-row', expect.board), WAIT);
    await page.shot('roadmap');
    await page.go(expect.projectHref.replace(/\/lead$/, ''));
    const old = road && await page.until(`!document.querySelector('.project-view').hidden && !!document.querySelector('.right .task-row2') && document.querySelector('.switch-link[aria-current]')?.innerText.trim() === 'Lead' ? 'the old address opens the lead conversation' : null`, WAIT);
    record('Roadmap', road && old, road ? (old || 'the old #/p/ address didn’t open the lead conversation') : `no "${expect.board}" on the roadmap`);

    // Deep links: the dial at Everything, the Files tab.
    await page.go(expect.projectHref + '?show=all&tab=files');
    const deep = await page.until(`(() => {
      const dial = document.querySelector('.dial .switch-link[aria-current]')?.innerText || '';
      const tab = document.querySelector('.right .switch-link[aria-selected="true"]')?.innerText || '';
      return /Everything/.test(dial) && tab.trim() === 'Files' && document.querySelector('.right .file-row') ? 'Everything, Files' : null;
    })()`, WAIT);
    record('Deep links', deep, deep || 'the address’s dial or tab wasn’t drawn');

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

    // Language: Spanish with ?lang=es (the tab's token stays: it is the tab's).
    const origin = new URL(url).origin;
    await page.send('Page.navigate', { url: `${origin}/?lang=es${expect.projectHref}` });
    const spanish = await page.until(`document.querySelector('.left .col-title')?.innerText === 'Proyectos' && /pregunta/.test(document.querySelector('.project-view .asked-title')?.innerText || '') ? 'Proyectos, ' + document.querySelector('.project-view .asked-title').innerText : null`, WAIT);
    await page.shot('spanish');
    record('Language', spanish, spanish || 'not in Spanish with ?lang=es');

    // Phone: 390 px wide.
    await page.send('Page.navigate', { url: `${origin}/${expect.projectHref}` });
    await page.send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 2, mobile: true });
    const phone = await page.until(`(() => {
      const card = document.querySelector('.project-view .card');
      const big = document.querySelector('.project-view .big');
      if (!card || !big || !big.offsetParent) return null;
      const wide = [...document.querySelectorAll('body *')].filter((el) => el.offsetParent && el.getBoundingClientRect().right > innerWidth + 1 && !el.closest('.left, .right, .sheet, .switch, .team-strip, pre, .copy-line, .table'));
      return document.documentElement.scrollWidth <= innerWidth && !wide.length ? 'fits 390 px' : 'too wide: ' + wide.slice(0, 3).map((el) => el.className).join(', ');
    })()`, WAIT);
    await page.shot('phone');
    record('Phone', phone === 'fits 390 px', phone || 'the lead conversation never drew at 390 px');
    await page.send('Emulation.setDeviceMetricsOverride', { width: 1400, height: 900, deviceScaleFactor: 1, mobile: false });

    if (process.env.PAGE_SHOTS) await shots(page, origin, process.env.PAGE_SHOTS);
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
