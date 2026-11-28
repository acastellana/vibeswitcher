// A card too large for a snapshot's part (the node's stub, `tooLarge`), read whole in parts (the no-terminal inventory's
// C7): `questions` with the card's id and `part`, from 0, then each next part with the `version` the first gave. Every
// part must name the same card, version and count; joined they must be the length the first said and, where the
// browser can hash (a secure origin), the SHA-256 the version is; then the JSON is that card. Anything else fails
// closed: nothing of a card is shown from parts that don't fit together. A node that changed the card meanwhile says
// `changed`: the read is started again by the store (a few times), never joined across versions.

// The node's bounds (`Requests.cardPartBytes`, `Requests.mostCardParts`): a part past them isn't taken.
export const PART_BYTES = 96 * 1024;
export const MOST_PARTS = 64;

const hex = (buffer) => [...new Uint8Array(buffer)].map((byte) => byte.toString(16).padStart(2, '0')).join('');

// The SHA-256 of `bytes` as lower-case hex, or null where the browser has no hashing (not a secure origin).
export async function sha256(bytes) {
  const subtle = globalThis.crypto?.subtle;
  if (!subtle) return null;
  return hex(await subtle.digest('SHA-256', bytes));
}

function decode(data) {
  if (typeof data !== 'string') return null;
  try {
    const binary = atob(data);
    const bytes = new Uint8Array(binary.length);
    for (let at = 0; at < binary.length; at++) bytes[at] = binary.charCodeAt(at);
    return bytes;
  } catch {
    return null;
  }
}

// Reads card `id` in parts through `request(kind, args)` (the store's). `progress(got, of)` after each part. Resolves
// to { card, version } (the card's whole value), { changed: true } (the node's card moved on while it was read),
// { older: true } (a node from before parts: it answered the card read without one), or { failed, error } (why not,
// the node's error when it gave one).
export async function readCardParts(request, id, { progress = () => {}, digest = sha256 } = {}) {
  const ask = (part, version) => request('questions', { card: id, part, ...(version ? { version } : {}) });
  const odd = { failed: 'odd' };
  let head = null;
  const chunks = [];
  for (let index = 0; head === null || index < head.parts; index++) {
    const reply = await ask(index, head?.version);
    if (!reply?.ok) return reply?.error?.code === 'changed' ? { changed: true } : { failed: 'refused', error: reply?.error || null };
    const part = reply.result?.part;
    if (!part) return index === 0 ? { older: true } : odd;
    if (head === null) {
      if (part.card !== id || typeof part.version !== 'string' || !Number.isInteger(part.parts) || part.parts < 1 || part.parts > MOST_PARTS
        || !Number.isInteger(part.bytes) || part.bytes < 0 || part.bytes > PART_BYTES * MOST_PARTS) return odd;
      head = part;
    }
    if (part.card !== id || part.version !== head.version || part.parts !== head.parts || part.bytes !== head.bytes || part.part !== index) return odd;
    const bytes = decode(part.data);
    if (!bytes || bytes.length > PART_BYTES || (index < head.parts - 1 && bytes.length !== PART_BYTES)) return odd;
    chunks.push(bytes);
    progress(index + 1, head.parts);
  }
  const whole = new Uint8Array(head.bytes);
  let at = 0;
  for (const chunk of chunks) {
    if (at + chunk.length > whole.length) return odd;
    whole.set(chunk, at);
    at += chunk.length;
  }
  if (at !== head.bytes) return odd;
  const hashed = await digest(whole);
  if (hashed !== null && hashed !== head.version) return odd;
  let card;
  try {
    card = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(whole));
  } catch {
    return odd;
  }
  if (!card || typeof card !== 'object' || card.id !== id) return odd;
  return { card, version: head.version };
}
