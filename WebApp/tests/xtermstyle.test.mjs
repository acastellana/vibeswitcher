// xterm.js's CSS under the page's policy (js/xtermstyle.js): a truecolor cell's style attribute is set property by
// property only when it is nothing but colours and a letter spacing, and a <style> element xterm.js appends is never
// put in the page, its text adopted as a script-made stylesheet. Run: node --test WebApp/tests/
import test from 'node:test';
import assert from 'node:assert/strict';
import { cellDeclarations, takeXtermStyles } from '../js/xtermstyle.js';

test('a cell style of colours and a letter spacing is read; anything else is not', () => {
  assert.deepEqual(cellDeclarations('color:#ff0000;'), [['color', '#ff0000']]);
  // Its own text read back (serialized by the browser), then the next declaration.
  assert.deepEqual(cellDeclarations('background-color: rgb(0, 0, 255);color:#ff00007f;'),
    [['background-color', 'rgb(0, 0, 255)'], ['color', '#ff00007f']]);
  assert.deepEqual(cellDeclarations('letter-spacing: -0.5px; color: rgba(1, 2, 3, 0.5);'), [['letter-spacing', '-0.5px'], ['color', 'rgba(1, 2, 3, 0.5)']]);
  for (const text of ['', ';', 'color:red', 'color:#ff0000;background:url(x)', 'background-image:none', 'color:#ff0000 !important',
    'color:expression(1)', 'color:#ff0000;}x{color:red', 'position:fixed', 'color:rgb(1,2,3);width:100px']) {
    assert.equal(cellDeclarations(text), null, text);
  }
});

test('the hooks set a cell\'s colours as properties and adopt a <style> element instead of putting it in the page', () => {
  const restore = {};
  for (const name of ['Node', 'Element', 'HTMLSpanElement', 'HTMLStyleElement', 'MutationObserver', 'CSSStyleSheet', 'document']) restore[name] = globalThis[name];
  try {
    const appended = [];
    const attributes = [];
    globalThis.Node = class { appendChild(child) { appended.push(child); return child; } };
    globalThis.Element = class extends globalThis.Node { setAttribute(name, value) { attributes.push([name, value]); } };
    globalThis.HTMLSpanElement = class extends globalThis.Element {
      constructor() { super(); this.style = { set: [], setProperty: (p, v) => this.style.set.push([p, v]) }; }
    };
    globalThis.HTMLStyleElement = class extends globalThis.Element { constructor() { super(); this.textContent = ''; } };
    const observers = [];
    globalThis.MutationObserver = class { constructor(fire) { this.fire = fire; observers.push(this); } observe() {} };
    globalThis.CSSStyleSheet = class { replaceSync(text) { this.text = text; } };
    globalThis.document = { adoptedStyleSheets: [] };

    takeXtermStyles();
    const cell = new globalThis.HTMLSpanElement();
    cell.setAttribute('style', 'color:#ff0000;');
    cell.setAttribute('style', 'position:fixed');
    cell.setAttribute('class', 'xterm-fg-1');
    assert.deepEqual(cell.style.set, [['color', '#ff0000']]);
    assert.deepEqual(attributes, [['style', 'position:fixed'], ['class', 'xterm-fg-1']]);

    const host = new globalThis.Element();
    const style = new globalThis.HTMLStyleElement();
    assert.equal(host.appendChild(style), style);
    const other = new globalThis.Element();
    host.appendChild(other);
    assert.deepEqual(appended, [other]);
    assert.equal(globalThis.document.adoptedStyleSheets.length, 1);
    style.textContent = '.xterm-rows span { height: 15px; }';
    for (const observer of observers) observer.fire();
    assert.equal(globalThis.document.adoptedStyleSheets[0].text, '.xterm-rows span { height: 15px; }');
  } finally {
    Object.assign(globalThis, restore);
  }
});
