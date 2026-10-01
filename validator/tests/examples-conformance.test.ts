import { describe, it, expect } from 'vitest';
import { readdirSync, readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseWorkout } from '../src/parser/index.js';

// Runs the shared LMWF example corpus (also consumed by the iOS
// ParserConformanceTests) through the validator parser.
const EXAMPLES = resolve(dirname(fileURLToPath(import.meta.url)), '../../liftmark-workout-format/examples');

function files(dir: string): string[] {
  return readdirSync(resolve(EXAMPLES, dir))
    .filter((f) => f.endsWith('.md'))
    .sort();
}

function parse(dir: string, file: string) {
  return parseWorkout(readFileSync(resolve(EXAMPLES, dir, file), 'utf8'));
}

describe('LMWF example conformance', () => {
  it.each(files('valid'))('valid/%s parses successfully', (file) => {
    expect(parse('valid', file).errors).toEqual([]);
  });

  it.each(files('errors'))('errors/%s fails validation', (file) => {
    expect(parse('errors', file).success).toBe(false);
  });

  it.each(files('warnings'))('warnings/%s parses successfully with warnings', (file) => {
    const result = parse('warnings', file);
    expect(result.errors).toEqual([]);
    expect(result.warnings.length).toBeGreaterThan(0);
  });
});

describe('exercise-level default rest example (spec TC-V35)', () => {
  it('expands the default into sets, set-level overrides, drop sets excluded', () => {
    const result = parse('valid', 'tc-exercise-default-rest.md');
    expect(result.warnings.filter((w) => w.includes('on its own line'))).toEqual([]);
    const rests = Object.fromEntries(
      result.data!.exercises.filter((e) => e.sets.length > 0).map((e) => [e.exerciseName, e.sets.map((s) => s.restSeconds)])
    );
    expect(rests).toEqual({
      'Bench Press': [90, 180, 180],
      'Bicep Curl': [60, null, null],
      'Hammer Curl': [30, 30],
      'Tricep Kickback': [90, 90],
    });
  });
});

describe('warning examples emit the documented warnings (spec TC-W01..W03)', () => {
  const lines = (warnings: string[], marker: string) =>
    warnings.filter((w) => w.includes(marker)).map((w) => Number(/^Line (\d+):/.exec(w)![1]));
  const STANDALONE = 'on its own line and has no effect';
  const IGNORED = 'Line ignored';

  it('TC-W01 workout-, superset- and post-first-set @rest warn; exercise-level default does not', () => {
    const result = parse('warnings', 'tc-misplaced-default-rest.md');
    expect(lines(result.warnings, STANDALONE)).toEqual([2, 5, 18]);
    const rests = result.data!.exercises.filter((e) => e.sets.length > 0).map((e) => e.sets.map((s) => s.restSeconds));
    expect(rests).toEqual([[60, 60], [null, null], [null, null]]);
  });

  it('TC-W02 standalone modifiers at every level', () => {
    const result = parse('warnings', 'tc-standalone-modifiers-everywhere.md');
    expect(lines(result.warnings, STANDALONE)).toEqual([2, 5, 9, 18]);
    expect(lines(result.warnings, IGNORED)).toEqual([]);
    for (const ex of result.data!.exercises) {
      for (const s of ex.sets) {
        expect(s.restSeconds).toBeNull();
        expect(s.isDropset).toBe(false);
      }
    }
  });

  it('TC-W03 text after the first set is ignored', () => {
    const result = parse('warnings', 'tc-text-after-sets-ignored.md');
    expect(lines(result.warnings, IGNORED)).toEqual([6]);
    expect(result.data!.exercises[0].sets).toHaveLength(3);
  });
});
