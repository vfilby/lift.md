# Home Screen

## Purpose
Main dashboard showing max lift tiles, recent workout plans, and an active workout resume banner. Serves as the primary landing page after app launch.

## Route
`/(tabs)/index` — First tab in the bottom tab bar.

## Layout
- **Header**: None (tab header provided by navigator)
- **Body**: ScrollView containing:
  1. Resume Workout Banner (conditional)
  2. Max Lifts section (2x2 grid of tiles)
  3. Recent Plans section (up to 3 plan cards)
  4. "Create Plan" button (inline, at end of scroll content)

### Layout Constraint: Tab Bar Clearance

**Critical**: All interactive UI elements MUST be fully visible and tappable above the tab bar. No buttons, cards, or interactive elements may be positioned behind or obscured by the tab bar (including translucent/frosted glass tab bars). The scroll content area must account for the tab bar inset — either by using safe area insets or by adding sufficient bottom padding so that the last element in the scroll view can be scrolled fully above the tab bar.

The "Create Plan" button MUST be placed **inside the ScrollView** as the last content item (not fixed/pinned to the bottom of the screen outside the scroll area). This ensures it scrolls naturally with content and is never obscured by the tab bar. If the content is short enough that no scrolling is needed, the button must still be visible above the tab bar.

## UI Elements

| Element | testID | Type |
|---------|--------|------|
| Screen container | `home-screen` | View |
| Resume banner | `resume-workout-banner` | TouchableOpacity |
| Max lift tile (per index) | `max-lift-tile-{index}` | TouchableOpacity |
| Recent plans section | `recent-plans` | View |
| Empty state | `empty-state` | View |
| Plan card (per plan) | `workout-card-{plan.id}` | TouchableOpacity |
| Create Plan button | `button-import-workout` | TouchableOpacity |
| Exercise picker modal | (from ExercisePickerModal) | Modal |

## User Interactions
- **Tap resume banner** → navigates to `/workout/active`
- **Tap plan card** → navigates to `/workout/{plan.id}`
- **Tap "Create Plan" button** → navigates to `/modal/import`
- **Tap max lift tile** → presents the exercise history sheet (same view as the history detail "Show details" sheet) for that tile's exercise
- **Long-press max lift tile** (400ms delay) → opens ExercisePickerModal with haptic feedback
- **Select exercise in picker** → updates `homeTiles` in settings for that tile index

## Navigation
- `/workout/active` — via resume banner
- `/workout/{id}` — via plan card tap
- `/modal/import` — via Create Plan button

## Error/Empty States
- **No plans**: Shows empty state view with "No plans yet" / "Import your first workout plan to get started"
- **No best weight for tile**: Shows em dash (—) instead of weight
- **No active session**: Resume banner hidden
