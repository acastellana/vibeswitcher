// Headless Chrome over the DevTools protocol, with Node's own WebSocket (Node 22): nothing installed. Shared by the
// page checks (scripts/e2e/real-page.cjs on the user's node, scripts/e2e/page-check.cjs on a scratch node in CI).
//
// - `launch(chromePath, out)`: Chrome on a profile of its own under `out` (removed by `close`), its DevTools endpoint.
// - `Protocol`: one socket to it, each request answered by its id (30 s at most).
// - `Page`: one tab, its console errors collected (console.error, exceptions, the log's errors), `evaluate`, `until` (a
//   condition polled until it holds: the check waits on what it looks for, never a fixed time), `go`, `shot`.
'use strict';
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Chrome's whole process group (it is started as the group's leader), or Chrome alone if the group is gone.
function killGroup(chrome) {
  try { process.kill(-chrome.pid, 'SIGKILL'); } catch { try { chrome.kill('SIGKILL'); } catch { /* gone */ } }
}

async function launch(chromePath, out) {
  const profile = path.join(out, `chrome-profile-${process.pid}`);
  fs.mkdirSync(profile, { recursive: true });
  const chrome = spawn(chromePath, ['--headless=new', '--no-sandbox', '--remote-debugging-port=0', `--user-data-dir=${profile}`,
    '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--window-size=1500,950', 'about:blank'],
  { stdio: ['ignore', 'ignore', 'pipe'], detached: true });
  chrome.stderr.on('data', () => {});
  const portFile = path.join(profile, 'DevToolsActivePort');
  // Chrome writes the file once it listens; a loaded machine may take a while.
  const end = Date.now() + 60000;
  while (!fs.existsSync(portFile) && Date.now() < end) await pause(100);
  if (!fs.existsSync(portFile)) {
    killGroup(chrome);
    throw new Error(`Chrome at ${chromePath} didn't open its DevTools port in 60 s`);
  }
  const [port, browserPath] = fs.readFileSync(portFile, 'utf8').split('\n');
  return {
    chrome, profile, endpoint: `ws://127.0.0.1:${port}${browserPath}`,
    // Chrome and its helpers (its own process group) ended, then its profile removed: a helper that outlived the
    // browser a moment may still write there, so the removal retries.
    async close() {
      const exited = new Promise((resolve) => { if (chrome.exitCode !== null || chrome.signalCode) resolve(); else chrome.once('exit', resolve); });
      killGroup(chrome);
      await exited;
      fs.rmSync(profile, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 });
    },
  };
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

  // A new tab, attached, its page, runtime and log on.
  async tab(out) {
    const { targetId } = await this.send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await this.send('Target.attachToTarget', { targetId, flatten: true });
    const page = new Page(this, sessionId, out);
    await Promise.all(['Page.enable', 'Runtime.enable', 'Log.enable'].map((method) => page.send(method)));
    return page;
  }
}

class Page {
  constructor(protocol, sessionId, out) {
    this.protocol = protocol;
    this.sessionId = sessionId;
    this.out = out;
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
      await pause(150);
    }
    return null;
  }

  // The page's own routing (`location.hash`): what it draws is waited on by the caller's `until`.
  async go(hash) {
    await this.evaluate(`location.hash = ${JSON.stringify(hash)}`);
  }

  async shot(name) {
    const { data } = await this.send('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(path.join(this.out, `${name}.png`), Buffer.from(data, 'base64'));
  }
}

// Where Chrome is on this machine: `$CHROME` when it names one, else Google Chrome's or Chromium's usual paths. Null
// for none.
function findChrome(env = process.env) {
  const candidates = [env.CHROME, '/opt/google/chrome/chrome', '/usr/bin/google-chrome', '/usr/bin/google-chrome-stable', '/usr/bin/chromium',
    '/usr/bin/chromium-browser'].filter(Boolean);
  return candidates.find((candidate) => { try { fs.accessSync(candidate, fs.constants.X_OK); return true; } catch { return false; } }) || null;
}

module.exports = { launch, Protocol, Page, pause, findChrome, killGroup };
