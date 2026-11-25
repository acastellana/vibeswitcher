// A phone's on-screen keyboard. Chrome on Android resizes the page under it (index.html's `interactive-widget`), so
// `dvh` follows; Safari on iOS keeps the page's height and only the visual viewport shrinks and pans. Either way, while
// a text box has the focus and the visual viewport is well short of the tallest it has been at this width, the root
// gets `keyboard` and the visible part's height and top (`--vv-height`, `--vv-top`), which style.css's phone block
// gives the page, and the box that has the focus is brought back into sight: the lead's message box with the
// conversation's end above it, any other box (a card's answer, a session's) where it is.
//
// followKeyboard({ root, win, doc, phone }) → { fit } (fit: measure now, for a test or a caller that knows better)

const EDITABLE = 'input:not([type="checkbox"]):not([type="radio"]):not([type="button"]):not([type="submit"]), textarea, [contenteditable="true"]';
// Less than this short of the tallest: a toolbar coming and going, not a keyboard.
const SLACK = 120;

export function followKeyboard({ root, win = globalThis, doc = globalThis.document, phone = () => true }) {
  const vv = win.visualViewport;
  if (!vv || !root) return { fit() {} };
  let tallest = 0;
  let width = 0;
  let up = false;
  function fit() {
    if (vv.width !== width) { width = vv.width; tallest = 0; }
    const active = doc.activeElement;
    const editing = !!active?.matches?.(EDITABLE);
    // The tallest is learnt with no keyboard up: a page opened with a box already focused learns it once it closes.
    if (!editing || vv.height > tallest) tallest = Math.max(tallest, vv.height);
    const keyboard = phone() && editing && vv.height < tallest - SLACK;
    root.classList.toggle('keyboard', keyboard);
    if (keyboard) {
      root.style.setProperty('--vv-height', `${Math.round(vv.height)}px`);
      root.style.setProperty('--vv-top', `${Math.round(vv.offsetTop || 0)}px`);
    } else {
      root.style.removeProperty('--vv-height');
      root.style.removeProperty('--vv-top');
    }
    if (keyboard && !up) win.requestAnimationFrame(() => reveal(active));
    up = keyboard;
  }
  // The lead's box: the conversation's last line just above it. Any other box: into sight where it is.
  function reveal(active) {
    if (doc.activeElement !== active) return;
    const lead = active.closest?.('.composer-lead');
    const scroll = lead ? lead.parentNode?.querySelector?.('.centre-scroll') : null;
    if (scroll) scroll.scrollTop = scroll.scrollHeight;
    else active.scrollIntoView?.({ block: 'nearest' });
  }
  vv.addEventListener('resize', fit);
  vv.addEventListener('scroll', fit);
  doc.addEventListener('focusin', fit);
  doc.addEventListener('focusout', () => win.requestAnimationFrame(fit));
  fit();
  return { fit };
}
