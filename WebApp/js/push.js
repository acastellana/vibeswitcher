// The push a lead asks for (push_remote), as the page shows it in the lead's chat: what goes where, its commits, and
// the two lines that settle it in a terminal, `vibeswitcher push` and `vibeswitcher decline-push` (the node's lead
// value, `push`, while the request is open). Nothing here pushes: a page is never the user's voice; the command shows
// the request and asks for its code where the user's own hands type it.

import { plural } from './words.js';
import { t } from './i18n.js';

// `text` as one shell word, as drive.js writes it: as it is when it needs no quoting, else in single quotes.
const word = (text) => {
  const value = String(text);
  return /^[A-Za-z0-9._\/:@%+=,-]+$/.test(value) ? value : `'${value.replace(/'/g, `'\\''`)}'`;
};

// A URL with no credentials in it: the node sends it so already (`PushText.displayURL`); this holds if one ever doesn't.
const shownURL = (url) => String(url || '').replace(/^([A-Za-z][A-Za-z0-9+.-]*:\/\/)[^/?#]*@/, '$1');

// What the card says of `push`, the lead of `root`'s open request; null when there's none.
export function pushLines(push, root) {
  if (!push || !root) return null;
  const subjects = push.subjects || [];
  return {
    what: t('puWhat', { branch: push.branch, short: push.short, n: push.ahead, target: push.target }),
    url: shownURL(push.url),
    subjects,
    more: Math.max(0, push.ahead - subjects.length),
    push: `vibeswitcher push ${word(root)}`,
    decline: `vibeswitcher decline-push ${word(root)}`,
  };
}

// What came of a push settled from this page (the waiting block's receipt: `outcome` pushed, upToDate or declined, the
// `short` sha and `target` taken at the click), as its line in the lead's conversation.
export function pushReceipt(receipt) {
  if (receipt.outcome === 'declined') return t('puDeclined');
  return t(receipt.outcome === 'upToDate' ? 'puUpToDate' : 'puPushed', { target: receipt.target, short: receipt.short });
}
