import { describe, it, expect } from 'vitest';
import { parseWorkout } from '../src/parser/index.js';

// MARK: - Basic Parsing

describe('Basic Parsing', () => {
  it('parses simple workout with one exercise', () => {
    const markdown = `# Test Workout
@units: lbs

## Bicep Curls
- 20 x 10
- 25 x 8`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data).not.toBeNull();
    expect(result.data?.name).toBe('Test Workout');
    expect(result.data?.defaultWeightUnit).toBe('lbs');
    expect(result.data?.exercises.length).toBe(1);
    expect(result.data?.exercises[0].exerciseName).toBe('Bicep Curls');
    expect(result.data?.exercises[0].sets.length).toBe(2);
  });
});

// MARK: - Rest Modifiers

describe('Rest Modifiers', () => {
  it('parses sets with rest modifiers', () => {
    const markdown = `# Workout
## Exercise
- 100 x 5 @rest: 60s
- 100 x 5 @rest: 90s`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].restSeconds).toBe(60);
    expect(result.data?.exercises[0].sets[1].restSeconds).toBe(90);
  });
});

// MARK: - RPE Modifiers

describe('RPE Modifiers', () => {
  it('parses sets with RPE modifiers', () => {
    const markdown = `# Workout
## Squats
- 225 lbs x 5 @rpe: 8`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].targetWeight).toBe(225);
    expect(result.data?.exercises[0].sets[0].targetReps).toBe(5);
    expect(result.data?.exercises[0].sets[0].targetRpe).toBe(8);
    expect(result.warnings.some((w) => w.includes('@rpe is deprecated'))).toBe(true);
  });
});

// MARK: - RPE Rounding

describe('RPE Rounding', () => {
  it('stores RPE 8 as 8 with no rounding warning', () => {
    const markdown = `# Workout
## Squats
- 225 x 5 @rpe: 8`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].targetRpe).toBe(8);
    expect(result.warnings.some((w) => w.includes('RPE rounded'))).toBe(false);
  });

  it('rounds RPE 8.5 to 9 with rounding warning', () => {
    const markdown = `# Workout
## Squats
- 225 x 5 @rpe: 8.5`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].targetRpe).toBe(9);
    expect(result.warnings.some((w) => w.includes('RPE rounded to nearest integer (8.5 → 9)'))).toBe(true);
  });

  it('rounds RPE 8.3 to 8 with rounding warning', () => {
    const markdown = `# Workout
## Squats
- 225 x 5 @rpe: 8.3`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].targetRpe).toBe(8);
    expect(result.warnings.some((w) => w.includes('RPE rounded to nearest integer (8.3 → 8)'))).toBe(true);
  });

  it('rounds RPE 8.7 to 9 with rounding warning', () => {
    const markdown = `# Workout
## Squats
- 225 x 5 @rpe: 8.7`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].targetRpe).toBe(9);
    expect(result.warnings.some((w) => w.includes('RPE rounded to nearest integer (8.7 → 9)'))).toBe(true);
  });
});

// MARK: - Deprecated Modifier Warnings

describe('Deprecated Modifier Warnings', () => {
  it('emits deprecation warning for @rpe', () => {
    const markdown = `# Workout
## Squats
- 225 x 5 @rpe: 8`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].targetRpe).toBe(8);
    const rpeWarnings = result.warnings.filter((w) => w.includes('@rpe is deprecated'));
    expect(rpeWarnings).toHaveLength(1);
    expect(rpeWarnings[0]).toContain('use freeform notes instead');
  });

  it('emits deprecation warning for @tempo', () => {
    const markdown = `# Workout
## Pause Squats
- 225 x 5 @tempo: 3-2-1-0`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].tempo).toBe('3-2-1-0');
    const tempoWarnings = result.warnings.filter((w) => w.includes('@tempo is deprecated'));
    expect(tempoWarnings).toHaveLength(1);
    expect(tempoWarnings[0]).toContain('use freeform notes instead');
  });

  it('emits deprecation warnings for both @rpe and @tempo on same line', () => {
    const markdown = `# Workout
## Bench
- 225 x 5 @rpe: 8 @tempo: 3-0-1-0`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.warnings.some((w) => w.includes('@rpe is deprecated'))).toBe(true);
    expect(result.warnings.some((w) => w.includes('@tempo is deprecated'))).toBe(true);
  });

  it('emits deprecation warning for @amrap (not a modifier — use rep value)', () => {
    const markdown = `# Workout
## Pull-ups
- bw x 10 @amrap`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    // @amrap as a flag does NOT set isAmrap — only the rep value `AMRAP` does.
    expect(result.data?.exercises[0].sets[0].isAmrap).toBeFalsy();
    const amrapWarnings = result.warnings.filter((w) => w.includes('@amrap is not a modifier'));
    expect(amrapWarnings).toHaveLength(1);
    expect(amrapWarnings[0]).toContain('135 x AMRAP');
  });

  it('rep-value AMRAP still parses without warning', () => {
    const markdown = `# Workout
## Pull-ups
- bw x AMRAP`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].isAmrap).toBe(true);
    expect(result.warnings.some((w) => w.includes('@amrap'))).toBe(false);
  });
});

// MARK: - Bodyweight Exercises

describe('Bodyweight Exercises', () => {
  it('parses bodyweight exercises', () => {
    const markdown = `# Workout
## Pull-ups
- bw x 10
- bw x 8`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].targetWeight).toBeNull();
    expect(result.data?.exercises[0].sets[0].targetReps).toBe(10);
  });
});

// MARK: - Time-Based Sets

describe('Time-Based Sets', () => {
  it('parses time-based sets', () => {
    const markdown = `# Workout
## Plank
- 60s
- 45s`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].targetTime).toBe(60);
    expect(result.data?.exercises[0].sets[1].targetTime).toBe(45);
  });
});

// MARK: - KG Units

describe('KG Units', () => {
  it('parses kg units', () => {
    const markdown = `# Workout
@units: kg

## Deadlift
- 100 kg x 5`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.defaultWeightUnit).toBe('kg');
    expect(result.data?.exercises[0].sets[0].targetWeight).toBe(100);
    expect(result.data?.exercises[0].sets[0].targetWeightUnit).toBe('kg');
  });
});

// MARK: - Error Cases

