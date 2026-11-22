// The real node's page, checked read-only in headless Chrome (scripts/e2e/real-page-check.sh runs it): pair with the URL
// `vibeswitcher web` printed, look at each acceptance row's view, screenshot it, and say pass, fail or skip for each.
//
// Read-only by construction: it navigates between the page's routes and switches the inspector's and a session's
// view tabs; the one button it presses is Brief me (a read). It never presses an option, Send, a draft, Hold, Stop or
// any other control that acts; it types into nothing (A10 is checked by the page's state alone: the hard rule is that
// nothing types into a real session). A23 sends `answer` and `send` on a WebSocket of its own with the page's token,
// naming a card and a session that don't exist, and expects both refused by voice before any handler.
//
// Chrome is driven over the DevTools protocol with Node's own WebSocket (Node 22): nothing installed.
//
// Usage: node real-page.cjs URL OUT-FOLDER [CHROME]
'use strict';
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const [url, out, chromePath = '/opt/google/chrome/chrome'] = process.argv.slice(2);
if (!url || !out) {
  console.error('usage: node real-page.cjs URL OUT-FOLDER [CHROME]');
  process.exit(64);
}
const origin = new URL(url).origin;
const results = [];
const record = (row, outcome, detail) => results.push({ row, outcome, detail: String(detail ?? '') });
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// MARK: Chrome and the protocol

async function launch() {
  const profile = path.join(out, `chrome-profile-${process.pid}`);
  fs.mkdirSync(profile, { recursive: true });
  const chrome = spawn(chromePath, ['--headless=new', '--no-sandbox', '--remote-debugging-port=0', `--user-data-dir=${profile}`,
    '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--window-size=1500,950', 'about:blank'],
  { stdio: ['ignore', 'ignore', 'pipe'] });
  chrome.stderr.on('data', () => {});
  const portFile = path.join(profile, 'DevToolsActivePort');
  for (let i = 0; i < 150 && !fs.existsSync(portFile); i++) await pause(100);
  const [port, browserPath] = fs.readFileSync(portFile, 'utf8').split('\n');
  return { chrome, profile, endpoint: `ws://127.0.0.1:${port}${browserPath}` };
}

class Protocol {
  constructor(endpoint) {
    this.next = 1;
    this.waiting = new Map();
    this.listeners = [];
    this.socket = new WebSocket(endpoint);
    this.opened = new Promise((resolve, reject) => { this.socket.onopen = resolve; this.socket.onerror = reject; });
    this.socket.onmessage = (event) => {
      const message = JSON.parse(event.data);
      if (message.id && this.waiting.has(message.id)) {
        const { resolve, reject } = this.waiting.get(message.id);
        this.waiting.delete(message.id);
        if (message.error) reject(new Error(message.error.message)); else resolve(message.result);
      } else if (message.method) {
        for (const listener of this.listeners) listener(message);
      }
    };
  }

  send(method, params = {}, sessionId) {
    const id = this.next++;
    this.socket.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    return new Promise((resolve, reject) => {
      this.waiting.set(id, { resolve, reject });
      setTimeout(() => { if (this.waiting.delete(id)) reject(new Error(`${method}: no answer in 30 s`)); }, 30000);
    });
  }
}

// MARK: The page

class Page {
  constructor(protocol, sessionId) {
    this.protocol = protocol;
    this.sessionId = sessionId;
    this.consoleErrors = [];
    protocol.listeners.push((message) => {
      if (message.sessionId !== sessionId) return;
      if (message.method === 'Runtime.consoleAPICalled' && message.params.type === 'error') {
        this.consoleErrors.push(message.params.args.map((arg) => arg.value ?? arg.description ?? '').join(' '));
      } else if (message.method === 'Runtime.exceptionThrown') {
        this.consoleErrors.push('exception: ' + (message.params.exceptionDetails.exception?.description || message.params.exceptionDetails.text));
      } else if (message.method === 'Log.entryAdded' && message.params.entry.level === 'error') {
        this.consoleErrors.push('log: ' + message.params.entry.text);
      }
    });
  }

  send(method, params) { return this.protocol.send(method, params, this.sessionId); }

  async evaluate(expression) {
    const result = await this.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (result.exceptionDetails) throw new Error(result.exceptionDetails.exception?.description || result.exceptionDetails.text);
    return result.result.value;
  }

