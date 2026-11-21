// The chat's extras that need no page (2026-11-21): Copy as Markdown and Export Chat (the Mac's ChatExport), find in
// the chat, the Overview's tokens and cost in words, and the image loader that asks the node for a picture's bytes a
// part at a time. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { chatMarkdown, exportName, findIn, searchText } from '../js/chatops.js';
import { usageWords, costWords, tokenCount } from '../js/activity.js';
import { imageLoader, MOST } from '../js/images.js';

const prompt = (id, text, more = {}) => ({ id, type: 'prompt', at: null, text, steered: false, fromLead: false, images: [], ...more });
const reply = (id, text) => ({ id, type: 'reply', at: null, text });
const tools = (id, list) => ({ id, type: 'tools', at: null, summary: '', tools: list });
const command = (id, line) => ({ id, name: 'Bash', title: line, at: null, detail: { type: 'command', command: line }, result: null });

test('the chat as Markdown is the Mac’s Export Chat: who said it, a run of tools as one quoted line', () => {
  const items = [
    prompt('p1', 'Why does it fail?', { images: [{ id: 'i', mediaType: 'image/png', bytes: 10 }] }),
    tools('t1', [command('c1', 'npm test'), command('c2', 'npm run lint')]),
    reply('r1', 'It reads the **wrong** header.'),
    prompt('p2', 'And the docs', { steered: true }),
    prompt('p3', 'Merge it', { steered: true, fromLead: true }),
    { id: 'n1', type: 'team', at: null, title: 'Report from worker', text: 'Done.' },
    prompt('pending:x', 'not yet', { pending: true }),
  ];
  assert.equal(chatMarkdown(items, 'Claude'), [
    '**You**\n\nWhy does it fail?\n\n_(1 image)_',
    '> Ran 2 commands',
    '**Claude**\n\nIt reads the **wrong** header.',
    '**You (while it worked)**\n\nAnd the docs',
    '**Project lead (while it worked)**\n\nMerge it',
    '**Report from worker**\n\nDone.',
  ].join('\n\n') + '\n');
  assert.equal(chatMarkdown([], 'Codex'), '\n');
});

test('an exported chat’s file name holds no character a file name can’t', () => {
  assert.equal(exportName('Fix: login/logout "now"'), 'Fix- login-logout -now-.md');
  assert.equal(exportName(''), 'Chat.md');
  assert.equal(exportName(null), 'Chat.md');
  assert.ok(exportName('x'.repeat(500)).length <= 123);
});

test('find looks through prompts, replies, messages and each tool’s title and command, case and accents aside', () => {
  const items = [prompt('p1', 'Fix the Café menu'), reply('r1', 'The cafe MENU is fixed.'), tools('t1', [command('c1', 'grep -r menu src')]),
    prompt('pending:y', 'menu again', { pending: true }), reply('r2', 'Nothing here')];
  assert.deepEqual(findIn(items, 'menu'), [0, 1, 2]);
  assert.deepEqual(findIn(items, 'CAFÉ'), [0, 1]);
  assert.deepEqual(findIn(items, '   '), []);
  assert.deepEqual(findIn(items, 'absent'), []);
  assert.match(searchText(items[2]), /grep -r menu src/);
});

test('tokens and cost read as the Mac’s ledger does', () => {
  assert.equal(usageWords({ tokens: { input: 1_234_567, cached: 1_100_000, output: 34_210 } }), '1.2M in (1.1M cached) · 34K out');
  assert.equal(usageWords({ tokens: { input: 950, cached: 0, output: 12 } }), '950 in · 12 out');
  assert.equal(usageWords({ tokens: null }), null);
  assert.equal(costWords({ cost: 1.234, costPartial: false }), '$1.23');
  assert.equal(costWords({ cost: 0.5, costPartial: true }), 'at least $0.50');
  assert.equal(costWords({ cost: null }), null);
  assert.deepEqual([999, 1_000, 9_960, 12_345, 999_600, 12_000_000].map(tokenCount), ['999', '1K', '10K', '12K', '1M', '12M']);
});

