// A chat's images (the Mac's image viewer, its inline picture): the bytes asked of the node (`chat.image`, by the
// session's id and the image's id in its chat, never a path) a part at a time, and shown as an object URL. The page's
// CSP lets an <img> load `blob:` URLs it made, and nothing else that isn't its own.
//
// - Only the types the node serves (PNG, JPEG, GIF, WebP), at most `MOST` bytes, and only when every part's type and
//   size agree with the first's: anything else is no picture, and the row keeps its line of words.
// - At most `AT_ONCE` images are asked at a time (each part is a quarter of the socket's queue at most), the rest wait.
// - Kept by session and id, the newest `KEPT` and at most `KEPT_BYTES` of them: a row drawn again shows its picture at
//   once; one pushed out is let go (`URL.revokeObjectURL`). Used one moves to the newest end, so the pictures a chat
//   shows stay while older ones go first: a chat of more than 60 pictures doesn't ask for them all again as it draws.

export const TYPES = ['image/png', 'image/jpeg', 'image/gif', 'image/webp'];
export const MOST = 8 << 20;
const AT_ONCE = 2;
export const KEPT = 400;
export const KEPT_BYTES = 96 << 20;

function bytesOf(base64) {
  const text = atob(base64);
  const bytes = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i);
  return bytes;
}

// `read(kind, args)` answers a read as the store's does (a promise of the reply). `urls` makes and lets go object URLs
// (the browser's `URL` by default; tests give their own).
export function imageLoader(read, urls = URL) {
  const kept = new Map();     // `${session} ${id}` → promise of a URL or null
  const ready = new Map();    // the same keys → the URL, once it is made
  const sizes = new Map();    // the same keys → its bytes, as the node said
  let bytes = 0;
  const waiting = [];
  let running = 0;

  function next() {
    while (running < AT_ONCE && waiting.length) {
      const job = waiting.shift();
      running += 1;
      fetchAll(job.session, job.id).then(job.resolve, () => job.resolve(null)).finally(() => { running -= 1; next(); });
    }
  }

  async function fetchAll(session, id) {
    const parts = [];
    let type = null;
    let total = null;
    let have = 0;
    do {
      const reply = await read('chat.image', { session, id, offset: have });
      const result = reply?.ok ? reply.result : null;
      if (!result || typeof result.data !== 'string' || result.offset !== have) return null;
      if (type === null) {
        type = result.mediaType;
        total = result.bytes;
        if (!TYPES.includes(type) || !Number.isInteger(total) || total <= 0 || total > MOST) return null;
      } else if (result.mediaType !== type || result.bytes !== total) {
        return null;
      }
      const part = bytesOf(result.data);
      if (!part.length) return null;
      parts.push(part);
      have += part.length;
    } while (have < total);
    if (have !== total) return null;
    return urls.createObjectURL(new Blob(parts, { type }));
  }

  return {
    // A promise of the object URL of image `image` (the chat's `{ id, mediaType, bytes }`) of `session`, or of null.
    url(session, image) {
      if (!image?.id || !TYPES.includes(image.mediaType) || !(image.bytes > 0) || image.bytes > MOST) return Promise.resolve(null);
      const key = `${session} ${image.id}`;
      if (kept.has(key)) {
        const found = kept.get(key);
        kept.delete(key);
        kept.set(key, found);
        return found;
      }
      const made = new Promise((resolve) => { waiting.push({ session, id: image.id, resolve }); next(); });
      kept.set(key, made);
      sizes.set(key, image.bytes);
      bytes += image.bytes;
      // One that couldn't be had is asked again next time.
      made.then((url) => {
        if (url === null && kept.get(key) === made) { kept.delete(key); bytes -= sizes.get(key) || 0; sizes.delete(key); }
        else if (url !== null && kept.get(key) === made) ready.set(key, url);
      });
      while (kept.size > KEPT || (bytes > KEPT_BYTES && kept.size > 1)) {
        const [oldest, promise] = kept.entries().next().value;
        kept.delete(oldest);
        ready.delete(oldest);
        bytes -= sizes.get(oldest) || 0;
        sizes.delete(oldest);
        promise.then((url) => { if (url) urls.revokeObjectURL(url); });
      }
      return made;
    },
    // The URL of an image already had, at once; else null (a row drawn again shows its picture with no flicker).
    known(session, image) {
      if (!image?.id) return null;
      const key = `${session} ${image.id}`;
      const url = ready.get(key) || null;
      // Seen again: the newest, the last to go.
      if (url && kept.has(key)) { const promise = kept.get(key); kept.delete(key); kept.set(key, promise); }
      return url;
    },
  };
}
