# CloudKit Sync Smoke Tests

Manual testing checklist for CloudKit sync using CKSyncEngine. Run on real devices before each release that touches sync code.

## Prerequisites

- [ ] Two Apple devices (iPhone/iPad) signed into the same iCloud account
- [ ] LiftMark Dev installed on both devices (or TestFlight build after release)
- [ ] CloudKit Dashboard access (icloud.developer.apple.com)
- [ ] iCloud Drive enabled on both devices
- [ ] Network connectivity on both devices

## 1. Fresh Install Sync

- [ ] Install on Device A, create or import a workout plan with multiple exercises and sets
- [ ] Open CloudKit Dashboard and verify the LiftMarkData zone contains the plan
- [ ] Verify all PlannedExercise and PlannedSet records are present in the zone
- [ ] Delete the app from Device A
- [ ] Reinstall LiftMark on Device A
- [ ] Verify the plan syncs back with all exercises and sets intact
- [ ] Verify exercise order is preserved
- [ ] Verify set details (weight, reps, attributes) match original

## 2. Multi-Device Sync

- [ ] On Device A, import a workout plan
- [ ] Wait up to 30 seconds for sync
- [ ] On Device B, verify the plan appears with all exercises and sets
- [ ] On Device B, favorite the plan
- [ ] On Device A, verify the favorite status updates
- [ ] On Device A, create a second plan
- [ ] On Device B, verify both plans are present

## 3. Workout Session Sync

- [ ] On Device A, start a workout session from a plan
- [ ] Complete 2-3 sets with actual weight/reps entered
- [ ] Complete the workout
- [ ] On Device B, verify the completed session appears in history
- [ ] Verify exercise names, set counts, actual weight/reps are correct
- [ ] Verify session duration and timestamps are present

## 4. Discard Workout (Canceled Status Protection)

- [ ] On Device A, start a workout session
- [ ] Complete at least one set
- [ ] Discard/cancel the workout
- [ ] Verify the session status is "canceled" on Device A
- [ ] On Device B, verify the session shows as canceled (not completed or in_progress)
- [ ] Verify that no subsequent sync overwrites the canceled status back to in_progress

## 5. Settings Sync

- [ ] On Device A, change the default weight unit to kg
- [ ] On Device A, change the theme to dark
- [ ] On Device A, toggle countdown sounds off
- [ ] On Device B, verify weight unit, theme, and countdown sounds match
- [ ] On Device A, accept the disclaimer (if not already accepted)
- [ ] On Device B, verify hasAcceptedDisclaimer is NOT synced (Device B should still require acceptance)
- [ ] On Device A, enable developer mode
- [ ] On Device B, verify developer mode is NOT enabled (local-only field)
- [ ] Verify no AI provider key (Anthropic, OpenAI, Gemini, Ollama) is ever visible in CloudKit Dashboard records

## 6. Gym Management

- [ ] On Device A, create a new gym with a custom name
- [ ] Add 3-4 pieces of equipment to the gym
- [ ] On Device B, verify the gym and all equipment appear
- [ ] On Device A, soft-delete the gym
- [ ] On Device B, verify the gym no longer appears in the list
- [ ] Force a full sync on Device B and verify the soft-deleted gym is not re-inserted

## 7. Conflict Resolution (Last-Writer-Wins)

- [ ] Put Device B in airplane mode
- [ ] On Device A, rename a workout plan to "Name A"
- [ ] On Device B (offline), rename the same plan to "Name B"
- [ ] Re-enable network on Device B
- [ ] Wait for sync to complete on both devices
- [ ] Verify both devices converge to the same name (the one with the later updatedAt timestamp)

## 8. Active Session Protection

- [ ] On Device A, start a workout session (leave it in progress)
- [ ] On Device B, delete the workout plan that the session is based on
- [ ] Wait for sync
- [ ] On Device A, verify the active session is still intact and usable
- [ ] Verify the parent plan's exercises and sets are still accessible during the workout
- [ ] Complete the workout on Device A
- [ ] Verify the completed session syncs to Device B

## 9. Plan Edit During Sync

- [ ] On Device A, import a plan with 5+ exercises
- [ ] Verify it syncs to Device B
- [ ] On Device A, edit the plan: add an exercise, remove an exercise, reorder
- [ ] On Device B, verify the updated plan matches (correct exercise count, order, names)
- [ ] Verify no duplicate exercises appear

## 10. Offline Resilience

- [ ] On Device A, go to airplane mode
- [ ] Create a new plan, start and complete a workout
- [ ] Re-enable network
- [ ] Verify all data syncs to CloudKit within 60 seconds
- [ ] On Device B, verify the plan and completed session appear

## 11. Large Data Volume

- [ ] Import 5+ workout plans with varied exercises
- [ ] Complete 10+ workout sessions over multiple days
- [ ] On a fresh install (Device B or reinstall), verify all data syncs correctly
- [ ] Verify no records are missing or duplicated

## Results

| Test | Device A | Device B | Pass/Fail | Notes |
|------|----------|----------|-----------|-------|
| 1. Fresh Install | | | | |
| 2. Multi-Device | | | | |
| 3. Session Sync | | | | |
| 4. Discard Workout | | | | |
| 5. Settings Sync | | | | |
| 6. Gym Management | | | | |
| 7. Conflict Resolution | | | | |
| 8. Active Session Protection | | | | |
| 9. Plan Edit | | | | |
| 10. Offline Resilience | | | | |
| 11. Large Volume | | | | |