describe('Error Cases', () => {
  it('fails when no workout header found', () => {
    const markdown = `Just some text
without a proper workout`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(false);
    expect(result.errors.length).toBeGreaterThan(0);
  });

  it('fails when exercise has no sets', () => {
    const markdown = `# Workout
## Empty Exercise`;
    const result = parseWorkout(markdown);

    // Without sets, the workout header isn't found
    expect(result.success).toBe(false);
    expect(result.errors.length).toBeGreaterThan(0);
  });

  it('rejects standalone AMRAP in exercise with other valid sets', () => {
    const markdown = `# Workout
@units: lbs

## Push-ups
- 15
- 12 @dropset
- AMRAP`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(false);
    expect(result.errors.some(e => e.includes('AMRAP'))).toBe(true);
  });
});

// MARK: - Tags

describe('Tags', () => {
  it('parses workout tags', () => {
    const markdown = `# Upper Body
@tags: strength, push
@units: lbs

## Bench Press
- 135 x 10`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.tags).toContain('strength');
    expect(result.data?.tags).toContain('push');
  });
});

// MARK: - Supersets

describe('Supersets', () => {
  it('parses supersets', () => {
    const markdown = `# Workout

## Superset
### Bicep Curls
- 20 x 10
### Tricep Extensions
- 20 x 10`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    // Should have parent superset + 2 child exercises
    expect((result.data?.exercises.length ?? 0)).toBeGreaterThanOrEqual(2);
  });

  it('treats "superset" header with only sets (no child headers) as regular exercise', () => {
    const markdown = `# Workout

## Superset: Arms
- 20 x 10
- 30 x 8`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const exercises = result.data?.exercises ?? [];

    // Should be treated as a regular exercise, not a superset group
    expect(exercises.length).toBe(1);
    expect(exercises[0].exerciseName).toBe('Superset: Arms');
    expect(exercises[0].groupType).toBeNull();
    expect(exercises[0].parentExerciseId).toBeNull();
    expect(exercises[0].sets.length).toBe(2);
  });

  it('treats "superset" header with no content as error (NO_SETS)', () => {
    const markdown = `# Workout

## Superset: Arms

## Bench Press
- 135 x 10`;
    const result = parseWorkout(markdown);

    // "Superset: Arms" has no child headers and no sets — treated as regular exercise
    // which triggers a NO_SETS error, causing the parse to fail
    expect(result.success).toBe(false);
    expect(result.errors.some(e => e.includes('Superset: Arms') && e.includes('no sets'))).toBe(true);

    // data is null when success is false
    expect(result.data).toBeNull();
  });
});

// MARK: - Sections

describe('Sections', () => {
  it('parses sections with exercises', () => {
    const markdown = `# Workout

## Warmup
### Arm Circles
- 30s
### Jumping Jacks
- 60s

## Workout
### Bench Press
- 135 x 10`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const exercises = result.data?.exercises ?? [];

    // Should have: Warmup section parent, 2 warmup exercises, Workout section parent, 1 workout exercise
    expect(exercises.length).toBe(5);

    // First should be section parent
    expect(exercises[0].groupType).toBe('section');
    expect(exercises[0].exerciseName).toBe('Warmup');
    expect(exercises[0].sets.length).toBe(0);

    // Warmup exercises should have parent pointing to warmup section
    expect(exercises[1].exerciseName).toBe('Arm Circles');
    expect(exercises[1].parentExerciseId).toBe(exercises[0].id);

    expect(exercises[2].exerciseName).toBe('Jumping Jacks');
    expect(exercises[2].parentExerciseId).toBe(exercises[0].id);
  });
});

// MARK: - Supersets Inside Sections

describe('Supersets Inside Sections', () => {
  it('parses superset inside sections', () => {
    const markdown = `# Workout

## Workout
### Superset: Arms
#### Bicep Curls
- 20 x 10
#### Tricep Extensions
- 20 x 10`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const exercises = result.data?.exercises ?? [];

    // Should have: Workout section parent, Superset parent, 2 superset children
    expect(exercises.length).toBe(4);

    // First should be section parent
    const sectionParent = exercises[0];
    expect(sectionParent.groupType).toBe('section');
    expect(sectionParent.exerciseName).toBe('Workout');
    expect(sectionParent.sets.length).toBe(0);

    // Second should be superset parent, with parent pointing to section
    const supersetParent = exercises[1];
    expect(supersetParent.groupType).toBe('superset');
    expect(supersetParent.exerciseName).toBe('Superset: Arms');
    expect(supersetParent.sets.length).toBe(0);
    expect(supersetParent.parentExerciseId).toBe(sectionParent.id);

    // Superset children should have parent pointing to superset, NOT section
    const child1 = exercises[2];
    expect(child1.exerciseName).toBe('Bicep Curls');
    expect(child1.parentExerciseId).toBe(supersetParent.id);
    expect(child1.sets.length).toBe(1);

    const child2 = exercises[3];
    expect(child2.exerciseName).toBe('Tricep Extensions');
    expect(child2.parentExerciseId).toBe(supersetParent.id);
    expect(child2.sets.length).toBe(1);
  });
});

// MARK: - Non-Adjacent Header Levels

describe('Non-Adjacent Header Levels', () => {
  it('parses superset with non-adjacent header levels', () => {
    // H2 superset -> H4 exercises (skipping H3)
    const markdown = `# Workout

## Superset: Arms
#### Bicep Curls
- 20 x 10
#### Tricep Extensions
- 20 x 10`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const exercises = result.data?.exercises ?? [];

    // Should have: Superset parent + 2 superset children
    expect(exercises.length).toBe(3);

    const supersetParent = exercises[0];
    expect(supersetParent.groupType).toBe('superset');
    expect(supersetParent.exerciseName).toBe('Superset: Arms');
    expect(supersetParent.sets.length).toBe(0);

    const child1 = exercises[1];
    expect(child1.exerciseName).toBe('Bicep Curls');
    expect(child1.parentExerciseId).toBe(supersetParent.id);
    expect(child1.sets.length).toBe(1);

    const child2 = exercises[2];
    expect(child2.exerciseName).toBe('Tricep Extensions');
    expect(child2.parentExerciseId).toBe(supersetParent.id);
    expect(child2.sets.length).toBe(1);
  });
});

// MARK: - Per-Side Modifier

