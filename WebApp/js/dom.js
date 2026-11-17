// DOM building. Everything on the page is made here from nodes and textContent: what an agent wrote is never markup
// (the design's "The web client"), so nothing in WebApp/ parses a string as HTML, and the page's content policy
// (Trusted Types, in index.html) refuses it if anything tried. tests/lint.test.mjs holds the source to that.

const SVG = 'http://www.w3.org/2000/svg';

function fill(node, children) {
  for (const child of children) {
    if (child == null || child === false) continue;
    if (Array.isArray(child)) fill(node, child);
    else node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
}

function set(node, props) {
  for (const [name, value] of Object.entries(props || {})) {
    if (value == null || value === false) continue;
    if (name === 'class') node.setAttribute('class', value);
    else if (name === 'text') node.textContent = value;
    else if (name === 'data') Object.assign(node.dataset, value);
    else if (name.startsWith('on')) node.addEventListener(name.slice(2), value);
    else node.setAttribute(name, value === true ? '' : String(value));
  }
}

// An element: `h('button', { class: 'row', onclick }, 'Label', child)`. Strings become text nodes.
export function h(tag, props, ...children) {
  const node = document.createElement(tag);
  set(node, props);
  fill(node, children);
  return node;
}

// The same for SVG.
export function s(tag, props, ...children) {
  const node = document.createElementNS(SVG, tag);
  set(node, props);
  fill(node, children);
  return node;
}

export function clear(node) {
  node.replaceChildren();
  return node;
}

// Sets `node`'s text only when it differs: a live row touched on every delta costs nothing while it reads the same.
export function setText(node, text) {
  if (node.textContent !== text) node.textContent = text;
}

// Toggles an attribute or class only when it differs.
export function setClass(node, name, on) {
  if (node.classList.contains(name) !== !!on) node.classList.toggle(name, !!on);
}

const reducedMotion = typeof matchMedia === 'function' ? matchMedia('(prefers-reduced-motion: reduce)') : { matches: true };
export function motionOK() { return !reducedMotion.matches; }

// Keeps `parent`'s children in step with `items`, by key: a row that stays keeps its node (and its focus, its
// scroll, its open state), a new one is made, a gone one removed, and the order follows `items`. `make(item)`
// returns `{ el, update(item) }`. With `move`, rows that changed place slide there (transform only) instead of
// jumping; with `enter`, new rows fade in.
export function keyed(parent, rows, items, key, make, { move = false, enter = false } = {}) {
  const before = new Map();
  const animate = motionOK() && parent.isConnected;
  if (move && animate) for (const [k, row] of rows) before.set(k, row.el.getBoundingClientRect().top);
  const next = new Map();
  let cursor = parent.firstChild;
  for (const item of items) {
    const k = key(item);
    let row = rows.get(k);
    const fresh = !row;
    if (fresh) row = make(item);
    row.update(item);
    next.set(k, row);
    if (row.el === cursor) cursor = cursor.nextSibling;
    else parent.insertBefore(row.el, cursor);
    if (fresh && enter && animate) row.el.classList.add('enter');
  }
  for (const [k, row] of rows) if (!next.has(k)) { row.el.remove(); row.gone?.(); }
  rows.clear();
  for (const [k, row] of next) rows.set(k, row);
  if (move && animate) {
    for (const [k, row] of rows) {
      const from = before.get(k);
      if (from === undefined) continue;
      const delta = from - row.el.getBoundingClientRect().top;
      if (Math.abs(delta) < 1) continue;
      row.el.animate([{ transform: `translateY(${delta}px)` }, { transform: 'none' }], { duration: 160, easing: 'cubic-bezier(.2,.8,.2,1)' });
    }
  }
}

// Runs `work` once before the next frame, however often it's asked: many deltas, one render.
export function framed(work) {
  let asked = false;
  return () => {
    if (asked) return;
    asked = true;
    requestAnimationFrame(() => { asked = false; work(); });
  };
}
