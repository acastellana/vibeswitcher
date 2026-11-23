// The rest of the Mac's Team tab: a result's screenshots (records.js's Results, `board.image`), and a task's details as
// its row opens (`TeamRowDetails`, `board.task`: why it last failed, its checkpoints, the worker's report, the audit and
// its findings, its merge and its score line). Read-only; asked of the node only when shown.

import { h, setText } from '../dom.js';
import { icon } from '../marks.js';
import { clock, moment } from '../words.js';
import { imageLoader } from '../images.js';
import { t } from '../i18n.js';

// A result's screenshots, as the chat's: its bytes asked a part at a time (`board.image`), shown as an object URL.
function resultImages(app) {
  // The loader's session is the project, its image id the result's and the index.
  return imageLoader((kind, args) => {
    const [update, index] = String(args.id).split('\u0000');
    return app.store.read('board.image', { project: args.session, update, index: Number(index), offset: args.offset });
  });
}

// A result's screenshots for records.js's Results: `(project, result)` → their element (each a picture once its bytes
// came, `board.image`), or null where the node doesn't serve them. At most `SCREENSHOTS` a result, as the node serves.
export const SCREENSHOTS = 6;
export function resultScreenshots(app) {
  const loader = resultImages(app);
  return (project, result) => {
    if (!app.store.can('board.image') || !project || !result.images) return null;
    const pictures = h('div', { class: 'result-images' });
    const count = Math.min(result.images, SCREENSHOTS);
    for (let index = 0; index < count; index++) {
      const holder = h('span', { class: 'image-note' }, icon('file', 12), t('rsScreenshot'));
      pictures.append(holder);
      loader.url(project, { id: `${result.id}\u0000${index}`, mediaType: 'image/png', bytes: 1 }).then((url) => {
        if (!url) return setText(holder, t('rsScreenshotNoLongerAvailable'));
        const picture = h('img', { class: 'chat-image', src: url, alt: t('rsShotAlt', { title: result.title, n: index + 1 }), decoding: 'async' });
        const button = h('button', { class: 'chat-image-button', type: 'button', 'aria-expanded': 'false', onclick: () => {
          const wide = !button.classList.contains('wide');
          button.classList.toggle('wide', wide);
          button.setAttribute('aria-expanded', String(wide));
        } }, picture);
        holder.replaceWith(button);
      });
    }
    if (result.images > count) pictures.append(h('span', { class: 'records-note' }, t('rsMoreKept', { n: result.images - count })));
    return pictures;
  };
}

// A task row's details, asked of the node as the row opens and again when it is opened again later.
export function taskDetails(app) {
  const body = h('div', { class: 'task-details', hidden: true });
  const button = h('button', { class: 'icon-button task-more', type: 'button', 'aria-expanded': 'false', title: t('rsDetails'), 'aria-label': t('rsDetails') }, icon('chevron', 10));
  let key = null;
  let asking = 0;

  function part(title, ...content) {
    return h('div', { class: 'task-part' }, h('div', { class: 'task-part-title' }, title), content);
  }

  function draw(details) {
    const parts = [];
    if (details.failure) parts.push(part(t('rsLastFailure'), h('p', { class: 'task-failure' }, details.failure)));
    if (details.checkpoints?.length) {
      parts.push(part(t('rsCheckpoints'), details.checkpoints.map((checkpoint) => h('div', { class: 'task-checkpoint' },
        h('time', { class: 'records-time' }, checkpoint.at ? clock(checkpoint.at) : ''), h('span', null, checkpoint.text)))));
    }
    if (details.report) parts.push(part(t('rsWorkerReport'), h('p', { class: 'task-report' }, details.report)));
    const audit = details.audit;
    if (audit?.panel) parts.push(part(t('rsAudit'), h('p', { class: 'records-note' }, audit.panel)));
    else if (audit) {
      parts.push(part(audit.last ? t('rsLastAudit') : t('rsAudit'),
        h('p', { class: audit.passes ? 'task-pass' : 'task-failure' }, audit.passes ? t('rsPassed') : t('rsNotPassed', { a: audit.completion, b: audit.integrity })),
        h('p', { class: 'task-report' }, audit.summary || ''), audit.vote ? h('p', { class: 'records-note' }, audit.vote) : null));
    }
    if (details.findings?.length) {
      parts.push(part(details.round ? t('rsFindingsRound', { n: details.round }) : t('rsFindings'), details.findings.map((finding) => h('div', {
        class: 'task-finding' + (finding.status === 'open' ? '' : ' closed') + (finding.blocks ? ' blocks' : ''),
      }, h('span', { class: 'task-finding-severity' }, finding.severity), h('span', null, finding.text)))));
    }
    if (details.merged) parts.push(h('p', { class: 'records-note' }, details.merged));
    if (details.score) parts.push(h('p', { class: 'records-note' + (details.reverted ? ' warn' : '') }, details.score));
    body.replaceChildren(...(parts.length ? parts : [h('p', { class: 'records-note' }, t('rsNothingMoreOnTheBoard'))]));
  }

  function load() {
    const [project, task] = key;
    const mine = ++asking;
    body.replaceChildren(h('p', { class: 'records-note' }, t('rsReadingTheBoard')));
    app.store.read('board.task', { project, task }).then((reply) => {
      if (mine !== asking) return;
      if (reply?.ok) draw(reply.result);
      else body.replaceChildren(h('p', { class: 'records-note' }, reply?.error?.message || t('rsTheNodeCouldnTRead')));
    });
  }

  button.addEventListener('click', (event) => {
    event.preventDefault();
    const opening = body.hidden;
    body.hidden = !opening;
    button.setAttribute('aria-expanded', String(opening));
    if (opening && key) load();
  });

  return {
    button,
    el: body,
    // The task this row shows: `project` (its board's) and the task's `slug`. Hidden where the node takes no `board.task`.
    set(project, slug) {
      button.hidden = !app.store.can('board.task') || !project;
      const next = [project, slug];
      if (key && key[0] === project && key[1] === slug) return;
      key = next;
      if (!body.hidden) load();
    },
  };
}