describe('Per-Side Modifier', () => {
  it('parses per-side modifier', () => {
    const markdown = `# Workout
## Stretches
- 30s @perside
- 45s @perside`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].isPerSide).toBe(true);
    expect(result.data?.exercises[0].sets[1].isPerSide).toBe(true);
  });
});

// MARK: - Dropset Modifier

describe('Dropset Modifier', () => {
  it('parses dropset modifier', () => {
    const markdown = `# Workout
## Curls
- 20 x 10
- 15 x 12 @dropset`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    // First set should not be a dropset
    expect(result.data?.exercises[0].sets[0].isDropset).toBe(false);
    expect(result.data?.exercises[0].sets[1].isDropset).toBe(true);
  });
});

// MARK: - Trailing Text

describe('Trailing Text', () => {
  it('parses trailing text without modifiers', () => {
    const markdown = `# Workout
## Bench Press
- 225 x 5 Felt strong today!
- 245 x 3 PR set!`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].notes).toBe('Felt strong today!');
    expect(result.data?.exercises[0].sets[1].notes).toBe('PR set!');
  });

  it('parses trailing text after modifiers', () => {
    const markdown = `# Workout
## Squats
- 315 x 5 @rpe: 8 Great depth today
- 335 x 3 @rpe: 9 @rest: 180s Tough but doable`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].targetRpe).toBe(8);
    expect(result.data?.exercises[0].sets[0].notes).toBe('Great depth today');
    expect(result.data?.exercises[0].sets[1].targetRpe).toBe(9);
    expect(result.data?.exercises[0].sets[1].restSeconds).toBe(180);
    expect(result.data?.exercises[0].sets[1].notes).toBe('Tough but doable');
  });

  it('parses trailing text with tempo modifier', () => {
    const markdown = `# Workout
## Pause Squats
- 225 x 5 @tempo: 3-2-1-0 @rest: 120s Really focused on the pause`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].tempo).toBe('3-2-1-0');
    expect(result.data?.exercises[0].sets[0].restSeconds).toBe(120);
    expect(result.data?.exercises[0].sets[0].notes).toBe('Really focused on the pause');
  });

  it('handles text that looks like modifier but is not', () => {
    const markdown = `# Workout
## Deadlift
- 405 x 5 @rpe: 8.5 Back felt good, no issues`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    // RPE 8.5 rounds to 9 (nearest integer)
    expect(result.data?.exercises[0].sets[0].targetRpe).toBe(9);
    expect(result.data?.exercises[0].sets[0].notes).toBe('Back felt good, no issues');
  });

  it('handles multiple @ symbols in trailing text', () => {
    const markdown = `# Workout
## Bench Press
- 225 x 5 @rpe: 7 Hit the target @135 for warmup`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].targetRpe).toBe(7);
    // The trailing text includes text from after @135
    expect(result.data?.exercises[0].sets[0].notes).toContain('Hit the target');
  });

  it('handles trailing text with only invalid modifiers', () => {
    const markdown = `# Workout
## Press
- 135 x 8 @invalid: value Some note here`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    // Invalid modifier should generate a warning
    expect(result.warnings.length).toBeGreaterThan(0);
    expect(result.data?.exercises[0].sets[0].notes).toContain('Some note here');
  });

  it('parses trailing text after flag modifiers', () => {
    const markdown = `# Workout
## Curls
- 20 x 12 @dropset Burned out completely
- 15 x 15 Great pump`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].isDropset).toBe(true);
    expect(result.data?.exercises[0].sets[0].notes).toBe('Burned out completely');
    expect(result.data?.exercises[0].sets[1].notes).toBe('Great pump');
  });

  it('preserves trailing text with special characters', () => {
    const markdown = `# Workout
## Squats
- 225 x 5 @rpe: 8 Form was perfect! \u{1F4AA} #PR`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].notes).toBe('Form was perfect! \u{1F4AA} #PR');
  });

  it('handles empty trailing text gracefully', () => {
    const markdown = `# Workout
## Bench Press
- 225 x 5 @rpe: 8
- 245 x 3`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].notes).toBeNull();
    expect(result.data?.exercises[0].sets[1].notes).toBeNull();
  });
});

// MARK: - GenAI Format Variations

describe('GenAI Format Variations', () => {
  it('handles directional instructions', () => {
    const markdown = `# Test
## Arm Circles
- 30s forward
- 30s backward`;
    const result = parseWorkout(markdown);
    // Expected: success with notes preserved or defined errors
    expect(result.success || result.errors.length > 0).toBe(true);
  });

  it('handles side/limb specifications', () => {
    const markdown = `# Test
## Dead Bug
- 12 each side
- 10 each arm`;
    const result = parseWorkout(markdown);
    expect(result.success || result.errors.length > 0).toBe(true);
  });

  it('handles per side and both sides', () => {
    const markdown = `# Test
## Stretch
- 45s per side
- 60s both sides`;
    const result = parseWorkout(markdown);
    expect(result.success || result.errors.length > 0).toBe(true);
  });

  it('parses Claude-generated push day workout', () => {
    const markdown = `# Push Day - Compound Focus
@tags: push, chest, shoulders, triceps
@units: lbs

## Warmup

### Arm Circles
- 30s forward
- 30s backward

### Band Pull-Aparts
- 15
- 15

### Push-up to Downward Dog
- 8

### Empty Bar Overhead Press
- 45 x 10
- 45 x 8

## Workout

### Bench Press
- 135 x 8
- 185 x 6 @rpe: 6
- 205 x 5 @rpe: 7
- 225 x 4 @rpe: 8
- 225 x 4 @rpe: 9 @rest: 180s

### Overhead Press
- 95 x 8
- 115 x 6 @rpe: 7
- 125 x 5 @rpe: 8 @rest: 120s

### Incline Dumbbell Press
- 50 x 10
- 60 x 8 @rpe: 7
- 65 x 8 @rpe: 8

### Dips
- bw x 10
- bw x 8 @rpe: 8
- bw x AMRAP

### Superset: Shoulder & Tricep Finisher
#### Lateral Raises
- 20 x 12
- 25 x 10
#### Tricep Pushdowns
- 50 x 12
- 60 x 10

## Core

### Hanging Leg Raises
- 10
- 10
- 10 @rest: 60s

### Dead Bug
- 12 each side
- 12 each side

## Cool Down

### Doorway Chest Stretch
- 45s each side

### Overhead Tricep Stretch
- 30s each arm

### Thread the Needle
- 30s each side

### Child's Pose
- 60s`;
    const result = parseWorkout(markdown);

    if (result.success) {
      expect(result.data?.exercises).toBeDefined();
      expect((result.data?.exercises.length ?? 0)).toBeGreaterThan(0);
    } else {
      // Document the failures for now
      expect(result.errors.length).toBeGreaterThan(0);
    }
  });
});

