// A code block in a reply that is a shell command, as the message that runs it in the session (the app's Run on a code
// block, `Sources/VibeCore/RunnableCommand.swift`, whose rules these follow): `! command`, which Claude Code and Codex
// run in their shell, the output joining the conversation. The page never runs it: Run leaves it as the session's draft
// (`session.draft`), and `vibeswitcher send SESSION` in a terminal shows it whole and asks for the typed code.
//
// What gets a Run, as the app's: a block in a shell language (bash, sh, zsh, shell, console…), or with no language whose
// first line is typed at a prompt (`$ `, `!`) or whose only line reads as one plain command (`untagged`, main's aa652c58:
// a known command word or a path first, not a sentence); none with a character that draws nothing or moves what is drawn (controls,
// format characters, blank-looking fillers, any space but a plain one), a heredoc, an open quote, or a long blank run that
// pushes the rest of a line out of sight. Several lines run joined with `&&` only when each stands on its own; a block
// whose lines mean something only together (the app runs it from a script file) gets no Run on the page.

const SHELLS = new Set(['bash', 'sh', 'zsh', 'shell', 'shellscript', 'console', 'terminal']);
const COMPOUND = new Set(['if', 'then', 'else', 'elif', 'fi', 'for', 'while', 'until', 'do', 'done', 'case', 'esac', 'select', 'function', '{', '}', '(', ')']);

// Characters that don't show, or change how what's around them shows (the app's `hasHiddenCharacters`, and the
// shell card's blank-looking ones): controls but tab and newline, format characters, separators and spaces other than
// a plain space, private use, unassigned, variation selectors, the combining grapheme joiner, the fillers.
const HIDDEN = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Co}\p{Cn}\p{Cs}\p{Zs}\u{FE00}-\u{FE0F}\u{E0100}-\u{E01EF}͏ᅟᅠ⠀ㅤﾠ]/u;

export function hasHidden(text) {
  for (const ch of text) {
    if (ch === '\n' || ch === '\t' || ch === ' ') continue;
    if (HIDDEN.test(ch)) return true;
  }
  return false;
}

// Whether quotes and backticks close on the line, and whether an unquoted `#` starts a comment in it.
export function scan(line) {
  let quote = null;
  let escaped = false;
  let previous = ' ';
  for (const ch of line) {
    const before = previous;
    previous = ch;
    if (escaped) { escaped = false; continue; }
    if (quote === "'") { if (ch === "'") quote = null; continue; }
    if (ch === '\\') { escaped = true; continue; }
    if (quote) { if (ch === quote) quote = null; continue; }
    if (ch === "'" || ch === '"' || ch === '`') quote = ch;
    else if (ch === '#' && /\s/.test(before)) return { balanced: true, comment: true };
  }
  return { balanced: quote === null && !escaped, comment: false };
}

const readsAsTyped = (command) => scan(command).balanced && !command.includes(' '.repeat(8)) && !command.includes('\t\t');

function joinsCleanly(command) {
  if (scan(command).comment) return false;
  const words = command.split(/\s+/).filter(Boolean);
  const first = words[0];
  const last = words[words.length - 1];
  if (!first || COMPOUND.has(first) || COMPOUND.has(last) || last.endsWith('()')) return false;
  if ('|&;)}'.includes(command[0])) return false;
  if ('|&;({'.includes(command[command.length - 1])) return false;
  return true;
}

// The message that runs `code` (a fenced block of `language`) in an agent's session, or null when it gets no Run.
export function runnable(code, language) {
  const lang = (language || '').toLowerCase().split(/\s+/)[0] || null;
  if (hasHidden(code) || code.includes('<<')) return null;
  const lines = code.split('\n').map((line) => line.trim());
  const first = lines.find((line) => line) || '';
  const marked = first.startsWith('!') || first.startsWith('$ ');
  if (!lang && !marked) return untagged(lines);
  if (!(lang ? SHELLS.has(lang) : marked)) return null;
  const consoleBlock = lang === 'console' || lang === 'terminal';
  const commands = [];
  let pending = '';
  for (const line of lines) {
    let command = line;
    if (consoleBlock && !pending && !command.startsWith('$ ')) continue;
    for (const prompt of ['$ ', '% ', '!']) {
      if (command.startsWith(prompt)) { command = command.slice(prompt.length).trim(); break; }
    }
    if (!pending && (!command || command.startsWith('#'))) continue;
    if (command.endsWith('\\')) { pending += command.slice(0, -1).trim() + ' '; continue; }
    commands.push(pending + command);
    pending = '';
  }
  if (pending) commands.push(pending.trim());
  if (!commands.length) return null;
  if (!commands.every(readsAsTyped)) return null;
  if (commands.length > 1 && !commands.every(joinsCleanly)) return null;
  const command = commands.join(' && ');
  return { command, prompt: '! ' + command };
}

