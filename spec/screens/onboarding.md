# Onboarding Screen

## Purpose

Welcome new users and present a legal disclaimer that must be accepted before using the app.

## Presentation

- Full screen, no tab bar, no navigation bar
- Shown once on first launch when `hasAcceptedDisclaimer` is `false`
- Cannot be dismissed — user must tap "I Understand" to proceed

## Layout

### Top Section — Welcome

- **App icon** (centered, moderate size)
- **Title**: "Welcome to LiftMark"
- **Subtitle**: "Markdown workouts you own"

### Middle Section — Brief Explanation

A short paragraph explaining what the app does:

> LiftMark helps you track your workouts using markdown — putting you in control of your plans and your data. Log your sets during sessions and keep a portable history of your training, ready for any text editor or AI assistant.

### Disclaimer Section — Scrollable

The following disclaimer text is displayed in a scrollable area with clear visual distinction (e.g., secondary background, inset card):

> **Tracking Only**
>
> LiftMark is a workout tracking tool. It does not provide exercise instruction, form guidance, coaching, or medical advice. You are solely responsible for knowing how to safely perform any exercises you track.
>
> **Assumption of Risk**
>
> Strength training and physical exercise carry inherent risks including injury, disability, and in rare cases death. By using this app, you acknowledge these risks and accept full responsibility for your physical safety during workouts.
>
> **Younger Users**
>
> If you are under 18, we recommend working with a parent, guardian, or qualified fitness professional when performing strength training exercises.

### Bottom Section — Accept Button

- **"I Understand"** button (primary style, full width)
  - testID: `onboarding-accept-button`
  - On tap: sets `hasAcceptedDisclaimer = true`, transitions to Home Screen

## Layout on larger screens

- Content is constrained to a readable column (max width ~500pt) and centered horizontally.
- When the content is shorter than the available height (e.g. iPad), the column is **centered vertically** rather than anchored to the top, so it does not float in the upper portion of a large screen.
- When the content is taller than the available height (e.g. small phones or large Dynamic Type), it scrolls, with the content top-aligned.

## Test IDs

| Element | testID |
|---------|--------|
| Onboarding screen | `onboarding-screen` |
| Accept button | `onboarding-accept-button` |

## Settings Re-access

The disclaimer text (without the accept button) is accessible from **Settings > About > Disclaimer** as a read-only view. This uses a shared component or identical text constant to ensure consistency.
