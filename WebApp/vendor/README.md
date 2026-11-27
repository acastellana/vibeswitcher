# WebApp/vendor: what the page runs that this project didn't write

The terminal's emulator (the live plan's slice 4, Task D5; the user's go-ahead, LW-D13, 2026-11-19): xterm.js, its
fit add-on and its search add-on (find in the terminal, P4: group G4 of v2-remaining, 2026-11-27), each at one exact
released version of the same release (xterm.js 6.0.0's, published 2025-12-22), copied byte for byte from the npm
registry's tarball. Nothing else from the packages is here: no source maps, no typings, no other add-on (no image, web
links, clipboard or ligatures).
The page loads them only where the node opens terminals (`js/views/terminal.js`), so the user's node never runs them.

How they were taken: each tarball downloaded over HTTPS with curl into an empty scratch folder, treated as data (no
`npm install`, nothing in it run), its SHA-512 compared with the registry's `dist.integrity`, then the built files and
the licence copied here. `tests/vendor.test.mjs` fails while a file here doesn't hash to the table below, and while a
file is here that the table doesn't name.

| Package | Version | Tarball | SHA-512 (the registry's `dist.integrity`, matched) |
| --- | --- | --- | --- |
| `@xterm/xterm` | 6.0.0 | https://registry.npmjs.org/@xterm/xterm/-/xterm-6.0.0.tgz | `sha512-TQwDdQGtwwDt+2cgKDLn0IRaSxYu1tSUjgKarSDkUM0ZNiSRXFpjxEsvc/Zgc5kq5omJ+V0a8/kIM2WD3sMOYg==` |
| `@xterm/addon-fit` | 0.11.0 | https://registry.npmjs.org/@xterm/addon-fit/-/addon-fit-0.11.0.tgz | `sha512-jYcgT6xtVYhnhgxh3QgYDnnNMYTcf8ElbxxFzX0IZo+vabQqSPAjC3c1wJrKB5E19VwQei89QCiZZP86DCPF7g==` |
| `@xterm/addon-search` | 0.16.0 | https://registry.npmjs.org/@xterm/addon-search/-/addon-search-0.16.0.tgz | `sha512-9OeuBFu0/uZJPu+9AHKY6g/w0Czyb/Ut0A5t79I4ULoU4IfU5BEpPFVGQxP4zTTMdfZEYkVIRYbHBX1xWwjeSA==` |

| File | From the tarball | SHA-256 |
| --- | --- | --- |
| `xterm.mjs` | `@xterm/xterm` `package/lib/xterm.mjs` | `b336ec65a086c056d4804b3d4c2347da5663d3f23c3f25be866467bd8857ad59` |
| `xterm.css` | `@xterm/xterm` `package/css/xterm.css` | `854a7c0fb70e8b1a083c16797ab827299fb18744f5ad34f227b48337e33293c6` |
| `LICENSE.xterm` | `@xterm/xterm` `package/LICENSE` | `b569f629d00f2626a8100df2a1798210535621e42164dfd426a6fe5aac7b0ccd` |
| `addon-fit.mjs` | `@xterm/addon-fit` `package/lib/addon-fit.mjs` | `2d87e1bddc73be9111de8beee5370c3bb7aac9c94e18e6f245f02ca741ef1769` |
| `LICENSE.addon-fit` | `@xterm/addon-fit` `package/LICENSE` | `e256f01188af527e4d06d21d06fbf785ae9c50d4b328bf03cbe0ba7f0aa4228f` |
| `addon-search.mjs` | `@xterm/addon-search` `package/lib/addon-search.mjs` | `3ea90162233f867b938cd29b8ad98f589643436bbb5445bd11b825dc99ff0c04` |
| `LICENSE.addon-search` | `@xterm/addon-search` `package/LICENSE` | `689ceb10716bd7a87a804c14951d7c2b818cbd60aab83d540902470ce3b13444` |

The licences (MIT) aren't served: `scripts/webapp-embed.sh` leaves `LICENSE*` out as it leaves this file out.

## The page's policy

Unchanged. xterm.js's DOM renderer is used (no canvas or WebGL add-on). It writes part of its CSS (a cell's size, the
theme) into `<style>` elements it makes, and a truecolor cell's colour into the cell's style attribute, both of which
`style-src 'self'` refuses. `js/xtermstyle.js` (loaded with xterm.js, by `js/views/terminal.js`) hands both to script-made CSS,
which the policy doesn't govern: a `<style>` element is never put in the page, its text goes to a stylesheet made by
script (`adoptedStyleSheets`); a cell's style attribute that is only colours and a letter spacing is set property by
property. So a terminal logs no refusal (checked in headless Chrome, 2026-11-20) and Claude Code's colours show.
xterm.js builds the text from the page's own options and from colours its parser has already normalized: nothing a
program prints becomes CSS. No `innerHTML` or other string-to-markup call is in either file (`WebAppLintTests` reads them as it reads the page's own).

## Find in the terminal

The search add-on finds in what the terminal holds (its scrollback and screen), the page's code only: nothing a program
prints reaches it but as text to search. Its highlights are xterm.js decorations, which xterm.js counts as proposed
API: `js/views/terminal.js` sets `allowProposedApi` for them. That option widens what the page's own code may call on
the emulator, nothing a program in the session can do. A decoration's colour is set property by property on the
element xterm.js makes (no style attribute, no `<style>`), so the policy stays as it is.

## Updating

A new version is a change of its own: the same steps, the tables above rewritten, the tests and the sandbox's
terminal looked at again (`js/views/terminal.js` uses the fit add-on's `proposeDimensions`, which reads xterm.js's
internals, so the two move together).
