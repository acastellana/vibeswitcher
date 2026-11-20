// Driving an ordinary session from the page (the parity table's gaps 1, 3 and 6): a message for it, its own question,
// starting one and ending one. No click is the user's voice (the plan's LW-D6): a message is left as a draft beside
// the session (`session.draft`), and everything else is the one line that does it in a terminal, a click to copy. The
// node shows that line's effect when it happens; the terminal asks for the typed code first.

import { h, setText, setClass } from '../dom.js';
import { icon } from '../marks.js';
import { AGENTS } from '../words.js';
import { copyLine } from './cards.js';
import {
  sessionShort, shellWord, renameLine, PAUSES, pauseLine, endable, endLine, closeShellsLine, resumeLine, endedEntry, newLine,
  PRESET_VARIABLES, presetProblem, presetLine, presetArgs, leadLine,
} from '../actions.js';

// The command line's words for a session and for what the user typed (js/actions.js, where the page's lines are made).
export { sessionShort, shellWord };

// Whether the page may drive `session` at all: one the node's host started, still running.
export const drivable = (session) => !!session?.hosted && !session.ended;

// Whether `drafted` (a session's draft) goes in as the free-text answer of `prompt` (the question open on its screen)
// when `vibeswitcher send` types it: a single choice with an option that takes words, and words that aren't a `/`
// command, with no images (the node's `send`, as the app's composer does).
export function answersQuestion(prompt, drafted) {
  return !!prompt && !prompt.multiSelect && (prompt.text || []).length > 0 && !!drafted?.text?.trim()
    && !drafted.text.trim().startsWith('/') && !(drafted.images || []).length;
}

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
      setClass(el, 'now', !!drafted.now);
      // A question open that takes typed words: the message goes in as its answer (the node's `send`, as the app's
      // composer does), so the box says so.
      const prompt = drivable(session) ? session.prompt : null;
      const answers = answersQuestion(prompt, drafted);
      setClass(el, 'answers', answers);
      setText(label, drafted.sending ? 'Saving your message…'
        : drafted.now ? `Steer ${AGENTS[session.agent] || 'the agent'} now: it gets this at its next step, without stopping`
          : answers ? `Your answer to the question above (sent as its “${prompt.options[prompt.text[0]]}” words)`
            : `Your message for ${AGENTS[session.agent] || 'the agent'}`);
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

