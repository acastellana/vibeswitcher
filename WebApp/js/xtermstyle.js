// xterm.js's DOM renderer writes CSS two ways the page's policy (style-src 'self') refuses, each refusal an error in the
// console and nothing applied (acceptance run, 2026-11-20: a terminal pane logged them by the dozen):
// - <style> elements it makes and puts in the page (a cell's size, the theme, the scrollbar), refused even empty;
// - a truecolor cell's colour as its style attribute (`setAttribute('style', 'color:#rrggbb;')`, its `_addStyle`), on
//   every row it draws: the colours Claude Code draws with were lost, shown in the default colour.
// `takeXtermStyles` hands both to script-made CSS, which the policy doesn't govern (as it lets xterm.js set
// `span.style.letterSpacing`), so the policy stays as it is: a <style> element appended anywhere isn't put in the page,
// its text goes to a stylesheet made by script (adoptedStyleSheets) and follows its later texts; a span's style
// attribute that is only a colour, a background colour or a letter spacing (`cellDeclarations`) is set property by
// property. Anything else goes on to the browser as before, and is refused. Nothing the program in the session prints
// becomes CSS: xterm.js builds the text from this page's options and from colours its parser has already turned into
// numbers. Nothing on the page but xterm.js makes <style> elements or style attributes (the policy refuses them);
// the hooks go in only when xterm.js is loaded (views/terminal.js), never on a page that shows no terminal.

const COLOUR = /^(color|background-color)\s*:\s*(#[0-9a-f]{6}|#[0-9a-f]{8}|rgba?\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}\s*(,\s*[0-9.]+\s*)?\))$/i;
const SPACING = /^(letter-spacing)\s*:\s*(-?\d+(\.\d+)?px)$/i;

// `color:#ff0000;background-color: rgb(0, 0, 255);` → [['color', '#ff0000'], ['background-color', 'rgb(0, 0, 255)']]:
// a cell's style as xterm.js writes it (its own earlier text read back, serialized, then the new declaration). Null
// when any declaration is something else.
export function cellDeclarations(text) {
  const declarations = [];
  for (const part of String(text).split(';')) {
    const trimmed = part.trim();
    if (!trimmed) continue;
    const match = COLOUR.exec(trimmed) || SPACING.exec(trimmed);
    if (!match) return null;
    declarations.push([match[1].toLowerCase(), match[2]]);
  }
  return declarations.length ? declarations : null;
}

let taken = false;

// Once per page, before the first terminal opens.
export function takeXtermStyles() {
  if (taken) return;
  taken = true;
  const sheets = new Map();
  const watch = new MutationObserver(() => { for (const element of sheets.keys()) copy(element); });
  function copy(element) {
    const sheet = sheets.get(element);
    const text = element.textContent;
    if (sheet.text !== text) { sheet.text = text; sheet.css.replaceSync(text); }
  }
  function adopt(element) {
    if (sheets.has(element)) return;
    sheets.set(element, { css: new CSSStyleSheet(), text: null });
    copy(element);
    document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheets.get(element).css];
    watch.observe(element, { childList: true, characterData: true, subtree: true });
  }
  const append = Node.prototype.appendChild;
  Node.prototype.appendChild = function appendChild(child) {
    if (child instanceof HTMLStyleElement) { adopt(child); return child; }
    return append.call(this, child);
  };
  const setAttribute = Element.prototype.setAttribute;
  HTMLSpanElement.prototype.setAttribute = function cellSetAttribute(name, value) {
    const declarations = String(name).toLowerCase() === 'style' ? cellDeclarations(value) : null;
    if (!declarations) return setAttribute.call(this, name, value);
    for (const [property, setting] of declarations) this.style.setProperty(property, setting);
  };
}
