// A chat's items and the ops that change them (the wire contract §6): applied by the store, made by the mock as the
// node makes them. Nothing here touches the page.
//
// An item is the wire's: { id, type: 'prompt' | 'reply' | 'tools' | 'team', at, … }. A chat as the store holds it is
// { items: [], index: Map(id → position) }.

import { plural } from './words.js';

// `ops` applied to `chat` in order, or nothing at all when one of them doesn't fit what the chat holds: a `text` op
// whose `at` isn't the item's text length now (in UTF-16 code units, JavaScript's own), or a `text` or `set` op for an
// item the chat doesn't have. Returns { gap: id } for that, else { touched: [{ type, id }] }.
//
// An `add` whose item carries the `action` of a message this client sent and holds as pending takes that pending
// item's place, so a message is never shown twice.
export function applyOps(chat, ops) {
  // First, whether every op fits: the text lengths and the ids as they will be after each op before it.
  const lengths = new Map();
  const present = new Map();
  const lengthOf = (id) => {
    if (lengths.has(id)) return lengths.get(id);
    const at = chat.index.get(id);
    return at === undefined ? undefined : textLength(chat.items[at]);
  };
  const has = (id) => (present.has(id) ? present.get(id) : chat.index.has(id));
  for (const op of ops) {
    if (op.op === 'add') {
      present.set(op.item.id, true);
      lengths.set(op.item.id, textLength(op.item));
    } else if (op.op === 'set') {
      if (!has(op.item.id)) return { gap: op.item.id };
      lengths.set(op.item.id, textLength(op.item));
    } else if (op.op === 'remove') {
      present.set(op.id, false);
      lengths.delete(op.id);
    } else if (op.op === 'text') {
      if (!has(op.id) || lengthOf(op.id) !== op.at) return { gap: op.id };
      lengths.set(op.id, op.at + op.append.length);
    }
  }
  // Then each, in place.
  const touched = [];
  for (const op of ops) {
    if (op.op === 'add') {
      const pending = op.item.action ? chat.index.get('pending:' + op.item.action) : undefined;
      if (pending !== undefined) {
        chat.index.delete('pending:' + op.item.action);
        chat.items[pending] = op.item;
        chat.index.set(op.item.id, pending);
        touched.push({ type: 'set', id: op.item.id });
      } else if (chat.index.has(op.item.id)) {
        chat.items[chat.index.get(op.item.id)] = op.item;
        touched.push({ type: 'set', id: op.item.id });
      } else {
        chat.items.push(op.item);
        chat.index.set(op.item.id, chat.items.length - 1);
        touched.push({ type: 'add', id: op.item.id, fresh: true });
      }
    } else if (op.op === 'set') {
      chat.items[chat.index.get(op.item.id)] = op.item;
      touched.push({ type: 'set', id: op.item.id });
    } else if (op.op === 'remove') {
      const at = chat.index.get(op.id);
      if (at === undefined) continue;
      chat.items.splice(at, 1);
      chat.index.delete(op.id);
      reindex(chat, at);
      touched.push({ type: 'remove', id: op.id });
    } else if (op.op === 'text') {
      const item = chat.items[chat.index.get(op.id)];
      item.text = (item.text || '') + op.append;
      touched.push({ type: 'text', id: op.id });
    }
    // Rule 3: an op this client doesn't know is skipped.
  }
  return { touched };
}

const textLength = (item) => (typeof item?.text === 'string' ? item.text.length : 0);

export function reindex(chat, from = 0) {
  for (let i = from; i < chat.items.length; i++) chat.index.set(chat.items[i].id, i);
}

// The ops that take `before` to `after` (both lists of items), as the node makes them: an item gone is `remove`; one
// whose only change is text that grew is `text`; any other change is `set`; new items at the end are `add`; an item
// out of place removes what follows it and adds it again.
export function diffOps(before, after) {
  const ops = [];
  const ids = new Set(after.map((item) => item.id));
  for (const item of before) if (!ids.has(item.id)) ops.push({ op: 'remove', id: item.id });
  const kept = before.filter((item) => ids.has(item.id));
  let i = 0;
  for (; i < kept.length && i < after.length && kept[i].id === after[i].id; i++) {
    const old = kept[i];
    const now = after[i];
    if (same(old, now)) continue;
    const grew = typeof old.text === 'string' && typeof now.text === 'string' && now.text.length > old.text.length
      && now.text.startsWith(old.text) && same({ ...old, text: '' }, { ...now, text: '' });
    ops.push(grew ? { op: 'text', id: now.id, at: old.text.length, append: now.text.slice(old.text.length) } : { op: 'set', item: now });
  }
  for (const item of kept.slice(i)) ops.push({ op: 'remove', id: item.id });
  for (const item of after.slice(i)) ops.push({ op: 'add', item });
  return ops;
}

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// "Ran 2 commands · edited 1 file · read 3 files" (ChatTimeline's summary, for a tools item the node didn't write).
export function summaryOf(tools) {
  const count = (type) => tools.filter((tool) => tool.detail?.type === type).length;
  const parts = [];
  const commands = count('command');
  const edits = count('edit') + count('write');
  const reads = count('read');
  const others = tools.length - commands - edits - reads;
  if (commands) parts.push(`ran ${plural(commands, 'command')}`);
  if (edits) parts.push(`edited ${plural(edits, 'file')}`);
  if (reads) parts.push(`read ${plural(reads, 'file')}`);
  if (others) parts.push(`used ${plural(others, 'tool')}`);
  const text = parts.join(' · ');
  return text.charAt(0).toUpperCase() + text.slice(1);
}

// "New since you looked" (the Mac's ChatTimeline marker): the position of the first item after `seen` (the id of the last
// item you had seen), or -1: nothing seen yet, `seen` not among the items (paged out, or gone), or nothing after it.
export function newSince(items, seen) {
  if (!seen) return -1;
  const at = items.findIndex((item) => item.id === seen);
  return at >= 0 && at < items.length - 1 ? at + 1 : -1;
}

// What came since, in a line under the marker: "Ran 2 commands · edited 1 file · 1 reply" (ChatTimeline.summary(of:)).
export function sinceSummary(items) {
  const tools = items.filter((item) => item.type === 'tools').flatMap((item) => item.tools || []);
  const replies = items.filter((item) => item.type === 'reply').length;
  const parts = tools.length ? [summaryOf(tools)] : [];
  if (replies) parts.push(replies === 1 ? '1 reply' : `${replies} replies`);
  const text = parts.join(' · ');
  return text.charAt(0).toUpperCase() + text.slice(1);
}
