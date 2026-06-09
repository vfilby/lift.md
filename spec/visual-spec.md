# Visual Specification

Design tokens and visual constants for the LiftMark iOS app. The Swift app uses iOS semantic system colors and SF Pro fonts; values below are the resolved defaults.

All custom colors use adaptive light/dark values to meet WCAG AA contrast minimums: 4.5:1 for normal text, 3:1 for large text and UI components. System semantic colors (`label`, `secondaryLabel`, `tertiaryLabel`) are Apple-managed and adapt via iOS "Increase Contrast" accessibility setting.

## Colors

### Primary & Status

| Token | Light | Dark | Contrast (L/D) | Usage |
|-------|-------|------|----------------|-------|
| Primary | `#0070E0` | `#007AFF` | 4.8:1 / 8.6:1 | Tint, active tab, links, current set highlight |
| Success | `#1E7E34` | `#30D158` | 5.4:1 / 10.4:1 | Completed sets, checkmarks, enabled toggles |
| Warning | `#C45100` | `#FF9F0A` | 4.9:1 / 11.3:1 | Skipped sets, caution badges |
| Destructive | `#C41F1F` | `#FF453A` | 5.9:1 / 5.5:1 | Delete, stop, error |

### Backgrounds

| Token | Light | Dark | Usage |
|-------|-------|------|-------|
| Screen | `systemBackground` | `#000000` | Main screen background |
| Card | `secondarySystemBackground` | `#1C1C1E` | Card surfaces, tab bar |
| Grouped | `systemGroupedBackground` | `#000000` | Settings-style grouped lists |
| Input | `tertiarySystemBackground` | `#2C2C2E` | Text field backgrounds |

### Text

| Token | Light | Dark | Usage |
|-------|-------|------|-------|
| Primary | `label` | `#F2F2F7` | Headings, body, values |
| Secondary | `secondaryLabel` | `#8E8E93` | Subtitles, hints, timestamps |
| Tertiary | `tertiaryLabel` | `#48484A` | Placeholders, disabled |

### Tab Bar

| Token | Light | Dark | Contrast (L/D) | Usage |
|-------|-------|------|----------------|-------|
| Selected | `#0070E0` | `#007AFF` | 4.8:1 / 8.6:1 | Active tab icon + label |
| Default | `#8E8E93` | `#8E8E93` | 3.3:1 / 6.4:1 | Inactive tab icon + label (3:1 UI component) |

### Workout Section Accents

| Token | Light | Dark | Contrast (L/D) | Usage |
|-------|-------|------|----------------|-------|
| Warmup | `#C45100` | `#FF9F0A` | 4.9:1 / 11.3:1 | Warmup section badge/text |
| Cooldown | `#0077B6` | `#64D2FF` | 4.8:1 / 11.5:1 | Cooldown section badge/text |

### Exercise Card Tints (Active Workout)

Tint overlays applied to `secondaryBackground` on active-workout exercise/superset cards, based on the aggregate status of all sets. Tints apply only when every set is finalized (completed or skipped) — any pending set keeps the card neutral. Full rule lives in `spec/screens/active-workout.md`.

| State | Overlay | Opacity |
|-------|---------|---------|
| Neutral (any pending / failed) | — | 0% (base `secondaryBackground` only) |
| All completed | Success (`#1E7E34` / `#30D158`) | 18% |
| All skipped | Warning (`#C45100` / `#FF9F0A`) | 18% |
| Mixed completed + skipped | Diagonal `LinearGradient(Success, Warning)` top-leading → bottom-trailing | 22% each stop |

Opacities are chosen to stay below 25% so label text on the card continues to meet WCAG AA against both light and dark system backgrounds. Tints reuse the existing Success and Warning tokens — no new color tokens are introduced.

## Typography

The app uses the iOS system font (SF Pro) throughout.

### Scale

| Style | Size | Weight | Usage |
|-------|------|--------|-------|
| Large Title | 34pt | Bold (700) | Screen titles (Home, Plans, etc.) |
| Title 2 | 22pt | Bold (700) | Section headings |
| Title 3 | 20pt | Semibold (600) | Input fields (active set weight/reps) |
| Headline | 17pt | Semibold (600) | Exercise names, card titles |
| Body | 17pt | Regular (400) | Default body text |
| Callout | 16pt | Regular (400) | Secondary labels |
| Subheadline | 15pt | Regular (400) | Button text, nav links |
| Caption | 12pt | Regular (400) | Input labels, hints, progress text |
| Caption 2 | 11pt | Regular (400) | Smallest labels ("UP NEXT") |

### Numeric Display

- Use `.monospacedDigit()` for all numeric values (weights, reps, timers, counters)
- Timer displays use monospaced system font at 48pt (exercise timer) or 24pt (rest timer)

## Spacing

| Token | Value | Usage |
|-------|-------|-------|
| XS | 4pt | Minimal gaps, inline padding |
| SM | 8pt | Between set rows, icon gaps |
| MD | 16pt | Content padding, section gaps |
| LG | 24pt | Between cards, section margins |
| XL | 32pt | Screen-level padding |

