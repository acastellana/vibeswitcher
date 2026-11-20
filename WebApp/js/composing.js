// What the page's composer works out as you type (the composer's lane, 2026-11-20): the word at the caret that asks for
// completion, as the app's composer finds it (`ComposerToken.at`), and an image put in the parts the node takes
// (`session.attach`: a page's message is at most 64 KiB).

// The word being typed at `caret` when it asks for completion: `/command` at the start of the message, or `@file`
// anywhere. { kind: 'slash' | 'mention', query, start, end } (offsets in UTF-16 units, as a textarea counts), or null.
export function tokenAt(text, caret) {
  if (caret < 0 || caret > text.length) return null;
  let start = caret;
  while (start > 0 && !/\s/.test(text[start - 1])) start -= 1;
  if (start === caret) return null;
  const word = text.slice(start, caret);
  if (word.startsWith('/') && start === 0) return { kind: 'slash', query: word.slice(1), start, end: caret };
  if (word.startsWith('@')) return { kind: 'mention', query: word.slice(1), start, end: caret };
  return null;
}

// `text` with the token replaced by `insert`, and where the caret goes: just after it.
export function accept(text, token, insert) {
  const rest = text.slice(token.end).replace(/^\s+/, '');
  return { text: text.slice(0, token.start) + insert + rest, caret: token.start + insert.length };
}

// The image types the node keeps as they are; anything else is drawn again as a PNG or JPEG first.
export const IMAGE_TYPES = ['image/png', 'image/jpeg', 'image/gif', 'image/webp'];
// The most an image may be, and the size of a part's bytes (base64 makes them a third larger, under 64 KiB).
export const MAX_IMAGE = 5 * 1024 * 1024;
export const PART = 36 * 1024;

// `bytes` (a Uint8Array) as base64.
export function base64(bytes) {
  let text = '';
  for (let i = 0; i < bytes.length; i += 8192) text += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return btoa(text);
}

// The parts `bytes` goes in, each { part, parts, data } for `session.attach`.
export function parts(bytes) {
  const count = Math.max(1, Math.ceil(bytes.length / PART));
  return Array.from({ length: count }, (_, part) => ({ part, parts: count, data: base64(bytes.subarray(part * PART, (part + 1) * PART)) }));
}
