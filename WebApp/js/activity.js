// The inspector's Activity tab, as the Mac's `ActivityFeed` reads it (Sources/VibeCore/ActivityFeed.swift): the files
// a session changed with their +/− line counts, and the commands it ran, oldest first. It is made from the chat's own
// items (README.md, "Chat item") and from nothing else, so it says only what the node sent: a line count is counted
// from an edit's two texts, a command's time from its call and its result. What the transcript knows and the chat's
// items don't carry (an exit code, a turn's tokens and cost) isn't shown.

import { diffLines } from './text.js';
import { tilde } from './words.js';

// The newest rows kept (ActivityFeed.read's limit).
export const LIMIT = 80;

// A path for reading: inside the session's folder it is relative to it; else under the home folder it starts at ~.
function relative(path, cwd, home) {
  const root = (cwd || '').replace(/\/+$/, '');
  return root && path.startsWith(root + '/') ? path.slice(root.length + 1) : tilde(path, home);
}

const lineCount = (text) => (text === '' ? 0 : text.replace(/\n$/, '').split('\n').length);

// The lines one call added and removed. `counts` keeps them by the call's id: an edit's texts don't change once made,
// and a chat's items are given again whole at every change.
function counted(tool, counts) {
  const kept = counts.get(tool.id);
  if (kept) return kept;
  let added = 0;
  let removed = 0;
  if (tool.detail.type === 'write') added = lineCount(tool.detail.content || '');
  else {
    for (const change of tool.detail.changes || []) {
      for (const line of diffLines(change.old || '', change.new || '')) {
        if (line.sign === '+') added += 1;
        else if (line.sign === '-') removed += 1;
      }
    }
  }
  const made = { added, removed };
  counts.set(tool.id, made);
  return made;
}

// The node's items (the wire contract §6: a run of tools is one `tools` item, `type` says what each is) as one entry a
// prompt and one a tool call; the mock's older shape (`kind`, a tool a row) passes as it is.
function flat(items) {
  const out = [];
  for (const item of items) {
    if (item.type === 'tools') for (const tool of item.tools || []) out.push({ ...tool, kind: 'tool' });
    else if (item.type && !item.kind) out.push({ ...item, kind: item.type });
    else out.push(item);
  }
  return out;
}

// The rows for a chat's `items`:
//
//   { key, kind: 'file', path, folder, name, verb: 'Edited' | 'Written', edits, added, removed, replaced }
//   { key, kind: 'command', title, line, took, failed, running }
//
// A file changed several times in one turn (from one prompt to the next) is one row, where it was first changed, with
// its counts summed. `folder` and `name` are `path` in two parts (the folder may be cut short, the name never is);
// `replaced` says the file was edited, so its removed lines count even at 0. A command's `line` is its first line,
// when its title is something else; `took` is seconds, null while it runs or when either time is missing.
export function ledger(items, { cwd = null, home = null, counts = new Map() } = {}) {
  const rows = [];
  let turn = 'start';
  let files = new Map();
  for (const item of flat(items)) {
    if (item.kind === 'prompt') {
      turn = item.id;
      files = new Map();
      continue;
    }
    if (item.kind !== 'tool' || !item.detail) continue;
    const detail = item.detail;
    if ((detail.type === 'edit' || detail.type === 'write') && detail.path) {
      // A change that didn't land changed nothing.
      if (item.result?.failed) continue;
      const { added, removed } = counted(item, counts);
      let row = files.get(detail.path);
      if (!row) {
        const path = relative(detail.path, cwd, home);
        const cut = path.lastIndexOf('/') + 1;
        row = { key: `file|${turn}|${detail.path}`, kind: 'file', path, folder: path.slice(0, cut), name: path.slice(cut), verb: 'Written', edits: 0, added: 0, removed: 0, replaced: false };
        files.set(detail.path, row);
        rows.push(row);
      }
      row.edits += 1;
      row.added += added;
      row.removed += removed;
      if (detail.type === 'edit') {
        row.verb = 'Edited';
        row.replaced = true;
      }
    } else if (detail.type === 'command') {
      const first = (detail.command || '').split('\n')[0];
      const more = (detail.command || '').includes('\n');
      const line = first + (more ? ' …' : '');
      const title = item.title && item.title !== detail.command ? item.title : line;
      const from = Date.parse(item.at);
      const to = Date.parse(item.result?.at);
      rows.push({
        key: 'command|' + item.id, kind: 'command', title, line: title === line ? null : line,
        took: item.result && Number.isFinite(from) && Number.isFinite(to) ? Math.max(0, (to - from) / 1000) : null,
        failed: !!item.result?.failed, running: !item.result,
      });
    }
  }
  return rows.length > LIMIT ? rows.slice(rows.length - LIMIT) : rows;
}

// "Edited, 3 times": what a file's row says under its path (ActivityRow.lines).
export function fileWords(row) {
  return row.verb + (row.edits > 1 ? `, ${row.edits} times` : '');
}
