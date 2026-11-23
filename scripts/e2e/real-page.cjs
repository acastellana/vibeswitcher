// The real node's page, checked read-only in headless Chrome (scripts/e2e/real-page-check.sh runs it): pair with the URL
// `vibeswitcher web` printed, look at each acceptance row's view, screenshot it, and say pass, fail or skip for each.
//
// The page is the redesigned one (docs/superpowers/specs/2026-11-23-v2-web-ui-design.md): projects on the left, a
// project's lead conversation in the centre and its team on the right, the session view under Your own sessions.
//
// Read-only by construction: it navigates between the page's routes and switches the inspector's and a session's
// view tabs; it opens a line's side sheet; the one button it presses is Brief me (a read). It never presses an option, Send, a draft, Hold, Stop or
// any other control that acts; it types into nothing (A10 is checked by the page's state alone: the hard rule is that
// nothing types into a real session). A23 sends `answer` and `send` on a WebSocket of its own with the page's token,
// naming a card and a session that don't exist, and expects both refused by voice before any handler.
//
// Chrome is driven over the DevTools protocol with Node's own WebSocket (Node 22): nothing installed.
//
// Usage: node real-page.cjs URL OUT-FOLDER [CHROME]
'use strict';
const fs = require('fs');
const path = require('path');
const { launch, Protocol, pause } = require('./chrome-cdp.cjs');

const [url, out, chromePath = '/opt/google/chrome/chrome'] = process.argv.slice(2);
if (!url || !out) {
  console.error('usage: node real-page.cjs URL OUT-FOLDER [CHROME]');
  process.exit(64);
}
const origin = new URL(url).origin;
const results = [];
const record = (row, outcome, detail) => results.push({ row, outcome, detail: String(detail ?? '') });

// Clicks the first element `selector` matches whose text is `text` (a view tab): never a control that acts.
const clickTab = (selector, text) => `(() => {
  const el = [...document.querySelectorAll(${JSON.stringify(selector)})].find((e) => e.innerText.trim() === ${JSON.stringify(text)} && e.offsetParent);
  if (!el) return false;
  el.click();
  return true;
})()`;

// MARK: The rows

