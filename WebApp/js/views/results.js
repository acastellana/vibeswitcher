// The rest of the Mac's Team tab (its `ResultsList` and `TeamRowDetails`): the lead's Results (the board's `results`,
// `post_update`'s cards: a title, a Markdown body drawn as text nodes, and its screenshots, `board.image`), and a task's
// details as its row opens (`board.task`: why it last failed, its checkpoints, the worker's report, the audit and its
// findings, its merge and its score line). Read-only; asked of the node only when shown.

import { h, setText } from '../dom.js';
import { icon } from '../marks.js';
import { clock, moment } from '../words.js';
import { markdown } from '../text.js';
import { imageLoader } from '../images.js';
import { SHOWN } from './records.js';

// A result's screenshots, as the chat's: its bytes asked a part at a time (`board.image`), shown as an object URL.
function resultImages(app) {
  // The loader's session is the project, its image id the result's and the index.
  return imageLoader((kind, args) => {
    const [update, index] = String(args.id).split('\u0000');
    return app.store.read('board.image', { project: args.session, update, index: Number(index), offset: args.offset });
  });
}

export function resultsSection(app) {
  const loader = resultImages(app);
  const list = h('div', { class: 'results-list' });
  const el = h('section', { class: 'inspect-group records-section results', hidden: true }, h('h2', { class: 'group-head' }, 'Results'), list);
  const open = new Set();
  let drawn = '';

  function card(project, result) {
    const pictures = h('div', { class: 'result-images' });
    for (let index = 0; index < (result.images || 0); index++) {
      const holder = h('span', { class: 'image-note' }, icon('file', 12), 'Screenshot');
      pictures.append(holder);
      if (!app.store.can('board.image')) continue;
      loader.url(project, { id: `${result.id}\u0000${index}`, mediaType: 'image/png', bytes: 1 }).then((url) => {
        if (!url) return setText(holder, 'Screenshot no longer available');
        const picture = h('img', { class: 'chat-image', src: url, alt: `${result.title}: screenshot ${index + 1}`, decoding: 'async' });
        const button = h('button', { class: 'chat-image-button', type: 'button', 'aria-expanded': 'false', onclick: () => {
          const wide = !button.classList.contains('wide');
          button.classList.toggle('wide', wide);
          button.setAttribute('aria-expanded', String(wide));
        } }, picture);
        holder.replaceWith(button);
      });
    }
    return h('article', { class: 'result-card' },
      h('div', { class: 'result-head' }, h('span', { class: 'result-title' }, result.title),
        result.at ? h('time', { class: 'records-time', title: moment(result.at) }, clock(result.at)) : null),
      h('div', { class: 'prose result-body' }, markdown(result.body || '')),
      result.images ? pictures : null);
  }

  return {
    el,
    update(board) {
      const results = board && !board.unreadable ? board.results || [] : [];
      el.hidden = results.length === 0;
      const now = JSON.stringify([board?.project, results]);
      if (now === drawn) return;
      drawn = now;
      const cards = results.map((result) => card(board.project, result));
      const earlier = cards.slice(SHOWN);
      const fold = earlier.length ? h('details', { class: 'records-earlier' }, h('summary', null, `Earlier results (${earlier.length})`), earlier) : null;
      if (fold) {
        fold.open = open.has('earlier');
        fold.addEventListener('toggle', () => { if (fold.open) open.add('earlier'); else open.delete('earlier'); });
      }
      list.replaceChildren(...cards.slice(0, SHOWN), ...(fold ? [fold] : []));
    },
  };
}

// A task row's details, asked of the node as the row opens and again when it is opened again later.
export function taskDetails(app) {
  const body = h('div', { class: 'task-details', hidden: true });
  const button = h('button', { class: 'icon-button task-more', type: 'button', 'aria-expanded': 'false', title: 'Details', 'aria-label': 'Details' }, icon('chevron', 10));
  let key = null;
  let asking = 0;

  function part(title, ...content) {
    return h('div', { class: 'task-part' }, h('div', { class: 'task-part-title' }, title), content);
  }

  function draw(details) {
    const parts = [];
    if (details.failure) parts.push(part('Last failure', h('p', { class: 'task-failure' }, details.failure)));
    if (details.checkpoints?.length) {
      parts.push(part('Checkpoints', details.checkpoints.map((checkpoint) => h('div', { class: 'task-checkpoint' },
        h('time', { class: 'records-time' }, checkpoint.at ? clock(checkpoint.at) : ''), h('span', null, checkpoint.text)))));
    }
    if (details.report) parts.push(part('Worker report', h('p', { class: 'task-report' }, details.report)));
    const audit = details.audit;
    if (audit?.panel) parts.push(part('Audit', h('p', { class: 'records-note' }, audit.panel)));
    else if (audit) {
      parts.push(part(audit.last ? 'Last audit' : 'Audit',
        h('p', { class: audit.passes ? 'task-pass' : 'task-failure' }, audit.passes ? 'Passed' : `Not passed: ${audit.completion}, ${audit.integrity}`),
        h('p', { class: 'task-report' }, audit.summary || ''), audit.vote ? h('p', { class: 'records-note' }, audit.vote) : null));
    }
    if (details.findings?.length) {
      parts.push(part(`Findings${details.round ? ` (round ${details.round})` : ''}`, details.findings.map((finding) => h('div', {
        class: 'task-finding' + (finding.status === 'open' ? '' : ' closed') + (finding.blocks ? ' blocks' : ''),
      }, h('span', { class: 'task-finding-severity' }, finding.severity), h('span', null, finding.text)))));
    }
    if (details.merged) parts.push(h('p', { class: 'records-note' }, details.merged));
    if (details.score) parts.push(h('p', { class: 'records-note' + (details.reverted ? ' warn' : '') }, details.score));
    body.replaceChildren(...(parts.length ? parts : [h('p', { class: 'records-note' }, 'Nothing more on the board for this task yet.')]));
  }

  function load() {
    const [project, task] = key;
    const mine = ++asking;
    body.replaceChildren(h('p', { class: 'records-note' }, 'Reading the board…'));
    app.store.read('board.task', { project, task }).then((reply) => {
      if (mine !== asking) return;
      if (reply?.ok) draw(reply.result);
      else body.replaceChildren(h('p', { class: 'records-note' }, reply?.error?.message || 'The node couldn’t read this task.'));
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
