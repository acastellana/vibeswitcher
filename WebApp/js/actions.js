// The lines the page drafts for what only the user's voice does (the parity table's page gaps, 2026-11-20): renaming,
// pausing, ending and resuming a session, closing a folder's finished shells, starting one from the palette, and
// editing the node's launch presets. Each is the `vibeswitcher` command to run in a terminal, where the typed code is
// asked; nothing here sends anything. No page in it: the views draw these (views/drive.js, views/start.js, the
// palette), and tests/actions.test.mjs reads them.

// A session as the command line names it: the first 8 characters of its host id (`vibeswitcher send` takes any prefix
// of 4 or more that only one session has).
export const sessionShort = (id) => String(id || '').replace(/^[^:]*:/, '').slice(0, 8);

// `text` as one shell word: as it is when it needs no quoting, else in single quotes, each ' written '\''. What the
// user typed never becomes a command that does something else when pasted.
export function shellWord(text) {
  const value = String(text);
  return /^[A-Za-z0-9._\/:@%+=,-]+$/.test(value) ? value : `'${value.replace(/'/g, `'\\''`)}'`;
}

// The word the command line finds `session` by: its short id for one the node's host runs (a prefix finds only those),
// else its whole id (`local:pts/9`, a session in a terminal of yours), which it matches exactly.
export function sessionWord(session) {
  return session?.hosted ? sessionShort(session.id) : shellWord(session?.id || '');
}

// `vibeswitcher rename`: the name given (trimmed), or with none the session's own name back. Null when there is
// nothing to do: no name typed and none of yours to reset.
export function renameLine(session, typed) {
  const name = String(typed || '').trim();
  if (name) return name === session.name ? null : `vibeswitcher rename ${sessionWord(session)} ${shellWord(name)}`;
  return session.name ? `vibeswitcher rename ${sessionWord(session)}` : null;
}

// The Mac's Pause menu (`RowMenu`), in its order, and the flag each is on the command line.
export const PAUSES = [
  { id: 'indefinitely', label: 'Until I resume it', flag: '' },
  { id: 'hour', label: 'For 1 hour', flag: ' --hours 1' },
  { id: 'morning', label: 'Until tomorrow morning', flag: ' --tomorrow' },
  { id: 'week', label: 'For 1 week', flag: ' --hours 168' },
];

// `vibeswitcher pause` for one of `PAUSES`, or `--off` (Resume Notifications) with `off`.
export function pauseLine(session, choice) {
  const word = sessionWord(session);
  if (choice === 'off') return `vibeswitcher pause ${word} --off`;
  const pause = PAUSES.find((one) => one.id === choice) || PAUSES[0];
  return `vibeswitcher pause ${word}${pause.flag}`;
}

// Whether the page offers to end `session`: one the node's host runs, still running, and no lead's or its team's
// (their lead and `vibeswitcher stop` end those).
export const endable = (session) => !!session?.hosted && !session.ended && !session.role;

export const endLine = (session) => `vibeswitcher end ${sessionShort(session.id)}`;

// `vibeswitcher close-shells FOLDER`: the node's shells in that folder or below that are back at their prompt.
export const closeShellsLine = (folder) => (folder ? `vibeswitcher close-shells ${shellWord(folder)}` : 'vibeswitcher close-shells');

// An ended session of yours (the node's `ended`): the line that starts it again in its conversation, or null when its
// conversation's id wasn't known.
export const resumeLine = (ended) => (ended?.conversation ? `vibeswitcher resume ${sessionShort(ended.session)}` : null);

// The node's ended entry for the session `id`, if it ended lately.
export const endedEntry = (node, id) => (node?.ended || []).find((entry) => entry.session === id) || null;

// The folders the palette offers to start a session in, newest first and each once: those of the sessions the node's
// host runs (by when they started), then those of your sessions that ended lately. At most `limit`.
export function recentFolders(sessions, ended, limit = 5) {
  const hosted = [...sessions].filter((session) => session.hosted && session.cwd && !session.role)
    .sort((a, b) => String(b.startedAt || '').localeCompare(String(a.startedAt || '')))
    .map((session) => session.cwd);
  const seen = new Set();
  const folders = [];
  for (const folder of [...hosted, ...(ended || []).map((entry) => entry.folder)]) {
    if (!folder || seen.has(folder)) continue;
    seen.add(folder);
    folders.push(folder);
    if (folders.length === limit) break;
  }
  return folders;
}

// The folders the palette offers to start a project lead in (the Mac's "Start Project Lead in …"): the shown session's
// folder first, then the recent ones (`recentFolders`), each once, at most `limit`.
export function leadFolders(selected, sessions, ended, limit = 6) {
  const folders = [];
  for (const folder of [selected?.hosted && !selected.role ? selected.cwd : null, ...recentFolders(sessions, ended, limit)]) {
    if (folder && !folders.includes(folder)) folders.push(folder);
  }
  return folders.slice(0, limit);
}

// `vibeswitcher lead FOLDER --goal GOAL` (no goal: the lead plans from its records), each one word.
export function leadLine(folder, goal = '') {
  const said = String(goal || '').trim();
  return `vibeswitcher lead ${shellWord(folder)}${said ? ` --goal ${shellWord(said)}` : ''}`;
}

// The palette's "New … in …" entries for `folders`: each folder's presets as the node lists them (`presetsOf(folder)`,
// its default first; Claude and Shell until the node answers), but those it can't start there.
export function newEntries(folders, presetsOf) {
  const entries = [];
  for (const folder of folders) {
    for (const preset of presetsOf(folder)) {
      if (preset.refused) continue;
      entries.push({ folder, preset });
    }
  }
  return entries;
}

// `vibeswitcher new FOLDER` for `preset` (a built-in by its agent, any other by its name) and an optional model.
export function newLine(folder, preset, model = '') {
  const how = preset.builtIn ? (preset.kind === 'shell' ? ' --agent shell' : preset.kind === 'codex' ? ' --agent codex' : '') : ` --preset ${shellWord(preset.name)}`;
  const chosen = preset.kind !== 'shell' ? String(model || '').trim() : '';
  return `vibeswitcher new ${shellWord(folder)}${how}${chosen ? ` --model ${shellWord(chosen)}` : ''}`;
}

// The variables a preset may set (`SessionPresets.allowedVariables`, the security review of 2026-11-20): the node
// refuses any other, and so does the command line before it asks for a code.
export const PRESET_VARIABLES = [
  'ANTHROPIC_DEFAULT_HAIKU_MODEL', 'ANTHROPIC_DEFAULT_OPUS_MODEL', 'ANTHROPIC_DEFAULT_SONNET_MODEL', 'ANTHROPIC_MODEL',
  'ANTHROPIC_SMALL_FAST_MODEL', 'CLAUDE_CODE_DISABLE_AUTO_MEMORY', 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC',
  'CLAUDE_CODE_DISABLE_TERMINAL_TITLE', 'CLAUDE_CODE_ENABLE_TODO_TOOLS', 'CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS',
  'CLAUDE_CODE_MAX_OUTPUT_TOKENS', 'CLAUDE_CODE_SUBAGENT_MODEL', 'DISABLE_AUTOUPDATER', 'DISABLE_BUG_COMMAND',
  'DISABLE_COST_WARNINGS', 'DISABLE_ERROR_REPORTING', 'DISABLE_NON_ESSENTIAL_MODEL_CALLS', 'DISABLE_TELEMETRY',
  'MAX_MCP_OUTPUT_TOKENS', 'MAX_THINKING_TOKENS',
];

// The built-in presets' names, which no preset of the file may take (they come from VibeSwitcher itself).
const BUILT_IN_NAMES = ['claude', 'codex', 'shell'];

// A preset's words after `claude` are plain words on the node (`SessionPresets.arguments`).
const PLAIN_WORD = /^[A-Za-z0-9_./:=,+@%\[\]-]+$/;

// Why the preset form can't make a line yet (null: it can): the node's own rules, said before the terminal says them.
// `form`: { name, kind ('claude' | 'shell'), args (the words after `claude`), env ([[NAME, VALUE]]) }.
export function presetProblem(form) {
  const name = String(form.name || '').trim();
  if (!name) return 'Give it a name.';
  if (name.startsWith('-')) return 'A name can’t start with -.';
  if (BUILT_IN_NAMES.includes(name.toLowerCase())) return `${name} is a built-in preset’s name: give it a name of its own.`;
  if (form.kind === 'claude') {
    const odd = String(form.args || '').split(/\s+/).filter(Boolean).find((word) => !PLAIN_WORD.test(word));
    if (odd) return `${odd}: Claude’s arguments are plain words here (letters, digits and _ . / : = , + @ % [ ] -).`;
  }
  for (const [variable] of form.env || []) {
    if (!variable) continue;
    if (!PRESET_VARIABLES.includes(variable)) return `${variable} isn’t one of the variables a preset may set.`;
  }
  return null;
}

// The words after `claude` in a preset's command (`claude --model opus` → `--model opus`).
export const presetArgs = (preset) => String(preset?.command || '').trim().replace(/^claude(\s+|$)/, '');

// `vibeswitcher preset add|edit|remove NAME …`: the preset as the form has it (`form`: { name, kind, args, keepShell,
// isDefault, env: [[NAME, VALUE]], unset: [NAME] }). `folder`: a project's preset (its folder), else one for every
// folder. An edit (`original`: the preset as the node lists it) says only what the form changed; a variable is set
// with its value, and one of the preset's taken off with `--unset`.
export function presetLine(op, form, { folder = null, original = null } = {}) {
  const name = String(form.name || '').trim();
  const words = ['vibeswitcher', 'preset', op, shellWord(original?.name || name)];
  if (folder) words.push('--folder', shellWord(folder));
  if (op === 'remove') return words.join(' ');
  const args = String(form.args || '').split(/\s+/).filter(Boolean).join(' ');
  if (op === 'add') {
    if (form.kind === 'shell') words.push('--shell');
    else if (args) words.push('--args', shellWord(args));
    if (form.keepShell) words.push('--keep-shell');
  } else {
    if (name && name !== original.name) words.push('--rename', shellWord(name));
    const kind = form.kind === 'shell' ? 'shell' : 'claude';
    if (kind !== original.kind) words.push(kind === 'shell' ? '--shell' : '--claude');
    if (kind === 'claude' && (args !== presetArgs(original) || kind !== original.kind)) words.push('--args', shellWord(args));
    if (!!form.keepShell !== !!original.keepShell) words.push(form.keepShell ? '--keep-shell' : '--no-keep-shell');
    for (const variable of form.unset || []) words.push('--unset', shellWord(variable));
  }
  for (const [variable, value] of form.env || []) if (variable && value) words.push('--env', shellWord(`${variable}=${value}`));
  if (form.isDefault && folder) words.push('--default');
  return words.join(' ');
}

// The start page's recent projects (the Mac's StartPage): the folders of the sessions the node's host runs and of your
// sessions that ended lately (`recentFolders`), then those the node says Claude Code and Codex know (`recent`'s
// `projects`, newest first), each once, at most `limit`; each with the project of the lead that runs there, from the
// node's answer or the leads it lists.
export function recentProjects(known, sessions, ended, leads, limit = 8) {
  const leadOf = new Map([...leads].filter((lead) => lead.root).map((lead) => [lead.root, lead.project]));
  const rows = [];
  const seen = new Set();
  const add = (folder, lead) => {
    if (!folder || seen.has(folder) || rows.length >= limit) return;
    seen.add(folder);
    rows.push({ folder, lead: lead || leadOf.get(folder) || null });
  };
  for (const folder of recentFolders(sessions, ended, limit)) add(folder, null);
  for (const project of known || []) add(project.folder, project.lead);
  return rows;
}

// The lines that start work in a recent project: a Claude session there, and its project lead (none while one runs:
// its board is a click away instead).
export function projectLines(row) {
  return { session: `vibeswitcher new ${shellWord(row.folder)}`, lead: row.lead ? null : leadLine(row.folder) };
}
