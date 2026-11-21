// A code block in a reply that is a shell command, as the message that runs it in the session (the app's Run on a code
// block, `Sources/VibeCore/RunnableCommand.swift`, whose rules these follow): `! command`, which Claude Code and Codex
// run in their shell, the output joining the conversation. The page never runs it: Run leaves it as the session's draft
// (`session.draft`), and `vibeswitcher send SESSION` in a terminal shows it whole and asks for the typed code.
//
// What gets a Run, as the app's: a block in a shell language (bash, sh, zsh, shell, console…), or with no language whose
// first line is typed at a prompt (`$ `, `!`); none with a character that draws nothing or moves what is drawn (controls,
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