// A node that answers `chat.image` from `images` (by id), in parts of `part` bytes, with `tamper` changing a reply.
function node(images, { part = 4, tamper = null } = {}) {
  const asked = [];
  const read = async (kind, args) => {
    asked.push({ kind, ...args });
    const bytes = images[args.id];
    if (!bytes) return { ok: false, error: { code: 'gone' } };
    const slice = bytes.slice(args.offset, args.offset + part);
    let result = { mediaType: 'image/png', bytes: bytes.length, offset: args.offset, data: Buffer.from(slice).toString('base64') };
    if (tamper) result = tamper(result, args);
    return { ok: true, result };
  };
  return { read, asked };
}
const fakeURLs = () => {
  const made = [];
  const revoked = [];
  return { made, revoked, createObjectURL: (blob) => { made.push(blob); return `blob:test/${made.length}`; }, revokeObjectURL: (url) => revoked.push(url) };
};

test('an image’s bytes come a part at a time, by the session and the image’s id, and make one blob of its type', async () => {
  const bytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 1, 2, 3, 4, 5, 6]);
  const { read, asked } = node({ shot: bytes });
  const urls = fakeURLs();
  const loader = imageLoader(read, urls);
  const image = { id: 'shot', mediaType: 'image/png', bytes: bytes.length };
  assert.equal(loader.known('s1', image), null);
  const url = await loader.url('s1', image);
  assert.equal(url, 'blob:test/1');
  assert.deepEqual(asked.map((one) => one.offset), [0, 4, 8]);
  assert.ok(asked.every((one) => one.kind === 'chat.image' && one.session === 's1' && one.id === 'shot'));
  assert.equal(urls.made[0].type, 'image/png');
  assert.deepEqual(new Uint8Array(await urls.made[0].arrayBuffer()), bytes);
  // Had once: at once after, and asked no more.
  assert.equal(loader.known('s1', image), url);
  assert.equal(await loader.url('s1', image), url);
  assert.equal(asked.length, 3);
});

test('no picture from an image of a type not served, too large, gone, or whose parts disagree', async () => {
  const bytes = new Uint8Array(10).fill(7);
  const cases = [
    [{ id: 'svg', mediaType: 'image/svg+xml', bytes: 10 }, {}],
    [{ id: 'big', mediaType: 'image/png', bytes: MOST + 1 }, {}],
    [{ id: 'gone', mediaType: 'image/png', bytes: 10 }, {}],
    [{ id: 'shot', mediaType: 'image/png', bytes: 10 }, { tamper: (result, args) => (args.offset ? { ...result, mediaType: 'image/gif' } : result) }],
    [{ id: 'shot', mediaType: 'image/png', bytes: 10 }, { tamper: (result) => ({ ...result, mediaType: 'text/html' }) }],
    [{ id: 'shot', mediaType: 'image/png', bytes: 10 }, { tamper: (result) => ({ ...result, offset: result.offset + 1 }) }],
    [{ id: 'shot', mediaType: 'image/png', bytes: 10 }, { tamper: (result) => ({ ...result, data: '' }) }],
  ];
  for (const [image, options] of cases) {
    const urls = fakeURLs();
    const url = await imageLoader(node({ shot: bytes }, options).read, urls).url('s1', image);
    assert.equal(url, null, JSON.stringify(image));
    assert.equal(urls.made.length, 0);
  }
});

test('at most two images are asked at once, and one pushed out of the kept ones is let go', async () => {
  let running = 0;
  let most = 0;
  const read = async (kind, args) => {
    running += 1;
    most = Math.max(most, running);
    await new Promise((resolve) => setImmediate(resolve));
    running -= 1;
    return { ok: true, result: { mediaType: 'image/png', bytes: 1, offset: 0, data: 'iQ==' } };
  };
  const urls = fakeURLs();
  const loader = imageLoader(read, urls);
  const all = await Promise.all(Array.from({ length: 70 }, (_, i) => loader.url('s1', { id: `i${i}`, mediaType: 'image/png', bytes: 1 })));
  assert.ok(all.every(Boolean));
  assert.equal(most, 2);
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(urls.revoked.length, 10);
  assert.equal(loader.known('s1', { id: 'i0' }), null);
  assert.equal(loader.known('s1', { id: 'i69' }), 'blob:test/70');
});