// What the Mac's row menu does to a session (Rename…, Pause, Resume Notifications, End Session…, Close Finished
// Shells…), under its header: pick one, and the line that does it shows, a click to copy. A lead and a lead's team
// aren't ended from here (their lead and `vibeswitcher stop` are). A session that ended has its Resume line, where the
// node knows its conversation. Returns { el, open(tab), toggle(), update(session, node) → whether it offers anything }.
export function actionsStrip() {
  const TABS = [
    { id: 'rename', label: 'Rename' },
    { id: 'pause', label: 'Pause' },
    { id: 'end', label: 'End' },
    { id: 'shells', label: 'Close shells' },
    { id: 'resume', label: 'Resume' },
  ];
  const tabs = h('div', { class: 'segmented', role: 'group', 'aria-label': 'Do' });
  const panel = h('div', { class: 'action-panel' });
  const close = h('button', { class: 'icon-button', type: 'button', 'aria-label': 'Close', title: 'Close' }, icon('close', 13));
  const el = h('div', { class: 'end-strip action-strip', role: 'group', 'aria-label': 'Rename, pause or end this session', hidden: true }, tabs, panel, close);
  let opened = false;
  let tab = 'rename';
  let id = null;
  let session = null;
  let node = null;
  let typed = null;
  let pause = 'indefinitely';
  let drawn = '';
  close.addEventListener('click', () => { opened = false; el.hidden = true; });

  // What can be done to it now: renamed and paused while the node lists it (any session, one in your own terminal
  // too: a name types nothing), ended when the page may end it, its folder's shells closed, resumed once ended.
  function offered() {
    if (!session) return [];
    const ended = endedEntry(node, session.id);
    if (session.ended) return ended ? ['resume'] : [];
    return ['rename', 'pause', ...(endable(session) ? ['end'] : []), ...(session.hosted && session.cwd ? ['shells'] : [])];
  }

  function line(text, label, note) {
    return [text ? copyLine(text, label) : null, note ? h('p', { class: 'confirm-note' }, note) : null];
  }

  function body() {
    if (tab === 'rename') {
      if (typed === null) typed = session.name || '';
      const input = h('input', { class: 'answer-input', type: 'text', value: typed, placeholder: session.task || 'Its own name', 'aria-label': 'Name', spellcheck: 'false', autocomplete: 'off' });
      const slot = h('div');
      const fill = () => {
        const text = renameLine(session, typed);
        slot.replaceChildren(...line(text, 'the command that renames it',
          text ? (typed.trim() ? 'Kept across a resume; the list and status show it.' : 'Gives it its own name back.')
            : typed.trim() ? 'That’s its name now.' : 'Type a name.'));
      };
      input.addEventListener('input', () => { typed = input.value; fill(); });
      fill();
      return [input, slot];
    }
    if (tab === 'pause') {
      if (session.paused) {
        return line(pauseLine(session, 'off'), 'the command that resumes its notifications',
          'Paused: greyed out, never reminded or notified of. This resumes its notifications.');
      }
      const choices = h('div', { class: 'segmented presets', role: 'group', 'aria-label': 'For how long' }, PAUSES.map((one) => h('button', {
        type: 'button', 'aria-pressed': String(one.id === pause), onclick: () => { pause = one.id; draw(true); },
      }, one.label)));
      return [choices, ...line(pauseLine(session, pause), 'the command that pauses it', 'Greyed out, and nothing reminds or notifies you of it until then.')];
    }
    if (tab === 'end') return line(endLine(session), 'the command that ends it', 'Its agent stops, with everything running in its terminal.');
    if (tab === 'shells') {
      return line(closeShellsLine(session.cwd), 'the command that closes the finished shells',
        'Ends this node’s shells in this folder or below that are back at their prompt; one still running something stays.');
    }
    const ended = endedEntry(node, session.id);
    const resume = resumeLine(ended);
    return [...line(resume, 'the command that resumes it', resume ? 'Starts it again in its same conversation.' : 'Its conversation id wasn’t known: it can’t be resumed.'),
      ended?.conversation ? copyLine(ended.conversation, 'its conversation id') : null];
  }

  function draw(force = false) {
    const can = offered();
    if (!can.includes(tab)) tab = can[0] || 'rename';
    const key = JSON.stringify([session?.id, session?.name, session?.paused, session?.cwd, can, tab, pause, endedEntry(node, session?.id)]);
    if (!force && key === drawn) return;
    drawn = key;
    tabs.replaceChildren(...TABS.filter((one) => can.includes(one.id)).map((one) => h('button', {
      type: 'button', 'aria-pressed': String(one.id === tab), onclick: () => { tab = one.id; draw(true); el.querySelector('.action-panel input, .action-panel .copy-button')?.focus(); },
    }, one.id === 'pause' && session?.paused ? 'Resume notifications' : one.label)));
    tabs.hidden = can.length < 2;
    panel.replaceChildren(...(session && can.length ? body() : []).filter(Boolean));
  }

  return {
    el,
    open(which) {
      if (which) tab = which;
      opened = true;
      draw(true);
      el.hidden = !offered().length;
      el.querySelector('.action-panel input, .action-panel .copy-button')?.focus();
    },
    toggle() { opened ? (opened = false, el.hidden = true) : this.open(); },
    update(next, nodeValue) {
      if (next?.id !== id) { opened = false; id = next?.id || null; typed = null; pause = 'indefinitely'; }
      session = next || null;
      node = nodeValue || null;
      const can = offered().length > 0;
      if (!can) opened = false;
      el.hidden = !opened;
      if (opened) draw();
      return can;
    },
  };
}