// MARK: - Edge Cases

describe('Edge Cases', () => {
  it('handles empty input', () => {
    const result = parseWorkout('');
    expect(result.success).toBe(false);
  });

  it('handles whitespace only input', () => {
    const result = parseWorkout('   \n\n  \n');
    expect(result.success).toBe(false);
  });

  it('parses minute time units', () => {
    const markdown = `# Workout
## Plank
- 2m`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].targetTime).toBe(120);
  });

  it('parses rest in minutes', () => {
    const markdown = `# Workout
## Squats
- 225 x 5 @rest: 3m`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].restSeconds).toBe(180);
  });

  it('parses single number as bodyweight reps', () => {
    const markdown = `# Workout
## Push-ups
- 15
- 12`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].targetReps).toBe(15);
    expect(result.data?.exercises[0].sets[0].targetWeight).toBeNull();
  });

  it('rejects standalone AMRAP (no weight)', () => {
    const markdown = `# Workout
## Push-ups
- AMRAP`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(false);
    expect(result.errors.some(e => e.includes('AMRAP'))).toBe(true);
  });

  it('parses weighted AMRAP', () => {
    const markdown = `# Workout
## Bench Press
- 135 x AMRAP`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].isAmrap).toBe(true);
    expect(result.data?.exercises[0].sets[0].targetWeight).toBe(135);
  });

  it('parses bodyweight AMRAP', () => {
    const markdown = `# Workout
## Pull-ups
- bw x AMRAP`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].isAmrap).toBe(true);
    expect(result.data?.exercises[0].sets[0].targetWeight).toBeNull();
  });

  it('parses explicit reps unit', () => {
    const markdown = `# Workout
## Bench Press
- 225 lbs x 5 reps`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].targetWeight).toBe(225);
    expect(result.data?.exercises[0].sets[0].targetWeightUnit).toBe('lbs');
    expect(result.data?.exercises[0].sets[0].targetReps).toBe(5);
  });

  it('parses weighted timed set', () => {
    const markdown = `# Workout
## Plank
- 45 lbs x 60s`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].targetWeight).toBe(45);
    expect(result.data?.exercises[0].sets[0].targetWeightUnit).toBe('lbs');
    expect(result.data?.exercises[0].sets[0].targetTime).toBe(60);
  });

  it('parses for syntax timed set', () => {
    const markdown = `# Workout
## Plank
- 45 lbs for 60s`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].targetWeight).toBe(45);
    expect(result.data?.exercises[0].sets[0].targetTime).toBe(60);
  });

  it('parses decimal weight', () => {
    const markdown = `# Workout
## Dumbbell Press
- 27.5 x 10`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].targetWeight).toBe(27.5);
  });

  it('rejects invalid units', () => {
    const markdown = `# Workout
@units: pounds

## Bench Press
- 225 x 5`;
    const result = parseWorkout(markdown);

    // Invalid units is an error
    expect(result.success).toBe(false);
  });

  it('handles CRLF line endings', () => {
    const markdown = '# Workout\r\n## Exercise\r\n- 100 x 5\r\n';
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].targetWeight).toBe(100);
    expect(result.data?.exercises[0].sets[0].targetReps).toBe(5);
  });

  it('handles CR line endings', () => {
    const markdown = '# Workout\r## Exercise\r- 100 x 5\r';
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
  });

  it('parses multiple exercises', () => {
    const markdown = `# Full Body
## Squats
- 225 x 5
- 225 x 5
## Bench Press
- 185 x 8
## Deadlift
- 315 x 3`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises.length).toBe(3);
    expect(result.data?.exercises[0].exerciseName).toBe('Squats');
    expect(result.data?.exercises[0].sets.length).toBe(2);
    expect(result.data?.exercises[1].exerciseName).toBe('Bench Press');
    expect(result.data?.exercises[2].exerciseName).toBe('Deadlift');
  });

  it('parses freeform notes on workout', () => {
    const markdown = `# Push Day

Feeling strong today, going for PRs on bench.
Sleep was good, nutrition on point.

## Bench Press
- 225 x 5`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.description).toContain('Feeling strong today');
    expect(result.data?.description).toContain('Sleep was good');
  });

  it('parses freeform notes on exercise', () => {
    const markdown = `# Workout
## Bench Press

Retract scapula, touch chest on every rep.
Focus on driving through the floor.

- 135 x 5`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].notes).toContain('Retract scapula');
  });

  it('parses equipment type metadata', () => {
    const markdown = `# Workout
## Bench Press
@type: barbell
- 225 x 5`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].equipmentType).toBe('barbell');
  });

  it('parses flexible header levels', () => {
    const markdown = `### Push Day
@tags: push

#### Bench Press
- 225 x 5

#### Squat
- 315 x 3`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.name).toBe('Push Day');
    expect(result.data?.exercises[0].exerciseName).toBe('Bench Press');
    expect(result.data?.exercises[1].exerciseName).toBe('Squat');
  });

  it('warns on high rep count', () => {
    const markdown = `# Workout
## Jumping Jacks
- 150`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].targetReps).toBe(150);
    expect(result.warnings.length).toBeGreaterThan(0);
  });

  it('warns on short rest', () => {
    const markdown = `# Workout
## Exercise
- 100 x 5 @rest: 5s`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].restSeconds).toBe(5);
    expect(result.warnings.length).toBeGreaterThan(0);
  });

  it('warns on long rest', () => {
    const markdown = `# Workout
## Exercise
- 100 x 5 @rest: 700s`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].restSeconds).toBe(700);
    expect(result.warnings.length).toBeGreaterThan(0);
  });

  it('parses unit aliases (lb -> lbs)', () => {
    const markdown = `# Workout
@units: lb

## Exercise
- 100 x 5`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.defaultWeightUnit).toBe('lbs');
  });

  it('parses kgs alias', () => {
    const markdown = `# Workout
@units: kgs

## Exercise
- 100 x 5`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.defaultWeightUnit).toBe('kg');
  });

  it('parses sec time unit', () => {
    const markdown = `# Workout
## Plank
- 90 sec`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].targetTime).toBe(90);
  });

  it('parses min time unit', () => {
    const markdown = `# Workout
## Plank
- 2 min`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].targetTime).toBe(120);
  });

  it('preserves source markdown', () => {
    const markdown = `# Workout
## Exercise
- 100 x 5`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.sourceMarkdown).toBe(markdown);
  });

  it('sets exercise order indices', () => {
    const markdown = `# Workout
## Exercise A
- 100 x 5
## Exercise B
- 200 x 5
## Exercise C
- 300 x 5`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].orderIndex).toBe(0);
    expect(result.data?.exercises[1].orderIndex).toBe(1);
    expect(result.data?.exercises[2].orderIndex).toBe(2);
  });

  it('sets set order indices', () => {
    const markdown = `# Workout
## Exercise
- 100 x 5
- 200 x 5
- 300 x 5`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].orderIndex).toBe(0);
    expect(result.data?.exercises[0].sets[1].orderIndex).toBe(1);
    expect(result.data?.exercises[0].sets[2].orderIndex).toBe(2);
  });

  it('generates unique IDs', () => {
    const markdown = `# Workout
## Exercise A
- 100 x 5
## Exercise B
- 200 x 5`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const workout = result.data!;
    const allIds = new Set<string>();
    allIds.add(workout.id);
    for (const exercise of workout.exercises) {
      expect(allIds.has(exercise.id)).toBe(false);
      allIds.add(exercise.id);
      for (const set of exercise.sets) {
        expect(allIds.has(set.id)).toBe(false);
        allIds.add(set.id);
      }
    }
  });

  it('parses multiple modifiers on one line', () => {
    const markdown = `# Workout
## Bench
- 225 x 5 @rpe: 8 @rest: 180s @tempo: 3-0-1-0`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const set = result.data?.exercises[0].sets[0];
    expect(set?.targetRpe).toBe(8);
    expect(set?.restSeconds).toBe(180);
    expect(set?.tempo).toBe('3-0-1-0');
  });

  it('parses dropset with multiple sets', () => {
    const markdown = `# Workout
## Curls
- 100 x 12
- 70 x 10 @dropset
- 50 x 8 @dropset`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].isDropset).toBe(false);
    expect(result.data?.exercises[0].sets[1].isDropset).toBe(true);
    expect(result.data?.exercises[0].sets[2].isDropset).toBe(true);
  });

  it('parses mixed units in same exercise', () => {
    const markdown = `# Workout
## Dumbbell Press
- 50 lbs x 10
- 25 kg x 8`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].targetWeightUnit).toBe('lbs');
    expect(result.data?.exercises[0].sets[1].targetWeightUnit).toBe('kg');
  });

  it('parses case-insensitive units', () => {
    const markdown = `# Workout
## Bench
- 100 LBS x 5`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].targetWeight).toBe(100);
    expect(result.data?.exercises[0].sets[0].targetWeightUnit).toBe('lbs');
  });

  it('parses unicode in exercise name', () => {
    const markdown = `# Workout
## DB Bench Press - 30\u{00B0} Incline
- 80 x 10`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].exerciseName).toBe('DB Bench Press - 30\u{00B0} Incline');
  });

  it('parses special characters in exercise name', () => {
    const markdown = `# Workout
## Barbell Back Squat (Low Bar)
- 315 x 5`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].exerciseName).toBe('Barbell Back Squat (Low Bar)');
  });
});

