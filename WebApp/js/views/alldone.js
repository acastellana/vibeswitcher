// The all-done card (the app's `AllDoneCard`): where a lead's board cleared, t('adAllTasksFinished'), the batch's summary
// (a headline and bullets), what it cost, and its tasks folded, each with how it ended. The board shows its newest
// (views/board.js), the lead's chat each one in its place (views/chat.js). Drawn from the node's value: nothing asked.
//
// The mark ("all done" on the project's row, the card at the end of its lead conversation) stays until it is dismissed
// (P-s1, the app's `AllDoneWatch.see`): Dismiss sends `seen {project}`, a read any page may send, and the node keeps
// the mark seen (`seen` on the board's `allDone`), so it stays gone after a reload. It goes at once here: the mark's id
// is kept as dismissed while the node is asked, and given back, with why, if the node refuses. The next batch's mark
// has its own id, so it shows again. The lead's chat keeps every card in its place.

import * as kit from '../kit.js';
import { h } from '../dom.js';
import { allDoneCard, since } from '../words.js';
import { t } from '../i18n.js';
import { refusalWords } from '../acting.js';

export function allDoneView(mark, { className = 'board-group all-done', dismiss = null } = {}) {
  const card = allDoneCard(mark);
  const title = kit.sectionTitle('h2', { class: 'board-group-head' }, h('span', null, t('adAllTasksFinished')),
    mark.at ? h('time', { class: 'board-task-when', data: { since: mark.at } }, since(mark.at)) : null);
  return h('section', { class: className, 'aria-label': t('adAllTasksFinished') },
    dismiss ? h('div', { class: 'all-done-head' }, title,
      kit.button('quiet', { size: 's', class: 'all-done-dismiss', title: t('adDismissTitle'), onclick: dismiss }, t('adDismiss'))) : title,
    card.headline ? h('p', { class: 'all-done-headline' }, card.headline) : h('p', { class: 'node-says' }, t('adWritingAShortSummaryOf')),
    card.bullets.length ? h('ul', { class: 'all-done-bullets' }, card.bullets.map((bullet) => h('li', null, bullet))) : null,
    card.cost ? h('p', { class: 'all-done-cost', title: card.costNote || '' }, card.cost) : null,
    h('details', { class: 'all-done-tasks' }, h('summary', null, card.count),
      h('ul', null, card.tasks.map((task) => h('li', { class: task.merged ? 'merged' : '' }, `${task.title} (${task.word})`)))));
}

// The marks dismissed on this page, by id, while the node is asked (and after: a board value from before the node
// marked it seen may still come).
const dismissed = new Set();

// The board's all-done mark while it still wants the user's look: not seen by the node, not dismissed here. Else null.
export function unseenAllDone(board) {
  const mark = board?.allDone;
  return mark && !mark.seen && !dismissed.has(mark.id) ? mark : null;
}

// Dismisses `project`'s mark: gone at once (the views that draw it are told, through the store's `boards`), then the
// node asked to keep it seen (`seen {project}`). Resolves with { ok } or { ok: false, why } (words), the mark back.
export async function dismissAllDone(store, project, mark) {
  const redraw = () => store.change?.('boards', [{ id: project, value: store.state.boards.get(project) ?? null }]);
  dismissed.add(mark.id);
  redraw();
  const reply = await store.request('seen', { project }).catch((error) => ({ ok: false, error: { message: String(error?.message || error) } }));
  if (reply?.ok) return { ok: true };
  dismissed.delete(mark.id);
  redraw();
  return { ok: false, why: refusalWords(reply?.error) };
}
