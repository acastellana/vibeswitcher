// Exercise the distribution script's real signing function on copies, without Keychain access.
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdtemp, writeFile, rm, readFile, mkdir, copyFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';

const binary = process.env.VIBESWITCHER_AUDIT_HOST || path.resolve('.build/debug/vibeswitcher-host');
const folder = await mkdtemp(path.join(tmpdir(), 'inject-'));
const source = path.join(folder, 'probe.c');
const library = path.join(folder, 'probe.dylib');
try {
  await writeFile(source, `#include <unistd.h>
__attribute__((constructor)) static void probe(void) {
  write(1, "AUDIT_INJECTED\\n", 15);
  _exit(0);
}
`);
  execFileSync('/usr/bin/clang', ['-dynamiclib', source, '-o', library], { timeout: 60000 });
  const bundle = path.join(folder, 'VibeSwitcher.app');
  const macOS = path.join(bundle, 'Contents/MacOS');
  await mkdir(macOS, { recursive: true });
  await copyFile('Resources/Info.plist', path.join(bundle, 'Contents/Info.plist'));
  const names = ['VibeSwitcher', 'vibeswitcher-hook', 'vibeswitcher-host', 'vibeswitcher-mcp'];
  for (const name of names) await copyFile(binary, path.join(macOS, name));
  const script = await readFile('scripts/build-app.sh', 'utf8');
  const signing = script.match(/^sign\(\) \{\n[\s\S]*?^\}/m)?.[0];
  assert.ok(signing, 'The distribution signing function must remain testable');
  execFileSync('/bin/bash', ['-c', 'APP="$1"; IDENTITY=(--sign -);\n' + signing + '\nsign',
    'audit-sign', bundle], { timeout: 60000, stdio: 'pipe' });
  for (const name of names) {
    const executable = path.join(macOS, name);
    const signature = spawnSync('/usr/bin/codesign', ['-dvv', executable], { encoding: 'utf8' });
    assert.match(signature.stderr, /flags=.*\bruntime\b/, `${name} must enable Hardened Runtime`);
    execFileSync('/usr/bin/codesign', ['--verify', '--strict', executable], { timeout: 10000 });
    // The host's probe exits before any app, socket, terminal or Keychain setup.
    const result = spawnSync(executable, ['--handover-probe', path.join(folder, 'missing-state')], {
      env: { PATH: '/usr/bin:/bin', HOME: folder, CFFIXED_USER_HOME: folder,
        VIBESWITCHER_HOME: path.join(folder, '.vibeswitcher'), TMPDIR: folder,
        DYLD_INSERT_LIBRARIES: library },
      encoding: 'utf8', timeout: 15000, killSignal: 'SIGKILL',
    });
    assert.doesNotMatch(result.stdout || '', /AUDIT_INJECTED/);
    assert.equal(result.status, 1, JSON.stringify(result));
    assert.match(result.stderr, /handover probe/);
  }
  execFileSync('/usr/bin/codesign', ['--verify', '--strict', bundle], { timeout: 10000 });
  console.log('PASS: app and all three helpers reject DYLD injection with valid hardened signatures.');
} finally { await rm(folder, { recursive: true, force: true }); }