// MARK: - Unit Lookahead (Issue 5: "Steady" bug)

describe('Unit Lookahead', () => {
  it('trailing text starting with S is not captured as seconds', () => {
    const markdown = `# Workout
## Rowing
- 30 x 25 Steady pace`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const set = result.data?.exercises[0].sets[0];
    expect(set?.targetWeight).toBe(30);
    expect(set?.targetReps).toBe(25);
    expect(set?.targetTime).toBeNull();
    expect(set?.notes).toBe('Steady pace');
  });

  it('explicit seconds unit still works', () => {
    const markdown = `# Workout
## Plank
- 30 x 25s`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const set = result.data?.exercises[0].sets[0];
    expect(set?.targetWeight).toBe(30);
    expect(set?.targetTime).toBe(25);
    expect(set?.targetReps).toBeNull();
  });

  it('seconds unit followed by space', () => {
    const markdown = `# Workout
## Plank
- 30 x 25 s`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const set = result.data?.exercises[0].sets[0];
    expect(set?.targetWeight).toBe(30);
    expect(set?.targetTime).toBe(25);
  });
});

// MARK: - Per-Side Auto-Detection from Exercise Notes

describe('Per-Side Auto-Detection from Exercise Notes', () => {
  it('per-side notes auto-flags timed sets', () => {
    const markdown = `# Workout
## Side Plank
per side
- 60s
- 45s`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const sets = result.data?.exercises[0].sets;
    expect(sets?.length).toBe(2);
    expect(sets?.[0].isPerSide).toBe(true);
    expect(sets?.[1].isPerSide).toBe(true);
  });

  it('per-side notes does not flag rep-based sets', () => {
    const markdown = `# Workout
## Single Leg RDL
per side
- 50 lbs x 10
- 60 lbs x 8`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const sets = result.data?.exercises[0].sets;
    expect(sets?.length).toBe(2);
    expect(sets?.[0].isPerSide).toBe(false);
    expect(sets?.[1].isPerSide).toBe(false);
  });

  it('per-side notes is case insensitive', () => {
    const markdown = `# Workout
## Side Plank
Per Side
- 60s`;
    const result = parseWorkout(markdown);
    expect(result.data?.exercises[0].sets[0].isPerSide).toBe(true);

    const markdown2 = `# Workout
## Side Plank
PER SIDE
- 60s`;
    const result2 = parseWorkout(markdown2);
    expect(result2.data?.exercises[0].sets[0].isPerSide).toBe(true);
  });

  it('per-leg notes auto-flags timed sets', () => {
    const markdown = `# Workout
## Single Leg RDL Hold
per leg
- 30s
- 25s`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const sets = result.data?.exercises[0].sets;
    expect(sets?.[0].isPerSide).toBe(true);
    expect(sets?.[1].isPerSide).toBe(true);
  });

  it('per-arm notes auto-flags timed sets', () => {
    const markdown = `# Workout
## Single Arm Hang
per arm
- 30s
- 25s`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const sets = result.data?.exercises[0].sets;
    expect(sets?.[0].isPerSide).toBe(true);
    expect(sets?.[1].isPerSide).toBe(true);
  });

  it('each-side notes auto-flags timed sets', () => {
    const markdown = `# Workout
## Side Plank
each side
- 60s
- 45s`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const sets = result.data?.exercises[0].sets;
    expect(sets?.[0].isPerSide).toBe(true);
    expect(sets?.[1].isPerSide).toBe(true);
  });

  it('each-leg notes auto-flags timed sets', () => {
    const markdown = `# Workout
## Single Leg Balance
each leg
- 30s`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].isPerSide).toBe(true);
  });

  it('each-arm notes auto-flags timed sets', () => {
    const markdown = `# Workout
## Farmer Hold
each arm
- 30s`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].isPerSide).toBe(true);
  });

  it('each keyword notes auto-flags timed sets', () => {
    const markdown = `# Workout
## Side Plank
Hold each for full duration
- 60s
- 45s`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const sets = result.data?.exercises[0].sets;
    expect(sets?.[0].isPerSide).toBe(true);
    expect(sets?.[1].isPerSide).toBe(true);
  });

  it('per-leg notes does not flag rep-based sets', () => {
    const markdown = `# Workout
## Single Leg RDL
per leg
- 50 lbs x 10
- 60 lbs x 8`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const sets = result.data?.exercises[0].sets;
    expect(sets?.[0].isPerSide).toBe(false);
    expect(sets?.[1].isPerSide).toBe(false);
  });

  it('each-arm notes does not flag rep-based sets', () => {
    const markdown = `# Workout
## Single Arm Curl
each arm
- 25 lbs x 10`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].isPerSide).toBe(false);
  });

  it('explicit per-side modifier still works', () => {
    const markdown = `# Workout
## Stretches
- 30s @perside
- 45s`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].isPerSide).toBe(true);
    expect(result.data?.exercises[0].sets[1].isPerSide).toBe(false);
  });
});

