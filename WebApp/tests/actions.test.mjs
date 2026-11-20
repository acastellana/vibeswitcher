// The lines the page drafts for the user's voice (js/actions.js, the parity table's page gaps of 2026-11-20): a
// session renamed, paused, ended, resumed, its folder's finished shells closed, a session started from the palette, a
// launch preset added, edited or removed. Each is the `vibeswitcher` command a terminal runs (it asks the typed code);
// what the user typed is one shell word, never more. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  sessionShort, shellWord, sessionWord, renameLine, pauseLine, PAUSES, endable, endLine, closeShellsLine, resumeLine, endedEntry,
  recentFolders, newEntries, newLine, presetProblem, presetLine, presetArgs, PRESET_VARIABLES,
} from '../js/actions.js';

const HOSTED = { id: 'local:3f2a9c41-7d1e-4b8a-9c0f-2e5d6a7b8c9d', hosted: true, cwd: '/home/me/site', name: null, role: null };
const MINE = { id: 'local:pts/9', hosted: false, cwd: '/home/me/notes', name: null, role: null };

// What a shell makes of a line: its words, as `sh -c` would split and unquote them (single quotes only: what shellWord writes).
function words(line) {
  const out = [];
  let word = null;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (c === "'") {
      const end = line.indexOf("'", i + 1);
      word = (word || '') + line.slice(i + 1, end);
      i = end;
    } else if (c === '\\') {
      word = (word || '') + line[++i];
    } else if (c === ' ') {
      if (word !== null) out.push(word);
      word = null;
    } else {
      assert.ok(!/[;&|$`<>(){}*?"\n]/.test(c), `an unquoted ${c} in ${line}`);
      word = (word || '') + c;
    }
  }
  if (word !== null) out.push(word);
  return out;
}

test('a session is named by its short id when hosted, by its whole id otherwise', () => {
  assert.equal(sessionShort(HOSTED.id), '3f2a9c41');
  assert.equal(sessionWord(HOSTED), '3f2a9c41');
  assert.equal(sessionWord(MINE), 'local:pts/9');
});

test('rename: the name as one word, its own name back with none, nothing when there is nothing to do', () => {
  const evil = `It's $(rm -rf ~); \`x\``;
  const line = renameLine(HOSTED, `  ${evil} `);
  assert.deepEqual(words(line), ['vibeswitcher', 'rename', '3f2a9c41', evil]);
  assert.equal(renameLine(HOSTED, ''), null, 'no name typed and none to reset');
  assert.equal(renameLine({ ...HOSTED, name: 'Mine' }, ''), 'vibeswitcher rename 3f2a9c41');
  assert.equal(renameLine({ ...HOSTED, name: 'Mine' }, 'Mine'), null, 'already its name');
  assert.deepEqual(words(renameLine(MINE, 'Notes')), ['vibeswitcher', 'rename', 'local:pts/9', 'Notes']);
});

test('pause: the Mac’s four choices and Resume Notifications, as the command line takes them', () => {
  assert.deepEqual(PAUSES.map((pause) => pauseLine(HOSTED, pause.id)), [
    'vibeswitcher pause 3f2a9c41', 'vibeswitcher pause 3f2a9c41 --hours 1', 'vibeswitcher pause 3f2a9c41 --tomorrow', 'vibeswitcher pause 3f2a9c41 --hours 168',
  ]);
  assert.equal(pauseLine(HOSTED, 'off'), 'vibeswitcher pause 3f2a9c41 --off');
  // The command line takes 1 to 720 hours.
  for (const pause of PAUSES) {
    const hours = Number(/--hours (\d+)/.exec(pauseLine(HOSTED, pause.id))?.[1] || 1);
    assert.ok(hours >= 1 && hours <= 720);
  }
});

test('end only an ordinary session the node’s host runs; close shells in its folder', () => {
  assert.ok(endable(HOSTED));
  assert.ok(!endable(MINE), 'one in a terminal of yours');
  assert.ok(!endable({ ...HOSTED, role: 'lead' }) && !endable({ ...HOSTED, role: 'worker' }), 'a lead and its team are their lead’s');
  assert.ok(!endable({ ...HOSTED, ended: true }));
  assert.equal(endLine(HOSTED), 'vibeswitcher end 3f2a9c41');
  assert.deepEqual(words(closeShellsLine('/home/me/my site')), ['vibeswitcher', 'close-shells', '/home/me/my site']);
  assert.equal(closeShellsLine(null), 'vibeswitcher close-shells');
});

test('resume: an ended session with its conversation known, by its short id', () => {
  const node = { ended: [{ session: HOSTED.id, folder: '/home/me/site', name: 'site', conversation: '7a3f0c21-9b4d', at: '' }, { session: 'local:aaaa1111', folder: '/x', name: 'x', conversation: null }] };
  assert.equal(resumeLine(endedEntry(node, HOSTED.id)), 'vibeswitcher resume 3f2a9c41');
  assert.equal(resumeLine(endedEntry(node, 'local:aaaa1111')), null, 'no conversation id: it can’t be resumed');
  assert.equal(endedEntry(node, 'local:nope'), null);
  assert.equal(endedEntry(null, HOSTED.id), null);
});

test('the palette’s folders: the hosted sessions’ newest first, then the ended ones’, each once, no lead’s', () => {
  const sessions = [
    { ...HOSTED, cwd: '/a', startedAt: '2026-11-20T10:00:00Z' },
    { ...HOSTED, cwd: '/b', startedAt: '2026-11-20T12:00:00Z' },
    { ...HOSTED, cwd: '/a', startedAt: '2026-11-20T09:00:00Z' },
    { ...HOSTED, cwd: '/lead', role: 'lead', startedAt: '2026-11-20T13:00:00Z' },
    { ...MINE, cwd: '/mine', startedAt: '2026-11-20T14:00:00Z' },
  ];
  assert.deepEqual(recentFolders(sessions, [{ folder: '/c' }, { folder: '/b' }]), ['/b', '/a', '/c']);
  assert.deepEqual(recentFolders(sessions, [{ folder: '/c' }], 2), ['/b', '/a']);
});

test('“New … in …”: each folder’s presets the node can start, and the line for each', () => {
  const presets = { '/a': [{ name: 'Opus', kind: 'claude', builtIn: false }, { name: 'Codex', kind: 'codex', builtIn: true, refused: 'not here' }, { name: 'Shell', kind: 'shell', builtIn: true }] };
  const entries = newEntries(['/a'], (folder) => presets[folder]);
  assert.deepEqual(entries.map((entry) => entry.preset.name), ['Opus', 'Shell']);
  assert.equal(newLine('/a', entries[0].preset), 'vibeswitcher new /a --preset Opus');
  assert.equal(newLine('/a b', { name: 'Claude', kind: 'claude', builtIn: true }, ' opus '), "vibeswitcher new '/a b' --model opus");
  assert.equal(newLine('/a', entries[1].preset, 'opus'), 'vibeswitcher new /a --agent shell', 'a shell takes no model');
});

test('the preset form’s problems are the node’s rules, said first', () => {
  assert.match(presetProblem({ name: '' }), /name/);
  assert.match(presetProblem({ name: 'shell', kind: 'shell' }), /built-in/);
  assert.match(presetProblem({ name: 'Fast', kind: 'claude', args: '--model $(x)' }), /plain words/);
  assert.match(presetProblem({ name: 'Fast', kind: 'claude', env: [['PATH', '/tmp']] }), /isn’t one of the variables/);
  assert.equal(presetProblem({ name: 'Fast', kind: 'claude', args: '--model opus', env: [['ANTHROPIC_MODEL', 'opus']] }), null);
  assert.equal(PRESET_VARIABLES.length, 20, 'the 20 reviewed variables');
});

test('a preset added, edited and removed: the line names only what changed, each value one word', () => {
  const add = presetLine('add', { name: 'Fast Opus', kind: 'claude', args: ' --model  opus ', env: [['ANTHROPIC_MODEL', 'claude opus'], ['DISABLE_TELEMETRY', '']], keepShell: true, isDefault: true }, { folder: '/home/me/site' });
  assert.deepEqual(words(add), ['vibeswitcher', 'preset', 'add', 'Fast Opus', '--folder', '/home/me/site', '--args', '--model opus', '--keep-shell',
    '--env', 'ANTHROPIC_MODEL=claude opus', '--default']);
  assert.equal(presetLine('add', { name: 'Sh', kind: 'shell', isDefault: true }), 'vibeswitcher preset add Sh --shell', 'a default needs a folder');

  const original = { name: 'Fast', kind: 'claude', command: 'claude --model opus', env: ['ANTHROPIC_MODEL'], keepShell: false };
  assert.equal(presetArgs(original), '--model opus');
  assert.equal(presetLine('edit', { name: 'Fast', kind: 'claude', args: '--model opus', keepShell: false }, { original }), 'vibeswitcher preset edit Fast', 'nothing changed');
  assert.deepEqual(words(presetLine('edit', { name: 'Faster', kind: 'claude', args: '--model sonnet', keepShell: true, unset: ['ANTHROPIC_MODEL'], env: [['MAX_THINKING_TOKENS', '9000']] }, { original, folder: '/s' })),
    ['vibeswitcher', 'preset', 'edit', 'Fast', '--folder', '/s', '--rename', 'Faster', '--args', '--model sonnet', '--keep-shell', '--unset', 'ANTHROPIC_MODEL', '--env', 'MAX_THINKING_TOKENS=9000']);
  assert.equal(presetLine('edit', { name: 'Fast', kind: 'shell' }, { original }), 'vibeswitcher preset edit Fast --shell');
  assert.equal(presetLine('remove', { name: 'Fast' }, { original, folder: '/s' }), 'vibeswitcher preset remove Fast --folder /s');
});

test('what the user typed is always one word, whatever it holds', () => {
  for (const text of ["a'b", "'", "''", 'a b', '$HOME', '`x`', 'a\nb', '-n', '--folder', 'é']) {
    assert.deepEqual(words(`x ${shellWord(text)}`), ['x', text]);
  }
});

test('the variables listed here are the node’s own (SessionPresets.allowedVariables)', () => {
  const swift = readFileSync(join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'Sources', 'VibeNode', 'Server', 'SessionPresets.swift'), 'utf8');
  const block = /allowedVariables: Set<String> = \[([^\]]*)\]/.exec(swift)[1];
  const names = [...block.matchAll(/"([A-Z_]+)"/g)].map((match) => match[1]).sort();
  assert.deepEqual([...PRESET_VARIABLES].sort(), names);
});