// Starting a session: a folder, one of the launch presets the node keeps for it (`session.presets`: the folder's own
// and its default first, as the app's New Session lists them; Claude and Shell when the node lists none), Claude's model;
// the line that starts it, as you type. `folder()` gives the folder to offer first. Returns { el, update() }.
// Starting a project lead in a folder (the Mac's Start Project Lead…, and the palette's "Start Project Lead in …"): the
// folder and the goal, and the line that starts it, a click to copy. Returns { el, choose(folder), update() }.
export function newLeadForm(app) {
  const path = h('input', { class: 'answer-input', type: 'text', placeholder: '/path/to/project', 'aria-label': 'Project folder', spellcheck: 'false', autocomplete: 'off' });
  const goal = h('textarea', { class: 'answer-input lead-goal', rows: 2, placeholder: 'The goal (optional: without one it plans from its records)', 'aria-label': 'Goal' });
  const lineSlot = h('div', { class: 'prompt-line' });
  const el = h('section', { class: 'new-session new-lead', 'aria-label': 'Start a project lead' },
    h('div', { class: 'new-head' }, h('h2', { class: 'new-title' }, 'Start a project lead')),
    h('div', { class: 'new-fields' }, path, goal),
    lineSlot,
    h('p', { class: 'confirm-note' }, 'A lead that runs workers, has their work verified, and merges. Run the line in a terminal on this node: it asks for a code (and, the first time, says to accept the project’s config and base), then starts the lead.'));
  function where() {
    const home = app.store.state.node?.home;
    const typed = path.value.trim();
    return home && (typed === '~' || typed.startsWith('~/')) ? home + typed.slice(1) : typed;
  }
  function draw() {
    const folder = where();
    lineSlot.replaceChildren(folder ? copyLine(leadLine(folder, goal.value), 'the command that starts the lead')
      : h('p', { class: 'confirm-note' }, 'Give a folder: the line that starts its lead shows here.'));
  }
  path.addEventListener('input', draw);
  goal.addEventListener('input', draw);
  draw();
  return {
    el,
    // The palette's "Start Project Lead in …": that folder in the form, the goal to write.
    choose(folder) {
      path.value = folder;
      draw();
      goal.focus?.();
      el.scrollIntoView?.({ block: 'nearest' });
    },
    update: draw,
  };
}

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
  // Adding, changing and removing the folder's presets: the `vibeswitcher preset` line for each.
  const editor = presetEditor({ folder: () => where() });
  const editing = h('button', { class: 'confirm-clear preset-edit-toggle', type: 'button', 'aria-expanded': 'false', onclick: () => {
    const open = editor.el.hidden;
    editor.el.hidden = !open;
    editing.setAttribute('aria-expanded', String(open));
    if (open) editor.update(presets, true);
  } }, 'Edit presets…');
  const el = h('section', { class: 'new-session', 'aria-label': 'Start a session' },
    h('div', { class: 'new-head' }, h('h2', { class: 'new-title' }, 'Start a session'), editing),
    h('div', { class: 'new-fields' }, path, kinds, model),
    about,
    lineSlot,
    h('p', { class: 'confirm-note' }, 'Run it in a terminal on this node: it asks for a code, then starts the session here.'),
    editor.el);
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
        chosen = presetChosen(presets, chosen, picked);
        draw();
      });
    }, 250);
  }

  function draw() {
    const preset = presets.find((one) => one.name === chosen && !one.refused) || presets.find((one) => one.name === chosen) || presets[0];
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
      if (!editor.el.hidden) editor.update(presets);
      return;
    }
    lineSlot.replaceChildren(copyLine(newLine(folder, preset, model.value), 'the command that starts it'));
    if (!editor.el.hidden) editor.update(presets);
  }
  path.addEventListener('input', () => { draw(); ask(); });
  model.addEventListener('input', draw);

  return {
    el,
    // The palette's "New … in …": that folder and preset in the form, and its line ready to copy.
    choose(given, name) {
      path.value = given;
      offered = true;
      chosen = name;
      picked = true;
      ask();
      draw();
      lineSlot.querySelector('.copy-button')?.focus();
      el.scrollIntoView?.({ block: 'nearest' });
    },
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

// The presets of yours for a folder (not the built-ins, which come from VibeSwitcher itself), and a form that adds one or
// changes one: the `vibeswitcher preset` line it makes, after the checks the node makes too (`presetProblem`). The page
// never sees a variable's value (the node sends their names only), so a change names only what it sets or takes off.
// Returns { el, update(presets, force) }.
export function presetEditor({ folder }) {
  const list = h('div', { class: 'preset-list' });
  const formSlot = h('div', { class: 'preset-form-slot' });
  const el = h('div', { class: 'preset-editor', hidden: true },
    h('p', { class: 'new-title' }, 'Your presets'), list, formSlot,
    h('p', { class: 'confirm-note' }, 'A changed presets file waits for your accept (`vibeswitcher config held`, then `config accept`): none of its presets starts, and no next change is taken, before that.'));
  let drawn = '';
  // What the form edits: null (closed), { op: 'add' }, { op: 'edit', original } or { op: 'remove', original }.
  let open = null;

  function form() {
    const where = folder();
    if (open.op === 'remove') {
      const scoped = open.original.project ? where : null;
      return h('div', { class: 'preset-form' }, h('p', { class: 'confirm-note' }, `Removes ${open.original.name}${scoped ? ' from this folder' : ' (every folder’s)'}.`),
        copyLine(presetLine('remove', { name: open.original.name }, { folder: scoped, original: open.original }), 'the command that removes it'));
    }
    const original = open.original || null;
    const state = {
      name: original?.name || '', kind: original?.kind === 'shell' ? 'shell' : 'claude', args: original ? presetArgs(original) : '',
      keepShell: !!original?.keepShell, isDefault: false, env: [], unset: [], scoped: original ? !!original.project : !!where,
    };
    const name = h('input', { class: 'answer-input', type: 'text', value: state.name, placeholder: 'Name', 'aria-label': 'Preset name', spellcheck: 'false', autocomplete: 'off' });
    const args = h('input', { class: 'answer-input', type: 'text', value: state.args, placeholder: 'Claude’s arguments, e.g. --model opus', 'aria-label': 'Claude’s arguments', spellcheck: 'false', autocomplete: 'off' });
    const kinds = h('div', { class: 'segmented', role: 'group', 'aria-label': 'Runs' });
    const tick = (label, key, disabled = false) => {
      const box = h('input', { type: 'checkbox', disabled });
      box.checked = state[key];
      box.addEventListener('change', () => { state[key] = box.checked; fill(); });
      return h('label', { class: 'preset-tick' }, box, ' ', label);
    };
    const variables = h('div', { class: 'preset-vars' });
    const lineSlot = h('div', { class: 'prompt-line' });
    const listId = 'preset-variables';
    const names = h('datalist', { id: listId }, PRESET_VARIABLES.map((variable) => h('option', { value: variable })));
    const addVariable = h('button', { class: 'confirm-clear', type: 'button', onclick: () => { state.env.push(['', '']); drawVariables(); variables.querySelector('.preset-var:last-child input')?.focus(); } }, 'Add a variable');

    function drawVariables() {
      const kept = (original?.env || []).map((variable) => {
        const off = state.unset.includes(variable);
        return h('span', { class: 'preset-chip' + (off ? ' off' : '') }, variable, h('button', {
          class: 'icon-button', type: 'button', 'aria-label': off ? `Keep ${variable}` : `Take ${variable} off`, title: off ? 'Keep it' : 'Take it off',
          onclick: () => { state.unset = off ? state.unset.filter((one) => one !== variable) : [...state.unset, variable]; drawVariables(); fill(); },
        }, icon(off ? 'plus' : 'close', 11)));
      });
      const rows = state.env.map((pair, index) => {
        const key = h('input', { class: 'answer-input', type: 'text', value: pair[0], placeholder: 'VARIABLE', list: listId, 'aria-label': 'Variable', spellcheck: 'false', autocomplete: 'off' });
        const value = h('input', { class: 'answer-input', type: 'text', value: pair[1], placeholder: 'Value', 'aria-label': 'Value', spellcheck: 'false', autocomplete: 'off' });
        key.addEventListener('input', () => { state.env[index][0] = key.value.trim(); fill(); });
        value.addEventListener('input', () => { state.env[index][1] = value.value; fill(); });
        return h('div', { class: 'preset-var' }, key, value);
      });
      variables.replaceChildren(...(kept.length ? [h('div', { class: 'preset-chips' }, kept)] : []), ...rows);
    }

    function fill() {
      args.hidden = state.kind === 'shell';
      [...kinds.children].forEach((button) => button.setAttribute('aria-pressed', String(button.dataset.kind === state.kind)));
      const scoped = state.scoped && where ? where : null;
      const problem = presetProblem(state) || (state.isDefault && !scoped ? 'A default is a folder’s: give a folder and keep it this folder’s.' : null);
      if (problem) { lineSlot.replaceChildren(h('p', { class: 'confirm-note' }, problem)); return; }
      const line = presetLine(open.op, state, { folder: scoped, original });
      // An edit that changes nothing yet: the line with no change in it.
      const unchanged = original && presetLine('edit', { name: original.name, kind: original.kind, args: presetArgs(original), keepShell: original.keepShell }, { folder: scoped, original });
      lineSlot.replaceChildren(open.op === 'edit' && line === unchanged
        ? h('p', { class: 'confirm-note' }, 'Change something: the line that does it shows here.')
        : copyLine(line, open.op === 'add' ? 'the command that adds it' : 'the command that changes it'));
    }

    kinds.replaceChildren(...[['claude', 'Claude'], ['shell', 'Shell']].map(([kind, label]) => h('button', {
      type: 'button', 'data-kind': kind, onclick: () => { state.kind = kind; fill(); },
    }, label)));
    name.addEventListener('input', () => { state.name = name.value; fill(); });
    args.addEventListener('input', () => { state.args = args.value; fill(); });
    drawVariables();
    const ticks = h('div', { class: 'preset-ticks' },
      open.op === 'add' ? tick('Only for this folder', 'scoped', !where) : null,
      tick('A shell stays when it ends', 'keepShell'),
      tick('This folder’s default', 'isDefault', !where));
    const node = h('div', { class: 'preset-form' }, h('div', { class: 'new-fields' }, name, kinds, args), variables, addVariable, names, ticks, lineSlot);
    fill();
    return node;
  }

  function drawList(presets) {
    const mine = presets.filter((preset) => !preset.builtIn);
    list.replaceChildren(...mine.map((preset) => h('div', { class: 'preset-row' },
      h('span', { class: 'preset-name' }, preset.name), h('span', { class: 'preset-note' }, [presetNote(preset), preset.project ? 'this folder’s' : 'every folder’s', preset.refused ? `can’t start: ${preset.refused}` : null].filter(Boolean).join(' · ')),
      h('span', { class: 'confirm-actions' },
        h('button', { class: 'confirm-clear', type: 'button', onclick: () => { open = { op: 'edit', original: preset }; formSlot.replaceChildren(form()); formSlot.querySelector('input')?.focus(); } }, 'Edit'),
        h('button', { class: 'confirm-clear', type: 'button', onclick: () => { open = { op: 'remove', original: preset }; formSlot.replaceChildren(form()); formSlot.querySelector('.copy-button')?.focus(); } }, 'Remove')))),
    h('button', { class: 'confirm-clear', type: 'button', onclick: () => { open = { op: 'add' }; formSlot.replaceChildren(form()); formSlot.querySelector('input')?.focus(); } }, 'Add a preset'));
  }

  return {
    el,
    update(presets, force = false) {
      const key = JSON.stringify([folder(), presets.map((preset) => [preset.name, preset.digest, preset.project, preset.refused])]);
      if (!force && key === drawn) return;
      const moved = drawn && key !== drawn;
      drawn = key;
      drawList(presets);
      // The folder or its presets changed under an open form: it closes, rather than edit what's no longer shown.
      if (moved || force) { open = null; formSlot.replaceChildren(); }
    },
  };
}

// The preset the form shows chosen once the node's list comes: the one you picked while it can start, else the first
// that can (the folder's default, as the node orders them). One the node refuses (a project's preset that takes a
// built-in's name, a variable a preset may not set) is never chosen for you.
export function presetChosen(presets, chosen, picked) {
  if (picked && presets.some((preset) => preset.name === chosen && !preset.refused)) return chosen;
  return presets.find((preset) => !preset.refused)?.name || chosen;
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