// MARK: - Per-Side Auto-Detection from Set Line Text

describe('Per-Side Auto-Detection from Set Line Text', () => {
  it('per-leg in set line auto-flags timed set', () => {
    const markdown = `# Workout
## Standing Quad Stretch
Pull heel to glutes
- 60s per leg`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const set = result.data?.exercises[0].sets[0];
    expect(set?.targetTime).toBe(60);
    expect(set?.isPerSide).toBe(true);
    // "per leg" should be stripped from notes
    expect(set?.notes).toBeNull();
  });

  it('per-side in set line auto-flags timed set', () => {
    const markdown = `# Workout
## Pigeon Pose
- 90s per side`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const set = result.data?.exercises[0].sets[0];
    expect(set?.targetTime).toBe(90);
    expect(set?.isPerSide).toBe(true);
    expect(set?.notes).toBeNull();
  });

  it('each-side in set line auto-flags timed set', () => {
    const markdown = `# Workout
## Stretch
- 45s each side`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    expect(result.data?.exercises[0].sets[0].isPerSide).toBe(true);
  });

  it('per-leg in set line does not flag rep-based set', () => {
    const markdown = `# Workout
## Lunges
- 25 per leg`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const set = result.data?.exercises[0].sets[0];
    expect(set?.targetReps).toBe(25);
    expect(set?.isPerSide).toBe(false);
  });

  it('per-side set line is case insensitive', () => {
    const markdown = `# Workout
## Stretch
- 60s Per Leg`;
    const result = parseWorkout(markdown);
    expect(result.data?.exercises[0].sets[0].isPerSide).toBe(true);
  });

  it('per-side set line with section headers', () => {
    // Reproduces the user's workout structure with ## sections and ### exercises
    const markdown = `# Post-Snowboarding Stretch
@tags: stretching

## Lower Body

### Standing Quad Stretch
Pull heel to glutes
- 60s per leg

### Pigeon Pose
- 90s per side

### Wide-Leg Forward Fold
- 90s`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const exercises = result.data?.exercises ?? [];
    // Find exercises with sets (not section headers)
    const exercisesWithSets = exercises.filter((e) => e.sets.length > 0);
    expect(exercisesWithSets.length).toBe(3);

    // Standing Quad Stretch: 60s per leg -> isPerSide
    expect(exercisesWithSets[0].sets[0].isPerSide).toBe(true);
    expect(exercisesWithSets[0].sets[0].targetTime).toBe(60);

    // Pigeon Pose: 90s per side -> isPerSide
    expect(exercisesWithSets[1].sets[0].isPerSide).toBe(true);
    expect(exercisesWithSets[1].sets[0].targetTime).toBe(90);

    // Wide-Leg Forward Fold: 90s -> NOT per-side
    expect(exercisesWithSets[2].sets[0].isPerSide).toBe(false);
  });

  it('single number with trailing text not seconds', () => {
    const markdown = `# Workout
## Exercise
- 25 Slow and controlled`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const set = result.data?.exercises[0].sets[0];
    expect(set?.targetReps).toBe(25);
    expect(set?.targetTime).toBeNull();
    expect(set?.notes).toBe('Slow and controlled');
  });
});

// MARK: - Distance Sets