  // Waits until `expression` is truthy (its value), or `ms`: the value, or null.
  async until(expression, ms = 10000) {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      const value = await this.evaluate(expression).catch(() => null);
      if (value) return value;
      await pause(200);
    }
    return null;
  }

  async go(hash) {
    await this.evaluate(`location.hash = ${JSON.stringify(hash)}`);
    await pause(400);
  }

  async shot(name) {
    const { data } = await this.send('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(path.join(out, `${name}.png`), Buffer.from(data, 'base64'));
  }
}

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
  const { chrome, profile, endpoint } = await launch();
  const protocol = new Protocol(endpoint);
  try {
    await protocol.opened;
    const { targetId } = await protocol.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await protocol.send('Target.attachToTarget', { targetId, flatten: true });
    const page = new Page(protocol, sessionId);
    await Promise.all(['Page.enable', 'Runtime.enable', 'Log.enable'].map((method) => page.send(method)));
    await page.send('Emulation.setDeviceMetricsOverride', { width: 1500, height: 950, deviceScaleFactor: 1, mobile: false });
    // A19: notifications granted to the page's origin, as the user's click would.
    const granted = await protocol.send('Browser.grantPermissions', { origin, permissions: ['notifications'] }).then(() => true, () => false);

    // A3: paired and connected, the sessions listed.
    await page.send('Page.navigate', { url });
    const connected = await page.until(`!!document.querySelector('.sidebar') && !document.querySelector('.offline:not([hidden])') && !!sessionStorage.getItem('vibeswitcher.token')`, 20000);
    const listed = await page.evaluate(`document.querySelectorAll('.sidebar .row-link').length`);
    await page.shot('a3-start');
    record('A3 pair', connected ? 'pass' : 'fail', connected ? `paired, ${listed} sessions listed` : 'no token or still offline after 20 s');
    if (!connected) return;

    // Brief me: a read; its text shown.
    const asked = await page.evaluate(clickTab('.confirm-clear', 'Brief me'));
    const brief = asked ? await page.until(`(() => { const p = document.querySelector('.brief-text'); return p && !p.hidden && p.innerText.trim().length > 0 ? p.innerText.trim().slice(0, 80) : null; })()`, 60000) : null;
    await page.shot('brief');
    record('Brief me', !asked ? 'skip' : brief ? 'pass' : 'fail', !asked ? 'no Brief me on the start page' : brief || 'no brief in 60 s');

    // A3: a session's chat and the inspector's tabs; dev servers when its row shows.
    const sessions = await page.evaluate(`[...document.querySelectorAll('.sidebar .row-link')].map((a) => a.getAttribute('href'))`);
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
      record('A3 chat', 'skip', 'no session listed');
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
      shell = await page.until(`(() => { const c = document.querySelector('.shell-command'); return c ? c.closest('article').innerText.slice(0, 120) : null; })()`, 1200);
      if (shell) { await page.shot('shell-card'); break; }
    }
    const shellText = shell || '';
    record('Shell card', !shell ? 'skip' : shellText.includes('vibeswitcher answer') ? 'pass' : 'fail', shell ? shellText.replace(/\s+/g, ' ') : 'no shell request waits');

    // A lead's Team tab: its tasks and results.
    const lead = await page.evaluate(`[...document.querySelectorAll('.sidebar .row')].find((row) => /lead/i.test(row.innerText))?.querySelector('.row-link')?.getAttribute('href') || null`);
    if (lead) {
      await page.go(lead);
      await page.until(`!!document.querySelector('.inspector')`, 5000);
      const team = await page.evaluate(clickTab('.inspector .segmented button', 'Team'));
      await pause(1200);
      const seen = await page.evaluate(`({ tasks: document.querySelectorAll('.inspector .task').length, results: !!document.querySelector('.inspector .results, .inspector [data-section="results"]') || /Results/.test(document.querySelector('.inspector')?.innerText || '') })`);
      await page.shot('team-tab');
      record('Team tab', team ? 'pass' : 'fail', team ? `${seen.tasks} tasks${seen.results ? ', results shown' : ''}` : 'no Team tab on the lead');
    } else {
      record('Team tab', 'skip', 'no lead runs');
    }

    // A3: a project's board.
    const boards = await page.evaluate(`[...new Set([...document.querySelectorAll('a[href^="#/p/"]')].map((a) => a.getAttribute('href')))]`);
    if (boards.length) {
      await page.go(boards[0]);
      const board = await page.until(`!!document.querySelector('.board-group')`, 8000);
      await page.shot('a3-board');
      record('A3 board', board ? 'pass' : 'fail', boards[0]);
    } else {
      record('A3 board', 'skip', 'no project board linked');
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
    chrome.kill('SIGKILL');
    await pause(300);
    fs.rmSync(profile, { recursive: true, force: true });
    fs.writeFileSync(path.join(out, 'report.json'), JSON.stringify(results, null, 2));
    const width = Math.max(...results.map((r) => r.row.length));
    console.log(`${'row'.padEnd(width)}  outcome  detail`);
    for (const r of results) console.log(`${r.row.padEnd(width)}  ${r.outcome.padEnd(7)}  ${r.detail}`);
    console.log(`screenshots and report.json: ${out}`);
    process.exit(results.some((r) => r.outcome === 'fail') ? 1 : 0);
  }
}

run();
