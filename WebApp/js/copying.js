// Copy, for a block of the chat (fenced code, a diff, a tool's output): one button that takes exactly the text it is
// given, says "Copied" for a moment, and where the browser refuses the clipboard selects the block for the keyboard's
// copy and says which keys.

import { h } from './dom.js';
import { icon } from './marks.js';
import { t } from './i18n.js';

const KEY_COPY = /Mac|iPhone|iPad/.test(globalThis.navigator?.platform || '') ? '⌘C' : 'Ctrl+C';
// How long "Copied" stays (the page's other Copy buttons' 1.6 s).
export const COPIED_MS = 1600;

// `text()` to the clipboard: whether it took it.
export async function writeClipboard(text) {
  try {
    await globalThis.navigator.clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}

// A Copy button for a block: `text()` is read at the click, so a block that grew copies what it holds then. `label`
// names what it copies (its title and accessible name); `word` is what it shows; `select()` gives the node to select
// where the clipboard is refused.
export function copyButton(text, label, word = t('cCopy'), select = null) {
  const words = h('span', { class: 'copy-word' }, word);
  const button = h('button', { class: 'copy-button block-copy', type: 'button', title: label, 'aria-label': label }, icon('copy', 13), words);
  let timer = null;
  button.addEventListener('click', async () => {
    const done = await writeClipboard(text());
    if (!done) {
      const node = select?.() || button.closest?.('.code, .diff, .output-box')?.querySelector('code, .diff-lines, pre');
      if (node) globalThis.getSelection?.()?.selectAllChildren(node);
    }
    words.textContent = done ? t('cCopied') : KEY_COPY;
    button.classList.toggle('done', done);
    clearTimeout(timer);
    timer = setTimeout(() => { words.textContent = word; button.classList.remove('done'); }, COPIED_MS);
  });
  return button;
}