## Corner Radius

| Token | Value | Usage |
|-------|-------|-------|
| XS | 4pt | Small chrome: side/status labels, set-number badge, progress bars, inline info boxes |
| SM | 8pt | Input fields, small containers |
| MD | 12pt | Cards (plans, exercises, history rows, summaries), modals — the standard card radius |
| LG | 16pt | Large surfaces / full-width banners (e.g. error banner) |

All radii below SM (XS) come from a token; no raw literal radii live outside `Theme.swift`.

### Shapes (Capsule)

Two element families are fully rounded (Capsule / pill) rather than using the radius scale:

| Family | Elements |
|--------|----------|
| **Buttons** | All primary/secondary filled buttons — Create Plan, Start Workout, Complete Set, Add Exercise, End Workout, Edit, Reprocess, Details, Add Drop, Paste, Build with AI, Import actions. System `.bordered`/`.borderedProminent` buttons use `.buttonBorderShape(.capsule)`; custom-background buttons clip to `Capsule()`. |
| **Badges / chips** | Tag chips (`push`, `upper`), `SUPERSET`, `AMRAP`, `Drop`, `/side`, Left/Right side labels — all `Capsule()`. |

**Intentional one-off radii** (not tokenized, by design): the 72×100pt phone-shaped theme thumbnails in the appearance picker (10pt, mimics a device), their 2pt skeleton content lines, and the 96pt onboarding app-icon mark (21pt continuous, mirrors the app-icon squircle).

## Component Dimensions

| Component | Dimension | Value |
|-----------|-----------|-------|
| Minimum tap target | Height | 44pt |
| Exercise badge | Diameter | 24pt |
| Set status icon | Diameter | 22pt |
| Tab bar icon | Frame | 22 × 22pt |
| Input field | Height | 40pt |
| Complete Set button | Height | 44pt |
| Progress bar | Height | 6pt |
| Toggle switch | Size | 51 × 27pt |

## Icons (SF Symbols)

### Tab Bar

| Tab | SF Symbol | Label |
|-----|-----------|-------|
| Home | `house` | LiftMark |
| Plans | `doc.on.clipboard` | Plans |
| History | `dumbbell` | Workouts |
| Settings | `gearshape` | Settings |

Active tab uses filled variant; inactive uses outline/stroke.

### Navigation & Actions

| Action | SF Symbol | Context |
|--------|-----------|---------|
| Back / Disclosure | `chevron.right` | Nav rows, card arrows |
| Expand / Collapse | `chevron.down` / `chevron.up` | Collapsible sections |
| Add | `plus` | Add exercise, add gym |
| Edit | `pencil` | Edit exercise |
| Delete | `trash` | Delete plan |
| More | `ellipsis.circle` | Options menu |
| Share / Export | `square.and.arrow.up` | Export data |
| Filter | `line.3.horizontal.decrease.circle` | Filter toggle |

### Workout Tracking

| Action | SF Symbol | Context |
|--------|-----------|---------|
| Pause | `pause.fill` | Pause workout |
| Play / YouTube | `play.rectangle` | YouTube search link |
| Skip | `forward.fill` | Skip set, skip rest |
| Complete | `checkmark.circle.fill` | Completed set indicator |
| Skip indicator | `minus.circle.fill` | Skipped set indicator |
| Current set | `arrow.right.circle.fill` | Active set indicator |
| Favorite | `heart` / `heart.fill` | Plan favorite toggle (red when filled, tertiary label when unfilled) |
| Timer | `timer` | Rest timer |

### Data & Visibility

| Action | SF Symbol | Context |
|--------|-----------|---------|
| Document | `doc.text` | Workout plan file |
| Clipboard | `doc.on.clipboard` | Copy/plan reference |
| Analytics | `chart.line.downtrend.xyaxis` | History/stats |
| Show | `eye` | Password visibility |
| Hide | `eye.slash` | Password visibility |
| Cancel / Remove | `xmark.circle.fill` | Cancel, remove API key |

## Set Row Visual States

| State | Indicator | Text Color | Border | Background |
|-------|-----------|------------|--------|------------|
| Pending | Grey number | Default | None | None |
| Current (active) | Blue `arrow.right.circle.fill` | Default | 1.5px Primary | Primary @ 8% opacity |
| Completed | Green `checkmark.circle.fill` | Success green | None | None |
| Skipped | Orange `minus.circle.fill` | Warning orange | None | None |
| Editing | Original status icon | Default | 1px Grey | None |

## Rest Timer / Exercise Timer

| Component | Font | Color |
|-----------|------|-------|
| Rest countdown | 24pt monospaced bold | Primary blue |
| Exercise timer | 48pt monospaced bold | Default (green when target reached) |
| Target label | 12pt caption | Secondary text |

## Theme Selector

Three-segment control: **Light** / **Dark** / **Auto**

- Active segment: filled Primary blue background, white text
- Inactive segment: transparent, secondary text
- Setting applies immediately via `overrideUserInterfaceStyle` on root window