async function run() {
  fs.mkdirSync(out, { recursive: true });
  const browser = await launch(chromePath, out);
  const protocol = new Protocol(browser.endpoint);
  try {
    await protocol.opened;
    const page = await protocol.tab(out);
    // This script's rows look a moment after each route (the page draws it): the CI's check waits on each view instead.
    const route = page.go.bind(page);
    page.go = async (hash) => { await route(hash); await pause(400); };
    await page.send('Emulation.setDeviceMetricsOverride', { width: 1500, height: 950, deviceScaleFactor: 1, mobile: false });
    // A19: notifications granted to the page's origin, as the user's click would.
    const granted = await protocol.send('Browser.grantPermissions', { origin, permissions: ['notifications'] }).then(() => true, () => false);

    // A3: paired and connected, the projects and your own sessions listed.
    await page.send('Page.navigate', { url });
    const connected = await page.until(`!!document.querySelector('.left') && !document.querySelector('.offline:not([hidden])') && !!sessionStorage.getItem('vibeswitcher.token')`, 20000);
    await page.shot('a3-start');
    const projects = connected ? await page.evaluate(`[...document.querySelectorAll('.left .project')].map((a) => a.getAttribute('href'))`) : [];
    await page.go('#/sessions');
    const sessions = connected ? await page.evaluate(`[...document.querySelectorAll('.own-row')].map((a) => a.getAttribute('href'))`) : [];
    record('A3 pair', connected ? 'pass' : 'fail', connected ? `paired, ${projects.length} projects and ${sessions.length} of your own sessions listed` : 'no token or still offline after 20 s');
    if (!connected) return;

    // Brief me: a read, from the left column's summary line; its text in the side sheet.
    const asked = await page.evaluate(`(() => { const b = document.querySelector('.left-summary'); if (!b || b.disabled) return false; b.click(); return true; })()`);
    const brief = asked ? await page.until(`(() => { const s = document.querySelector('.sheet:not([hidden]) .sheet-body'); const t = s?.innerText.trim() || ''; return t && !/^Briefing|^Resumiendo/.test(t) ? t.slice(0, 80) : null; })()`, 60000) : null;
    await page.shot('brief');
    record('Brief me', !asked ? 'skip' : brief ? 'pass' : 'fail', !asked ? 'the node writes no briefing for this page' : brief || 'no brief in 60 s');
    await page.evaluate(`document.querySelector('.sheet-close')?.click()`);

    // A3: one of your own sessions' chat and the inspector's tabs; dev servers when its row shows.
    if (sessions.length) {
      await page.go(sessions[0]);
      const chat = await page.until(`!!document.querySelector('.chat-column')`, 10000);
      await page.shot('a3-chat');
      record('A3 chat', chat ? 'pass' : 'fail', chat ? sessions[0] : 'no chat column');
      const tabs = await page.evaluate(`[...document.querySelectorAll('.inspector .segmented button')].filter((b) => b.offsetParent).map((b) => b.innerText.trim())`);
      for (const tab of tabs) {
        await page.evaluate(clickTab('.inspector .segmented button', tab));
        await pause(700);
        await page.shot(`a3-inspector-${tab.toLowerCase().replace(/\W+/g, '-')}`);
      }
      record('A3 inspector', tabs.length ? 'pass' : 'fail', tabs.join(', ') || 'no tabs');
    } else {
      record('A3 chat', 'skip', 'none of your own sessions listed');
    }
    let ports = null;
    for (const href of sessions.slice(0, 12)) {
      await page.go(href);
      ports = await page.until(`(document.querySelector('.inspector')?.innerText || '').match(/localhost:\\d{4,5}[^\\n]*/)?.[0] || null`, 1500);
      if (ports) { await page.shot('dev-servers'); break; }
    }
    record('Dev servers', ports ? 'pass' : 'skip', ports ? ports.replace(/\s+/g, ' ').slice(0, 80) : 'no session listens on a port now');

    // The shell request card, under its asking session's chat, when one waits.
    let shell = null;
    for (const href of sessions.slice(0, 20)) {
      await page.go(href);
      shell = await page.until(`(() => { const c = document.querySelector('.shell-command, .plugin-body'); return c ? c.closest('article').innerText.slice(0, 160) : null; })()`, 1200);
      if (shell) { await page.shot('shell-card'); break; }
    }
    const shellText = shell || '';
    record('Shell card', !shell ? 'skip' : shellText.includes('vibeswitcher answer') ? 'pass' : 'fail', shell ? shellText.replace(/\s+/g, ' ') : 'no shell request waits');

    // Each project's lead conversation and its Team tab: the header, the lines, the tasks.
    if (projects.length) {
      const said = [];
      let all = true;
      for (const [index, href] of projects.entries()) {
        await page.go(href);
        const seen = await page.until(`(() => {
          const big = document.querySelector('.project-view .big');
          const right = document.querySelector('.right');
          if (!big || !right || !right.offsetParent) return null;
          return { big: big.innerText, lines: document.querySelectorAll('.project-view .line').length, tasks: document.querySelectorAll('.right .task-row2').length,
            waiting: document.querySelectorAll('.project-view .card:not(.closed)').length };
        })()`, 8000);
        await page.shot(index === 0 ? 'team-tab' : `team-tab-${index + 1}`);
        all = all && !!seen;
        said.push(`${decodeURIComponent(href).split('/')[2]?.slice(-8)}: ` + (seen ? `${seen.big}, ${seen.lines} lines, ${seen.waiting} cards waiting, ${seen.tasks} tasks` : 'not drawn'));
      }
      record('Team tab', all ? 'pass' : 'fail', said.join('; '));
      // A line's whole text in the side sheet.
      await page.go(projects[0] + '?show=all');
      const line = await page.until(`(() => { const l = document.querySelector('.project-view .line'); if (!l) return null; l.click(); return true; })()`, 3000);
      const sheet = line && await page.until(`(() => { const s = document.querySelector('.sheet:not([hidden])'); return s ? s.querySelector('.sheet-title').innerText.slice(0, 80) : null; })()`, 5000);
      await page.shot('side-sheet');
      record('Side sheet', !line ? 'skip' : sheet ? 'pass' : 'fail', !line ? 'no line in the first project’s conversation' : sheet || 'the line opened no sheet');
      // The roadmap, without goals.
      await page.go(projects[0].replace(/\/lead$/, '/roadmap'));
      const road = await page.until(`!!document.querySelector('.road-intro')`, 8000);
      await page.shot('a3-roadmap');
      record('A3 roadmap', road ? 'pass' : 'fail', projects[0].replace(/\/lead$/, '/roadmap'));
    } else {
      record('Team tab', 'skip', 'no project listed');
      record('Side sheet', 'skip', 'no project listed');
      record('A3 roadmap', 'skip', 'no project listed');
    }

    // A3 settings; this node with its health; statistics; between leads.
    const views = [
      ['A3 settings', '#/settings', `document.querySelectorAll('.setting').length`],
      ['Health', '#/node', `(() => { const t = document.querySelector('main, .node-column')?.innerText || ''; return /\\bHEALTH\\b/i.test(t) && /\\bFreezes\\b/.test(t) ? 'shown' : null; })()`],
      ['Stats', '#/stats', `(() => { const c = document.querySelector('.stats-column'); return c && c.innerText.trim().length > 20 ? c.innerText.trim().split('\\n')[0].slice(0, 60) : null; })()`],
      ['Mail', '#/mail', `(() => { const t = document.querySelector('main')?.innerText || document.body.innerText; return /between leads/i.test(t) ? 'shown' : null; })()`],
    ];
    for (const [row, hash, check] of views) {
      await page.go(hash);
      const seen = await page.until(check, 8000);
      await page.shot(row.toLowerCase().replace(/\W+/g, '-'));
      record(row, seen ? 'pass' : 'fail', seen ? `${hash}: ${seen}` : `${hash}: nothing shown`);
    }

    // A10: a hosted session's Terminal tab: watch-only, its input disabled. No key is typed (a real session).
    let a10 = null;
    for (const href of sessions.slice(0, 12)) {
      await page.go(href);
      if (!(await page.evaluate(clickTab('.head .segmented button', 'Terminal')))) continue;
      a10 = await page.until(`(() => {
        const screen = document.querySelector('.terminal-screen:not([hidden]) .xterm');
        if (!screen) return null;
        // The page's watch-only state: its pane marked watching (xterm's disableStdin set with it) and its note shown.
        return { watching: !!document.querySelector('.terminal-pane.is-watching'), note: document.querySelector('.terminal-watching:not([hidden])')?.innerText || '' };
      })()`, 8000);
      await page.shot('a10-terminal');
      if (a10) break;
    }
    record('A10 terminal', !a10 ? 'skip' : a10.watching && a10.note ? 'pass' : 'fail',
      !a10 ? 'no hosted session with a terminal' : `watching ${a10.watching}${a10.note ? ', "' + a10.note.trim().replace(/\s+/g, ' ').slice(0, 60) + '"' : ', no watching note'}`);

    // A19: notifications as the page sees them, and its title.
    const a19 = await page.evaluate(`({ permission: typeof Notification === 'undefined' ? 'none' : Notification.permission, title: document.title })`);
    record('A19 notifications', granted && a19.permission === 'granted' ? 'pass' : 'fail', `permission ${a19.permission}, title "${a19.title}" (a notification itself needs a question or prompt)`);

    // A23: the page's token on a socket of its own: answer and send refused (voice), naming nothing that exists.
    const a23 = await page.evaluate(`(async () => {
      const token = sessionStorage.getItem('vibeswitcher.token');
      if (!token) return { error: 'no token in this tab' };
      const ws = new WebSocket(${JSON.stringify(origin.replace(/^http/, 'ws') + '/ws')});
      await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; setTimeout(reject, 5000); });
      const messages = [];
      ws.onmessage = (event) => messages.push(JSON.parse(event.data));
      const reply = async (id) => { for (let i = 0; i < 50; i++) { const m = messages.find((m) => m.re === id); if (m) return m; await new Promise((r) => setTimeout(r, 100)); } return { timeout: true }; };
      ws.send(JSON.stringify({ v: 1, id: 'a', kind: 'auth', args: { token, client: 'acceptance' } }));
      for (let i = 0; i < 50 && !messages.some((m) => m.kind === 'hello'); i++) await new Promise((r) => setTimeout(r, 100));
      ws.send(JSON.stringify({ v: 1, id: '1', kind: 'answer', args: { card: 'local:card:none', text: 'x' }, action: crypto.randomUUID() }));
      const answer = await reply('1');
      ws.send(JSON.stringify({ v: 1, id: '2', kind: 'send', args: { session: 'local:none', text: 'x' }, action: crypto.randomUUID() }));
      const send = await reply('2');
      ws.close();
      return { answer: answer.error?.code || 'not refused', send: send.error?.code || 'not refused' };
    })()`).catch((error) => ({ error: String(error) }));
    record('A23 page token', a23.answer === 'voice' && a23.send === 'voice' ? 'pass' : 'fail', a23.error || `answer ${a23.answer}, send ${a23.send}`);

    // A3: no console error over the whole run.
    record('A3 console', page.consoleErrors.length ? 'fail' : 'pass', page.consoleErrors.length ? page.consoleErrors.slice(0, 3).join(' | ') : 'none');
  } catch (error) {
    record('run', 'fail', error.message);
  } finally {
    try { protocol.socket.close(); } catch {}
    await browser.close().catch((error) => record('cleanup', 'fail', error.message));
    fs.writeFileSync(path.join(out, 'report.json'), JSON.stringify(results, null, 2));
    const width = Math.max(...results.map((r) => r.row.length));
    console.log(`${'row'.padEnd(width)}  outcome  detail`);
    for (const r of results) console.log(`${r.row.padEnd(width)}  ${r.outcome.padEnd(7)}  ${r.detail}`);
    console.log(`screenshots and report.json: ${out}`);
    process.exit(results.some((r) => r.outcome === 'fail') ? 1 : 0);
  }
}

run();
