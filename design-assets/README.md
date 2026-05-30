# LiftMark Brand — Final Assets

The clean, use-these set for the LiftMark family:
- **LiftMark** — the iOS app
- **LiftMark Format** — the open workout format (formerly "LMWF")
- **lift.md** — consumer styling / domain treatment (same mark)

Open **`LiftMark-Brand-Book.html`** (or the PDF) for the full guidelines.

## The mark
LM monogram (Space Grotesk Bold) on a **blue-gradient tile** with an **orange-depth bar** beneath. Blue-gradient tile is primary; ink and light tiles are alternates. Sub-brands add a light **JetBrains Mono** descriptor after a thin divider (`LiftMark Format`, `lift.md format`).

## Gradients — one rule
Keep surface/fill gradients inside a single hue; never fade blue into orange (it browns).
- `--lm-gradient-tile`   `#356CFF -> #1F46CE` — tiles / surfaces
- `--lm-gradient-orange` `#ED5305 -> #FF8A3D` — logo bar, in-app accents, progress
- `--lm-gradient-energy` `blue -> magenta -> orange` — thin DECORATIVE rules only (cover/footer/OG); never a fill or behind text

## Core colors
| Role | Hex |
|------|-----|
| LiftMark Blue | `#2D5BFF` |
| Blue 600 (links/text on light) | `#1E45E6` |
| LiftMark Orange | `#FF6A1A` |
| Ink | `#0E1116` |

## Fonts (OFL)
Space Grotesk (display/wordmark) · Inter (body/UI) · JetBrains Mono (code + sub-brand descriptor).

## Folder map
```
LiftMark-Brand-Book.html / .pdf
assets/
  logos/   icons (blue/ink/light + square), glyph, wordmarks, and all
           lockups incl. LiftMark Format / lift.md format (SVG)
  icons/   app icons + favicons + square App Store icon (PNG, lm-*)
  social/  OG cards — og-liftmark, og-liftmd (SVG + PNG)
  tokens/  liftmark-tokens.css · liftmark-tokens.json · LiftMarkColors.swift
  fonts/   Space Grotesk · Inter · JetBrains Mono (woff2 + ttf)
```

## Pick the right file
| Need | File |
|------|------|
| App icon / primary mark | `assets/logos/icon-blue.svg` |
| App Store upload | `assets/icons/lm-appstore-1024.png` |
| Favicon | `assets/icons/lm-favicon-32.png` |
| App lockup (light / dark) | `assets/logos/lockup-liftmark-{ink,white}.svg` |
| Format lockup | `assets/logos/lockup-liftmark-format-{ink,white}.svg` |
| lift.md lockup | `assets/logos/lockup-liftmd-{ink,white}.svg` |
| Wordmark / glyph alone | `assets/logos/wm-*` · `mark-lm-*` |

## Tokens
Web: `@import "assets/tokens/liftmark-tokens.css";` -> `var(--lm-accent)`, `var(--lm-orange)`, `var(--lm-gradient-tile)`.
iOS: drop in `LiftMarkColors.swift` -> `Color.lmAccent`, `Color.lmOrange`.

## Licenses
App code MPL-2.0 · LiftMark Format spec CC BY-SA 4.0 · Fonts SIL OFL.