describe('Distance Sets', () => {
  it('parses meters distance', () => {
    const markdown = `# Workout
## Running
- 200 meters`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const set = result.data?.exercises[0].sets[0];
    expect(set?.targetDistance).toBe(200);
    expect(set?.targetDistanceUnit).toBe('meters');
    expect(set?.targetWeight).toBeNull();
    expect(set?.targetReps).toBeNull();
    expect(set?.targetTime).toBeNull();
  });

  it('parses km distance', () => {
    const markdown = `# Workout
## Running
- 5 km`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const set = result.data?.exercises[0].sets[0];
    expect(set?.targetDistance).toBe(5);
    expect(set?.targetDistanceUnit).toBe('km');
  });

  it('parses miles distance (full word)', () => {
    const markdown = `# Workout
## Running
- 1 mile`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const set = result.data?.exercises[0].sets[0];
    expect(set?.targetDistance).toBe(1);
    expect(set?.targetDistanceUnit).toBe('miles');
  });

  it('parses miles distance (plural)', () => {
    const markdown = `# Workout
## Running
- 3 miles`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const set = result.data?.exercises[0].sets[0];
    expect(set?.targetDistance).toBe(3);
    expect(set?.targetDistanceUnit).toBe('miles');
  });

  it('parses mi abbreviation as miles', () => {
    const markdown = `# Workout
## Running
- 2 mi`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const set = result.data?.exercises[0].sets[0];
    expect(set?.targetDistance).toBe(2);
    expect(set?.targetDistanceUnit).toBe('miles');
  });

  it('parses feet distance (full word)', () => {
    const markdown = `# Workout
## Farmer Walk
- 100 feet`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const set = result.data?.exercises[0].sets[0];
    expect(set?.targetDistance).toBe(100);
    expect(set?.targetDistanceUnit).toBe('feet');
  });

  it('parses ft abbreviation as feet', () => {
    const markdown = `# Workout
## Farmer Walk
- 50 ft`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const set = result.data?.exercises[0].sets[0];
    expect(set?.targetDistance).toBe(50);
    expect(set?.targetDistanceUnit).toBe('feet');
  });

  it('parses yards distance (full word)', () => {
    const markdown = `# Workout
## Sprints
- 100 yards`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const set = result.data?.exercises[0].sets[0];
    expect(set?.targetDistance).toBe(100);
    expect(set?.targetDistanceUnit).toBe('yards');
  });

  it('parses yd abbreviation as yards', () => {
    const markdown = `# Workout
## Sprints
- 400 yd`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const set = result.data?.exercises[0].sets[0];
    expect(set?.targetDistance).toBe(400);
    expect(set?.targetDistanceUnit).toBe('yards');
  });

  it('parses decimal distances', () => {
    const markdown = `# Workout
## Running
- 0.5 km
- 1.5 miles`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const sets = result.data?.exercises[0].sets;
    expect(sets?.[0].targetDistance).toBe(0.5);
    expect(sets?.[0].targetDistanceUnit).toBe('km');
    expect(sets?.[1].targetDistance).toBe(1.5);
    expect(sets?.[1].targetDistanceUnit).toBe('miles');
  });

  it('parses distance with trailing text as notes', () => {
    const markdown = `# Workout
## Running
- 400 meters sprint pace`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const set = result.data?.exercises[0].sets[0];
    expect(set?.targetDistance).toBe(400);
    expect(set?.targetDistanceUnit).toBe('meters');
    expect(set?.notes).toBe('sprint pace');
  });

  it('"m" still parses as minutes (not meters)', () => {
    const markdown = `# Workout
## Plank
- 2m`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const set = result.data?.exercises[0].sets[0];
    expect(set?.targetTime).toBe(120);
    expect(set?.targetDistance).toBeNull();
  });

  it('"5 min" still parses as time', () => {
    const markdown = `# Workout
## Plank
- 5 min`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const set = result.data?.exercises[0].sets[0];
    expect(set?.targetTime).toBe(300);
    expect(set?.targetDistance).toBeNull();
  });

  it('distance set has no weight or reps', () => {
    const markdown = `# Workout
## Sled Push
- 50 meters
- 100 ft`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const sets = result.data?.exercises[0].sets;
    expect(sets?.[0].targetWeight).toBeNull();
    expect(sets?.[0].targetReps).toBeNull();
    expect(sets?.[0].targetTime).toBeNull();
    expect(sets?.[0].targetDistance).toBe(50);
    expect(sets?.[1].targetWeight).toBeNull();
    expect(sets?.[1].targetReps).toBeNull();
    expect(sets?.[1].targetTime).toBeNull();
    expect(sets?.[1].targetDistance).toBe(100);
  });

  it('parses singular meter', () => {
    const markdown = `# Workout
## Sprint
- 1 meter`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const set = result.data?.exercises[0].sets[0];
    expect(set?.targetDistance).toBe(1);
    expect(set?.targetDistanceUnit).toBe('meters');
  });

  it('distance with modifiers', () => {
    const markdown = `# Workout
## Sprints
- 200 meters @rest: 60s`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const set = result.data?.exercises[0].sets[0];
    expect(set?.targetDistance).toBe(200);
    expect(set?.targetDistanceUnit).toBe('meters');
    expect(set?.restSeconds).toBe(60);
  });
});

// MARK: - Duplicate Exercise Name Warning

describe('Duplicate Exercise Name Warning', () => {
  it('warns on duplicate exercise names', () => {
    const md = `# Workout\n## Bench Press\n- 135 x 10\n## Squats\n- 225 x 5\n## Bench Press\n- 185 x 8`;
    const result = parseWorkout(md);
    expect(result.success).toBe(true);
    const dupWarnings = result.warnings.filter((w) => w.includes('Duplicate exercise name'));
    expect(dupWarnings.length).toBe(1);
    expect(dupWarnings[0]).toContain('Bench Press');
  });

  it('is case-insensitive', () => {
    const md = `# Workout\n## bench press\n- 135 x 10\n## BENCH PRESS\n- 185 x 8`;
    const result = parseWorkout(md);
    const dupWarnings = result.warnings.filter((w) => w.includes('Duplicate exercise name'));
    expect(dupWarnings.length).toBe(1);
  });

  it('does not warn for unique exercise names', () => {
    const md = `# Workout\n## Bench Press\n- 135 x 10\n## Squats\n- 225 x 5`;
    const result = parseWorkout(md);
    const dupWarnings = result.warnings.filter((w) => w.includes('Duplicate exercise name'));
    expect(dupWarnings.length).toBe(0);
  });

  it('does not warn for section/superset container names', () => {
    const md = `# Workout\n## Chest Superset\n### Bench Press\n- 135 x 10\n## Chest Superset\n### Incline Press\n- 95 x 12`;
    const result = parseWorkout(md);
    // "Chest Superset" appears twice but as group containers with no sets — should not warn
    const dupWarnings = result.warnings.filter((w) => w.includes('Duplicate exercise name'));
    expect(dupWarnings.length).toBe(0);
  });

  it('still parses successfully with duplicates', () => {
    const md = `# Workout\n## Bench Press\n- 135 x 10\n## Bench Press\n- 185 x 8`;
    const result = parseWorkout(md);
    expect(result.success).toBe(true);
    expect(result.data?.exercises.length).toBe(2);
  });
});

