// Run via scripts/test.sh --web Tests/SecurityAudit. Only synthetic sessions on a scratch host.
import assert from 'node:assert/strict';
import net from 'node:net';
import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { once } from 'node:events';

const binary = process.env.VIBESWITCHER_AUDIT_HOST || path.resolve('.build/debug/vibeswitcher-host');
const folder = await mkdtemp(path.join(tmpdir(), 'audit-'));
const home = path.join(folder, 'home');
await mkdir(home);
const socketPath = path.join(folder, 'host.sock');
const child = spawn(binary, ['--socket', socketPath, '--lock', path.join(folder, 'custom.lock'),
  '--app-executable', process.execPath,
  '--exit-with', String(process.pid), '--idle-exit', '60'], {
  env: { PATH: '/usr/bin:/bin', HOME: home, CFFIXED_USER_HOME: home,
    VIBESWITCHER_HOME: path.join(home, '.vibeswitcher'), TMPDIR: folder, SHELL: '/bin/sh' },
  stdio: 'ignore',
});
const clients = [];
// Hosts started after the first, ended with it.
const others = [];
// Each wait's own: a second host's start isn't held to what the first one's left.
async function eventually(action) {
  const deadline = Date.now() + 20000;
  while (Date.now() < deadline) {
    const result = await action();
    if (result) return result;
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  throw new Error('Scratch host probe timed out');
}
async function connect(at = socketPath) {
  const socket = await eventually(async () => {
    const candidate = net.createConnection(at);
    try { await once(candidate, 'connect'); return candidate; }
    catch { candidate.destroy(); return null; }
  });
  clients.push(socket);
  let buffer = Buffer.alloc(0), seq = 0;
  const answers = new Map();
  socket.on('data', bytes => {
    buffer = Buffer.concat([buffer, bytes]);
    while (buffer.length >= 4 && buffer.length >= 4 + buffer.readUInt32BE()) {
      const size = buffer.readUInt32BE();
      if (buffer[4] === 0) {
        const message = JSON.parse(buffer.subarray(5, 4 + size));
        if (message.replyTo != null) answers.set(message.replyTo, message.event);
      }
      buffer = buffer.subarray(4 + size);
    }
  });
  return async request => {
    const number = ++seq;
    const payload = Buffer.from(JSON.stringify({ seq: number, request }));
    const head = Buffer.alloc(5);
    head.writeUInt32BE(payload.length + 1);
    socket.write(Buffer.concat([head, payload]));
    return eventually(() => answers.get(number));
  };
}
try {
  const creator = await connect();
  // A fresh host must not accept a CLI attempt to designate the attacking client as the app.
  const replaced = await creator({ replaceAppKey: { key: Buffer.alloc(32, 7).toString('base64') } });
  assert.ok(replaced.error, 'Fresh-start CLI arguments must not grant the client app identity');
  // No app proof or session ancestry: this connection must have no terminal authority.
  const created = await creator({ spawn: { _0: { cwd: home,
    command: 'printf "AUDIT_FAKE_SECRET\\n"; read answer; printf "AUDIT_RECEIVED:%s\\n" "$answer"; exec /bin/cat',
    env: {}, cols: 80, rows: 24, keepShell: false, label: 'Synthetic audit', agent: null } } });
  assert.ok(created.error, 'An unknown client must not spawn a terminal');
  const id = '00000000-0000-0000-0000-000000000001';
  const observer = await connect();
  const welcome = await observer({ hello: { protocolVersion: 1, app: 'unauthenticated-audit' } });
  assert.deepEqual(welcome.welcome.sessions, []);
  for (const request of [
    { screen: { id } }, { styledScreen: { id } }, { history: { id, lines: 10 } },
    { attach: { id, cols: 80, rows: 24 } }, { resize: { id, cols: 80, rows: 24 } },
    { input: { id, bytes: Buffer.from('synthetic\n').toString('base64'), reply: false } },
    { inputUnit: { id, writes: [{ bytes: 'DQ==', delay: 0 }], more: false } },
    { kill: { id } }, { remove: { id } }, { shutdown: {} },
  ]) {
    const answer = await observer(request);
    assert.ok(answer.error, `Must refuse ${Object.keys(request)[0]}`);
  }
  console.log('PASS: unknown processes cannot spawn, discover, read, attach, type, resize or shut down the scratch host.');
  // Linux: the tests' stand-in for the app (a connector named by --test-app-connector, for the process named by
  // --test-app-pid) is a scratch host's only. The user's host (here the scratch home's: no --lock, so it holds that
  // home's own) refuses both flags, saying so, and what reaches it by its path is still nobody: every request only the
  // app may make is refused. The Mac has no connector (and its user's host would read the login Keychain).
  if (process.platform === 'linux') {
    const usersSocket = path.join(folder, 'users.sock');
    const usersHome = path.join(folder, 'users-home');
    await mkdir(usersHome);
    const users = spawn(binary, ['--socket', usersSocket, '--exit-with', String(process.pid), '--idle-exit', '600',
      '--housekeeping', '3600', '--test-app-pid', String(process.pid), '--test-app-connector', '3'], {
      env: { PATH: '/usr/bin:/bin', HOME: usersHome, VIBESWITCHER_HOME: path.join(usersHome, '.vibeswitcher'),
        TMPDIR: folder, SHELL: '/bin/sh' },
      stdio: ['ignore', 'ignore', 'pipe', 'pipe'],
    });
    others.push(users);
    let said = '';
    users.stderr.on('data', bytes => { said += bytes; });
    await eventually(async () => said.includes('started'));
    assert.match(said, /refused --test-app-pid and --test-app-connector/, 'The user\'s host must refuse the test stand-in');
    const byPath = await connect(usersSocket);
    for (const request of [
      { census: {} }, { replaceAppKey: { key: Buffer.alloc(32, 7).toString('base64') } },
      { spawn: { _0: { cwd: usersHome, command: 'true', env: {}, cols: 80, rows: 24, keepShell: false, label: 'Audit', agent: null } } },
      { handover: { executable: binary } }, { shutdown: {} },
    ]) {
      const answer = await byPath(request);
      assert.ok(answer.error, `The user's host must refuse ${Object.keys(request)[0]} by its path`);
    }
    console.log('PASS: the user\'s host refuses the test stand-in for the app, and nothing by its path is the app.');

    // Linux: the app is the host's server child, through its connector (S2). A scratch host whose --server is a script
    // that never asks for a connection: neither this audit's client by the path nor a client the script itself starts
    // (by the path too: its connector isn't the client's) may do what only the app may.
    const serverFolder = path.join(folder, 'srv');
    await mkdir(serverFolder);
    const serverSocket = path.join(serverFolder, 'h.sock');
    const appOnly = [
      { proveApp: { answer: Buffer.alloc(32, 1).toString('base64') } },
      { replaceAppKey: { key: Buffer.alloc(32, 7).toString('base64') } },
      { handover: { executable: binary } },
      { vault: { _0: { issue: { role: 'lead', root: path.join(serverFolder, 'repo') } } } },
      { spawn: { _0: { cwd: serverFolder, command: 'true', env: {}, cols: 80, rows: 24, keepShell: false, label: 'Audit', agent: null } } },
    ];
    const frames = appOnly.map((request, index) => {
      const payload = Buffer.from(JSON.stringify({ seq: index + 1, request }));
      const head = Buffer.alloc(5);
      head.writeUInt32BE(payload.length + 1);
      return Buffer.concat([head, payload]);
    });
    await writeFile(path.join(serverFolder, 'server-requests'), Buffer.concat(frames));
    // Its arguments: --host-connector N --host-socket PATH, then its root's. Its client connects by the path (dash can't
    // close the connector, above 9, for it: a byte the client sent on it would be refused as another sender's anyway,
    // ServerChildTests.aChildOfTheServerIsNotTheApp). It ends, its group with it, once the host has gone.
    const script = path.join(serverFolder, 'server.sh');
    await writeFile(script, [
      '#!/bin/sh',
      'dir=$(dirname "$4")',
      '(cat "$dir/server-requests"; exec sleep 3600) | nc -U "$4" >"$dir/server-replies" &',
      'while kill -0 $PPID 2>/dev/null; do sleep 1; done',
      'kill 0',
      '',
    ].join('\n'), { mode: 0o755 });
    const served = spawn(binary, ['--socket', serverSocket, '--lock', path.join(serverFolder, 'h.lock'), '--exit-with', String(process.pid),
      '--idle-exit', '600', '--housekeeping', '3600', '--server', script], {
      env: { PATH: '/usr/bin:/bin', HOME: home, VIBESWITCHER_HOME: path.join(home, '.vibeswitcher'), TMPDIR: folder, SHELL: '/bin/sh' },
      stdio: ['ignore', 'ignore', 'pipe'],
    });
    others.push(served);
    let serverSaid = '';
    served.stderr.on('data', bytes => { serverSaid += bytes; });
    await eventually(async () => serverSaid.includes('server child pid'));
    assert.match(serverSaid, /server child pid \d+ started/, 'The scratch host must start its server child');
    const audit = await connect(serverSocket);
    for (const request of appOnly) {
      const answer = await audit(request);
      assert.ok(answer.error || answer.vault?._0?.refused, `The audit's own client must be refused ${Object.keys(request)[0]}: ${JSON.stringify(answer)}`);
    }
    // The script's client's answers, as its nc wrote them.
    const answers = await eventually(async () => {
      let bytes;
      try { bytes = await readFile(path.join(serverFolder, 'server-replies')); } catch { return null; }
      const found = new Map();
      while (bytes.length >= 4 && bytes.length >= 4 + bytes.readUInt32BE()) {
        const size = bytes.readUInt32BE();
        if (bytes[4] === 0) {
          const message = JSON.parse(bytes.subarray(5, 4 + size));
          if (message.replyTo != null) found.set(message.replyTo, message.event);
        }
        bytes = bytes.subarray(4 + size);
      }
      return found.size >= appOnly.length ? found : null;
    });
    appOnly.forEach((request, index) => {
      const answer = answers.get(index + 1);
      assert.ok(answer && (answer.error || answer.vault?._0?.refused),
        `A client the server child starts must be refused ${Object.keys(request)[0]}: ${JSON.stringify(answer)}`);
    });
    assert.doesNotMatch(serverSaid, /app connection made/);
    console.log('PASS: with a server child, neither a client by the path nor a client the server starts is the app.');
  }
} finally {
  clients.forEach(client => client.destroy());
  for (const host of [child, ...others]) {
    if (host.exitCode == null && host.signalCode == null) {
      host.kill('SIGTERM');
      await Promise.race([once(host, 'exit'), new Promise(resolve => setTimeout(resolve, 3000))]);
      if (host.exitCode == null && host.signalCode == null) { host.kill('SIGKILL'); await once(host, 'exit'); }
    }
  }
  await rm(folder, { recursive: true, force: true });
}
