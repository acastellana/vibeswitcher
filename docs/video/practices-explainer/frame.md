# frame.md: the look

**Concept:** a switchyard at night. Each task is a car on its own track, and the lead throws the switches: a contract
is loaded, the car runs on its own siding (a worktree), stops at the inspection shed (audit) and the signal (merge gate),
and only a green signal lets it onto the main line. It is calm, engineered and legible, like a signal-box diagram, not
a dashboard.

## Palette (dark, warm-tinted, one accent)

| Token | Hex | Use |
| --- | --- | --- |
| `--bg` | `#12110f` | the one background, every scene |
| `--panel` | `#1c1a17` | cards, panels |
| `--line` | `#3a352d` | rails, hairlines, borders |
| `--fg` | `#f1ebe0` | primary text |
| `--muted` | `#a39a8b` | secondary text, labels (AA on bg) |
| `--accent` | `#f0a63a` | signal amber: the lead, switches, focal hits |
| `--go` | `#7ccf8e` | pass, merged, green signal |
| `--stop` | `#ef7a68` | Important finding, refused, red signal |
| `--info` | `#8fb6e8` | Codex, secondary actors (sparingly) |

No full-screen linear gradients. Depth comes from a faint track grid, an amber radial glow behind the focal point
and oversized ghost words at about 12 % opacity.

## Type

- **Archivo Black** (400 only) for headlines: heavy and industrial, like stencilled signage. 72–120 px, tracking −0.03em.
- **Montserrat** 400/700 for body lines: plain, and it stays in the background. 30–40 px.
- **IBM Plex Mono** 400/700 for everything that is a real thing in the system: commands, field names, branch names,
  numbers, labels. 20–30 px.

The tension is between the signage (a statement) and the stamped mono labels (the system's own words). Every
`code`-like token on screen is a real name from the code or docs.

## Motion

Rails draw themselves (svg-path-draw). Cars slide with a slow-fast-slow nudge. Cards spring in (spring-pop-entrance)
and lists waterfall. Numbers count up (counting-dynamic-scale). Signals blink once and settle. Ambient: the glow
breathes and the ghost words drift. Each scene fades in over 0.4 s and out over 0.4 s, with hard cuts between them.

## Do / Don't

- Do anchor content to the left edge with a scene kicker (mono, amber, `01 / STRUCTURE`) top-left.
- Do keep every line readable in 2 s for each 3 s it is on screen.
- Don't use logos, brand marks or imitation UI of real products.
- Don't use neon, purple-blue gradients or gradient text.