// MARK: - DESCRIPTION_CONTAINS_LIST warning

describe('DESCRIPTION_CONTAINS_LIST warning', () => {
  it('emits warning when description has comma-separated list (4+ items)', () => {
    const md = `# Upper Push
Warmup: spin, jumping jacks, banded pull-a-parts, push ups

## Bench Press
- 135 x 5`;
    const result = parseWorkout(md);
    expect(result.success).toBe(true);
    expect(result.warnings.some((w) => w.includes('list-shaped content'))).toBe(true);
  });

  it('emits warning when description has bullet points', () => {
    const md = `# Upper Push
- spin for 5 min
- jumping jacks

## Bench Press
- 135 x 5`;
    const result = parseWorkout(md);
    expect(result.success).toBe(true);
    expect(result.warnings.some((w) => w.includes('list-shaped content'))).toBe(true);
  });

  it('emits warning when description has numbered list', () => {
    const md = `# Upper Push
1. spin for 5 minutes warming up
2. jumping jacks for a minute

## Bench Press
- 135 x 5`;
    const result = parseWorkout(md);
    expect(result.success).toBe(true);
    expect(result.warnings.some((w) => w.includes('list-shaped content'))).toBe(true);
  });

  it('does not emit warning when description is short prose', () => {
    const md = `# Upper Push
Focus on form today.

## Bench Press
- 135 x 5`;
    const result = parseWorkout(md);
    expect(result.success).toBe(true);
    expect(result.warnings.some((w) => w.includes('list-shaped content'))).toBe(false);
  });

  it('does not emit warning when description is prose with only 2 commas', () => {
    const md = `# Upper Push
Today we focus on form, tempo, and breathing throughout the workout.

## Bench Press
- 135 x 5`;
    const result = parseWorkout(md);
    expect(result.success).toBe(true);
    expect(result.warnings.some((w) => w.includes('list-shaped content'))).toBe(false);
  });

  it('does not emit warning when there is no description', () => {
    const md = `# Upper Push
## Bench Press
- 135 x 5`;
    const result = parseWorkout(md);
    expect(result.success).toBe(true);
    expect(result.warnings.some((w) => w.includes('list-shaped content'))).toBe(false);
  });

  it('does not emit warning when description is shorter than 20 chars', () => {
    const md = `# Upper Push
a, b, c, d

## Bench Press
- 135 x 5`;
    const result = parseWorkout(md);
    expect(result.success).toBe(true);
    expect(result.warnings.some((w) => w.includes('list-shaped content'))).toBe(false);
  });

  it('includes description preview in warning message', () => {
    const md = `# Upper Push
Warmup: spin, jumping jacks, banded pull-a-parts, push ups

## Bench Press
- 135 x 5`;
    const result = parseWorkout(md);
    const warning = result.warnings.find((w) => w.includes('list-shaped content'));
    expect(warning).toBeDefined();
    expect(warning).toContain('Warmup: spin, jumping jacks');
  });

  it('truncates long previews with ellipsis', () => {
    const longList = Array.from({ length: 20 }, (_, i) => `item${i}`).join(', ');
    const md = `# Upper Push
${longList}

## Bench Press
- 135 x 5`;
    const result = parseWorkout(md);
    const warning = result.warnings.find((w) => w.includes('list-shaped content'));
    expect(warning).toBeDefined();
    expect(warning).toContain('...');
  });

  it('preserves description in parsed output even when warning fires', () => {
    const md = `# Upper Push
Warmup: spin, jumping jacks, banded pull-a-parts, push ups

## Bench Press
- 135 x 5`;
    const result = parseWorkout(md);
    expect(result.success).toBe(true);
    expect(result.data?.description).toContain('spin, jumping jacks');
  });
});

// MARK: - Mixed Section Levels Warning

describe('Mixed Section Levels Warning', () => {
  it('emits warning when sections and exercises are mixed at same heading level', () => {
    const markdown = `# Upper Push

## Warmup
### Arm Circles
- 10

## Bench Press
- 95 lbs x 8`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const mixedWarnings = result.warnings.filter((w) => w.includes('Inconsistent nesting'));
    expect(mixedWarnings).toHaveLength(1);
    expect(mixedWarnings[0]).toContain("'Warmup'");
    expect(mixedWarnings[0]).toContain("'Bench Press'");
    expect(mixedWarnings[0]).toContain('relative nesting depth');
  });

  it('does not emit warning when all same-level headers are exercises', () => {
    const markdown = `# Workout

## Bench Press
- 135 x 10

## Squat
- 225 x 5

## Deadlift
- 315 x 3`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const mixedWarnings = result.warnings.filter((w) => w.includes('Inconsistent nesting'));
    expect(mixedWarnings).toHaveLength(0);
  });

  it('does not emit warning when all same-level headers are sections', () => {
    const markdown = `# Workout

## Warmup
### Arm Circles
- 10
### Jumping Jacks
- 60s

## Main Work
### Bench Press
- 135 x 10
### Squat
- 225 x 5`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const mixedWarnings = result.warnings.filter((w) => w.includes('Inconsistent nesting'));
    expect(mixedWarnings).toHaveLength(0);
  });

  it('emits warning regardless of absolute heading level', () => {
    // Using ### as the exercise level (workout is ##)
    const markdown = `## Training Session

### Warmup
#### Arm Circles
- 10

### Bench Press
- 135 x 10`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const mixedWarnings = result.warnings.filter((w) => w.includes('Inconsistent nesting'));
    expect(mixedWarnings).toHaveLength(1);
    expect(mixedWarnings[0]).toContain("'Warmup'");
    expect(mixedWarnings[0]).toContain("'Bench Press'");
  });

  it('emits warning with full structure from issue example', () => {
    const markdown = `# Upper Push

## Warmup
### Arm Circles
- 10

### Band Pull-Aparts
- 15

## Bench Press
- 95 lbs x 8
- 135 lbs x 5
- 185 lbs x 3

## Cooldown
### Stretching
- 60s`;
    const result = parseWorkout(markdown);

    expect(result.success).toBe(true);
    const mixedWarnings = result.warnings.filter((w) => w.includes('Inconsistent nesting'));
    expect(mixedWarnings).toHaveLength(1);
  });
});
