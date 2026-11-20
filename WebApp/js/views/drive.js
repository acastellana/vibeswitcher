// Driving an ordinary session from the page (the parity table's gaps 1, 3 and 6): a message for it, its own question,
// starting one and ending one. No click is the user's voice (the plan's LW-D6): a message is left as a draft beside
// the session (`session.draft`), and everything else is the one line that does it in a terminal, a click to copy. The
// node shows that line's effect when it happens; the terminal asks for the typed code first.

import { h, setText, setClass } from '../dom.js';
import { icon } from '../marks.js';
import { AGENTS } from '../words.js';
import { copyLine } from './cards.js';

// A session as the command line names it: the first 8 characters of its host id (`vibeswitcher send` takes any prefix
// of 4 or more that only one session has).
export const sessionShort = (id) => String(id || '').replace(/^[^:]*:/, '').slice(0, 8);

// `text` as one shell word: as it is when it needs no quoting, else in single quotes, each ' written '\''. What the
// user typed never becomes a command that does something else when pasted.
export function shellWord(text) {
  const value = String(text);
  return /^[A-Za-z0-9._\/:@%+=,-]+$/.test(value) ? value : `'${value.replace(/'/g, `'\\''`)}'`;
}

// Whether the page may drive `session` at all: one the node's host started, still running.
export const drivable = (session) => !!session?.hosted && !session.ended;

// The message drafted for a session, over its composer: the text as it will be typed, the line that sends it, and
// Edit (back into the box) and Discard. Returns { el, update(session) }.
export function draftBox(app, { edit }) {
  const label = h('span', { class: 'confirm-label' });
  const text = h('p', { class: 'confirm-text' });
  const pictures = h('p', { class: 'confirm-note draft-images', hidden: true });
  const lineSlot = h('div');
  const refused = h('p', { class: 'card-notice', role: 'alert', hidden: true });
  let id = null;
  let drawn = '';
  const editButton = h('button', { class: 'confirm-clear', type: 'button', title: 'Put the message back in the box', onclick: () => {
    const drafted = app.store.sessionDraftOf(id);
    if (drafted) edit(drafted.text, drafted.images || []);
  } }, 'Edit');
  const discard = h('button', { class: 'confirm-clear', type: 'button', title: 'Take the draft off the session', onclick: () => app.store.sessionDraft(id, null) }, 'Discard');
  const note = h('p', { class: 'confirm-note' }, 'Run it in a terminal: it shows the message and asks for a code. Nothing is typed into the session before that.');
  const el = h('div', { class: 'confirm composer-draft', role: 'group', 'aria-label': 'Send your message from a terminal', hidden: true },
    h('div', { class: 'confirm-head' }, label, h('span', { class: 'confirm-actions' }, editButton, discard)), text, pictures, lineSlot, note, refused);

  return {
    el,
    update(session) {
      id = session?.id || null;
      const drafted = id ? app.store.sessionDraftOf(id) : null;
      const why = id ? app.store.state.sessionDraftRefused.get(id) : null;
      el.hidden = !drafted && !why;
      refused.hidden = !why;
      if (why) setText(refused, why);
      if (!drafted) return;
      setClass(el, 'sending', drafted.sending);
      setText(label, drafted.sending ? 'Saving your message…' : `Your message for ${AGENTS[session.agent] || 'the agent'}`);
      setText(text, drafted.text);
      text.hidden = !drafted.text;
      const images = drafted.images || [];
      pictures.hidden = !images.length;
      setText(pictures, images.length ? `With ${images.length === 1 ? 'an image' : `${images.length} images`}: ${images.map((path) => path.split('/').pop()).join(', ')}` : '');
      const line = `vibeswitcher send ${sessionShort(id)}`;
      if (line !== drawn) {
        drawn = line;
        lineSlot.replaceChildren(copyLine(line, 'the command that sends it'));
      }
    },
  };
}

// The messages `vibeswitcher send` sent while a question or picker was open on the session's screen, which the node
// holds and types in once it closes (`queued`, as the app's composer holds them). Returns { el, update(session) }.
export function queuedStrip() {
  const head = h('span', { class: 'confirm-label' });
  const list = h('ol', { class: 'queued-list' });
  const el = h('div', { class: 'confirm composer-draft queued', role: 'status', hidden: true }, head, list,
    h('p', { class: 'confirm-note' }, 'Typed in, in this order, once what is open on its screen closes: answer it, or close it in the session’s terminal.'));
  let drawn = '';
  return {
    el,
    update(session) {
      const queued = drivable(session) ? session.queued || [] : [];
      el.hidden = !queued.length;
      const now = JSON.stringify(queued.map((item) => [item.action, item.text, item.images]));
      if (now === drawn) return;
      drawn = now;
      setText(head, queued.length === 1 ? 'A message waits to go in' : `${queued.length} messages wait to go in`);
      list.replaceChildren(...queued.map((item) => h('li', null, item.text || '', item.images ? h('span', { class: 'queued-images' }, ` (+${item.images} image${item.images === 1 ? '' : 's'})`) : null)));
    },
  };
}

// The question open on a session's screen (a permission prompt, its own question, a plan to approve), as the node read
// it: the options numbered as the screen numbers them. A pick shows the line that answers it, `vibeswitcher reply`;
// an option that takes words opens a field, and the line carries them. Returns { el, update(session) }.
export function promptCard(app) {
  const el = h('article', { class: 'card ask session-prompt', tabindex: -1, hidden: true });
  let key = '';
  let chosen = null;
  let words = '';

  function draw(session) {
    const prompt = session.prompt;
    const agent = AGENTS[session.agent] || 'The agent';
    const takes = new Set(prompt.text || []);
    const short = sessionShort(session.id);
    const buttons = prompt.options.map((option, index) => h('button', {
      class: 'option' + (chosen === index ? ' chosen' : ''), type: 'button', 'aria-pressed': String(chosen === index),
      onclick: () => { chosen = index; draw(session); el.querySelector(takes.has(index) ? '.answer-input' : '.copy-button')?.focus(); },
    }, h('span', { class: 'option-key', 'aria-hidden': 'true' }, String(index + 1)), h('span', { class: 'option-text' }, option),
    prompt.descriptions?.[index] ? h('span', { class: 'option-note' }, prompt.descriptions[index]) : null));
    const parts = [
      h('header', { class: 'card-head' }, h('span', { class: 'priority blocking' }, `${agent} is asking`)),
      h('pre', { class: 'ask-text' }, prompt.question),
    ];
    if (prompt.multiSelect) {
      parts.push(h('ol', { class: 'options read-only' }, prompt.options.map((option) => h('li', { class: 'option' }, h('span', { class: 'option-text' }, option)))),
        h('p', { class: 'confirm-note' }, 'It takes several ticks: answer it in the session’s own terminal.'));
    } else {
      parts.push(h('div', { class: 'options' }, buttons));
      if (chosen !== null && takes.has(chosen)) {
        const input = h('input', { class: 'answer-input', type: 'text', value: words, placeholder: 'Your words', 'aria-label': 'Your words for this option',
          oninput: () => { words = input.value; line.replaceChildren(command()); } });
        parts.push(input);
      }
      const command = () => {
        if (chosen === null) return h('p', { class: 'confirm-note' }, 'Pick an answer: the line that gives it in a terminal shows here.');
        const typed = takes.has(chosen) && words.trim() ? ` ${shellWord(words.trim())}` : '';
        return copyLine(`vibeswitcher reply ${short} ${chosen + 1}${typed}`, 'the command that answers it');
      };
      const line = h('div', { class: 'prompt-line' }, command());
      parts.push(line, h('p', { class: 'confirm-note' }, 'Run it in a terminal: it shows this question and asks for a code, then answers it as you, only while this question is still on the screen.'));
    }
    el.replaceChildren(...parts);
  }

  return {
    el,
    update(session) {
      const prompt = drivable(session) ? session.prompt : null;
      el.hidden = !prompt;
      if (!prompt) { key = ''; return; }
      const now = JSON.stringify([session.id, prompt.question, prompt.options, prompt.at]);
      if (now === key) return;
      // Another question (or the same one asked again): nothing picked for it yet.
      if (!key.startsWith(JSON.stringify([session.id, prompt.question]).slice(0, -1))) { chosen = null; words = ''; }
      key = now;
      draw(session);
    },
  };
}

// Ending a session, under its header: the line that ends it and what that does. A lead and a lead's team aren't ended
// from here (their lead and `vibeswitcher stop` are). Returns { el, toggle(), update(session) }.
export function endStrip() {
  const lineSlot = h('div');
  const close = h('button', { class: 'icon-button', type: 'button', 'aria-label': 'Close', title: 'Close' }, icon('close', 13));
  const el = h('div', { class: 'end-strip', role: 'group', 'aria-label': 'End this session', hidden: true },
    h('div', { class: 'end-text' }, h('strong', null, 'End this session'), h('span', null, ' — its agent stops, with everything running in its terminal.')),
    lineSlot, close);
  let open = false;
  let id = null;
  close.addEventListener('click', () => { open = false; el.hidden = true; });
  return {
    el,
    toggle() { open = !open; el.hidden = !open; if (open) el.querySelector('.copy-button')?.focus(); },
    update(session) {
      if (session?.id !== id) { open = false; id = session?.id || null; }
      const can = drivable(session) && !session.role;
      if (!can) open = false;
      el.hidden = !open;
      if (can) lineSlot.replaceChildren(copyLine(`vibeswitcher end ${sessionShort(session.id)}`, 'the command that ends it'));
      return can;
    },
  };
}

// Starting a session: a folder, one of the launch presets the node keeps for it (`session.presets`: the folder's own
// and its default first, as the app's New Session lists them; Claude and Shell when the node lists none), Claude's model;
// the line that starts it, as you type. `folder()` gives the folder to offer first. Returns { el, update() }.
export function newSessionForm(app, { folder }) {
  const BUILT_IN = [{ name: 'Claude', kind: 'claude', builtIn: true }, { name: 'Shell', kind: 'shell', builtIn: true }];
  let presets = BUILT_IN;
  let chosen = 'Claude';
  // Whether you picked one: until then the folder's default (the first listed) is.
  let picked = false;
  let asked = null;
  let timer = null;
  const path = h('input', { class: 'answer-input', type: 'text', placeholder: '/path/to/project', 'aria-label': 'Folder', spellcheck: 'false', autocomplete: 'off' });
  const model = h('input', { class: 'answer-input model-input', type: 'text', placeholder: 'Model (optional)', 'aria-label': 'Model', spellcheck: 'false', autocomplete: 'off' });
  const kinds = h('div', { class: 'segmented presets', role: 'group', 'aria-label': 'Preset' });
  const about = h('p', { class: 'confirm-note preset-about', hidden: true });
  const lineSlot = h('div', { class: 'prompt-line' });
  const el = h('section', { class: 'new-session', 'aria-label': 'Start a session' },
    h('h2', { class: 'new-title' }, 'Start a session'),
    h('div', { class: 'new-fields' }, path, kinds, model),
    about,
    lineSlot,
    h('p', { class: 'confirm-note' }, 'Run it in a terminal on this node: it asks for a code, then starts the session here.'));
  let offered = false;

  // `~/` is the node's home, as a shell would read it (the command line takes the folder as given).
  function where() {
    const home = app.store.state.node?.home;
    const typed = path.value.trim();
    return home && (typed === '~' || typed.startsWith('~/')) ? home + typed.slice(1) : typed;
  }

  // The node's presets for the folder, asked a moment after it changes (an absolute path only).
  function ask() {
    const folder = where();
    if (!app.store.can('session.presets') || folder === asked) return;
    asked = folder;
    clearTimeout(timer);
    timer = setTimeout(() => {
      app.store.read('session.presets', folder.startsWith('/') ? { folder } : {}).then((reply) => {
        if (asked !== folder || !reply?.ok) return;
        presets = reply.result.presets.length ? reply.result.presets : BUILT_IN;
        if (!picked || !presets.some((preset) => preset.name === chosen && !preset.refused)) chosen = presets.find((preset) => !preset.refused)?.name || chosen;
        draw();
      });
    }, 250);
  }

  function draw() {
    const preset = presets.find((one) => one.name === chosen) || presets[0];
    kinds.replaceChildren(...presets.map((one) => h('button', {
      type: 'button', 'aria-pressed': String(one === preset), disabled: !!one.refused, title: one.refused ? `Can’t start here: ${one.refused}` : presetNote(one),
      onclick: () => { chosen = one.name; picked = true; draw(); },
    }, one.name)));
    model.hidden = preset.kind !== 'claude';
    about.hidden = preset.builtIn || !presetNote(preset);
    setText(about, preset.builtIn ? '' : presetNote(preset));
    const folder = where();
    if (!folder) {
      lineSlot.replaceChildren(h('p', { class: 'confirm-note' }, 'Give a folder: the line that starts it shows here.'));
      return;
    }
    const chosenModel = preset.kind === 'claude' ? model.value.trim() : '';
    const how = preset.builtIn ? (preset.kind === 'shell' ? ' --agent shell' : '') : ` --preset ${shellWord(preset.name)}`;
    const line = `vibeswitcher new ${shellWord(folder)}${how}${chosenModel ? ` --model ${shellWord(chosenModel)}` : ''}`;
    lineSlot.replaceChildren(copyLine(line, 'the command that starts it'));
  }
  path.addEventListener('input', () => { draw(); ask(); });
  model.addEventListener('input', draw);

  return {
    el,
    update() {
      if (!offered && !path.value) {
        const given = folder();
        if (given) { path.value = given; offered = true; }
      }
      ask();
      draw();
    },
  };
}

// A preset in a few words: what it runs, the variables it sets (by name), whether a shell stays.
export function presetNote(preset) {
  const parts = [];
  if (preset.kind === 'shell') parts.push('a shell');
  else if (preset.command) parts.push(`runs ${preset.command}`);
  if (preset.env?.length) parts.push(`sets ${preset.env.join(', ')}`);
  if (preset.keepShell) parts.push('a shell stays when it ends');
  if (preset.default) parts.push('this folder’s default');
  return parts.join(' · ');
}