// A block with no language (a bare fence) whose only line reads as one plain shell command (the app's
// `RunnableCommand.untagged`, main's aa652c58): drafted as that line's tagged block would be. On 2026-11-18 a lead
// showed `cd …/prototype && python3 -m http.server …` in a bare fence and the block had only Copy.
function untagged(lines) {
  const content = lines.filter((line) => line);
  if (content.length !== 1) return null;
  const line = content[0];
  if (!readsAsTyped(line) || !readsAsCommand(line)) return null;
  return { command: line, prompt: '! ' + line };
}

// The programs that risk something (the app's `riskyPrograms`): they run too, from the draft `vibeswitcher send` asks
// a code for, as every Run does.
const RISKY = ['rm', 'rmdir', 'mv', 'cp', 'dd', 'mkfs', 'diskutil', 'sudo', 'su', 'doas', 'chmod', 'chown', 'chgrp', 'kill',
  'killall', 'pkill', 'shutdown', 'reboot', 'halt', 'curl', 'wget', 'eval', 'exec', 'source', '.', 'sh', 'bash',
  'zsh', 'fish', 'python', 'python3', 'node', 'ruby', 'perl', 'osascript', 'launchctl', 'defaults', 'security',
  'ssh', 'scp', 'rsync', 'env', 'xargs', 'nohup', 'command', 'builtin', 'find', 'truncate', 'shred', 'crontab'];

// Words that start a command line (the app's `commandWords`): the programs people run from a chat's code blocks, and
// the risky ones.
export const COMMAND_WORDS = new Set([...RISKY,
  'cd', 'pushd', 'ls', 'cat', 'echo', 'printf', 'pwd', 'open', 'mkdir', 'touch', 'ln', 'du', 'df', 'stat', 'file',
  'head', 'tail', 'less', 'more', 'grep', 'rg', 'sed', 'awk', 'jq', 'yq', 'sort', 'uniq', 'wc', 'diff', 'tree',
  'which', 'type', 'man', 'export', 'unset', 'set', 'time', 'watch', 'sleep', 'test', 'true', 'false', 'ps', 'lsof',
  'top', 'htop', 'tmux', 'screen', 'tar', 'zip', 'unzip', 'gzip', 'gunzip', 'ping', 'dig', 'nc', 'nslookup',
  'git', 'gh', 'npm', 'npx', 'pnpm', 'yarn', 'bun', 'bunx', 'deno', 'pip', 'pip3', 'pipx', 'uv', 'uvx', 'poetry',
  'pytest', 'tox', 'gem', 'bundle', 'rails', 'rake', 'go', 'cargo', 'rustc', 'rustup', 'swift', 'swiftc',
  'xcodebuild', 'xcrun', 'make', 'cmake', 'ninja', 'docker', 'docker-compose', 'podman', 'kubectl', 'helm',
  'terraform', 'brew', 'java', 'mvn', 'gradle', 'php', 'composer', 'dotnet', 'flutter', 'dart', 'sqlite3', 'psql',
  'mysql', 'redis-cli', 'hugo', 'jekyll', 'mkdocs', 'ffmpeg', 'ollama', 'claude', 'codex', 'code', 'vim', 'nvim',
  'nano', 'pbcopy', 'pbpaste', 'say', 'caffeinate', 'http', 'vs-shell', 'vs-heavy', 'vs-wallet', 'passage',
]);

const PATH_WORD = /^[A-Za-z0-9/._~+@-]+$/;

// `NAME=value`: an environment assignment before the command.
const isAssignment = (word) => /^[A-Za-z_][A-Za-z0-9_]*=/.test(word);

// Whether one line reads as a command rather than prose (the app's `readsAsCommand`): after any `NAME=value` words, its
// first word is a known command or a path (`/…`, `./…`, `../…`, `~/…`, or `dir/file.ext`), and it doesn't end like a
// sentence (a letter, then `.`, `:`, `?`, `!` or `,`).
export function readsAsCommand(line) {
  const first = line.split(' ').filter(Boolean).find((word) => !isAssignment(word));
  if (!first) return false;
  if (/\p{L}[.:?!,]$/u.test(line)) return false;
  if (COMMAND_WORDS.has(first)) return true;
  if (!first.includes('/') || !PATH_WORD.test(first)) return false;
  if (['/', './', '../', '~/'].some((start) => first.startsWith(start))) return first.length > 1;
  // A relative path names a file to run: `scripts/build-app.sh`, not `and/or`.
  const name = first.split('/').at(-1);
  return name.slice(1).includes('.') && !name.endsWith('.');
}
