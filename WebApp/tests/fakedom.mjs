// A small stand-in DOM for drawing a view in Node's tests: elements and text nodes, their attributes, classes, data,
// children and click handlers; enough for js/dom.js's `h` and the views that build with it. Not a browser: no layout,
// no markup parsing (nothing here parses a string as HTML, as nothing in the page may). Not a test file itself
// (scripts/test.sh runs *.test.mjs only).
//
//   const dom = installDom();  …  dom.restore();
//   find(el, (node) => node.tag === 'button' && node.textContent === 'Push').click();

class FakeClassList {
  constructor(node) { this.node = node; }
  get names() { return (this.node.attrs.class || '').split(/\s+/).filter(Boolean); }
  set names(list) { this.node.attrs.class = [...new Set(list)].join(' '); }
  add(...names) { this.names = [...this.names, ...names]; }
  remove(...names) { this.names = this.names.filter((name) => !names.includes(name)); }
  contains(name) { return this.names.includes(name); }
  toggle(name, on = !this.contains(name)) { if (on) this.add(name); else this.remove(name); return on; }
}

export class FakeNode {
  constructor(tag, text = null) {
    this.tag = tag;
    this.tagName = tag === '#text' ? '#text' : tag.toUpperCase();
    this.text = text;
    this.children = [];
    this.parentNode = null;
    this.attrs = {};
    this.dataset = {};
    this.handlers = {};
    this.style = { setProperty() {}, removeProperty() {} };
    this.classList = new FakeClassList(this);
    this.value = '';
    this.disabled = false;
    this.checked = false;
  }
  get isConnected() { return false; }
  get childNodes() { return this.children; }
  get firstChild() { return this.children[0] || null; }
  get nextSibling() {
    const siblings = this.parentNode?.children || [];
    return siblings[siblings.indexOf(this) + 1] || null;
  }
  get className() { return this.attrs.class || ''; }
  set className(value) { this.attrs.class = value; }
  get hidden() { return 'hidden' in this.attrs; }
  set hidden(on) { if (on) this.attrs.hidden = ''; else delete this.attrs.hidden; }
  get title() { return this.attrs.title || ''; }
  set title(value) { this.attrs.title = String(value); }
  get id() { return this.attrs.id || ''; }
  setAttribute(name, value) { this.attrs[name] = String(value); if (name === 'disabled') this.disabled = true; }
  getAttribute(name) { return name in this.attrs ? this.attrs[name] : null; }
  removeAttribute(name) { delete this.attrs[name]; }
  hasAttribute(name) { return name in this.attrs; }
  addEventListener(name, fn) { (this.handlers[name] ||= []).push(fn); }
  removeEventListener(name, fn) { this.handlers[name] = (this.handlers[name] || []).filter((one) => one !== fn); }
  dispatch(name, event = {}) {
    const full = { target: this, currentTarget: this, preventDefault() {}, stopPropagation() {}, ...event };
    for (const fn of this.handlers[name] || []) fn(full);
  }
  click() { if (!this.disabled) this.dispatch('click'); }
  detach(node) { if (node.parentNode) node.parentNode.children = node.parentNode.children.filter((one) => one !== node); node.parentNode = this; return node; }
  // As a browser does, anything not a node is appended as its text (null as "null").
  append(...nodes) { for (const node of nodes) this.children.push(this.detach(node instanceof FakeNode ? node : new FakeNode('#text', String(node)))); }
  prepend(...nodes) { this.children.unshift(...nodes.map((node) => this.detach(node))); }
  replaceChildren(...nodes) { for (const child of this.children) child.parentNode = null; this.children = []; this.append(...nodes); }
  insertBefore(node, before) {
    this.detach(node);
    const at = before ? this.children.indexOf(before) : -1;
    if (at < 0) this.children.push(node); else this.children.splice(at, 0, node);
    return node;
  }
  remove() { if (this.parentNode) this.parentNode.children = this.parentNode.children.filter((one) => one !== this); this.parentNode = null; }
  contains(node) { return node === this || this.children.some((child) => child.contains(node)); }
  matches() { return false; }
  closest() { return null; }
  focus() {}
  blur() {}
  animate() { return { finished: Promise.resolve(), cancel() {} }; }
  getBoundingClientRect() { return { top: 0, left: 0, width: 0, height: 0, right: 0, bottom: 0 }; }
  querySelector() { return null; }
  querySelectorAll() { return []; }
  get textContent() { return this.text ?? this.children.map((child) => child.textContent).join(''); }
  set textContent(value) { this.text = this.tag === '#text' ? String(value) : null; this.children = []; if (this.tag !== '#text' && value !== '') this.append(new FakeNode('#text', String(value))); }
  // What a reader sees: the text of every node not hidden.
  get shownText() { return this.hidden ? '' : this.text ?? this.children.map((child) => child.shownText).join(''); }
}

// Every node under `node` (itself first) that `test` holds for.
export function findAll(node, test) {
  return [...(test(node) ? [node] : []), ...node.children.flatMap((child) => findAll(child, test))];
}
export const find = (node, test) => findAll(node, test)[0] || null;
export const byClass = (name) => (node) => node.classList.contains(name);
export const button = (text) => (node) => node.tag === 'button' && node.textContent.includes(text);

// Puts the stand-in in place of the browser's globals the page's modules read; `restore()` puts back what was there.
export function installDom() {
  const names = ['Node', 'document', 'requestAnimationFrame', 'matchMedia'];
  const before = Object.fromEntries(names.map((name) => [name, globalThis[name]]));
  globalThis.Node = FakeNode;
  globalThis.document = {
    createElement: (tag) => new FakeNode(tag), createElementNS: (_, tag) => new FakeNode(tag), createTextNode: (text) => new FakeNode('#text', text),
    activeElement: null, visibilityState: 'visible', hidden: false, addEventListener() {}, body: new FakeNode('body'), documentElement: new FakeNode('html'),
  };
  // A frame runs at once: what a delta asks for is drawn before the test reads it.
  globalThis.requestAnimationFrame = (fn) => { fn(); return 0; };
  globalThis.matchMedia = () => ({ matches: true, addEventListener() {} });
  return { restore() { for (const name of names) { if (before[name] === undefined) delete globalThis[name]; else globalThis[name] = before[name]; } } };
}
